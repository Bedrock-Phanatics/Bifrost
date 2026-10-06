const std = @import("std");
const Config = @import("../config/Config.zig");
const Backend = @import("Backend.zig");
const Health = @import("Health.zig");

const Router = @This();

pub const Set = struct {
    bits: std.StaticBitSet(Config.max_backends) = .empty,

    pub fn add(self: *Set, id: Backend.Id) void {
        self.bits.set(id.index());
    }

    pub fn contains(self: Set, id: Backend.Id) bool {
        return self.bits.isSet(id.index());
    }

    pub fn count(self: Set) usize {
        return self.bits.count();
    }
};

backends: []const Backend,
health: ?*const Health,
next: usize = 0,

pub fn init(backends: []const Backend, health: ?*const Health) Router {
    std.debug.assert(backends.len != 0);
    return .{ .backends = backends, .health = health };
}

pub fn pick(self: *Router, skip: Set, healthy_only: bool) ?Backend.Id {
    for (0..self.backends.len) |_| {
        const id: Backend.Id = .of(self.next);
        self.next = (self.next + 1) % self.backends.len;
        if (skip.contains(id)) continue;
        const status = if (self.health) |health| health.status(id) else .unknown;
        if (status == .unhealthy or (healthy_only and status != .healthy)) continue;
        return id;
    }
    return null;
}

pub fn get(self: *const Router, id: Backend.Id) *const Backend {
    return &self.backends[id.index()];
}

const none: Set = .{};

fn testBackends(comptime count: usize) ![count]Backend {
    var backends: [count]Backend = undefined;
    for (&backends, 1..) |*backend, port| backend.* = try .init(null, .{ .ip4 = .loopback(@intCast(port)) });
    return backends;
}

fn pickPort(router: *Router) !u16 {
    return router.get(router.pick(none, false) orelse return error.NoBackend).address.getPort();
}

test "pick cycles through backends in order" {
    const backends = try testBackends(2);
    var router: Router = .init(&backends, null);
    for ([_]u16{ 1, 2, 1, 2 }) |port| try std.testing.expectEqual(port, try pickPort(&router));
}

test "pick never returns a skipped backend" {
    const backends = try testBackends(3);
    var router: Router = .init(&backends, null);
    var tried: Set = .{};
    for (0..backends.len) |_| tried.add(router.pick(tried, false).?);
    try std.testing.expectEqual(backends.len, tried.count());
    try std.testing.expectEqual(@as(?Backend.Id, null), router.pick(tried, false));
}

test "pick skips unhealthy backends and fails when none are left" {
    const backends = try testBackends(3);
    var health: Health = .init(&backends, 1000, 100);
    var router: Router = .init(&backends, &health);

    health.markFailed(.of(1));
    for ([_]u16{ 1, 3, 1, 3 }) |port| try std.testing.expectEqual(port, try pickPort(&router));

    health.markFailed(.of(0));
    health.markFailed(.of(2));
    try std.testing.expectEqual(@as(?Backend.Id, null), router.pick(none, false));
}

test "healthy_only skips backends health checks haven't vouched for" {
    const backends = try testBackends(2);
    var health: Health = .init(&backends, 1000, 100);
    var router: Router = .init(&backends, &health);
    try std.testing.expectEqual(@as(?Backend.Id, null), router.pick(none, true));
    health.entries[1].status.store(.healthy, .release);
    try std.testing.expectEqual(@as(?Backend.Id, .of(1)), router.pick(none, true));
    var unchecked: Router = .init(&backends, null);
    try std.testing.expectEqual(@as(?Backend.Id, null), unchecked.pick(none, true));
}
