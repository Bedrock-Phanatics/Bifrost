//! Only the `run` task touches raknet objects; other tasks talk to it through atomics and `wake`.

const std = @import("std");
const raknet = @import("raknet");
const Config = @import("../config/Config.zig");
const Dial = @import("../backend/Dial.zig");
const Router = @import("../backend/Router.zig");
const Watch = @import("../net/watch.zig").Watch;
const Link = @import("Link.zig");
const Stats = @import("Stats.zig");

const Proxy = @This();
const log = std.log.scoped(.proxy);

gpa: std.mem.Allocator,
io: std.Io,
config: Config,
router: Router,
listener: *raknet.Server,
links: std.ArrayList(*Link) = .empty,
by_session: std.AutoHashMapUnmanaged(*raknet.Session, *Link) = .empty,
dials: std.Io.Group = .init,
wake: std.Io.Event = .unset,
listener_watch: Watch(raknet.Server) = .{},
listener_busy: bool = false,
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
    self.* = .{ .gpa = gpa, .io = io, .config = config, .router = undefined, .listener = listener };
    self.router = .init(self.config.backends());
    return self;
}

pub fn destroy(self: *Proxy) void {
    self.closeAll();
    self.links.deinit(self.gpa);
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
    self.wake.set(self.io);
}

pub fn run(self: *Proxy) void {
    while (!self.stop_requested.load(.acquire)) self.turn();
    self.closeAll();
}

fn turn(self: *Proxy) void {
    self.armWatches() catch return self.stop();
    self.wake.wait(self.io) catch return self.stop();
    // Reset first so a wake that lands mid-turn isn't lost
    self.wake.reset();

    const listener_ready = self.listener_watch.take(self.io);
    if (listener_ready or self.listener_busy) self.pollListener();
    const links_busy = self.serviceLinks() catch return self.stop();
    if (links_busy or self.listener_busy) self.wake.set(self.io);
}

fn armWatches(self: *Proxy) !void {
    self.listener_watch.arm(self.io, self.listener, &self.wake) catch |err| {
        log.err("listener watch failed: {t}", .{err});
        return err;
    };
    for (self.links.items) |link| link.arm(&self.wake);
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
        log.warn("listener poll failed: {t}", .{err});
        return;
    };
    self.listener_busy = stats.datagrams != 0;
}

fn serviceLinks(self: *Proxy) error{Canceled}!bool {
    var busy = false;
    var i: usize = 0;
    while (i < self.links.items.len) {
        const link = self.links.items[i];
        try link.service();
        busy = busy or link.busy;
        if (!link.isFinished()) {
            i += 1;
            continue;
        }
        _ = self.links.swapRemove(i);
        link.destroy();
        self.stats.links_closed += 1;
    }
    return busy;
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
    try self.links.ensureUnusedCapacity(self.gpa, 1);
    try self.by_session.ensureUnusedCapacity(self.gpa, 1);
    const link = try Link.create(self.gpa, self.io, &self.stats, session, .init(self.config.pending_packets, self.config.pending_bytes));
    errdefer link.destroy();

    const options: raknet.ClientOptions = .{ .handshake_timeout_ms = self.config.connect_timeout_ms };
    try self.dials.concurrent(self.io, Dial.run, .{ &link.dial, self.gpa, self.io, self.router.pick(), options, &self.wake });
    link.dialing = true;
    self.links.appendAssumeCapacity(link);
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
    self.dials.cancel(self.io);
    for (self.links.items) |link| {
        link.session = null;
        link.destroy();
        self.stats.links_closed += 1;
    }
    self.links.clearRetainingCapacity();
}
