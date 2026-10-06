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
const PacketQueue = @import("PacketQueue.zig");
const Scheduler = @import("Scheduler.zig");
const Stats = @import("Stats.zig");

const Link = @This();
const log = std.log.scoped(.link);

const max_polls_per_turn = 4;
// Each dial can take a full connect timeout; past this only health-checked backends are tried
const max_dial_attempts = 3;

pub const Env = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    stats: *Stats,
    scheduler: *Scheduler,
    observer_pool: *bedwire.BufferPool,
    auth: Observer.Auth,
    health: ?*Health,
    router: *Router,
    connect_timeout_ms: u32,
    pending_packets: u32,
    pending_bytes: u32,
    managed: ?*Managed.Shared = null,
    transfer: Transfer.Settings = .{ .limits = .{ .dial_ms = 5_000, .phase_ms = 5_000, .total_ms = 15_000 }, .queue_packets = 64, .queue_bytes = 1024 * 1024 },
    next_epoch: ?*Transfer.State.Epoch = null,
    events: Events = .{},
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
observer: Observer,
managed: ?*Managed = null,
transfer: ?*Transfer = null,
id: u64 = 0,
player: abi.Player = .{},
announced: bool = false,
watch: Watch(raknet.Client) = .{},
node: std.DoublyLinkedList.Node = .{},
// Can't free the link while it's still on the ready stack
queued: std.atomic.Value(bool) = .init(false),
next_ready: ?*Link = null,

pub fn create(env: *const Env, session: *raknet.Session) !*Link {
    const self = try env.gpa.create(Link);
    errdefer env.gpa.destroy(self);
    const managed = if (env.managed) |shared| try Managed.create(env.gpa, shared, env.pending_packets, env.pending_bytes) else null;
    errdefer if (managed) |m| m.destroy();
    self.* = .{
        .env = env,
        .session = session,
        .pending = .init(env.pending_packets, env.pending_bytes),
        .observer = try .init(env.observer_pool),
        .managed = managed,
    };
    if (managed != null) self.observer.watching = false;
    return self;
}

pub fn destroy(self: *Link) void {
    self.endTransfer(.player_left);
    self.env.events.disconnected(&self.player);
    self.cancelDial();
    self.dropBackend();
    if (self.managed) |managed| managed.destroy();
    self.pending.deinit(self.env.gpa);
    self.observer.deinit();
    self.env.gpa.destroy(self);
}

pub fn connect(self: *Link) (error{NoBackendAvailable} || std.Io.ConcurrentError)!void {
    std.debug.assert(self.dial_task == null and self.backend == null);
    const id = self.env.router.pick(self.tried, self.tried.count() >= max_dial_attempts) orelse return error.NoBackendAvailable;
    self.tried.add(id);
    self.backend_id = id;
    self.env.events.backendSelected(self.player, id.index());
    self.dial = .{};
    const options: raknet.ClientOptions = .{ .handshake_timeout_ms = self.env.connect_timeout_ms };
    const address = self.env.router.get(id).address;
    self.dial_task = try self.env.io.concurrent(Dial.run, .{ &self.dial, self.env.gpa, self.env.io, address, options, Scheduler.linkNotify(self) });
}

pub fn isFinished(self: *const Link) bool {
    return self.dial_task == null and self.session == null and self.backend == null;
}

pub fn forwardToBackend(self: *Link, payload: []const u8) !void {
    if (self.managed) |managed| {
        if (self.backend == null and self.dial_task == null) return error.BackendClosed;
        try managed.fromPlayer(self.ends(self.session.?), payload);
        if (!self.announced) if (managed.identity) |identity| self.announce(identity);
        if (self.backend != null) self.env.scheduler.schedule(self);
        return;
    }
    if (self.observer.watching and self.observe(.client_to_server, payload).rejects()) return error.LoginRejected;
    if (self.observer.identity) |identity| {
        self.announce(identity);
        self.observer.dropIdentity();
    }
    if (self.backend) |client| {
        try client.send(payload, .reliable_ordered, 0);
        self.env.stats.bump(.bytes_to_backend, payload.len);
        self.env.scheduler.schedule(self);
    } else if (self.dial_task != null) {
        try self.pending.push(self.env.gpa, payload);
    } else return error.BackendClosed;
}

