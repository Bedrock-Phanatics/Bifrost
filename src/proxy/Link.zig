const std = @import("std");
const raknet = @import("raknet");
const bedwire = @import("bedwire");
const Backend = @import("../backend/Backend.zig");
const Dial = @import("../backend/Dial.zig");
const Health = @import("../backend/Health.zig");
const Router = @import("../backend/Router.zig");
const Watch = @import("../net/watch.zig").Watch;
const no_wait = @import("../net/watch.zig").no_wait;
const Observer = @import("../protocol/Observer.zig");
const Managed = @import("../session/Managed.zig");
const Transfer = @import("../transfer/Transfer.zig");
const Events = @import("../plugin/Events.zig");
const abi = @import("../plugin/abi.zig");
const Network = @import("../plugin/Network.zig");
const Handles = @import("../plugin/Handles.zig");
const Budget = @import("Budget.zig");
const PacketQueue = @import("PacketQueue.zig");
const Rate = @import("Rate.zig");
const Scheduler = @import("Scheduler.zig");
const Stats = @import("Stats.zig");
const Metrics = @import("Metrics.zig");
const trace = @import("../trace.zig");

const Link = @This();
const log = std.log.scoped(.link);

const max_polls_per_turn = 4;
// Each dial can take a full connect timeout; past this only health-checked backends are tried
const max_dial_attempts = 3;
pub const backlog_packets: usize = 256;
pub const backlog_bytes: usize = 4 * 1024 * 1024;

pub const Deadlines = struct {
    login_ms: u32 = 30_000,
    resource_packs_ms: u32 = 600_000,
    join_ms: u32 = 120_000,
    slow_player_ms: u32 = 5_000,
};

pub const Stage = enum { login, resource_packs, joining, playing };

pub const Env = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    stats: *Stats,
    scheduler: *Scheduler,
    observer_pool: ?*bedwire.BufferPool,
    auth: Observer.Auth,
    health: ?*Health,
    router: *Router,
    connect_timeout_ms: u32,
    pending_packets: u32,
    pending_bytes: u32,
    budget: ?*Budget = null,
    logins: ?*Rate = null,
    player_bytes_per_second: u32 = 0,
    deadlines: Deadlines = .{},
    managed: ?*Managed.Shared = null,
    transfer: Transfer.Settings = .{ .limits = .{ .dial_ms = 5_000, .phase_ms = 5_000, .total_ms = 15_000 }, .queue_packets = 64, .queue_bytes = 1024 * 1024 },
    transfers: ?*u32 = null,
    max_transfers: u32 = std.math.maxInt(u32),
    next_epoch: ?*Transfer.State.Epoch = null,
    events: Events = .{},
    timings: ?*Metrics.Timings = null,
};

pub const Transport = struct { retransmits: u64 = 0, lost: u64 = 0, queued: u64 = 0 };

const Seen = struct {
    retransmits: u64 = 0,
    lost: u64 = 0,

    fn delta(self: *Seen, stats: raknet.SessionStatistics, total: *Transport) void {
        total.retransmits += stats.retransmitted_datagrams -| self.retransmits;
        total.lost += stats.lost_datagrams -| self.lost;
        self.* = .{ .retransmits = stats.retransmitted_datagrams, .lost = stats.lost_datagrams };
    }
};

env: *const Env,
// The listener owns this, don't touch it after detachSession
session: ?*raknet.Session,
backend: ?*raknet.Client = null,
backend_closing: bool = false,
backend_error: ?anyerror = null,
dial: Dial = .{},
backend_id: Backend.Id = .of(0),
dial_task: ?std.Io.Future(void) = null,
tried: Router.Set = .{},
pending: PacketQueue,
observer: ?Observer,
managed: ?*Managed = null,
transfer: ?*Transfer = null,
id: u64 = 0,
player: abi.Player = .{},
announced: bool = false,
published: abi.PlayerState = .{},
authentication: abi.AuthenticationState = .pending,
network_rates: Network.Rates = .{},
network_backend: ?*raknet.Client = null,
watch: Watch(raknet.Client) = .{},
// Can't free the link while it's still on the ready stack
queued: std.atomic.Value(bool) = .init(false),
next_ready: ?*Link = null,
stage: Stage = .login,
stage_since_ms: u64,
backlogged_since_ms: ?u64 = null,
parked: bool = false,
park_node: std.DoublyLinkedList.Node = .{},
dial_started_ns: u64 = 0,
transfer_started_ns: u64 = 0,
seen_player: Seen = .{},
seen_backend: Seen = .{},
seen_client: ?*raknet.Client = null,

