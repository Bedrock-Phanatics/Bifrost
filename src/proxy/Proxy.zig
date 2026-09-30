//! Only the `run` task touches raknet objects; other tasks reach it through the scheduler.

const std = @import("std");
const raknet = @import("raknet");
const Config = @import("../config/Config.zig");
const Router = @import("../backend/Router.zig");
const Watch = @import("../net/watch.zig").Watch;
const Link = @import("Link.zig");
const Scheduler = @import("Scheduler.zig");
const Stats = @import("Stats.zig");

const Proxy = @This();
const log = std.log.scoped(.proxy);

const max_listener_failures = 32;

gpa: std.mem.Allocator,
io: std.Io,
config: Config,
router: Router,
listener: *raknet.Server,
scheduler: Scheduler,
links: std.DoublyLinkedList = .{},
by_session: std.AutoHashMapUnmanaged(*raknet.Session, *Link) = .empty,
listener_watch: Watch(raknet.Server) = .{},
listener_busy: bool = false,
listener_failures: u8 = 0,
stop_requested: std.atomic.Value(bool) = .init(false),
stats: Stats = .{},

pub fn create(gpa: std.mem.Allocator, io: std.Io, config: Config) !*Proxy {
    try config.validate();
    const self = try gpa.create(Proxy);
    errdefer gpa.destroy(self);

    var raknet_config: raknet.Config = .{};
    raknet_config.listener.maximum_connections = config.max_players;
    const listener = try raknet.Server.listen(gpa, io, config.bind, .{
        .advertisement = config.motd(),
        .config = raknet_config,
    });
    self.* = .{
        .gpa = gpa,
        .io = io,
        .config = config,
        .router = undefined,
        .listener = listener,
        .scheduler = .{ .io = io },
    };
    self.router = .init(self.config.backends());
    return self;
}

pub fn destroy(self: *Proxy) void {
    self.closeAll();
    self.listener.destroy();
    self.gpa.destroy(self);
}

pub fn localAddress(self: *const Proxy) std.Io.net.IpAddress {
    // TODO: switch to a public accessor once raknet-zig has one
    return self.listener.socket.value.address;
}

/// Safe to call from any thread.
pub fn stop(self: *Proxy) void {
    self.stop_requested.store(true, .release);
    self.scheduler.wake.set(self.io);
}

pub fn run(self: *Proxy) void {
    while (!self.stop_requested.load(.acquire)) self.turn();
    self.closeAll();
}

fn turn(self: *Proxy) void {
    self.listener_watch.arm(self.io, self.listener, self.scheduler.wakeNotify()) catch |err| {
        log.err("listener watch failed: {t}", .{err});
        return self.stop();
    };
    self.scheduler.wake.wait(self.io) catch return self.stop();
    // Reset first so a wake that lands mid-turn isn't lost
    self.scheduler.wake.reset();

    const listener_ready = self.listener_watch.take(self.io);
    if (listener_ready or self.listener_busy) self.pollListener();
    self.serviceReady() catch return self.stop();
    if (self.listener_busy or self.scheduler.hasReady()) self.scheduler.wake.set(self.io);
}

fn pollListener(self: *Proxy) void {
    const result = self.listener.poll(.{ .duration = .{ .raw = .zero, .clock = .awake } }, .{
        .context = self,
        .connected = onConnected,
        .message = onMessage,
        .disconnected = onDisconnected,
    });
    const stats = result catch |err| {
        self.listener_busy = false;
        if (err == error.Canceled) return self.stop();
        self.stats.listener_errors += 1;
        self.listener_failures += 1;
        if (self.listener_failures < max_listener_failures) return log.warn("listener poll failed: {t}", .{err});
        log.err("listener keeps failing, stopping: {t}", .{err});
        return self.stop();
    };
    self.listener_failures = 0;
    self.listener_busy = stats.datagrams != 0;
}

fn serviceReady(self: *Proxy) error{Canceled}!void {
    var next = self.scheduler.takeReady();
    while (next) |link| {
        // Read before clearing `queued`, after which another task may push it again
        next = link.next_ready;
        link.queued.store(false, .release);
        try link.service();
        if (link.isFinished() and !link.queued.load(.acquire)) {
            self.links.remove(&link.node);
            link.destroy();
            self.stats.links_closed += 1;
        }
    }
}

fn onConnected(context: *anyopaque, session: *raknet.Session) error{ApplicationFailure}!void {
    const self: *Proxy = @ptrCast(@alignCast(context));
    self.accept(session) catch |err| {
        log.warn("rejecting player: {t}", .{err});
        self.stats.sessions_rejected += 1;
        return error.ApplicationFailure;
    };
}

fn accept(self: *Proxy, session: *raknet.Session) !void {
    try self.by_session.ensureUnusedCapacity(self.gpa, 1);
    const pending: @FieldType(Link, "pending") = .init(self.config.pending_packets, self.config.pending_bytes);
    const link = try Link.create(self.gpa, self.io, &self.stats, &self.scheduler, session, pending);
    errdefer link.destroy();

    try link.startDial(self.router.pick(), .{ .handshake_timeout_ms = self.config.connect_timeout_ms });
    self.links.append(&link.node);
    self.by_session.putAssumeCapacity(session, link);
    self.stats.sessions_accepted += 1;
}

fn onMessage(context: *anyopaque, session: *raknet.Session, payload: raknet.BorrowedPayload) error{ApplicationFailure}!void {
    const self: *Proxy = @ptrCast(@alignCast(context));
    const link = self.by_session.get(session) orelse return error.ApplicationFailure;
    link.forwardToBackend(payload.bytes) catch |err| {
        log.debug("dropping player: {t}", .{err});
        return error.ApplicationFailure;
    };
}

fn onDisconnected(context: *anyopaque, session: *raknet.Session) void {
    const self: *Proxy = @ptrCast(@alignCast(context));
    const entry = self.by_session.fetchRemove(session) orelse return;
    entry.value.detachSession();
}

fn closeAll(self: *Proxy) void {
    self.listener_watch.cancel(self.io);
    self.listener.close();
    self.by_session.clearAndFree(self.gpa);
    while (self.links.popFirst()) |node| {
        const link: *Link = @fieldParentPtr("node", node);
        link.session = null;
        link.destroy();
        self.stats.links_closed += 1;
    }
    // Every task that could push has been awaited, so stale entries are never read
    self.scheduler.ready.store(null, .monotonic);
}
