const std = @import("std");

const State = @This();
const log = std.log.scoped(.transfer);

pub const Epoch = u32;

pub const Phase = enum {
    dialing,
    logging_in,
    joining,
    preparing_client,
    syncing_client,
    closing_source,

    pub fn committed(self: Phase) bool {
        return @backingInt(self) >= @backingInt(Phase.syncing_client);
    }
};

pub const Event = enum {
    dialed,
    logged_in,
    target_ready,
    client_prepared,
    client_synced,
    source_closed,
    target_failed,
    source_failed,
    expired,
    player_left,
    shutdown,
};

pub const Action = enum {
    none,
    stale,
    prepare_client,
    commit,
    close_source,
    finish,
    roll_back,
    disconnect,
    abandon,
};

pub const Outcome = enum { committed, failed_before_commit, failed_after_commit, timed_out };

pub const Step = struct {
    action: Action,
    outcome: ?Outcome = null,
};

pub const Limits = struct {
    dial_ms: u32,
    phase_ms: u32,
    total_ms: u32,
};

epoch: Epoch,
phase: Phase = .dialing,
limits: Limits,
phase_deadline_ns: u64,
deadline_ns: u64,

pub fn init(epoch: Epoch, limits: Limits, now_ns: u64) State {
    return .{
        .epoch = epoch,
        .limits = limits,
        .phase_deadline_ns = now_ns + ms(limits.dial_ms) + ms(limits.phase_ms),
        .deadline_ns = now_ns + ms(limits.total_ms),
    };
}

pub fn nextDeadline(self: *const State) u64 {
    return @min(self.phase_deadline_ns, self.deadline_ns);
}

pub fn expired(self: *const State, now_ns: u64) bool {
    return now_ns >= self.nextDeadline();
}

pub fn applyFrom(self: *State, epoch: Epoch, event: Event, now_ns: u64) Step {
    if (epoch != self.epoch) return .{ .action = .stale };
    return self.apply(event, now_ns);
}

pub fn apply(self: *State, event: Event, now_ns: u64) Step {
    const from = self.phase;
    const step = self.decide(event, now_ns);
    log.debug("transfer {d}: {t} in {t} -> {t} ({t})", .{ self.epoch, event, from, self.phase, step.action });
    return step;
}

fn decide(self: *State, event: Event, now_ns: u64) Step {
    const committed = self.phase.committed();
    switch (event) {
        .player_left, .shutdown => return .{
            .action = .abandon,
            .outcome = if (committed) .failed_after_commit else .failed_before_commit,
        },
        .expired => return .{
            .action = if (committed) .disconnect else .roll_back,
            .outcome = .timed_out,
        },
        .target_failed => return if (committed)
            .{ .action = .disconnect, .outcome = .failed_after_commit }
        else
            .{ .action = .roll_back, .outcome = .failed_before_commit },
        .source_failed => return switch (self.phase) {
            .syncing_client => .{ .action = .none },
            .closing_source => finished,
            else => .{ .action = .disconnect, .outcome = .failed_before_commit },
        },
        else => {},
    }
    const expected: Event, const next: ?Phase, const action: Action = switch (self.phase) {
        .dialing => .{ .dialed, .logging_in, .none },
        .logging_in => .{ .logged_in, .joining, .none },
        .joining => .{ .target_ready, .preparing_client, .prepare_client },
        .preparing_client => .{ .client_prepared, .syncing_client, .commit },
        .syncing_client => .{ .client_synced, .closing_source, .close_source },
        .closing_source => .{ .source_closed, null, .finish },
    };
    if (event != expected) return self.decide(.target_failed, now_ns);
    const phase = next orelse return finished;
    self.phase = phase;
    self.phase_deadline_ns = now_ns + ms(self.limits.phase_ms);
    return .{ .action = action };
}

const finished: Step = .{ .action = .finish, .outcome = .committed };

fn ms(value: u32) u64 {
    return @as(u64, value) * std.time.ns_per_ms;
}

const test_limits: Limits = .{ .dial_ms = 100, .phase_ms = 50, .total_ms = 1_000 };
const happy_path = [_]Event{ .dialed, .logged_in, .target_ready, .client_prepared, .client_synced, .source_closed };

fn at(phase: Phase) State {
    var state: State = .init(1, test_limits, 0);
    for (happy_path[0..@backingInt(phase)]) |event| _ = state.apply(event, 0);
    std.debug.assert(state.phase == phase);
    return state;
}

