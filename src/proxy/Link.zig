const std = @import("std");
const raknet = @import("raknet");
const Dial = @import("../backend/Dial.zig");
const Watch = @import("../net/watch.zig").Watch;
const PacketQueue = @import("PacketQueue.zig");
const Scheduler = @import("Scheduler.zig");
const Stats = @import("Stats.zig");

const Link = @This();
const log = std.log.scoped(.link);

const max_polls_per_turn = 4;
const no_wait: std.Io.Timeout = .{ .duration = .{ .raw = .zero, .clock = .awake } };

gpa: std.mem.Allocator,
io: std.Io,
stats: *Stats,
scheduler: *Scheduler,
/// Owned by the listener, gone after `detachSession`.
session: ?*raknet.Session,
backend: ?*raknet.Client = null,
dial: Dial = .{},
dial_task: ?std.Io.Future(void) = null,
pending: PacketQueue,
watch: Watch(raknet.Client) = .{},
node: std.DoublyLinkedList.Node = .{},
/// Set while the link is on the scheduler's ready stack, so it can't be freed yet.
queued: std.atomic.Value(bool) = .init(false),
next_ready: ?*Link = null,

pub fn create(gpa: std.mem.Allocator, io: std.Io, stats: *Stats, scheduler: *Scheduler, session: *raknet.Session, pending: PacketQueue) !*Link {
    const self = try gpa.create(Link);
    self.* = .{ .gpa = gpa, .io = io, .stats = stats, .scheduler = scheduler, .session = session, .pending = pending };
    return self;
}

pub fn destroy(self: *Link) void {
    if (self.dial_task) |*task| {
        task.cancel(self.io);
        self.dial_task = null;
        if (self.dial.finished()) |result| {
            if (result) |client| client.destroy() else |_| {}
        }
    }
    self.closeBackend();
    self.pending.deinit(self.gpa);
    self.gpa.destroy(self);
}

pub fn startDial(self: *Link, address: std.Io.net.IpAddress, options: raknet.ClientOptions) std.Io.ConcurrentError!void {
    self.dial_task = try self.io.concurrent(Dial.run, .{ &self.dial, self.gpa, self.io, address, options, Scheduler.linkNotify(self) });
}

pub fn isFinished(self: *const Link) bool {
    return self.dial_task == null and self.session == null and self.backend == null;
}

pub fn forwardToBackend(self: *Link, payload: []const u8) !void {
    if (self.backend) |client| {
        try client.send(payload, .reliable_ordered, 0);
        self.stats.bytes_to_backend += payload.len;
        // The send may have moved the next retransmit deadline
        self.scheduler.schedule(self);
    } else if (self.dial_task != null) {
        try self.pending.push(self.gpa, payload);
    } else return error.BackendClosed;
}

pub fn detachSession(self: *Link) void {
    self.session = null;
    self.closeBackend();
    self.scheduler.schedule(self);
}

pub fn service(self: *Link) error{Canceled}!void {
    if (self.dial_task) |*task| if (self.dial.finished()) |result| {
        task.await(self.io);
        self.dial_task = null;
        self.adopt(result);
    };
    _ = self.watch.take(self.io);
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
    self.watch.arm(self.io, client, Scheduler.linkNotify(self)) catch |err| return self.fail(err);
    if (!drained) self.scheduler.schedule(self);
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
    self.watch.cancel(self.io);
    client.destroy();
    self.pending.clear(self.gpa);
}
