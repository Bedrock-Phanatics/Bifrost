const std = @import("std");
const raknet = @import("raknet");
const bedwire = @import("bedwire");
const Backend = @import("../backend/Backend.zig");
const Dial = @import("../backend/Dial.zig");
const Notify = @import("../net/Notify.zig");
const Watch = @import("../net/watch.zig").Watch;
const no_wait = @import("../net/watch.zig").no_wait;
const Managed = @import("../session/Managed.zig");
const Upstream = Managed.Upstream;
const Stats = @import("../proxy/Stats.zig");
pub const State = @import("State.zig");

const Transfer = @This();
const log = std.log.scoped(.transfer);

const max_polls_per_turn = 4;
const max_queued_packets = 256;

pub const Host = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    stats: *Stats,
    managed: *Managed,
    player: *raknet.Session,
    notify: Notify,
    backend: *?*raknet.Client,
    backend_watch: *Watch(raknet.Client),

    fn ends(self: Host) Managed.Ends {
        return .{ .io = self.io, .stats = self.stats, .player = self.player, .backend = self.backend.* };
    }
};

pub const Result = enum { running, finished, rolled_back, disconnect, abandoned };

const Queue = struct {
    bytes: std.ArrayList(u8) = .empty,
    lengths: std.ArrayList(u32) = .empty,
    max_packets: usize,
    max_bytes: usize,

    fn push(self: *Queue, gpa: std.mem.Allocator, packet: []const u8) !void {
        if (self.lengths.items.len == self.max_packets or packet.len > self.max_bytes - self.bytes.items.len) return error.QueueFull;
        try self.lengths.ensureUnusedCapacity(gpa, 1);
        try self.bytes.appendSlice(gpa, packet);
        self.lengths.appendAssumeCapacity(@intCast(packet.len));
    }

    fn slices(self: *const Queue, out: [][]const u8) []const []const u8 {
        var offset: usize = 0;
        for (self.lengths.items, out[0..self.lengths.items.len]) |len, *slice| {
            slice.* = self.bytes.items[offset..][0..len];
            offset += len;
        }
        return out[0..self.lengths.items.len];
    }

    fn deinit(self: *Queue, gpa: std.mem.Allocator) void {
        self.bytes.deinit(gpa);
        self.lengths.deinit(gpa);
    }
};

const Seen = packed struct {
    logged_in: bool = false,
    joined: bool = false,
    failed: bool = false,
};

state: State,
target: Backend.Id,
dial: Dial = .{},
dial_task: ?std.Io.Future(void) = null,
client: ?*raknet.Client = null,
upstream: Upstream,
watch: Watch(raknet.Client) = .{},
timer: ?std.Io.Future(void) = null,
timer_fired: std.atomic.Value(bool) = .init(false),
queue: Queue,
source: ?*raknet.Client = null,
seen: Seen = .{},
result: Result = .running,
host: ?Host = null,

pub fn create(host: Host, target: Backend.Id, address: std.Io.net.IpAddress, epoch: State.Epoch, limits: State.Limits, queue_packets: u32, queue_bytes: u32) !*Transfer {
    const self = try host.gpa.create(Transfer);
    errdefer host.gpa.destroy(self);
    self.* = .{
        .state = .init(epoch, limits, now(host.io)),
        .target = target,
        .upstream = try .init(host.managed.shared),
        .queue = .{ .max_packets = @min(queue_packets, max_queued_packets), .max_bytes = queue_bytes },
    };
    errdefer self.upstream.deinit();
    const options: raknet.ClientOptions = .{ .handshake_timeout_ms = limits.dial_ms };
    self.dial_task = try host.io.concurrent(Dial.run, .{ &self.dial, host.gpa, host.io, address, options, host.notify });
    errdefer self.cancelTasks(host.io);
    try self.armTimer(host);
    host.stats.bump(.transfers_started, 1);
    log.info("transfer {d} to backend {d} started", .{ epoch, target.index() });
    return self;
}

