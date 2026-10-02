const std = @import("std");
const Config = @import("../config/Config.zig");
const Health = @import("../backend/Health.zig");
const Notify = @import("../net/Notify.zig");
const Observer = @import("../protocol/Observer.zig");
const Admission = @import("Admission.zig");
const Proxy = @import("Proxy.zig");
const Stats = @import("Stats.zig");

const Workers = @This();

gpa: std.mem.Allocator,
io: std.Io,
config: Config,
admission: Admission,
health: Health,
watchers: []Notify,
proxies: []*Proxy,

pub fn create(gpa: std.mem.Allocator, io: std.Io, config: Config, auth: Observer.Auth) !*Workers {
    try config.validate();
    const self = try gpa.create(Workers);
    errdefer gpa.destroy(self);
    self.* = .{
        .gpa = gpa,
        .io = io,
        .config = config,
        .admission = .init(config.max_players),
        .health = undefined,
        .watchers = &.{},
        .proxies = &.{},
    };
    self.health = .init(self.config.backends(), config.health_interval_ms, config.health_timeout_ms);
    self.proxies = try gpa.alloc(*Proxy, config.workers);
    errdefer gpa.free(self.proxies);
    self.watchers = try gpa.alloc(Notify, config.workers);
    errdefer gpa.free(self.watchers);

    var created: usize = 0;
    errdefer for (self.proxies[0..created]) |proxy| proxy.destroy();
    var worker_config = config;
    for (self.proxies, self.watchers) |*proxy, *watcher| {
        proxy.* = try Proxy.create(gpa, io, worker_config, .{ .auth = auth, .admission = &self.admission, .health = &self.health });
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
    for (self.proxies) |proxy| sum.add(proxy.stats);
    return sum;
}

fn runWorker(self: *Workers, proxy: *Proxy) void {
    proxy.run();
    self.stop();
}