test "the happy path walks every phase and commits once" {
    var state: State = .init(1, test_limits, 0);
    const actions = [_]Action{ .none, .none, .prepare_client, .commit, .close_source, .finish };
    for (happy_path, actions) |event, action| {
        const step = state.apply(event, 0);
        try std.testing.expectEqual(action, step.action);
        try std.testing.expectEqual(if (action == .finish) @as(?Outcome, .committed) else null, step.outcome);
    }
}

test "every failure has one outcome in every phase" {
    for (std.enums.values(Phase)) |phase| {
        const committed = phase.committed();
        var state = at(phase);
        try std.testing.expectEqual(Step{
            .action = if (committed) .disconnect else .roll_back,
            .outcome = if (committed) .failed_after_commit else .failed_before_commit,
        }, state.apply(.target_failed, 0));
        state = at(phase);
        try std.testing.expectEqual(Step{ .action = if (committed) .disconnect else .roll_back, .outcome = .timed_out }, state.apply(.expired, 0));
        for ([_]Event{ .player_left, .shutdown }) |event| {
            state = at(phase);
            try std.testing.expectEqual(Step{
                .action = .abandon,
                .outcome = if (committed) .failed_after_commit else .failed_before_commit,
            }, state.apply(event, 0));
        }
        state = at(phase);
        const expected: Step = switch (phase) {
            .syncing_client => .{ .action = .none },
            .closing_source => .{ .action = .finish, .outcome = .committed },
            else => .{ .action = .disconnect, .outcome = .failed_before_commit },
        };
        try std.testing.expectEqual(expected, state.apply(.source_failed, 0));
    }
}

test "out of order events count as a failed target" {
    for (std.enums.values(Phase)) |phase| {
        for (happy_path) |event| {
            if (event == happy_path[@backingInt(phase)]) continue;
            var state = at(phase);
            const step = state.apply(event, 0);
            try std.testing.expectEqual(if (phase.committed()) Action.disconnect else Action.roll_back, step.action);
        }
    }
}

test "events from an older transfer are ignored" {
    var state: State = .init(2, test_limits, 0);
    try std.testing.expectEqual(Action.stale, state.applyFrom(1, .dialed, 0).action);
    try std.testing.expectEqual(Phase.dialing, state.phase);
    try std.testing.expectEqual(Action.none, state.applyFrom(2, .dialed, 0).action);
    try std.testing.expectEqual(Phase.logging_in, state.phase);
}

test "each phase gets its own deadline under the overall one" {
    var state: State = .init(1, test_limits, 0);
    try std.testing.expectEqual(@as(u64, 150 * std.time.ns_per_ms), state.nextDeadline());
    _ = state.apply(.dialed, 90 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u64, 140 * std.time.ns_per_ms), state.nextDeadline());
    try std.testing.expect(!state.expired(139 * std.time.ns_per_ms));
    try std.testing.expect(state.expired(140 * std.time.ns_per_ms));

    state = .init(1, .{ .dial_ms = 100, .phase_ms = 500, .total_ms = 200 }, 0);
    _ = state.apply(.dialed, 50 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u64, 200 * std.time.ns_per_ms), state.nextDeadline());
}

test "random event streams never move backwards or report an outcome for the wrong side of the commit" {
    var prng: std.Random.DefaultPrng = .init(0x7a5f);
    const events = std.enums.values(Event);
    for (0..20_000) |_| {
        const random = prng.random();
        var state: State = .init(1, .{ .dial_ms = 10, .phase_ms = 10, .total_ms = 100 }, 0);
        for (0..32) |_| {
            const before = state.phase;
            const step = state.apply(events[random.uintLessThan(usize, events.len)], random.uintAtMost(u64, 200 * std.time.ns_per_ms));
            try std.testing.expect(@backingInt(state.phase) >= @backingInt(before));
            if (step.outcome) |outcome| switch (outcome) {
                .committed, .failed_after_commit => try std.testing.expect(before.committed()),
                .failed_before_commit => try std.testing.expect(!before.committed()),
                .timed_out => {},
            };
            switch (step.action) {
                .roll_back => try std.testing.expect(!before.committed()),
                .finish, .disconnect, .abandon => {},
                else => continue,
            }
            try std.testing.expect(step.outcome != null);
            break;
        }
    }
}