pub fn create(env: *const Env, session: *raknet.Session) !*Link {
    const self = try env.gpa.create(Link);
    errdefer env.gpa.destroy(self);
    const managed = if (env.managed) |shared| try Managed.create(env.gpa, shared, env.pending_packets, env.pending_bytes) else null;
    errdefer if (managed) |m| m.destroy();
    self.* = .{
        .env = env,
        .session = session,
        .pending = .init(env.pending_packets, env.pending_bytes, env.budget),
        .observer = if (env.observer_pool) |pool| try Observer.init(pool, env.player_bytes_per_second) else null,
        .managed = managed,
        .stage_since_ms = nowMs(env.io),
    };
    return self;
}

pub fn destroy(self: *Link) void {
    self.env.scheduler.unpark(self);
    self.endTransfer(.player_left);
    self.env.events.disconnected(&self.player);
    self.cancelDial();
    self.dropBackend();
    if (self.managed) |managed| managed.destroy();
    self.pending.deinit(self.env.gpa);
    if (self.observer) |*observer| observer.deinit();
    self.env.gpa.destroy(self);
}

pub fn connect(self: *Link) (error{NoBackendAvailable} || std.Io.ConcurrentError)!void {
    defer self.publishState();
    std.debug.assert(self.dial_task == null and self.backend == null);
    const span = trace.zone(@src(), "routing");
    const picked = self.env.router.pick(self.tried, self.tried.count() >= max_dial_attempts);
    span.end();
    const id = picked orelse return error.NoBackendAvailable;
    self.tried.add(id);
    self.backend_id = id;
    self.env.events.backendSelected(self.player, id.index());
    self.dial = .{};
    self.dial_started_ns = Metrics.nowNs(self.env.io);
    const options: raknet.ClientOptions = .{ .handshake_timeout_ms = self.env.connect_timeout_ms };
    const address = self.env.router.get(id).address;
    self.dial_task = try self.env.io.concurrent(Dial.run, .{ &self.dial, self.env.gpa, self.env.io, address, options, Scheduler.linkNotify(self) });
}

pub fn isFinished(self: *const Link) bool {
    return self.dial_task == null and self.session == null and self.backend == null;
}

pub fn forwardToBackend(self: *Link, payload: []const u8) !void {
    defer self.publishState();
    if (self.managed) |managed| {
        if (self.backend == null and self.dial_task == null) return error.BackendClosed;
        managed.fromPlayer(self.ends(self.session.?), payload) catch |err| {
            if (managed.identity == null and managed.player_phase == .login) self.authentication = if (err == error.OutOfMemory or err == error.ServerBusy) .unavailable else .rejected;
            return err;
        };
        if (!self.announced) if (managed.identity) |identity| self.announce(identity);
        if (self.backend != null) self.env.scheduler.schedule(self);
        return;
    }
    const observer = &self.observer.?;
    if (observer.watching and self.observe(observer, .client_to_server, payload).rejects()) return error.LoginRejected;
    if (observer.identity) |identity| {
        self.announce(identity);
        observer.dropIdentity();
    }
    if (self.backend) |client| {
        try client.send(payload, .reliable_ordered, 0);
        self.env.stats.bump(.bytes_to_backend, payload.len);
        self.env.stats.bump(.messages_to_backend, 1);
        self.env.scheduler.schedule(self);
    } else if (self.dial_task != null) {
        try self.pending.push(self.env.gpa, payload);
    } else return error.BackendClosed;
}

pub fn sendMessage(self: *Link, text: []const u8) !void {
    const managed = self.managed orelse return error.NotManaged;
    const session = self.session orelse return error.NotInGame;
    if (!session.isConnected()) return error.NotInGame;
    if (!managed.inGame()) return error.NotInGame;
    try managed.sendText(self.ends(session), text);
}

pub fn disconnect(self: *Link, reason: []const u8) abi.Status {
    const session = self.session orelse return .stale_handle;
    if (!session.isConnected()) return .too_late;
    var status: abi.Status = .ok;
    if (reason.len != 0) {
        if (self.managed) |managed| {
            managed.sendDisconnect(self.ends(session), reason) catch {
                status = .failed;
            };
        }
    }
    session.close();
    if (self.env.events.plugins) |plugins| plugins.handles.invalidatePackets(self.player);
    self.publishState();
    self.env.scheduler.schedule(self);
    return status;
}

