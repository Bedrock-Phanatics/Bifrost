const std = @import("std");
const bifrost = @import("bifrost");
const fixtures = @import("../support/fixtures.zig");

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

test "a player leaving mid-connect cancels the dial" {
    const silent = try fixtures.silent(io);
    defer silent.close(io);
    var proxy_config = try fixtures.config(&.{silent.address});
    proxy_config.connect_timeout_ms = 60_000;
    var running: Running = undefined;
    try running.start(io, proxy_config, .{});
    defer running.deinit();

    var player: Player = try .connect(io, running.address());
    player.deinit();
    try running.waitForStat(.links_closed, 1);

    running.stop();
    try std.testing.expectEqual(@as(u64, 0), running.stats().backend_failures);
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
    var transport: bifrost.NetherNet = undefined;
    const proxy = try bifrost.Proxy.create(gpa, io, try fixtures.config(&.{fixtures.nowhere}), .{ .transport = &transport });
    proxy.stop();
    proxy.run();
    proxy.destroy();
}

test "create cleans up after allocation failures" {
    try std.testing.checkAllAllocationFailures(gpa, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var transport: bifrost.NetherNet = undefined;
            const proxy = try bifrost.Proxy.create(allocator, io, try fixtures.config(&.{fixtures.nowhere}), .{ .transport = &transport });
            proxy.destroy();
        }
    }.run, .{});
}

test "players that come and go hand back their links and admission slots" {
    var backend: Backend = undefined;
    try backend.start(io, .{});
    defer backend.deinit();
    var running: Running = undefined;
    try running.start(io, try fixtures.config(&.{backend.address()}), .{});
    defer running.deinit();

    for (0..3) |round| {
        var player: Player = try .connect(io, running.address());
        defer player.deinit();
        try player.roundTrip("\xfehello");
        try player.leave();
        try running.waitForStat(.links_closed, round + 1);
        try fixtures.waitFor(io, &backend.disconnects, @intCast(round + 1));
    }

    running.stop();
    try std.testing.expectEqual(@as(u32, 0), running.proxy.admission.active.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 3), running.stats().sessions_accepted);
}

// The backend leg's last messages can still be lost when it closes, see docs/limits.md, so only the proxy's side is held to it
test "a leaving player's last packets all reach the proxy and go on to the backend" {
    var backend: Backend = undefined;
    try backend.start(io, .{});
    defer backend.deinit();
    var running: Running = undefined;
    var proxy_config = try fixtures.config(&.{backend.address()});
    proxy_config.connect_timeout_ms = 60_000;
    try running.start(io, proxy_config, .{});
    defer running.deinit();

    var player: Player = try .connect(io, running.address());
    defer player.deinit();
    try player.roundTrip("\xfehello");
    var payload: [8000]u8 = @splat(7);
    payload[0] = 0xfe;
    const burst = 20;
    for (0..burst) |_| try player.send(&payload);
    try player.leave();

    try running.waitForStat(.messages_to_backend, burst + 1);
    try fixtures.waitFor(io, &backend.disconnects, 1);
    try std.testing.expectEqual(@as(u32, burst + 1), backend.received.load(.acquire));
}

test "a leaving player's packets still arrive when the proxy had paused reading them" {
    var backend: Backend = undefined;
    try backend.start(io, .{});
    defer backend.deinit();
    var running: Running = undefined;
    var proxy_config = try fixtures.config(&.{backend.address()});
    proxy_config.connect_timeout_ms = 60_000;
    try running.start(io, proxy_config, .{});
    defer running.deinit();

    var player: Player = try .connect(io, running.address());
    defer player.deinit();
    try player.roundTrip("\xfehello");
    // The worker takes this every turn, so holding it stalls the worker
    running.proxy.mailbox_mutex.lockUncancelable(io);
    var payload: [8000]u8 = @splat(7);
    payload[0] = 0xfe;
    const burst = 100;
    for (0..burst) |_| try player.send(&payload);
    try player.leave();
    running.proxy.mailbox_mutex.unlock(io);

    try running.waitForStat(.messages_to_backend, burst + 1);
    try fixtures.waitFor(io, &backend.disconnects, 1);
    try std.testing.expectEqual(@as(u32, burst + 1), backend.received.load(.acquire));
}
