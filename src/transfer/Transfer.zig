const std = @import("std");
const bedwire = @import("bedwire");
const Backend = @import("../backend/Backend.zig");
const Dial = @import("../backend/Dial.zig");
const Notify = @import("../net/Notify.zig");
const NetherNet = @import("../net/NetherNet.zig");
const Peer = @import("../net/Peer.zig");
const Managed = @import("../session/Managed.zig");
const Upstream = Managed.Upstream;
const self_id = @import("../session/self_id.zig");
const Budget = @import("../proxy/Budget.zig");
const trace = @import("../trace.zig");
const Stats = @import("../proxy/Stats.zig");
const Events = @import("../plugin/Events.zig");
const abi = @import("../plugin/abi.zig");
const content = @import("../content/policy.zig");
const packs = @import("../content/packs.zig");
const registries = @import("../content/registries.zig");
pub const State = @import("State.zig");
const Queue = @import("Queue.zig");
const Handoff = @import("Handoff.zig");

const Transfer = @This();
const log = std.log.scoped(.transfer);

const max_messages_per_turn = 64;
const max_queued_packets = 256;

pub const Host = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    stats: *Stats,
    transport: *const NetherNet,
    managed: *Managed,
    player: *Peer,
    notify: Notify,
    backend: *?Peer,
    events: Events = .{},
    source_backend: u32 = abi.no_backend,

    fn ends(self: Host) Managed.Ends {
        return .{ .io = self.io, .stats = self.stats, .player = self.player, .backend = if (self.backend.*) |*backend| backend else null };
    }
};

pub const Result = enum { running, finished, rolled_back, disconnect, abandoned };

