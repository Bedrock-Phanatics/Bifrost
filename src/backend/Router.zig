const std = @import("std");
const Health = @import("Health.zig");
const IpAddress = std.Io.net.IpAddress;

const Router = @This();

pub const Pick = struct { index: usize, address: IpAddress };

backends: []const IpAddress,
health: ?*const Health,
next: usize = 0,

pub fn init(backends: []const IpAddress, health: ?*const Health) Router {
    std.debug.assert(backends.len != 0);
    return .{ .backends = backends, .health = health };
}

pub fn pick(self: *Router) ?Pick {
    for (0..self.backends.len) |_| {
        const index = self.next;
        self.next = (index + 1) % self.backends.len;
        if (self.health) |health| if (health.status(index) == .unhealthy) continue;
        return .{ .index = index, .address = self.backends[index] };
    }
    return null;
}

test "pick cycles through backends in order" {
    const backends = [_]IpAddress{ .{ .ip4 = .loopback(1) }, .{ .ip4 = .loopback(2) } };
    var router: Router = .init(&backends, null);
    for ([_]u16{ 1, 2, 1, 2 }) |port| try std.testing.expectEqual(port, router.pick().?.address.getPort());
}

test "pick skips unhealthy backends and fails when none are left" {
    const backends = [_]IpAddress{ .{ .ip4 = .loopback(1) }, .{ .ip4 = .loopback(2) }, .{ .ip4 = .loopback(3) } };
    var health: Health = .init(&backends, 1000, 100);
    var router: Router = .init(&backends, &health);

    health.markFailed(1);
    for ([_]u16{ 1, 3, 1, 3 }) |port| try std.testing.expectEqual(port, router.pick().?.address.getPort());

    health.markFailed(0);
    health.markFailed(2);
    try std.testing.expectEqual(@as(?Pick, null), router.pick());
}