pub fn destroy(self: *Transfer, gpa: std.mem.Allocator, io: std.Io) void {
    self.cancelTasks(io);
    if (self.client) |client| client.destroy();
    if (self.source) |source| source.destroy();
    self.upstream.deinit();
    self.queue.deinit(gpa);
    gpa.destroy(self);
}

pub fn end(self: *Transfer, io: std.Io, stats: *Stats, event: State.Event) void {
    if (self.result != .running) return;
    record(stats, self.state.apply(event, now(io)));
    self.result = .abandoned;
}

pub fn service(self: *Transfer, host: Host) error{Canceled}!Result {
    if (self.dial_task) |*task| if (self.dial.finished()) |result| {
        task.await(host.io);
        self.dial_task = null;
        if (result) |client| {
            self.client = client;
            self.on(host, .dialed);
            if (self.result == .running) self.upstream.connected(self.context(host)) catch self.on(host, .target_failed);
        } else |err| {
            log.info("transfer {d}: dial failed: {t}", .{ self.state.epoch, err });
            self.on(host, .target_failed);
        }
    };
    if (self.result != .running) return self.result;
    if (self.timer_fired.swap(false, .acquire)) {
        if (self.state.expired(now(host.io))) self.on(host, .expired) else self.armTimer(host) catch self.on(host, .target_failed);
    }
    if (self.result != .running) return self.result;

    _ = self.watch.take(host.io);
    const client = self.client orelse return self.result;
    self.host = host;
    defer self.host = null;
    var drained = false;
    for (0..max_polls_per_turn) |_| {
        _ = client.poll(no_wait, self, onTargetMessage) catch |err| switch (err) {
            error.Timeout => {
                drained = true;
                break;
            },
            error.Canceled => return error.Canceled,
            else => self.seen.failed = true,
        };
        if (self.seen.failed) break;
    }
    if (client.isClosed()) self.seen.failed = true;
    self.settle(host);
    if (self.result != .running or self.client == null) return self.result;
    self.watch.arm(host.io, client, host.notify) catch self.on(host, .target_failed);
    if (!drained) host.notify.send();
    return self.result;
}

fn settle(self: *Transfer, host: Host) void {
    if (self.seen.failed) return self.on(host, .target_failed);
    if (self.seen.logged_in and self.state.phase == .logging_in) self.on(host, .logged_in);
    if (self.seen.joined and self.state.phase == .joining) self.on(host, .target_ready);
}

fn onTargetMessage(opaque_self: *anyopaque, payload: raknet.BorrowedPayload) error{ApplicationFailure}!void {
    const self: *Transfer = @ptrCast(@alignCast(opaque_self));
    self.receive(self.host.?, payload.bytes) catch |err| {
        log.info("transfer {d}: target failed: {t}", .{ self.state.epoch, err });
        self.seen.failed = true;
        return error.ApplicationFailure;
    };
}

fn receive(self: *Transfer, host: Host, frame: []const u8) !void {
    var packets = try self.upstream.session.ingest(frame);
    defer packets.deinit();
    const ctx = self.context(host);
    if (self.upstream.phase != .ready) {
        const packet = packets.next() orelse return error.MalformedBatch;
        switch (try self.upstream.receive(ctx, packet)) {
            .wants_login => try host.managed.loginUpstream(&self.upstream, ctx),
            .logged_in => self.seen.logged_in = true,
        }
        return;
    }
    var buffer: [64]u8 = undefined;
    while (packets.next()) |packet| {
        if (self.seen.joined) {
            try self.queue.push(host.gpa, packet.bytes);
            continue;
        }
        switch (packet.kind orelse continue) {
            .resource_packs_info => try self.upstream.send(ctx, &.{try Managed.encodeTyped(&buffer, .{ .resource_pack_client_response = .{ .response = .{ .downloading_finished = "" } } })}),
            .resource_pack_stack => {
                try self.upstream.send(ctx, &.{try Managed.encodeTyped(&buffer, .{ .resource_pack_client_response = .{ .response = .{ .resource_pack_stack_finished = "" } } })});
                try self.upstream.session.advance(.waiting_for_start_game);
            },
            .start_game => {
                self.seen.joined = true;
                try self.queue.push(host.gpa, packet.bytes);
            },
            .disconnect => return error.BackendRefused,
            else => {},
        }
    }
    if (self.seen.joined and self.upstream.session.state == .waiting_for_start_game) try self.upstream.session.advance(.spawn_ready);
}

