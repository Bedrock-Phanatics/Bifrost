const std = @import("std");
const raknet = @import("raknet");
const Dial = @import("../backend/Dial.zig");
const Watch = @import("../net/watch.zig").Watch;
const PacketQueue = @import("PacketQueue.zig");
const Stats = @import("Stats.zig");

const Link = @This();
const log = std.log.scoped(.link);

const max_polls_per_turn = 4;
const no_wait: std.Io.Timeout = .{ .duration = .{ .raw = .zero, .clock = .awake } };

gpa: std.mem.Allocator,
io: std.Io,
stats: *Stats,
/// Owned by the listener, gone after `detachSession`.
session: ?*raknet.Session,
backend: ?*raknet.Client = null,
/// Keeps the link alive while the dial task can still write to it.
dialing: bool = false,
dial: Dial = .{},
pending: PacketQueue,
watch: Watch(raknet.Client) = .{},
busy: bool = false,

pub fn create(gpa: std.mem.Allocator, io: std.Io, stats: *Stats, session: *raknet.Session, pending: PacketQueue) !*Link {
    const self = try gpa.create(Link);
    self.* = .{ .gpa = gpa, .io = io, .stats = stats, .session = session, .pending = pending };
    return self;
}

pub fn destroy(self: *Link) void {
    if (self.dialing) {
        self.dialing = false;
        if (self.dial.finished().?) |client| client.destroy() else |_| {}
    }
    self.closeBackend();
    self.pending.deinit(self.gpa);
    self.gpa.destroy(self);
}

pub fn isFinished(self: *const Link) bool {
    return !self.dialing and self.session == null and self.backend == null;
}

pub fn forwardToBackend(self: *Link, payload: []const u8) !void {
    if (self.backend) |client| {
        try client.send(payload, .reliable_ordered, 0);
        self.stats.bytes_to_backend += payload.len;
    } else if (self.dialing) {
        try self.pending.push(self.gpa, payload);
    } else return error.BackendClosed;
}

pub fn arm(self: *Link, wake: *std.Io.Event) void {
    const client = self.backend orelse return;
    self.watch.arm(self.io, client, wake) catch |err| self.fail(err);
}

pub fn service(self: *Link) error{Canceled}!void {
    const ready = self.watch.take(self.io);
    if (self.dialing or self.busy or ready) try self.pump();
}

pub fn detachSession(self: *Link) void {
    self.session = null;
    self.closeBackend();
}

fn pump(self: *Link) error{Canceled}!void {
    self.busy = false;
    if (self.dialing) {
        const result = self.dial.finished() orelse return;
        self.dialing = false;
        self.adopt(result);
    }
    const client = self.backend orelse return;
    for (0..max_polls_per_turn) |_| {
        _ = client.poll(no_wait, self, onBackendMessage) catch |err| switch (err) {
            error.Timeout => break,
            error.Canceled => return error.Canceled,
            else => return self.fail(err),
        };
    } else self.busy = true;
    if (client.isClosed()) self.fail(error.ConnectionClosed);
}

fn adopt(self: *Link, result: Dial.ConnectError!*raknet.Client) void {
    const client = result catch |err| {
        log.warn("backend connect failed: {t}", .{err});
        self.stats.backend_failures += 1;
        return self.closeSession();
    };
    self.backend = client;
    self.stats.backends_connected += 1;
    if (self.session == null) return self.closeBackend();
    self.flushPending(client) catch |err| self.fail(err);
}

fn onBackendMessage(context: *anyopaque, payload: raknet.BorrowedPayload) error{ApplicationFailure}!void {
    const self: *Link = @ptrCast(@alignCast(context));
    const session = self.session orelse return error.ApplicationFailure;
    session.send(payload.bytes, .reliable_ordered, 0) catch return error.ApplicationFailure;
    self.stats.bytes_to_player += payload.bytes.len;
}

fn flushPending(self: *Link, client: *raknet.Client) !void {
    defer self.pending.clear(self.gpa);
    for (self.pending.items()) |packet| {
        try client.send(packet, .reliable_ordered, 0);
        self.stats.bytes_to_backend += packet.len;
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
    self.busy = false;
    self.watch.cancel(self.io);
    client.destroy();
    self.pending.clear(self.gpa);
}
