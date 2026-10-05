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
const Backend = @import("../backend/Backend.zig");
const Transfer = @import("../transfer/Transfer.zig");
const Link = @import("Link.zig");
const Plugins = @import("../plugin/Plugins.zig");
const abi = @import("../plugin/abi.zig");
const Scheduler = @import("Scheduler.zig");
const Stats = @import("Stats.zig");

const Proxy = @This();
const log = std.log.scoped(.proxy);

const max_listener_failures = 32;
const mailbox_capacity = 64;

pub const TransferRequest = struct { player: u64, target: Backend.Id };

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
next_player: u64 = 0,
next_epoch: Transfer.State.Epoch = 0,
mailbox_mutex: std.Io.Mutex = .init,
mailbox: [mailbox_capacity]TransferRequest = undefined,
mailbox_len: usize = 0,

pub const Options = struct {
    auth: Observer.Auth = .off,
    admission: ?*Admission = null,
    health: ?*Health = null,
    proxy_key: ?proxy_key.Ecdsa.KeyPair = null,
    plugins: ?*Plugins = null,
    worker: u32 = 0,
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
    if (options.plugins) |plugins| {
        plugins.attachWorker(options.worker, self.scheduler.wakeNotify());
        if (self.managed) |*shared| shared.hooks = .{ .plugins = plugins, .worker = options.worker };
    }
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
        .transfer = .{
            .limits = .{
                .dial_ms = config.connect_timeout_ms,
                .phase_ms = config.transfer_phase_timeout_ms,
                .total_ms = config.transfer_timeout_ms,
            },
            .queue_packets = config.pending_packets,
            .queue_bytes = config.pending_bytes,
            .content_policy = config.content_policy,
        },
        .next_epoch = &self.next_epoch,
        .events = .{ .plugins = options.plugins, .worker = options.worker },
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

// Any thread; the player's own worker runs it
pub fn requestTransfer(self: *Proxy, player: u64, target: Backend.Id) error{MailboxFull}!void {
    {
        self.mailbox_mutex.lockUncancelable(self.io);
        defer self.mailbox_mutex.unlock(self.io);
        if (self.mailbox_len == mailbox_capacity) return error.MailboxFull;
        self.mailbox[self.mailbox_len] = .{ .player = player, .target = target };
        self.mailbox_len += 1;
    }
    self.scheduler.wake.set(self.io);
}

fn drainMailbox(self: *Proxy) void {
    var requests: [mailbox_capacity]TransferRequest = undefined;
    const count = count: {
        self.mailbox_mutex.lockUncancelable(self.io);
        defer self.mailbox_mutex.unlock(self.io);
        const count = self.mailbox_len;
        @memcpy(requests[0..count], self.mailbox[0..count]);
        self.mailbox_len = 0;
        break :count count;
    };
    for (requests[0..count]) |request| self.startTransfer(request);
}

fn startTransfer(self: *Proxy, request: TransferRequest) void {
    const found = self.findLink(request.player) orelse return self.rejectTransfer(request, error.UnknownPlayer);
    found.requestTransfer(request.target) catch |err| self.rejectTransfer(request, err);
}

pub fn message(self: *Proxy, link_id: u64, text: []const u8) void {
    const link = self.findLink(link_id) orelse return;
    link.sendMessage(text) catch |err| log.debug("plugin message dropped: {t}", .{err});
}

fn findLink(self: *Proxy, id: u64) ?*Link {
    var it = self.links.first;
    while (it) |node| : (it = node.next) {
        const link: *Link = @fieldParentPtr("node", node);
        if (link.id == id) return link;
    }
    return null;
}

fn routeTransfer(context: *anyopaque, link: u64, backend: u32) abi.Status {
    const self: *Proxy = @ptrCast(@alignCast(context));
    self.requestTransfer(link, .of(backend)) catch return .busy;
    return .ok;
}

fn rejectTransfer(self: *Proxy, request: TransferRequest, err: anyerror) void {
    log.info("transfer of player {d} to backend {d} rejected: {t}", .{ request.player, request.target.index(), err });
    self.stats.bump(.transfers_rejected, 1);
}

pub fn stop(self: *Proxy) void {
    self.env.events.proxyStopping();
    self.stop_requested.store(true, .release);
    self.scheduler.wake.set(self.io);
}

pub fn run(self: *Proxy) void {
    self.env.events.proxyStarted();
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
    self.drainMailbox();
    self.env.events.drain(self.io, self);
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
    link.id = self.next_player + 1;
    link.player = self.env.events.connected(.{ .context = self, .worker = self.env.events.worker, .link = link.id, .transfer = routeTransfer }, session.address);
    if (link.managed) |managed| managed.plugin_player = link.player;

    try link.connect();
    self.next_player += 1;
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