pub fn networkStats(self: *Link, target: abi.PacketTarget, out: *abi.NetworkStats) abi.Status {
    const session = self.session orelse return .stale_handle;
    if (!session.isConnected()) return .too_late;
    const now_ms = @import("../plugin/Packets.zig").now(self.env.io) / std.time.ns_per_ms;
    switch (target) {
        .player => out.* = Network.snapshot(session.statistics(), now_ms),
        .backend => {
            const client = self.backend orelse return .too_late;
            if (self.backend_closing or client.isClosed()) return .too_late;
            if (self.network_backend != client) {
                self.network_backend = client;
                self.network_rates = .{};
            }
            out.* = Network.snapshot(client.statistics(), now_ms);
            self.network_rates.sample(client.traffic(), out);
        },
        else => return .invalid_argument,
    }
    return .ok;
}

pub fn gameplay(self: *Link, query: Handles.Query) abi.Status {
    const session = self.session orelse return .stale_handle;
    if (!session.isConnected()) return .too_late;
    const managed = self.managed orelse return .unsupported;
    const now_ms = @import("../plugin/Packets.zig").now(self.env.io) / std.time.ns_per_ms;
    return managed.gameplay.answer(query, now_ms, managed.client_state.effects);
}

pub fn playerState(self: *const Link) abi.PlayerState {
    var state: abi.PlayerState = .{
        .backend = if (self.tried.count() != 0) @intCast(self.backend_id.index()) else abi.no_backend,
        .authentication = if (self.authentication != .pending) self.authentication else if (self.env.auth == .off) .disabled else .pending,
        .mode = if (self.managed != null) .managed else .passthrough,
    };
    if (self.managed) |managed| {
        if (managed.identity != null) state.authentication = .authenticated;
        state.phase = switch (managed.player.state) {
            .transport_ready, .network_settings => .settings,
            .authenticating => .login,
            .encrypted_handshake => .handshake,
            .resource_packs => .resource_packs,
            .waiting_for_start_game, .spawn_ready => .joining,
            .in_game => .in_game,
            .closing => .closing,
            .disconnected => .disconnected,
        };
    }
    if (self.observer) |observer| if (observer.verified) {
        state.authentication = .authenticated;
    };
    if (self.transfer) |transfer| {
        state.transfer = transfer.pluginState();
        if (transfer.state.phase.committed()) state.backend = @intCast(transfer.target.index());
    }
    if (self.session) |session| {
        if (session.state == .closing or session.state == .closed) {
            state.connection = .closing;
            state.phase = .closing;
        }
    } else {
        state.connection = .disconnected;
        state.phase = .disconnected;
    }
    return state;
}

fn publishState(self: *Link) void {
    if (self.env.events.plugins == null or self.player.id == 0) return;
    const state = self.playerState();
    if (std.meta.eql(state, self.published)) return;
    self.published = state;
    self.env.events.stateChanged(self.player, state);
}

pub fn sendPacket(self: *Link, target: abi.PacketTarget, bytes: []const u8) abi.Status {
    const managed = self.managed orelse return .unsupported;
    const session = self.session orelse return .stale_handle;
    if (!session.isConnected()) return .too_late;
    if (self.transfer != null) return .busy;
    const client = self.backend orelse return .too_late;
    if (self.backend_closing or self.backend_error != null or !managed.inGame()) return .too_late;
    if (backlogged(if (target == .player) session.statistics() else client.statistics(), false)) return .busy;
    managed.inject(self.ends(session), target, bytes) catch |err| {
        if (err == error.NotInGame) return .too_late;
        self.fail(err);
        return .failed;
    };
    self.env.scheduler.schedule(self);
    return .ok;
}

fn announce(self: *Link, identity: bedwire.Identity) void {
    self.announced = true;
    self.published = self.playerState();
    self.env.events.authenticated(self.player, identity.display_name, identity.xuid, identity.uuid, identity.online, self.published);
}

pub fn detachSession(self: *Link) void {
    self.endTransfer(.player_left);
    self.env.events.disconnected(&self.player);
    self.session = null;
    self.cancelDial();
    self.closeBackend();
    self.env.scheduler.schedule(self);
}

