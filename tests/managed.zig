const std = @import("std");
const bifrost = @import("bifrost");
const fixtures = @import("support/fixtures.zig");
const managed = @import("support/managed.zig");

const Running = fixtures.Running;
const gpa = std.testing.allocator;
const io = std.testing.io;

test "a managed player logs in to a backend as the proxy and relays game packets" {
    const proxy_key = try managed.proxyKey(1);
    var keys = try managed.keySet();
    defer keys.deinit();
    var backend: managed.Backend = undefined;
    try backend.start(io, proxy_key.public_key);
    defer backend.deinit();
    var running: Running = undefined;
    try running.start(io, try managed.config(&.{backend.address()}), .{ .auth = .{ .verify = &keys }, .proxy_key = proxy_key });
    defer running.deinit();

    const player = try managed.Player.connect(io, running.address(), 2);
    defer player.destroy();
    try player.login("Steve", "2535400000000001");
    try player.spawn();
    try player.echo("hello");
    try player.echo(&@as([3000]u8, @splat('x')));

    try std.testing.expectEqualStrings("Steve", backend.name());
    try std.testing.expectEqual(@as(usize, 0), backend.identity_xuid_len);
    try std.testing.expect(!backend.identity_online);
    running.stop();
    try std.testing.expectEqual(@as(u64, 1), running.stats().logins_verified);
    try std.testing.expectEqual(@as(u64, 1), running.stats().proxy_logins);
}
