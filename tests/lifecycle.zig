const std = @import("std");
const bifrost = @import("bifrost");
const fixtures = @import("support/fixtures.zig");

const Backend = fixtures.Backend;
const Running = fixtures.Running;
const Player = fixtures.Player;
const gpa = std.testing.allocator;
const io = std.testing.io;

test "an unreachable backend closes the player" {
    const silent = try fixtures.silent(io);
    defer silent.close(io);
    var running: Running = undefined;
    try running.start(io, try fixtures.config(&.{silent.address}), .{});
    defer running.deinit();

    var player: Player = try .connect(io, running.address());
    defer player.deinit();
    try player.send("\xfequeued");
    try player.awaitClosed();

    running.stop();
    try std.testing.expectEqual(@as(u64, 1), running.stats().backend_failures);
    try std.testing.expectEqual(@as(u64, 1), running.stats().links_closed);
}

test "a player leaving mid-connect frees its link once the dial ends" {
    const silent = try fixtures.silent(io);
    defer silent.close(io);
    var running: Running = undefined;
    try running.start(io, try fixtures.config(&.{silent.address}), .{});
    defer running.deinit();

    var player: Player = try .connect(io, running.address());
    player.deinit();
    try io.sleep(.fromMilliseconds(1_000), .awake);

    running.stop();
    try std.testing.expectEqual(@as(u64, 1), running.stats().backend_failures);
    try std.testing.expectEqual(@as(u64, 1), running.stats().links_closed);
}

test "a backend disconnect closes the player" {
    var backend: Backend = undefined;
    try backend.start(io, .{});
    defer backend.deinit();
    var running: Running = undefined;
    try running.start(io, try fixtures.config(&.{backend.address()}), .{});
    defer running.deinit();

    var player: Player = try .connect(io, running.address());
    defer player.deinit();
    try player.roundTrip("\xfehello");
    try player.send(fixtures.kick);
    try player.awaitClosed();

    running.stop();
    try std.testing.expectEqual(@as(u64, 1), running.stats().links_closed);
    try std.testing.expectEqual(@as(u64, 0), running.stats().backend_failures);
}

test "stopping disconnects live players and backends" {
    var backend: Backend = undefined;
    try backend.start(io, .{});
    defer backend.deinit();
    var running: Running = undefined;
    try running.start(io, try fixtures.config(&.{backend.address()}), .{});
    defer running.deinit();

    var players: [2]Player = undefined;
    for (&players) |*player| player.* = try .connect(io, running.address());
    defer for (&players) |*player| player.deinit();
    for (&players) |*player| try player.roundTrip("\xfehello");

    running.stop();
    for (&players) |*player| try player.awaitClosed();
    try fixtures.waitFor(io, &backend.disconnects, 2);
    try std.testing.expectEqual(@as(u64, 2), running.stats().links_closed);
}

test "stopping cancels in-flight dials" {
    const silent = try fixtures.silent(io);
    defer silent.close(io);
    var proxy_config = try fixtures.config(&.{silent.address});
    proxy_config.connect_timeout_ms = 60_000;
    var running: Running = undefined;
    try running.start(io, proxy_config, .{});
    defer running.deinit();

    var players: [3]Player = undefined;
    for (&players) |*player| player.* = try .connect(io, running.address());
    defer for (&players) |*player| player.deinit();
    for (&players) |*player| try player.send("\xfequeued");
    try io.sleep(.fromMilliseconds(100), .awake);

    const started = std.Io.Clock.awake.now(io);
    running.stop();
    try std.testing.expect(started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 5_000);
    try std.testing.expectEqual(@as(u64, 3), running.stats().sessions_accepted);
    try std.testing.expectEqual(@as(u64, 0), running.stats().backends_connected);
    for (&players) |*player| try player.awaitClosed();
}

test "stop before run is safe" {
    const proxy = try bifrost.Proxy.create(gpa, io, try fixtures.config(&.{fixtures.nowhere}), .{});
    proxy.stop();
    proxy.run();
    proxy.destroy();
}

test "create cleans up after allocation failures" {
    try std.testing.checkAllAllocationFailures(gpa, struct {
        fn run(allocator: std.mem.Allocator) !void {
            const proxy = try bifrost.Proxy.create(allocator, io, try fixtures.config(&.{fixtures.nowhere}), .{});
            proxy.destroy();
        }
    }.run, .{});
}

test "a leaving player's last packets still reach the backend" {
    var backend: Backend = undefined;
    try backend.start(io, .{});
    defer backend.deinit();
    var running: Running = undefined;
    try running.start(io, try fixtures.config(&.{backend.address()}), .{});
    defer running.deinit();

    var player: Player = try .connect(io, running.address());
    defer player.deinit();
    try player.roundTrip("\xfehello");
    var payload: [8000]u8 = @splat(7);
    payload[0] = 0xfe;
    const burst = 200;
    for (0..burst) |_| try player.send(&payload);
    player.client.close();
    try player.awaitClosed();

    try fixtures.waitFor(io, &backend.received, burst + 1);
    try fixtures.waitFor(io, &backend.disconnects, 1);
}