pub fn service(self: *Link) error{Canceled}!void {
    defer self.publishState();
    if (self.dial_task) |*task| if (self.dial.finished()) |result| {
        task.await(self.env.io);
        self.dial_task = null;
        self.adopt(result);
    };
    if (self.transfer) |transfer| if (self.session) |session| switch (try transfer.service(self.transferHost(session))) {
        .running => {},
        .finished => {
            self.endTransfer(null);
        },
        .rolled_back, .abandoned => self.endTransfer(null),
        .disconnect => {
            self.endTransfer(null);
            self.closeSession();
        },
    };
    _ = self.watch.take(self.env.io);
    const client = self.backend orelse return;
    const span = trace.zone(@src(), "backend io");
    defer span.end();

    var drained = false;
    var paused = false;
    for (0..max_polls_per_turn) |_| {
        if (self.playerBacklogged()) {
            paused = true;
            break;
        }
        _ = client.poll(no_wait, self, onBackendMessage) catch |err| switch (err) {
            error.Timeout => {
                drained = true;
                break;
            },
            error.Canceled => return error.Canceled,
            else => return if (self.backend_closing) self.dropBackend() else self.fail(err),
        };
    }
    if (self.backend_error) |err| {
        self.backend_error = null;
        return self.fail(err);
    }
    if (client.isClosed()) return if (self.backend_closing) self.dropBackend() else self.fail(error.ConnectionClosed);
    if (self.transfer) |transfer| if (self.session) |session| transfer.syncClient(self.transferHost(session)) catch |err| return self.fail(err);
    if (paused) return self.pause();
    self.backlogged_since_ms = null;
    self.env.scheduler.unpark(self);
    self.watch.arm(self.env.io, client, Scheduler.linkNotify(self)) catch |err| return self.fail(err);
    if (!drained) self.env.scheduler.schedule(self);
}

// The backend isn't read until the player catches up, so RakNet's own flow control slows it down
fn pause(self: *Link) void {
    if (self.backlogged_since_ms == null) {
        self.backlogged_since_ms = nowMs(self.env.io);
        self.env.stats.bump(.backlog_pauses, 1);
    }
    self.env.scheduler.park(self);
}

pub fn playerBacklogged(self: *const Link) bool {
    const session = self.session orelse return false;
    if (session.state != .connected) return false;
    return backlogged(session.statistics(), self.backlogged_since_ms != null);
}

fn backlogged(stats: raknet.SessionStatistics, draining: bool) bool {
    // Resuming at half the mark keeps a busy player from flapping
    const shift: u1 = @intFromBool(draining);
    return stats.queued_packets >= backlog_packets >> shift or stats.queued_payload_bytes >= backlog_bytes >> shift;
}

// Worker only, once a second, so counters survive sessions closing
pub fn sampleTransport(self: *Link, total: *Transport) void {
    if (self.session) |session| if (session.state == .connected) {
        const stats = session.statistics();
        self.seen_player.delta(stats, total);
        total.queued += stats.queued_packets;
    };
    const client = self.backend orelse return;
    if (self.seen_client != client) {
        self.seen_client = client;
        self.seen_backend = .{};
    }
    self.seen_backend.delta(client.statistics(), total);
}

pub fn checkDeadlines(self: *Link, now_ms: u64) void {
    const session = self.session orelse return;
    if (session.state != .connected) return;
    const deadlines = self.env.deadlines;
    if (self.backlogged_since_ms) |since| if (now_ms -| since >= deadlines.slow_player_ms) {
        self.env.stats.bump(.slow_players, 1);
        log.debug("player {d} can't keep up, closing", .{self.id});
        _ = self.disconnect("Connection too slow");
        return;
    };
    const stage = self.currentStage();
    if (stage != self.stage) {
        self.stage = stage;
        self.stage_since_ms = now_ms;
        return;
    }
    const limit_ms = switch (stage) {
        .login => deadlines.login_ms,
        .resource_packs => deadlines.resource_packs_ms,
        .joining => deadlines.join_ms,
        .playing => return,
    };
    if (now_ms -| self.stage_since_ms < limit_ms) return;
    const stats = self.env.stats;
    switch (stage) {
        .login => stats.bump(.login_timeouts, 1),
        .resource_packs => stats.bump(.resource_pack_timeouts, 1),
        .joining, .playing => stats.bump(.join_timeouts, 1),
    }
    log.debug("player {d} timed out in {t}", .{ self.id, stage });
    _ = self.disconnect("Timed out");
}

