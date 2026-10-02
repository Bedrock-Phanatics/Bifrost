const std = @import("std");
const zio = @import("zio");
const fixtures = @import("support/fixtures.zig");

const Backend = fixtures.Backend;
const Running = fixtures.Running;
const Player = fixtures.Player;
const gpa = std.testing.allocator;

test "relays both directions on a threaded runtime" {
    try relayBothWays(std.testing.io);
}

test "relays both directions on the zio runtime" {
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    try relayBothWays(rt.io());
}

fn relayBothWays(io: std.Io) !void {
    var backend: Backend = undefined;
    try backend.start(io, .{});
    defer backend.deinit();
    var running: Running = undefined;
    try running.start(io, try fixtures.config(&.{backend.address()}), .{});
    defer running.deinit();

    var player: Player = try .connect(io, running.address());
    errdefer player.deinit();
    try player.roundTrip("\xfehello");
    const large = try gpa.alloc(u8, 20_000);
    defer gpa.free(large);
    for (large, 0..) |*byte, i| byte.* = @truncate(i);
    large[0] = 0xfe; // RakNet treats low first bytes as control packets
    try player.roundTrip(large);
    player.deinit();

    try fixtures.waitFor(io, &backend.disconnects, 1);
    running.stop();
    const stats = running.stats();
    try std.testing.expectEqual(@as(u64, 1), stats.sessions_accepted);
    try std.testing.expectEqual(@as(u64, 1), stats.links_closed);
    try std.testing.expectEqual(@as(u64, 20_006), stats.bytes_to_backend);
    try std.testing.expectEqual(@as(u64, 20_006), stats.bytes_to_player);
}

test "backend traffic reaches an idle player" {
    const io = std.testing.io;
    var backend: Backend = undefined;
    try backend.start(io, .{ .greeting = "\xfewelcome" });
    defer backend.deinit();
    var running: Running = undefined;
    try running.start(io, try fixtures.config(&.{backend.address()}), .{});
    defer running.deinit();

    var player: Player = try .connect(io, running.address());
    defer player.deinit();
    try player.expect("\xfewelcome");
}

test "players keep their own link while others come and go" {
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    const io = rt.io();
    var backend: Backend = undefined;
    try backend.start(io, .{});
    defer backend.deinit();
    var proxy_config = try fixtures.config(&.{backend.address()});
    proxy_config.max_players = 64;
    var running: Running = undefined;
    try running.start(io, proxy_config, .{});
    defer running.deinit();

    var players: [24]Player = undefined;
    for (&players) |*player| player.* = try .connect(io, running.address());
    var alive: usize = players.len;
    defer for (players[0..alive]) |*player| player.deinit();

    var tags: [players.len][16]u8 = undefined;
    for (0..3) |_| {
        for (players[0..alive], 0..) |*player, i| try player.send(try std.fmt.bufPrint(&tags[i], "\xfeplayer-{d}", .{i}));
        for (players[0..alive], 0..) |*player, i| try player.expect(try std.fmt.bufPrint(&tags[i], "\xfeplayer-{d}", .{i}));
        const leaving = alive / 3;
        for (players[alive - leaving .. alive]) |*player| player.deinit();
        alive -= leaving;
    }
    const left: u32 = @intCast(players.len - alive);
    try fixtures.waitFor(io, &backend.disconnects, left);
    for (players[0..alive]) |*player| try player.roundTrip("\xfestill here");

    running.stop();
    try std.testing.expectEqual(@as(u64, players.len), running.stats().sessions_accepted);
    try std.testing.expectEqual(@as(u64, players.len), running.stats().links_closed);
}
