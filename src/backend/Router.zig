const std = @import("std");
const IpAddress = std.Io.net.IpAddress;

const Router = @This();

backends: []const IpAddress,
next: usize = 0,

pub fn init(backends: []const IpAddress) Router {
    std.debug.assert(backends.len != 0);
    return .{ .backends = backends };
}

pub fn pick(self: *Router) IpAddress {
    const backend = self.backends[self.next];
    self.next = (self.next + 1) % self.backends.len;
    return backend;
}

test "pick cycles through backends in order" {
    const backends = [_]IpAddress{ .{ .ip4 = .loopback(1) }, .{ .ip4 = .loopback(2) } };
    var router: Router = .init(&backends);
    for ([_]u16{ 1, 2, 1, 2 }) |port| try std.testing.expectEqual(port, router.pick().getPort());
}
