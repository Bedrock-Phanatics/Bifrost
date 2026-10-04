const std = @import("std");
const raknet = @import("raknet");
const bedwire = @import("bedwire");
const Config = @import("../config/Config.zig");
const Health = @import("../backend/Health.zig");
const Router = @import("../backend/Router.zig");
const Notify = @import("../net/Notify.zig");
const Watch = @import("../net/watch.zig").Watch;
const no_wait = @import("../net/watch.zig").no_wait;
const Observer = @import("../protocol/Observer.zig");
const Managed = @import("../session/Managed.zig");
const proxy_key = @import("../session/proxy_key.zig");
const advertisement = @import("../protocol/advertisement.zig");
const Admission = @import("Admission.zig");
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
admission: *Admission,
own_admission: Admission,
observer_pool: bedwire.BufferPool,
managed: ?Managed.Shared,
env: Link.Env,
links: std.DoublyLinkedList = .{},
listener_watch: Watch(raknet.Server) = .{},
listener_busy: bool = false,
listener_failures: u8 = 0,
stop_requested: std.atomic.Value(bool) = .init(false),
health_changed: std.atomic.Value(bool) = .init(false),
stats: Stats = .{},

pub const Options = struct {
    auth: Observer.Auth = .off,
    admission: ?*Admission = null,
    health: ?*Health = null,
    proxy_key: ?proxy_key.Ecdsa.KeyPair = null,
};

pub fn create(gpa: std.mem.Allocator, io: std.Io, config: Config, options: Options) !*Proxy {
    try config.validate();
    const self = try gpa.create(Proxy);
    errdefer gpa.destroy(self);

    var raknet_config: raknet.Config = .{};
    raknet_config.listener.maximum_connections = config.max_players;
    var ad_buffer: [advertisement_capacity]u8 = undefined;
    const listener = try raknet.Server.listen(gpa, io, config.bind, .{
        .advertisement = renderAdvertisement(&config, &ad_buffer, 0),
        .config = raknet_config,
        .reuse_port = config.workers > 1,
    });
    errdefer listener.destroy();
    var observer_pool = try Observer.initPool(gpa);
    errdefer observer_pool.deinit();
    const own_per_ip = if (options.admission == null) config.max_players_per_ip else 0;
    var own_admission: Admission = try .init(gpa, config.max_players, own_per_ip);
    errdefer own_admission.deinit();
    var managed: ?Managed.Shared = switch (config.session_mode) {
        .passthrough => null,
        .managed => try .init(
            gpa,
            options.proxy_key orelse return error.MissingProxyKey,
            switch (options.auth) {
                .verify => |keys| keys,
                .off => return error.ManagedNeedsVerifiedLogins,
            },
        ),
    };
    errdefer if (managed) |*shared| shared.deinit(gpa);

    self.* = .{
        .gpa = gpa,
        .io = io,
        .config = config,
        .router = undefined,
        .listener = listener,
        .scheduler = .{ .io = io },
        .admission = undefined,
        .own_admission = own_admission,
        .observer_pool = observer_pool,
        .managed = managed,
        .env = undefined,
    };
    self.admission = options.admission orelse &self.own_admission;
    self.router = .init(self.config.backends(), options.health);
    self.env = .{
        .gpa = gpa,
        .io = io,
        .stats = &self.stats,
        .scheduler = &self.scheduler,
        .observer_pool = &self.observer_pool,
        .auth = options.auth,
        .health = options.health,
        .router = &self.router,
        .connect_timeout_ms = config.connect_timeout_ms,
        .pending_packets = config.pending_packets,
        .pending_bytes = config.pending_bytes,
        .managed = if (self.managed) |*shared| shared else null,
    };
    return self;
}

pub fn destroy(self: *Proxy) void {
    self.closeAll();
    if (self.managed) |*shared| shared.deinit(self.gpa);
    self.own_admission.deinit();
    self.observer_pool.deinit();
    self.listener.destroy();
    self.gpa.destroy(self);
}

pub fn localAddress(self: *const Proxy) std.Io.net.IpAddress {
    return self.listener.localAddress();
}