pub const Settings = struct {
    limits: State.Limits,
    queue_packets: u32,
    queue_bytes: u32,
    content_policy: content.Policy = .initial,
    budget: ?*Budget = null,
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
client: ?Peer = null,
upstream: Upstream,
timer: ?std.Io.Future(void) = null,
timer_fired: std.atomic.Value(bool) = .init(false),
queue: Queue,
source: ?Peer = null,
seen: Seen = .{},
result: Result = .running,
outcome: ?State.Outcome = null,
content_policy: content.Policy,
target_packs: packs.Fingerprint = .{},
target_registries: registries.Fingerprint = .{},
target_spawn: ?Handoff.Target = null,
target_ids: self_id.Ids = .{},
target_modes: struct { player: i32, world: i32 } = .{ .player = 0, .world = 0 },
handoff: ?Handoff = null,
managed: *Managed,
mismatch: ?content.Mismatch = null,

pub fn create(host: Host, target: Backend.Id, address: std.Io.net.IpAddress, epoch: State.Epoch, settings: Settings) !*Transfer {
    const self = try host.gpa.create(Transfer);
    errdefer host.gpa.destroy(self);
    self.* = .{
        .state = .init(epoch, settings.limits, now(host.io)),
        .target = target,
        .upstream = try .init(host.managed.shared),
        .queue = .{ .max_packets = @min(settings.queue_packets, max_queued_packets), .max_bytes = settings.queue_bytes, .budget = settings.budget },
        .content_policy = settings.content_policy,
        .managed = host.managed,
    };
    errdefer self.upstream.deinit();
    self.dial_task = try host.io.concurrent(Dial.run, .{ &self.dial, host.transport, address, host.notify });
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
    if (self.client) |*client| client.destroy();
    if (self.source) |*source| source.destroy();
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
    const span = trace.zone(@src(), "transfer");
    defer span.end();
    if (self.dial_task) |*task| if (self.dial.finished()) |result| {
        task.await(host.io);
        self.dial_task = null;
        if (result) |connection| {
            self.client = .init(connection);
            self.client.?.watch(host.notify);
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

    if (self.client == null) return self.result;

    const client = &self.client.?;
    var drained = false;
    for (0..max_messages_per_turn) |_| {
        const message = client.next() catch {
            self.seen.failed = true;
            break;
        } orelse {
            drained = true;
            break;
        };
        if (message.reliability == .reliable) self.receive(host, message.data) catch |err| {
            log.info("transfer {d}: target failed: {t}", .{ self.state.epoch, err });
            self.seen.failed = true;
        };
        // Once the world is in, the link reads the target with backpressure
        if (self.seen.failed or self.worldSeen(host.managed)) break;
    }
    self.settle(host);
    if (self.result != .running or self.client == null) return self.result;
    if (!drained) host.notify.send();
    return self.result;
}

fn settle(self: *Transfer, host: Host) void {
    if (self.seen.failed) return self.on(host, .target_failed);
    if (self.seen.logged_in and self.state.phase == .logging_in) self.on(host, .logged_in);
    const managed = host.managed;
    if (self.worldSeen(managed) and self.state.phase == .joining) {
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

fn worldSeen(self: *const Transfer, managed: *const Managed) bool {
    return self.seen.started and (self.seen.world or self.target_registries.covers(&managed.initial_registries));
}

fn incompatibility(self: *const Transfer, managed: *const Managed) ?content.Mismatch {
    if (self.target_registries.difference(&managed.initial_registries)) |kind| return .of(kind);
    return switch (self.content_policy) {
        .initial => null,
        .match => if (self.target_packs.eql(managed.initial_packs)) null else .packs,
    };
}

fn receive(self: *Transfer, host: Host, frame: []const u8) !void {
    var packets = try self.upstream.session.ingest(frame);
    defer packets.deinit();
    const ctx = self.context(host);
    var buffer: [64]u8 = undefined;
    if (self.upstream.phase != .ready) {
        const packet = packets.next() orelse return error.MalformedBatch;
        switch (try self.upstream.receive(packet)) {
            .wants_login => return host.managed.loginUpstream(&self.upstream, ctx),
            // The player already has its LoginSuccess, the rest of the batch still counts
            .logged_in => {
                self.seen.logged_in = true;
                if (host.managed.cache_supported) |supported| try self.upstream.send(ctx, &.{try Managed.encodeTyped(&buffer, .{ .client_cache_status = .{ .is_cache_supported = supported } })});
            },
        }
    }
    while (packets.next()) |packet| {
        if (registries.isRegistry(packet.kind)) {
            const decoded = try self.upstream.session.decodePacket(packet);
            try self.target_registries.record(decoded);
            if (packet.kind == .start_game) {
                const start = try Managed.typed(decoded, .start_game);
                self.target_spawn = .{ .dimension = start.settings.spawn_settings.dimension, .position = finite(start.position) };
                self.target_ids = .{ .runtime = start.runtime_id, .unique = start.entity_id };
                self.target_modes = .{ .player = @backingInt(start.game_type), .world = @backingInt(start.settings.game_type) };
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
    if (step.action != .commit) self.publish(host);
    self.record(host.stats, step);
    switch (step.action) {
        .none, .stale => {},
        .prepare_client => return self.on(host, .client_prepared),
        .commit => self.commit(host) catch |err| {
            log.info("transfer {d}: commit failed: {t}", .{ self.state.epoch, err });
            return self.on(host, .target_failed);
        },
        .close_source => {
            if (self.source) |*source| source.destroy();
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

pub fn pluginState(self: *const Transfer) abi.TransferState {
    return switch (self.state.phase) {
        .dialing => .dialing,
        .logging_in => .logging_in,
        .joining => .joining,
        .preparing_client => .preparing_client,
        .syncing_client => .syncing_client,
        .closing_source => .closing_source,
    };
}

fn publish(self: *const Transfer, host: Host) void {
    const plugins = host.events.plugins orelse return;
    var info: abi.PlayerInfo = undefined;
    if (!plugins.handles.copyInfo(host.managed.plugin_player, &info)) return;
    info.state.transfer = self.pluginState();
    info.state.backend = if (self.state.phase.committed()) @intCast(self.target.index()) else host.source_backend;
    _ = plugins.handles.setState(host.managed.plugin_player, info.state);
}

fn commit(self: *Transfer, host: Host) !void {
    const managed = host.managed;
    self.source = host.backend.*;
    host.backend.* = self.client;
    self.client = null;
    self.upstream = managed.swapUpstream(self.upstream);
    self.publish(host);
    var outbox: Managed.Outbox = .init(host.gpa);
    defer outbox.deinit();
    try managed.client_state.reset(&outbox);
    // The client keeps its old game mode unless told, and the target never sends it again
    if (Managed.Gameplay.gameMode(self.target_modes.player, self.target_modes.world)) |mode| try outbox.emit(.{ .set_player_game_type = .{ .player_game_type = @fromBackingInt(mode) } });
    const spawn = self.target_spawn.?;
    managed.gameplay.transferred(now(host.io) / std.time.ns_per_ms, spawn.dimension, spawn.position, self.target_modes.player, self.target_modes.world);
    self.handoff = try .begin(managed.client_dimension, spawn, &outbox);
    managed.syncing = true;
    managed.dimension_acks = 0;
    managed.target_spawned = self.seen.spawned;
    managed.backend_ids = self.target_ids;
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
    managed.gameplay.synced();
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
    return host.managed.upstreamContext(host.ends(), &self.client.?);
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
    var task = self.dial_task orelse return;
    self.dial_task = null;
    self.dial.cancel(&task, io);
}

fn now(io: std.Io) u64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}
