const std = @import("std");
const Config = @import("../config/Config.zig");
const Health = @import("../backend/Health.zig");
const Notify = @import("../net/Notify.zig");
const Observer = @import("../protocol/Observer.zig");
const proxy_key = @import("../session/proxy_key.zig");
const Admission = @import("Admission.zig");
const Proxy = @import("Proxy.zig");
const Stats = @import("Stats.zig");
const Plugins = @import("../plugin/Plugins.zig");

const Workers = @This();
const log = std.log.scoped(.stats);

const report_interval_s = 60;

gpa: std.mem.Allocator,
io: std.Io,
config: Config,
admission: Admission,
health: Health,
watchers: []Notify,
proxies: []*Proxy,

pub const Options = struct {
    auth: Observer.Auth = .off,
    proxy_key: ?proxy_key.Ecdsa.KeyPair = null,
    plugins: ?*Plugins = null,
};

pub fn create(gpa: std.mem.Allocator, io: std.Io, config: Config, options: Options) !*Workers {
    try config.validate();
    const self = try gpa.create(Workers);
    errdefer gpa.destroy(self);
    self.* = .{
        .gpa = gpa,
        .io = io,
        .config = config,
        .admission = try .init(gpa, config.max_players, config.max_players_per_ip),
        .health = undefined,
        .watchers = &.{},
        .proxies = &.{},
    };
    errdefer self.admission.deinit();
    self.health = .init(self.config.backends(), config.health_interval_ms, config.health_timeout_ms);
    self.proxies = try gpa.alloc(*Proxy, config.workers);
    errdefer gpa.free(self.proxies);
    self.watchers = try gpa.alloc(Notify, config.workers);
    errdefer gpa.free(self.watchers);

    var created: usize = 0;
    errdefer for (self.proxies[0..created]) |proxy| proxy.destroy();
    var worker_config = config;
    for (self.proxies, self.watchers, 0..) |*proxy, *watcher, worker| {
        proxy.* = try Proxy.create(gpa, io, worker_config, .{
            .auth = options.auth,
            .admission = &self.admission,
            .health = &self.health,
            .proxy_key = options.proxy_key,
            .plugins = options.plugins,
            .worker = @intCast(worker),
        });
        watcher.* = proxy.*.healthNotify();
        created += 1;
        // Needed when bind uses port 0
        worker_config.bind = self.proxies[0].localAddress();
    }
    self.health.watchers = self.watchers;
    return self;
}

pub fn destroy(self: *Workers) void {
    for (self.proxies) |proxy| proxy.destroy();
    self.admission.deinit();
    self.gpa.free(self.watchers);
    self.gpa.free(self.proxies);
    self.gpa.destroy(self);
}

pub fn localAddress(self: *const Workers) std.Io.net.IpAddress {
    return self.proxies[0].localAddress();
}

pub fn stop(self: *Workers) void {
    for (self.proxies) |proxy| proxy.stop();
}

pub fn run(self: *Workers) !void {
    var health_task = try self.io.concurrent(Health.run, .{ &self.health, self.io });
    defer health_task.cancel(self.io);
    var report_task = try self.io.concurrent(report, .{self});
    defer report_task.cancel(self.io);

    const tasks = try self.gpa.alloc(std.Io.Future(void), self.proxies.len);
    defer self.gpa.free(tasks);
    var started: usize = 0;
    defer for (tasks[0..started]) |*task| task.await(self.io);
    errdefer self.stop();

    for (self.proxies, tasks) |proxy, *task| {
        task.* = try self.io.concurrent(runWorker, .{ self, proxy });
        started += 1;
    }
}

pub fn totals(self: *const Workers) Stats {
    var sum: Stats = .{};
    for (self.proxies) |proxy| sum.add(proxy.stats.snapshot());
    return sum;
}

fn report(self: *Workers) void {
    while (true) {
        self.io.sleep(.fromSeconds(report_interval_s), .awake) catch return;
        const totals_now = self.totals();
        log.info("{d} online, {d} joined, {d}/{d} backends up, {d} backend failures, {Bi:.1} to backends, {Bi:.1} to players", .{
            self.admission.active.load(.monotonic),
            totals_now.sessions_accepted,
            self.health.healthyCount(),
            self.health.backends.len,
            totals_now.backend_failures,
            totals_now.bytes_to_backend,
            totals_now.bytes_to_player,
        });
    }
}

fn runWorker(self: *Workers, proxy: *Proxy) void {
    proxy.run();
    self.stop();
}
