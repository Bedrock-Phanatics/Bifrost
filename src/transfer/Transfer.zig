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
const content = @import("../content/policy.zig");
const packs = @import("../content/packs.zig");
const registries = @import("../content/registries.zig");
pub const State = @import("State.zig");
const Queue = @import("Queue.zig");
const Handoff = @import("Handoff.zig");

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

pub const Settings = struct {
    limits: State.Limits,
    queue_packets: u32,
    queue_bytes: u32,
    content_policy: content.Policy = .initial,
};

const Seen = packed struct {
    logged_in: bool = false,
    started: bool = false,
    spawned: bool = false,
    world: bool = false,
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
outcome: ?State.Outcome = null,
content_policy: content.Policy,
target_packs: packs.Fingerprint = .{},
target_registries: registries.Fingerprint = .{},
target_spawn: ?Handoff.Target = null,
target_runtime_id: u64 = 0,
handoff: ?Handoff = null,
managed: *Managed,
mismatch: ?content.Mismatch = null,
host: ?Host = null,

pub fn create(host: Host, target: Backend.Id, address: std.Io.net.IpAddress, epoch: State.Epoch, settings: Settings) !*Transfer {
    const self = try host.gpa.create(Transfer);
    errdefer host.gpa.destroy(self);
    self.* = .{
        .state = .init(epoch, settings.limits, now(host.io)),
        .target = target,
        .upstream = try .init(host.managed.shared),
        .queue = .{ .max_packets = @min(settings.queue_packets, max_queued_packets), .max_bytes = settings.queue_bytes },
        .content_policy = settings.content_policy,
        .managed = host.managed,
    };
    errdefer self.upstream.deinit();
    const options: raknet.ClientOptions = .{ .handshake_timeout_ms = settings.limits.dial_ms };
    self.dial_task = try host.io.concurrent(Dial.run, .{ &self.dial, host.gpa, host.io, address, options, host.notify });
    errdefer self.cancelTasks(host.io);
    try self.armTimer(host);
    host.stats.bump(.transfers_started, 1);
    log.info("transfer {d} to backend {d} started", .{ epoch, target.index() });
    return self;
}

pub fn destroy(self: *Transfer, gpa: std.mem.Allocator, io: std.Io) void {
    if (self.managed.hold == &self.queue) self.managed.hold = null;
    if (self.handoff != null) self.managed.syncing = false;
    self.cancelTasks(io);
    if (self.client) |client| client.destroy();
    if (self.source) |source| source.destroy();
    self.upstream.deinit();
    self.queue.deinit(gpa);
    gpa.destroy(self);
}

pub fn end(self: *Transfer, io: std.Io, stats: *Stats, event: State.Event) void {
    if (self.result != .running) return;
    self.record(stats, self.state.apply(event, now(io)));
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
    if (self.state.phase == .syncing_client) {
        self.syncClient(host) catch |err| {
            log.info("transfer {d}: client sync failed: {t}", .{ self.state.epoch, err });
            self.on(host, .target_failed);
        };
        return self.result;
    }

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
    const managed = host.managed;
    const complete = self.seen.world or self.target_registries.covers(&managed.initial_registries);
    if (self.seen.started and complete and self.state.phase == .joining) {
        if (self.incompatibility(managed)) |mismatch| {
            self.mismatch = mismatch;
            switch (mismatch) {
                inline else => |reason| host.stats.bump(@field(std.meta.FieldEnum(Stats), "incompatible_" ++ @tagName(reason)), 1),
            }
            log.info("transfer {d}: target content is incompatible: {t}", .{ self.state.epoch, mismatch });
            return self.on(host, .target_failed);
        }
        self.on(host, .target_ready);
    }
}

fn incompatibility(self: *const Transfer, managed: *const Managed) ?content.Mismatch {
    if (self.target_registries.difference(&managed.initial_registries)) |kind| return .of(kind);
    return switch (self.content_policy) {
        .initial => null,
        .match => if (self.target_packs.eql(managed.initial_packs)) null else .packs,
    };
}

// Returning an error would make RakNet drop the target without telling it
fn onTargetMessage(opaque_self: *anyopaque, payload: raknet.BorrowedPayload) error{ApplicationFailure}!void {
    const self: *Transfer = @ptrCast(@alignCast(opaque_self));
    if (self.seen.failed) return;
    self.receive(self.host.?, payload.bytes) catch |err| {
        log.info("transfer {d}: target failed: {t}", .{ self.state.epoch, err });
        self.seen.failed = true;
    };
}

fn receive(self: *Transfer, host: Host, frame: []const u8) !void {
    var packets = try self.upstream.session.ingest(frame);
    defer packets.deinit();
    const ctx = self.context(host);
    var buffer: [64]u8 = undefined;
    if (self.upstream.phase != .ready) {
        const packet = packets.next() orelse return error.MalformedBatch;
        switch (try self.upstream.receive(ctx, packet)) {
            .wants_login => try host.managed.loginUpstream(&self.upstream, ctx),
            .logged_in => {
                self.seen.logged_in = true;
                if (host.managed.cache_supported) |supported| try self.upstream.send(ctx, &.{try Managed.encodeTyped(&buffer, .{ .client_cache_status = .{ .is_cache_supported = supported } })});
            },
        }
        return;
    }
    while (packets.next()) |packet| {
        if (registries.isRegistry(packet.kind)) {
            const decoded = try self.upstream.session.decodePacket(packet);
            try self.target_registries.record(decoded);
            if (packet.kind == .start_game) {
                const start = try Managed.typed(decoded, .start_game);
                self.target_spawn = .{ .dimension = start.settings.spawn_settings.dimension, .position = finite(start.position) };
                self.target_runtime_id = start.runtime_id;
                self.seen.started = true;
            }
            continue;
        }
        if (self.seen.started) {
            if (endsRegistries(packet.kind)) self.seen.world = true;
            if (packet.kind == .play_status and (try Managed.typed(try self.upstream.session.decodePacket(packet), .play_status)).status == .playerspawn) {
                self.seen.spawned = true;
                continue;
            }
            try self.queue.push(host.gpa, packet.bytes);
            continue;
        }
        switch (packet.kind orelse continue) {
            .resource_packs_info => {
                self.target_packs.info = try packs.infoHash(try Managed.typed(try self.upstream.session.decodePacket(packet), .resource_packs_info));
                try self.upstream.send(ctx, &.{try Managed.encodeTyped(&buffer, .{ .resource_pack_client_response = .{ .response = .{ .downloading_finished = "" } } })});
            },
            .resource_pack_stack => {
                self.target_packs.stack = try packs.stackHash(try Managed.typed(try self.upstream.session.decodePacket(packet), .resource_pack_stack));
                try self.upstream.send(ctx, &.{try Managed.encodeTyped(&buffer, .{ .resource_pack_client_response = .{ .response = .{ .resource_pack_stack_finished = "" } } })});
                try self.upstream.session.advance(.waiting_for_start_game);
            },
            .disconnect => return error.BackendRefused,
            else => {},
        }
    }
    if (self.seen.started and self.upstream.session.state == .waiting_for_start_game) {
        try self.upstream.session.advance(.spawn_ready);
        if (host.managed.chunk_radius) |radius| try self.upstream.send(ctx, &.{try Managed.encodeTyped(&buffer, .{ .request_chunk_radius = .{
            .chunk_radius = radius.radius,
            .max_chunk_radius = radius.max,
        } })});
    }
}

fn endsRegistries(kind: ?bedwire.PacketKind) bool {
    return switch (kind orelse return false) {
        .network_chunk_publisher_update, .level_chunk, .sub_chunk, .play_status => true,
        else => false,
    };
}

fn on(self: *Transfer, host: Host, event: State.Event) void {
    const phase = self.state.phase;
    const step = self.state.apply(event, now(host.io));
    self.record(host.stats, step);
    switch (step.action) {
        .none, .stale => {},
        .prepare_client => return self.on(host, .client_prepared),
        .commit => self.commit(host) catch |err| {
            log.info("transfer {d}: commit failed: {t}", .{ self.state.epoch, err });
            return self.on(host, .target_failed);
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
    var outbox: Managed.Outbox = .init(host.gpa);
    defer outbox.deinit();
    try managed.client_state.reset(&outbox);
    self.handoff = try .begin(managed.client_dimension, self.target_spawn.?, &outbox);
    managed.syncing = true;
    managed.dimension_acks = 0;
    managed.target_spawned = self.seen.spawned;
    managed.backend_runtime_id = self.target_runtime_id;
    try managed.sendOutbox(host.ends(), &outbox);
    if (self.handoff.?.waitingForTarget()) {
        managed.hold = &self.queue;
    } else try self.release(host);
}

fn release(self: *Transfer, host: Host) !void {
    const managed = host.managed;
    managed.hold = null;
    var slices: [max_queued_packets][]const u8 = undefined;
    const skipped = try managed.deliver(host.ends(), self.queue.slices(&slices));
    if (skipped != 0) log.debug("transfer {d}: held back {d} world packets for client sync", .{ self.state.epoch, skipped });
    self.queue.clear();
}

pub fn syncClient(self: *Transfer, host: Host) !void {
    const managed = host.managed;
    if (self.state.phase != .syncing_client) return;
    while (managed.dimension_acks != 0 and !self.handoff.?.arrived()) {
        managed.dimension_acks -= 1;
        var outbox: Managed.Outbox = .init(host.gpa);
        defer outbox.deinit();
        if (try self.handoff.?.acknowledged(&outbox) == .sent_target) {
            try managed.sendOutbox(host.ends(), &outbox);
            try self.release(host);
        }
    }
    // The client's ack and the target's spawn can land in either order
    if (!self.handoff.?.arrived() or !managed.target_spawned) return;
    managed.syncing = false;
    managed.client_dimension = self.handoff.?.target.dimension;
    try managed.spawnTarget(host.ends());
    self.on(host, .client_synced);
}

fn finite(position: bedwire.protocol.Vec3f) bedwire.protocol.Vec3f {
    if (std.math.isFinite(position.x) and std.math.isFinite(position.y) and std.math.isFinite(position.z)) return position;
    return .{ .x = 0, .y = 0, .z = 0 };
}

fn record(self: *Transfer, stats: *Stats, step: State.Step) void {
    const outcome = step.outcome orelse return;
    self.outcome = outcome;
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