pub fn sendMessage(self: *Link, text: []const u8) !void {
    const managed = self.managed orelse return error.NotManaged;
    const session = self.session orelse return error.NotInGame;
    if (!managed.inGame()) return error.NotInGame;
    try managed.sendText(self.ends(session), text);
}

fn announce(self: *Link, identity: bedwire.Identity) void {
    self.announced = true;
    self.env.events.authenticated(self.player, identity.display_name, identity.xuid);
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
    if (self.dial_task) |*task| if (self.dial.finished()) |result| {
        task.await(self.env.io);
        self.dial_task = null;
        self.adopt(result);
    };
    if (self.transfer) |transfer| if (self.session) |session| switch (try transfer.service(self.transferHost(session))) {
        .running => {},
        .finished => {
            const target = transfer.target;
            self.endTransfer(null);
            self.backend_id = target;
        },
        .rolled_back, .abandoned => self.endTransfer(null),
        .disconnect => {
            self.endTransfer(null);
            self.closeSession();
        },
    };
    _ = self.watch.take(self.env.io);
    const client = self.backend orelse return;

    var drained = false;
    for (0..max_polls_per_turn) |_| {
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
    self.watch.arm(self.env.io, client, Scheduler.linkNotify(self)) catch |err| return self.fail(err);
    if (!drained) self.env.scheduler.schedule(self);
}

fn observe(self: *Link, direction: bedwire.TapDirection, payload: []const u8) Observer.Event {
    const event = self.observer.observe(.{ .gpa = self.env.gpa, .io = self.env.io, .auth = self.env.auth }, direction, payload);
    const stats = self.env.stats;
    switch (event) {
        .none => {},
        .encrypted => stats.bump(.handshakes_observed, 1),
        .gave_up => stats.bump(.observer_gave_up, 1),
        .login_verified => stats.bump(.logins_verified, 1),
        .login_rejected => stats.bump(.logins_rejected, 1),
        .auth_unavailable => stats.bump(.auth_unavailable, 1),
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
    self.env.stats.bump(.backends_connected, 1);
    const session = self.session orelse return self.dropBackend();
    if (self.managed) |managed| return managed.backendConnected(self.ends(session)) catch |err| self.fail(err);
    self.flushPending(client) catch |err| self.fail(err);
}

pub fn requestTransfer(self: *Link, requested: Backend.Id) !void {
    self.startTransfer(requested) catch |err| {
        self.env.events.transferEnded(self.player, self.backend_id.index(), requested.index(), .rejected);
        return err;
    };
}

fn startTransfer(self: *Link, requested: Backend.Id) !void {
    const managed = self.managed orelse return error.NotManaged;
    if (self.transfer != null) return error.TransferInProgress;
    const session = self.session orelse return error.NotInGame;
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
    const epoch = self.env.next_epoch.?;
    epoch.* +%= 1;
    self.transfer = try Transfer.create(self.transferHost(session), target, self.env.router.get(target).address, epoch.*, self.env.transfer);
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
    };
}

fn endTransfer(self: *Link, event: ?Transfer.State.Event) void {
    const transfer = self.transfer orelse return;
    self.transfer = null;
    if (event) |cause| transfer.end(self.env.io, self.env.stats, cause);
    self.env.events.transferEnded(self.player, self.backend_id.index(), transfer.target.index(), failure(transfer));
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
    if (self.backend_error != null) return;
    const session = self.session orelse return;
    if (self.managed) |managed| return managed.fromBackend(self.ends(session), payload.bytes) catch |err| {
        log.debug("managed session failed: {t}", .{err});
        self.backend_error = err;
    };
    if (self.observer.watching and self.observe(.server_to_client, payload.bytes).rejects()) {
        self.backend_error = error.LoginRejected;
        return;
    }
    session.send(payload.bytes, .reliable_ordered, 0) catch |err| {
        self.backend_error = err;
        return;
    };
    self.env.stats.bump(.bytes_to_player, payload.bytes.len);
}

fn flushPending(self: *Link, client: *raknet.Client) !void {
    defer self.pending.clear(self.env.gpa);
    for (self.pending.items()) |packet| {
        try client.send(packet, .reliable_ordered, 0);
        self.env.stats.bump(.bytes_to_backend, packet.len);
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
