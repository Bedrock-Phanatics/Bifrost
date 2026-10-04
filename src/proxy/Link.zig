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
const PacketQueue = @import("PacketQueue.zig");
const Scheduler = @import("Scheduler.zig");
const Stats = @import("Stats.zig");

const Link = @This();
const log = std.log.scoped(.link);

const max_polls_per_turn = 4;
// Each attempt can take a full connect timeout
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
};

env: *const Env,
// The listener owns this, don't touch it after detachSession
session: ?*raknet.Session,
backend: ?*raknet.Client = null,
backend_closing: bool = false,
dial: Dial = .{},
backend_id: Backend.Id = .of(0),
dial_task: ?std.Io.Future(void) = null,
tried: Router.Set = .{},
pending: PacketQueue,
observer: Observer,
managed: ?*Managed = null,
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
    self.cancelDial();
    self.dropBackend();
    if (self.managed) |managed| managed.destroy();
    self.pending.deinit(self.env.gpa);
    self.observer.deinit();
    self.env.gpa.destroy(self);
}

pub fn connect(self: *Link) (error{NoBackendAvailable} || std.Io.ConcurrentError)!void {
    std.debug.assert(self.dial_task == null and self.backend == null);
    if (self.tried.count() == max_dial_attempts) return error.NoBackendAvailable;
    const id = self.env.router.pick(self.tried) orelse return error.NoBackendAvailable;
    self.tried.add(id);
    self.backend_id = id;
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
        if (self.backend != null) self.env.scheduler.schedule(self);
        return;
    }
    if (self.observer.watching and self.observe(.client_to_server, payload).rejects()) return error.LoginRejected;
    if (self.backend) |client| {
        try client.send(payload, .reliable_ordered, 0);
        self.env.stats.bump(.bytes_to_backend, payload.len);
        self.env.scheduler.schedule(self);
    } else if (self.dial_task != null) {
        try self.pending.push(self.env.gpa, payload);
    } else return error.BackendClosed;
}

pub fn detachSession(self: *Link) void {
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
    if (client.isClosed()) return if (self.backend_closing) self.dropBackend() else self.fail(error.ConnectionClosed);
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

fn ends(self: *Link, session: *raknet.Session) Managed.Ends {
    return .{ .io = self.env.io, .stats = self.env.stats, .player = session, .backend = if (self.backend_closing) null else self.backend };
}

fn onBackendMessage(context: *anyopaque, payload: raknet.BorrowedPayload) error{ApplicationFailure}!void {
    const self: *Link = @ptrCast(@alignCast(context));
    const session = self.session orelse return error.ApplicationFailure;
    if (self.managed) |managed| return managed.fromBackend(self.ends(session), payload.bytes) catch |err| {
        log.debug("managed session failed: {t}", .{err});
        return error.ApplicationFailure;
    };
    if (self.observer.watching and self.observe(.server_to_client, payload.bytes).rejects()) return error.ApplicationFailure;
    session.send(payload.bytes, .reliable_ordered, 0) catch return error.ApplicationFailure;
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