fn currentStage(self: *const Link) Stage {
    if (self.managed) |managed| {
        if (managed.upstream.phase != .ready) return .login;
        return switch (managed.player.state) {
            .transport_ready, .network_settings, .authenticating, .encrypted_handshake => .login,
            .resource_packs => .resource_packs,
            .waiting_for_start_game, .spawn_ready => .joining,
            .in_game, .closing, .disconnected => .playing,
        };
    }
    if (self.observer) |observer| if (observer.watching) return .login;
    return .playing;
}

fn nowMs(io: std.Io) u64 {
    return @intCast(@divFloor(std.Io.Clock.awake.now(io).nanoseconds, std.time.ns_per_ms));
}

fn observe(self: *Link, observer: *Observer, direction: bedwire.TapDirection, payload: []const u8) Observer.Event {
    const event = observer.observe(.{ .gpa = self.env.gpa, .io = self.env.io, .auth = self.env.auth, .now_ms = nowMs(self.env.io), .logins = self.env.logins }, direction, payload);
    const stats = self.env.stats;
    switch (event) {
        .none => {},
        .encrypted => stats.bump(.handshakes_observed, 1),
        .gave_up => stats.bump(.observer_gave_up, 1),
        .login_verified => stats.bump(.logins_verified, 1),
        .login_rejected => {
            self.authentication = .rejected;
            stats.bump(.logins_rejected, 1);
        },
        .auth_unavailable => {
            self.authentication = .unavailable;
            stats.bump(.auth_unavailable, 1);
        },
        .login_throttled => {
            self.authentication = .unavailable;
            stats.bump(.logins_throttled, 1);
        },
        .flooded => stats.bump(.player_floods, 1),
    }
    return event;
}

fn adopt(self: *Link, result: Dial.ConnectError!*raknet.Client) void {
    const client = result catch |err| {
        log.warn("backend {f} connect failed: {t}", .{ self.env.router.get(self.backend_id).*, err });
        self.env.stats.bump(.backend_failures, 1);
        if (err == error.Canceled) return self.closeSession();
        if (self.env.health) |health| health.markFailed(self.backend_id);
        if (self.session == null) return;
        self.connect() catch |retry_err| {
            log.warn("giving up on player: {t}", .{retry_err});
            self.closeSession();
        };
        return;
    };
    self.backend = client;
    self.network_rates = .{};
    self.env.stats.bump(.backends_connected, 1);
    if (self.env.timings) |timings| timings.dial.record(Metrics.sinceUs(self.env.io, self.dial_started_ns));
    const session = self.session orelse return self.dropBackend();
    if (self.managed) |managed| return managed.backendConnected(self.ends(session)) catch |err| self.fail(err);
    self.flushPending(client) catch |err| self.fail(err);
}

pub fn requestTransfer(self: *Link, requested: Backend.Id) !void {
    defer self.publishState();
    self.startTransfer(requested) catch |err| {
        self.env.events.stateChanged(self.player, self.playerState());
        self.env.events.transferEnded(self.player, self.backend_id.index(), requested.index(), .rejected);
        return err;
    };
}

fn startTransfer(self: *Link, requested: Backend.Id) !void {
    const managed = self.managed orelse return error.NotManaged;
    if (self.transfer != null) return error.TransferInProgress;
    const session = self.session orelse return error.NotInGame;
    if (!session.isConnected()) return error.NotInGame;
    if (self.backend == null or self.backend_closing or !managed.inGame()) return error.NotInGame;
    const decision = self.env.events.transferRequested(self.player, self.backend_id.index(), requested.index());
    const target: Backend.Id = switch (decision.action) {
        .cancel => return error.CanceledByPlugin,
        .redirect => .of(decision.backend),
        else => requested,
    };
    if (target.index() >= self.env.router.backends.len) return error.UnknownBackend;
    if (target == self.backend_id) return error.AlreadyThere;
    if (self.env.health) |health| if (health.status(target) == .unhealthy) return error.BackendDown;
    if (self.env.transfers) |count| if (count.* >= self.env.max_transfers) return error.TooManyTransfers;
    const epoch = self.env.next_epoch.?;
    epoch.* +%= 1;
    self.transfer = try Transfer.create(self.transferHost(session), target, self.env.router.get(target).address, epoch.*, self.env.transfer);
    if (self.env.transfers) |count| count.* += 1;
    self.transfer_started_ns = Metrics.nowNs(self.env.io);
    self.env.scheduler.schedule(self);
}

