const std = @import("std");
const raknet = @import("raknet");
const Config = @import("../config/Config.zig");
const Backend = @import("Backend.zig");
const Notify = @import("../net/Notify.zig");
const advertisement = @import("../protocol/advertisement.zig");

const Health = @This();
const log = std.log.scoped(.health);

pub const Status = enum(u8) { unknown, healthy, unhealthy };

const Entry = struct {
    status: std.atomic.Value(Status) = .init(.unknown),
    players: std.atomic.Value(u32) = .init(0),
};

backends: []const Backend,
interval_ms: u32,
timeout_ms: u32,
entries: [Config.max_backends]Entry = @splat(.{}),
watchers: []const Notify = &.{},

pub fn init(backends: []const Backend, interval_ms: u32, timeout_ms: u32) Health {
    return .{ .backends = backends, .interval_ms = interval_ms, .timeout_ms = timeout_ms };
}

pub fn status(self: *const Health, id: Backend.Id) Status {
    return self.entries[id.index()].status.load(.acquire);
}

pub fn markFailed(self: *Health, id: Backend.Id) void {
    if (self.entries[id.index()].status.swap(.unhealthy, .acq_rel) != .unhealthy) self.changed();
}

pub fn healthyCount(self: *const Health) usize {
    var count: usize = 0;
    for (self.entries[0..self.backends.len]) |*entry| count += @intFromBool(entry.status.load(.acquire) == .healthy);
    return count;
}

pub fn onlinePlayers(self: *const Health) u32 {
    var total: u32 = 0;
    for (self.entries[0..self.backends.len]) |*entry| {
        if (entry.status.load(.acquire) == .healthy) total +|= entry.players.load(.monotonic);
    }
    return total;
}

pub fn run(self: *Health, io: std.Io) void {
    while (true) {
        self.checkAll(io) catch return;
        io.sleep(.fromMilliseconds(self.interval_ms), .awake) catch return;
    }
}

pub fn checkAll(self: *Health, io: std.Io) error{Canceled}!void {
    var group: std.Io.Group = .init;
    for (0..self.backends.len) |index| {
        group.concurrent(io, check, .{ self, io, index }) catch check(self, io, index);
    }
    try group.await(io);
}

fn check(self: *Health, io: std.Io, index: usize) void {
    var buffer: [1024]u8 = undefined;
    const backend = &self.backends[index];
    const pong = raknet.ping(io, backend.address, &buffer, self.timeout_ms) catch |err| {
        if (err == error.Canceled) return;
        if (self.entries[index].status.swap(.unhealthy, .acq_rel) != .unhealthy) {
            log.warn("backend {f} is down: {t}", .{ backend.*, err });
            self.changed();
        }
        return;
    };
    const entry = &self.entries[index];
    const players_now = advertisement.players(pong.advertisement) orelse 0;
    const old_players = entry.players.swap(players_now, .monotonic);
    const old_status = entry.status.swap(.healthy, .acq_rel);
    if (old_status == .unhealthy) log.info("backend {f} is back", .{backend.*});
    if (old_status != .healthy or old_players != players_now) self.changed();
}

fn changed(self: *Health) void {
    for (self.watchers) |watcher| watcher.send();
}

test "online players sum healthy backends and saturate" {
    var backends: [3]Backend = undefined;
    for (&backends, 1..) |*backend, port| backend.* = try .init(null, .{ .ip4 = .loopback(@intCast(port)) });
    var health: Health = .init(&backends, 1000, 100);
    try std.testing.expectEqual(@as(u32, 0), health.onlinePlayers());

    health.entries[0].status.store(.healthy, .release);
    health.entries[0].players.store(std.math.maxInt(u32) - 1, .monotonic);
    health.entries[1].status.store(.healthy, .release);
    health.entries[1].players.store(5, .monotonic);
    health.entries[2].status.store(.unhealthy, .release);
    health.entries[2].players.store(1000, .monotonic);
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), health.onlinePlayers());
    try std.testing.expectEqual(@as(usize, 2), health.healthyCount());

    health.markFailed(.of(0));
    try std.testing.expectEqual(Status.unhealthy, health.status(.of(0)));
    try std.testing.expectEqual(@as(u32, 5), health.onlinePlayers());
}
