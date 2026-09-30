const std = @import("std");
const raknet = @import("raknet");
const bedwire = @import("bedwire");
const Dial = @import("../backend/Dial.zig");
const Watch = @import("../net/watch.zig").Watch;
const Observer = @import("../protocol/Observer.zig");
const PacketQueue = @import("PacketQueue.zig");
const Scheduler = @import("Scheduler.zig");
const Stats = @import("Stats.zig");

const Link = @This();
const log = std.log.scoped(.link);

const max_polls_per_turn = 4;
const no_wait: std.Io.Timeout = .{ .duration = .{ .raw = .zero, .clock = .awake } };

pub const Env = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    stats: *Stats,
    scheduler: *Scheduler,
    observer_pool: *bedwire.BufferPool,
    auth: Observer.Auth,
    pending_packets: u32,
    pending_bytes: u32,
};

env: *const Env,
// The listener owns this, don't touch it after detachSession
session: ?*raknet.Session,
backend: ?*raknet.Client = null,
dial: Dial = .{},
dial_task: ?std.Io.Future(void) = null,
pending: PacketQueue,
observer: Observer,
watch: Watch(raknet.Client) = .{},
node: std.DoublyLinkedList.Node = .{},
// Can't free the link while it's still on the ready stack
queued: std.atomic.Value(bool) = .init(false),
next_ready: ?*Link = null,

pub fn create(env: *const Env, session: *raknet.Session) !*Link {
    const self = try env.gpa.create(Link);
    errdefer env.gpa.destroy(self);
    self.* = .{
        .env = env,
        .session = session,
        .pending = .init(env.pending_packets, env.pending_bytes),
        .observer = try .init(env.observer_pool),
    };
    return self;
}

pub fn destroy(self: *Link) void {
    if (self.dial_task) |*task| {
        task.cancel(self.env.io);
        self.dial_task = null;
        if (self.dial.finished()) |result| {
            if (result) |client| client.destroy() else |_| {}
        }
    }
    self.closeBackend();
    self.pending.deinit(self.env.gpa);
    self.observer.deinit();
    self.env.gpa.destroy(self);
}

pub fn startDial(self: *Link, address: std.Io.net.IpAddress, options: raknet.ClientOptions) std.Io.ConcurrentError!void {
    self.dial_task = try self.env.io.concurrent(Dial.run, .{ &self.dial, self.env.gpa, self.env.io, address, options, Scheduler.linkNotify(self) });
}

pub fn isFinished(self: *const Link) bool {
    return self.dial_task == null and self.session == null and self.backend == null;
}

pub fn forwardToBackend(self: *Link, payload: []const u8) !void {
    if (self.observer.watching and self.observe(.client_to_server, payload).rejects()) return error.LoginRejected;
    if (self.backend) |client| {
        try client.send(payload, .reliable_ordered, 0);
        self.env.stats.bytes_to_backend += payload.len;
        self.env.scheduler.schedule(self);
    } else if (self.dial_task != null) {
        try self.pending.push(self.env.gpa, payload);
    } else return error.BackendClosed;
}

pub fn detachSession(self: *Link) void {
    self.session = null;
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
            else => return self.fail(err),
        };
    }
    if (client.isClosed()) return self.fail(error.ConnectionClosed);
    self.watch.arm(self.env.io, client, Scheduler.linkNotify(self)) catch |err| return self.fail(err);
    if (!drained) self.env.scheduler.schedule(self);
}

fn observe(self: *Link, direction: bedwire.TapDirection, payload: []const u8) Observer.Event {
    const event = self.observer.observe(.{ .gpa = self.env.gpa, .io = self.env.io, .auth = self.env.auth }, direction, payload);
    const stats = self.env.stats;
    switch (event) {
        .none => {},
        .encrypted => stats.handshakes_observed += 1,
        .gave_up => stats.observer_gave_up += 1,
        .login_verified => stats.logins_verified += 1,
        .login_rejected => stats.logins_rejected += 1,
        .auth_unavailable => stats.auth_unavailable += 1,
    }
    return event;
}

fn adopt(self: *Link, result: Dial.ConnectError!*raknet.Client) void {
    const client = result catch |err| {
        log.warn("backend connect failed: {t}", .{err});
        self.env.stats.backend_failures += 1;
        return self.closeSession();
    };
    self.backend = client;
    self.env.stats.backends_connected += 1;
    if (self.session == null) return self.closeBackend();
    self.flushPending(client) catch |err| self.fail(err);
}

fn onBackendMessage(context: *anyopaque, payload: raknet.BorrowedPayload) error{ApplicationFailure}!void {
    const self: *Link = @ptrCast(@alignCast(context));
    const session = self.session orelse return error.ApplicationFailure;
    if (self.observer.watching and self.observe(.server_to_client, payload.bytes).rejects()) return error.ApplicationFailure;
    session.send(payload.bytes, .reliable_ordered, 0) catch return error.ApplicationFailure;
    self.env.stats.bytes_to_player += payload.bytes.len;
}

fn flushPending(self: *Link, client: *raknet.Client) !void {
    defer self.pending.clear(self.env.gpa);
    for (self.pending.items()) |packet| {
        try client.send(packet, .reliable_ordered, 0);
        self.env.stats.bytes_to_backend += packet.len;
    }
}

fn fail(self: *Link, err: anyerror) void {
    log.debug("closing link: {t}", .{err});
    self.closeBackend();
    self.closeSession();
}

fn closeSession(self: *Link) void {
    if (self.session) |session| session.close();
}

fn closeBackend(self: *Link) void {
    const client = self.backend orelse return;
    self.backend = null;
    self.watch.cancel(self.env.io);
    client.destroy();
    self.pending.clear(self.env.gpa);
}
