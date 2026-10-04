const std = @import("std");
const bifrost = @import("bifrost");
const fixtures = @import("support/fixtures.zig");
const managed = @import("support/managed.zig");

const Running = fixtures.Running;
const io = std.testing.io;

test "a player moves from one backend to another" {
    const proxy_key = try managed.proxyKey(1);
    var keys = try managed.keySet();
    defer keys.deinit();
    var a: managed.Backend = undefined;
    try a.start(io, proxy_key.public_key);
    defer a.deinit();
    var b: managed.Backend = undefined;
    try b.start(io, proxy_key.public_key);
    defer b.deinit();
    var running: Running = undefined;
    try running.start(io, try managed.config(&.{ a.address(), b.address() }), .{ .auth = .{ .verify = &keys }, .proxy_key = proxy_key });
    defer running.deinit();

    const player = try managed.Player.connect(io, running.address(), 2);
    defer player.destroy();
    try player.login("Steve", "2535400000000001");
    try player.spawn();
    try player.echo("on a");
    try std.testing.expectEqual(@as(u32, 1), a.echoes.load(.acquire));

    try running.proxy.requestTransfer(1, .of(1));
    try running.waitForStat(.transfers_committed, 1);
    try player.echo("on b");
    try std.testing.expectEqual(@as(u32, 1), b.echoes.load(.acquire));
    try fixtures.waitFor(io, &a.disconnects, 1);
}