fn on(self: *Transfer, host: Host, event: State.Event) void {
    const phase = self.state.phase;
    const step = self.state.apply(event, now(host.io));
    record(host.stats, step);
    switch (step.action) {
        .none, .stale => {},
        .prepare_client => return self.on(host, .client_prepared),
        .commit => {
            self.commit(host) catch |err| {
                log.info("transfer {d}: commit failed: {t}", .{ self.state.epoch, err });
                return self.on(host, .target_failed);
            };
            return self.on(host, .client_synced);
        },
        .close_source => {
            if (self.source) |source| source.destroy();
            self.source = null;
            return self.on(host, .source_closed);
        },
        .finish => {
            log.info("transfer {d} to backend {d} committed", .{ self.state.epoch, self.target.index() });
            self.result = .finished;
        },
        .roll_back => {
            log.info("transfer {d} rolled back in {t}", .{ self.state.epoch, phase });
            self.result = .rolled_back;
        },
        .disconnect => self.result = .disconnect,
        .abandon => self.result = .abandoned,
    }
    if (self.result == .running and self.state.phase != phase) self.armTimer(host) catch self.on(host, .target_failed);
}

fn commit(self: *Transfer, host: Host) !void {
    const managed = host.managed;
    self.watch.cancel(host.io);
    host.backend_watch.cancel(host.io);
    self.source = host.backend.*;
    host.backend.* = self.client;
    self.client = null;
    self.upstream = managed.swapUpstream(self.upstream);
    var slices: [max_queued_packets][]const u8 = undefined;
    const skipped = try managed.deliver(host.ends(), self.queue.slices(&slices));
    if (skipped != 0) log.debug("transfer {d}: held back {d} world packets for client sync", .{ self.state.epoch, skipped });
    self.queue.bytes.clearRetainingCapacity();
    self.queue.lengths.clearRetainingCapacity();
    if (managed.upstream.session.state == .spawn_ready) try managed.upstream.session.advance(.in_game);
}

fn record(stats: *Stats, step: State.Step) void {
    const outcome = step.outcome orelse return;
    switch (outcome) {
        .committed => stats.bump(.transfers_committed, 1),
        .failed_before_commit => stats.bump(.transfers_failed_before_commit, 1),
        .failed_after_commit => stats.bump(.transfers_failed_after_commit, 1),
        .timed_out => stats.bump(.transfers_timed_out, 1),
    }
}

fn context(self: *Transfer, host: Host) Upstream.Context {
    return host.managed.upstreamContext(host.ends(), self.client.?);
}

fn armTimer(self: *Transfer, host: Host) !void {
    if (self.timer) |*timer| timer.cancel(host.io);
    self.timer = null;
    self.timer_fired.store(false, .monotonic);
    self.timer = try host.io.concurrent(wake, .{ host.io, self.state.nextDeadline(), &self.timer_fired, host.notify });
}

fn wake(io: std.Io, deadline_ns: u64, fired: *std.atomic.Value(bool), notify: Notify) void {
    io.sleep(.fromNanoseconds(deadline_ns -| now(io)), .awake) catch return;
    fired.store(true, .release);
    notify.send();
}

fn cancelTasks(self: *Transfer, io: std.Io) void {
    if (self.timer) |*timer| timer.cancel(io);
    self.timer = null;
    self.watch.cancel(io);
    var task = self.dial_task orelse return;
    self.dial_task = null;
    task.cancel(io);
    if (self.dial.finished()) |result| {
        if (result) |client| client.destroy() else |_| {}
    }
}

fn now(io: std.Io) u64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}