fn transferHost(self: *Link, session: *raknet.Session) Transfer.Host {
    return .{
        .gpa = self.env.gpa,
        .io = self.env.io,
        .stats = self.env.stats,
        .managed = self.managed.?,
        .player = session,
        .notify = Scheduler.linkNotify(self),
        .backend = &self.backend,
        .backend_watch = &self.watch,
        .events = self.env.events,
        .source_backend = @intCast(self.backend_id.index()),
    };
}

fn endTransfer(self: *Link, event: ?Transfer.State.Event) void {
    const transfer = self.transfer orelse return;
    const source = self.backend_id;
    self.transfer = null;
    if (self.env.transfers) |count| count.* -= 1;
    if (event) |cause| transfer.end(self.env.io, self.env.stats, cause);
    if (transfer.outcome == .committed) if (self.env.timings) |timings| timings.transfer.record(Metrics.sinceUs(self.env.io, self.transfer_started_ns));
    if (transfer.state.phase.committed()) {
        self.backend_id = transfer.target;
        self.network_rates = .{};
    }
    self.publishState();
    self.env.events.transferEnded(self.player, source.index(), transfer.target.index(), failure(transfer));
    transfer.destroy(self.env.gpa, self.env.io);
}

fn failure(transfer: *const Transfer) abi.TransferFailure {
    return switch (transfer.outcome orelse return .failed_before_commit) {
        .committed => .none,
        .failed_before_commit => if (transfer.mismatch != null) .incompatible_content else .failed_before_commit,
        .failed_after_commit => .failed_after_commit,
        .timed_out => .timed_out,
    };
}

fn ends(self: *Link, session: *raknet.Session) Managed.Ends {
    return .{ .io = self.env.io, .stats = self.env.stats, .player = session, .backend = if (self.backend_closing) null else self.backend };
}

// Errors wait for the poll to end; returning one would drop the backend without telling it
fn onBackendMessage(context: *anyopaque, payload: raknet.BorrowedPayload) error{ApplicationFailure}!void {
    const self: *Link = @ptrCast(@alignCast(context));
    const span = trace.zone(@src(), "backend packet");
    defer span.end();
    defer self.publishState();
    if (self.backend_error != null) return;
    const session = self.session orelse return;
    if (self.managed) |managed| return managed.fromBackend(self.ends(session), payload.bytes) catch |err| {
        log.debug("managed session failed: {t}", .{err});
        self.backend_error = err;
    };
    const observer = &self.observer.?;
    if (observer.watching and self.observe(observer, .server_to_client, payload.bytes).rejects()) {
        self.backend_error = error.LoginRejected;
        return;
    }
    session.send(payload.bytes, .reliable_ordered, 0) catch |err| {
        self.backend_error = err;
        return;
    };
    self.env.stats.bump(.bytes_to_player, payload.bytes.len);
    self.env.stats.bump(.messages_to_player, 1);
}

fn flushPending(self: *Link, client: *raknet.Client) !void {
    defer self.pending.clear(self.env.gpa);
    for (self.pending.items()) |packet| {
        try client.send(packet, .reliable_ordered, 0);
        self.env.stats.bump(.bytes_to_backend, packet.len);
        self.env.stats.bump(.messages_to_backend, 1);
    }
}

fn cancelDial(self: *Link) void {
    var task = self.dial_task orelse return;
    self.dial_task = null;
    task.cancel(self.env.io);
    if (self.dial.finished()) |result| {
        if (result) |client| client.destroy() else |_| {}
    }
}

fn fail(self: *Link, err: anyerror) void {
    log.debug("closing link: {t}", .{err});
    const committed = if (self.transfer) |transfer| transfer.state.phase.committed() else false;
    self.endTransfer(if (committed) .target_failed else .source_failed);
    self.dropBackend();
    self.closeSession();
}

fn closeSession(self: *Link) void {
    if (self.session) |session| session.close();
    self.publishState();
}

fn closeBackend(self: *Link) void {
    const client = self.backend orelse return;
    if (self.backend_closing) return;
    self.backend_closing = true;
    self.pending.clear(self.env.gpa);
    client.close();
}

fn dropBackend(self: *Link) void {
    const client = self.backend orelse return;
    self.backend = null;
    self.backend_closing = false;
    self.watch.cancel(self.env.io);
    client.destroy();
    self.pending.clear(self.env.gpa);
}