pub fn healthNotify(self: *Proxy) Notify {
    return .{ .context = self, .call = onHealthChanged };
}

fn onHealthChanged(context: *anyopaque) void {
    const self: *Proxy = @ptrCast(@alignCast(context));
    self.health_changed.store(true, .release);
    self.scheduler.wake.set(self.io);
}

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
    // Reset before checking, or we could miss a wake
    self.scheduler.wake.reset();

    if (self.health_changed.swap(false, .acquire)) self.refreshAdvertisement();
    const listener_ready = self.listener_watch.take(self.io);
    if (listener_ready or self.listener_busy) self.pollListener();
    self.serviceReady() catch return self.stop();
    if (self.listener_busy or self.scheduler.hasReady()) self.scheduler.wake.set(self.io);
}

const advertisement_capacity = Config.max_motd_len + 32;

fn renderAdvertisement(config: *const Config, buffer: *[advertisement_capacity]u8, online: u32) []const u8 {
    return advertisement.render(buffer, config.motd(), online, config.max_players) catch config.motd();
}

fn refreshAdvertisement(self: *Proxy) void {
    const health = self.env.health orelse return;
    var buffer: [advertisement_capacity]u8 = undefined;
    self.listener.setAdvertisement(renderAdvertisement(&self.config, &buffer, health.onlinePlayers())) catch |err|
        log.warn("advertisement not updated: {t}", .{err});
}

fn pollListener(self: *Proxy) void {
    const result = self.listener.poll(no_wait, .{
        .context = self,
        .connected = onConnected,
        .message = onMessage,
        .disconnected = onDisconnected,
    });
    const stats = result catch |err| {
        self.listener_busy = false;
        if (err == error.Canceled) return self.stop();
        self.stats.bump(.listener_errors, 1);
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
        // Grab next first, another task can push this link again once queued is cleared
        next = link.next_ready;
        link.queued.store(false, .release);
        try link.service();
        if (link.isFinished() and !link.queued.load(.acquire)) {
            self.links.remove(&link.node);
            link.destroy();
            self.stats.bump(.links_closed, 1);
        }
    }
}

fn onConnected(context: *anyopaque, session: *raknet.Session) error{ApplicationFailure}!void {
    const self: *Proxy = @ptrCast(@alignCast(context));
    self.accept(session) catch |err| {
        log.warn("rejecting player: {t}", .{err});
        self.stats.bump(.sessions_rejected, 1);
        // Returning an error here drops the player without telling them
        session.close();
    };
}

fn accept(self: *Proxy, session: *raknet.Session) !void {
    try self.admission.enter(self.io, session.address);
    errdefer self.admission.leave(self.io, session.address);
    const link = try Link.create(&self.env, session);
    errdefer link.destroy();

    try link.connect();
    self.links.append(&link.node);
    session.setUserData(link);
    self.stats.bump(.sessions_accepted, 1);
}

fn linkOf(session: *const raknet.Session) ?*Link {
    return @ptrCast(@alignCast(session.userData() orelse return null));
}

fn onMessage(_: *anyopaque, session: *raknet.Session, payload: raknet.BorrowedPayload) error{ApplicationFailure}!void {
    const link = linkOf(session) orelse return error.ApplicationFailure;
    link.forwardToBackend(payload.bytes) catch |err| {
        log.debug("dropping player: {t}", .{err});
        session.close();
    };
}

fn onDisconnected(context: *anyopaque, session: *raknet.Session) void {
    const self: *Proxy = @ptrCast(@alignCast(context));
    const link = linkOf(session) orelse return;
    session.setUserData(null);
    link.detachSession();
    self.admission.leave(self.io, session.address);
}

fn closeAll(self: *Proxy) void {
    self.listener_watch.cancel(self.io);
    self.listener.close();
    while (self.links.popFirst()) |node| {
        const link: *Link = @fieldParentPtr("node", node);
        // The session outlives the link until listener.destroy()
        if (link.session) |session| {
            session.setUserData(null);
            self.admission.leave(self.io, session.address);
        }
        link.session = null;
        link.destroy();
        self.stats.bump(.links_closed, 1);
    }
    self.scheduler.ready.store(null, .monotonic);
}
