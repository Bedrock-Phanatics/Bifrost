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
pub const Link = @import("Link.zig");
const Plugins = @import("../plugin/Plugins.zig");
const Handles = Plugins.Handles;
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
observer_pool: ?bedwire.BufferPool,
managed: ?Managed.Shared,
env: Link.Env,
links: std.AutoArrayHashMapUnmanaged(u64, *Link) = .empty,
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
        .offline_rate_per_second = config.handshake_rate_per_ip,
        .offline_burst = 2 * config.handshake_rate_per_ip,
    });
    errdefer listener.destroy();
    var observer_pool: ?bedwire.BufferPool = if (config.session_mode == .passthrough) try Observer.initPool(gpa) else null;
    errdefer if (observer_pool) |*pool| pool.deinit();
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
    if (managed) |*shared| shared.transfers = config.backend_count > 1;

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
        .observer_pool = if (self.observer_pool) |*pool| pool else null,
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
    self.links.deinit(self.gpa);
    if (self.managed) |*shared| shared.deinit(self.gpa);
    self.own_admission.deinit();
    if (self.observer_pool) |*pool| pool.deinit();
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
pub fn requestTransfer(self: *Proxy, player: u64, target: Backend.Id) error{ MailboxFull, Canceled }!void {
    {
        self.mailbox_mutex.lockUncancelable(self.io);
        defer self.mailbox_mutex.unlock(self.io);
        if (self.stop_requested.load(.acquire)) return error.Canceled;
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
    return self.links.get(id);
}

pub fn packet(self: *Proxy, link_id: u64, target: abi.PacketTarget, bytes: []const u8) abi.Status {
    const link = self.findLink(link_id) orelse return .stale_handle;
    return link.sendPacket(target, bytes);
}

pub fn action(self: *Proxy, link_id: u64, disconnect: bool, backend: u32, reason: []const u8) abi.Status {
    const link = self.findLink(link_id) orelse return .stale_handle;
    if (disconnect) return link.disconnect(reason);
    if (backend >= self.router.backends.len) return .invalid_argument;
    link.requestTransfer(.of(backend)) catch |err| return switch (err) {
        error.NotManaged => .unsupported,
        error.TransferInProgress => .busy,
        error.NotInGame, error.AlreadyThere => .too_late,
        error.CanceledByPlugin => .canceled,
        else => .failed,
    };
    return .ok;
}

fn routeNetwork(context: *anyopaque, link_id: u64, target: abi.PacketTarget, out: *abi.NetworkStats) abi.Status {
    const self: *Proxy = @ptrCast(@alignCast(context));
    const link = self.findLink(link_id) orelse return .too_late;
    return link.networkStats(target, out);
}

fn routeGameplay(context: *anyopaque, link_id: u64, query: Handles.Query) abi.Status {
    const self: *Proxy = @ptrCast(@alignCast(context));
    const link = self.findLink(link_id) orelse return .too_late;
    return link.gameplay(query);
}

fn routeTransfer(context: *anyopaque, link: u64, backend: u32) abi.Status {
    const self: *Proxy = @ptrCast(@alignCast(context));
    self.requestTransfer(link, .of(backend)) catch |err| return switch (err) {
        error.MailboxFull => .busy,
        error.Canceled => .canceled,
    };
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
    defer @atomicStore(u64, &self.stats.session_memory_bytes, self.listener.session_quota.used_bytes, .monotonic);
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
            const removed = self.links.swapRemove(link.id);
            std.debug.assert(removed);
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
    try self.links.ensureUnusedCapacity(self.gpa, 1);
    const link = try Link.create(&self.env, session);
    errdefer link.destroy();
    link.id = std.math.add(u64, self.next_player, 1) catch return error.PlayerIdExhausted;
    self.next_player = link.id;
    link.player = self.env.events.connected(.{ .context = self, .worker = self.env.events.worker, .link = link.id, .transfer = routeTransfer, .network = routeNetwork, .gameplay = routeGameplay, .io = self.io }, session.address, if (self.env.events.plugins != null) link.playerState() else .{});
    if (link.managed) |managed| managed.plugin_player = link.player;

    try link.connect();
    self.links.putAssumeCapacityNoClobber(link.id, link);
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
        _ = link.disconnect("");
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
    defer @atomicStore(u64, &self.stats.session_memory_bytes, self.listener.session_quota.used_bytes, .monotonic);
    self.listener_watch.cancel(self.io);
    self.listener.close();
    while (self.links.pop()) |entry| {
        const link = entry.value;
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

test "stopped workers reject transfer mailbox submissions without waking" {
    var config: Config = .{ .bind = .{ .ip4 = .loopback(0) }, .max_players = 2 };
    try config.addBackend(null, .{ .ip4 = .loopback(9) });
    const proxy = try Proxy.create(std.testing.allocator, std.testing.io, config, .{});
    defer proxy.destroy();
    for (0..mailbox_capacity) |id| try proxy.requestTransfer(id + 1, .of(0));
    try std.testing.expectError(error.MailboxFull, proxy.requestTransfer(1, .of(0)));
    proxy.stop();
    proxy.scheduler.wake.reset();
    try std.testing.expectError(error.Canceled, proxy.requestTransfer(1, .of(0)));
    try std.testing.expectEqual(abi.Status.canceled, routeTransfer(proxy, 1, 0));
    try std.testing.expectEqual(mailbox_capacity, proxy.mailbox_len);
    proxy.mailbox_len = 0;
    try std.testing.expectError(error.Canceled, proxy.requestTransfer(1, .of(0)));
    try std.testing.expectEqual(@as(usize, 0), proxy.mailbox_len);
    try std.testing.expect(!proxy.scheduler.wake.isSet());
}

test "worker link IDs are retired after failed connections and never wrap" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var config: Config = .{ .bind = .{ .ip4 = .loopback(0) }, .max_players = 2 };
    try config.addBackend(null, .{ .ip4 = .loopback(9) });
    var health: Health = .init(config.backends(), 1000, 100);
    health.markFailed(.of(0));
    const proxy = try Proxy.create(gpa, io, config, .{ .health = &health });
    defer proxy.destroy();
    var session: raknet.Session = undefined;
    session.address = .{ .ip4 = .loopback(1) };
    for (1..3) |id| {
        try std.testing.expectError(error.NoBackendAvailable, proxy.accept(&session));
        try std.testing.expectEqual(id, proxy.next_player);
        try std.testing.expectEqual(@as(usize, 0), proxy.links.count());
        try std.testing.expectEqual(@as(u32, 0), proxy.admission.active.load(.monotonic));
    }
    proxy.next_player = std.math.maxInt(u64);
    try std.testing.expectError(error.PlayerIdExhausted, proxy.accept(&session));
    try std.testing.expectEqual(std.math.maxInt(u64), proxy.next_player);
    try std.testing.expectEqual(@as(u32, 0), proxy.admission.active.load(.monotonic));
}

test "worker link lookup rejects retired IDs after index growth" {
    var proxy: Proxy = undefined;
    proxy.links = .empty;
    defer proxy.links.deinit(std.testing.allocator);
    var links: [64]Link = undefined;
    for (&links, 0..) |*link, i| {
        link.id = (i + 1) * 97;
        link.managed = null;
        try proxy.links.putNoClobber(std.testing.allocator, link.id, link);
    }
    for (&links) |link| try std.testing.expectEqual(abi.Status.unsupported, proxy.packet(link.id, .player, ""));
    const retired = links[16].id;
    try std.testing.expect(proxy.links.swapRemove(retired));
    links[16].id = 100000;
    try proxy.links.putNoClobber(std.testing.allocator, links[16].id, &links[16]);
    try std.testing.expectEqual(abi.Status.stale_handle, proxy.packet(retired, .player, ""));
    try std.testing.expectEqual(abi.Status.stale_handle, proxy.packet(0, .player, ""));
    for (&links) |link| try std.testing.expectEqual(abi.Status.unsupported, proxy.packet(link.id, .player, ""));
    while (proxy.links.pop()) |entry| try std.testing.expectEqual(abi.Status.stale_handle, proxy.packet(entry.key, .player, ""));
}

test "worker link registration cleans up allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            var config: Config = .{ .bind = .{ .ip4 = .loopback(0) }, .max_players = 2 };
            try config.addBackend(null, .{ .ip4 = .loopback(9) });
            var health: Health = .init(config.backends(), 1000, 100);
            health.markFailed(.of(0));
            const proxy = try Proxy.create(gpa, std.testing.io, config, .{ .health = &health });
            defer proxy.destroy();
            var session: raknet.Session = undefined;
            session.address = .{ .ip4 = .loopback(1) };
            if (proxy.accept(&session)) |_| return error.ExpectedRejection else |err| {
                if (err != error.NoBackendAvailable) return err;
            }
            try std.testing.expectEqual(@as(u32, 0), proxy.admission.active.load(.monotonic));
            try std.testing.expectEqual(@as(usize, 0), proxy.links.count());
        }
    }.run, .{});
}
