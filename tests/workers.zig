const std = @import("std");
const bifrost = @import("bifrost");
const fixtures = @import("support/fixtures.zig");

const Backend = fixtures.Backend;
const Running = fixtures.Running;
const RunningWorkers = fixtures.RunningWorkers;
const Player = fixtures.Player;
const gpa = std.testing.allocator;
const io = std.testing.io;

const multi = bifrost.Config.multi_worker_supported;

fn workersConfig(backend: std.Io.net.IpAddress, count: u8) !bifrost.Config {
    var result = try fixtures.config(&.{backend});
    result.workers = count;
    result.max_players = 64;
    return result;
}

test "more than one worker is refused where reuse_port isn't supported" {
    if (multi) return error.SkipZigTest;
    try std.testing.expectError(error.InvalidLimit, bifrost.Workers.create(gpa, io, try workersConfig(fixtures.nowhere, 2), .off));
}

test "max_players is shared by proxies using one admission" {
    var backend: Backend = undefined;
    try backend.start(io, .{});
    defer backend.deinit();
    var admission: bifrost.Admission = .init(2);
    var proxies: [2]Running = undefined;
    try proxies[0].start(io, try fixtures.config(&.{backend.address()}), .{ .admission = &admission });
    defer proxies[0].deinit();
    try proxies[1].start(io, try fixtures.config(&.{backend.address()}), .{ .admission = &admission });
    defer proxies[1].deinit();

    var first: Player = try .connect(io, proxies[0].address());
    var first_alive = true;
    defer if (first_alive) first.deinit();
    try first.roundTrip("\xfehello");
    var second: Player = try .connect(io, proxies[1].address());
    defer second.deinit();
    try second.roundTrip("\xfehello");

    var rejected: Player = try .connect(io, proxies[1].address());
    defer rejected.deinit();
    try rejected.awaitClosed();

    first.deinit();
    first_alive = false;
    try fixtures.eventually(io, &admission, struct {
        fn check(a: *bifrost.Admission) bool {
            return a.active.load(.acquire) == 1;
        }
    }.check);
    var third: Player = try .connect(io, proxies[1].address());
    defer third.deinit();
    try third.roundTrip("\xfehello");

    proxies[1].stop();
    try std.testing.expectEqual(@as(u64, 1), proxies[1].stats().sessions_rejected);
}

test "reuse_port workers share one port and spread players" {
    if (!multi) return error.SkipZigTest;
    var backend: Backend = undefined;
    try backend.start(io, .{});
    defer backend.deinit();
    var running: RunningWorkers = undefined;
    try running.start(io, try workersConfig(backend.address(), 4));
    defer running.deinit();

    const port = running.address().getPort();
    try std.testing.expect(port != 0);
    for (running.workers.proxies) |proxy| try std.testing.expectEqual(port, proxy.localAddress().getPort());

    var players: [12]Player = undefined;
    var connected: usize = 0;
    defer for (players[0..connected]) |*player| player.deinit();
    for (&players) |*player| {
        player.* = try .connect(io, running.address());
        connected += 1;
    }
    for (&players) |*player| try player.roundTrip("\xfehello");

    try running.stop();
    try std.testing.expectEqual(@as(u64, players.len), running.totals().sessions_accepted);
    var busy: usize = 0;
    for (running.workers.proxies) |proxy| busy += @intFromBool(proxy.stats.sessions_accepted != 0);
    try std.testing.expect(busy > 1);
}

test "global max_players holds across reuse_port workers" {
    if (!multi) return error.SkipZigTest;
    var backend: Backend = undefined;
    try backend.start(io, .{});
    defer backend.deinit();
    var workers_config = try workersConfig(backend.address(), 4);
    workers_config.max_players = 3;
    var running: RunningWorkers = undefined;
    try running.start(io, workers_config);
    defer running.deinit();

    var players: [8]Player = undefined;
    var connected: usize = 0;
    defer for (players[0..connected]) |*player| player.deinit();
    for (0..players.len) |_| {
        // raknet's own cap can turn players away before we do
        players[connected] = Player.connect(io, running.address()) catch |err| switch (err) {
            error.NoFreeIncomingConnections => continue,
            else => return err,
        };
        connected += 1;
    }
    var admitted: usize = 0;
    for (players[0..connected]) |*player| {
        player.roundTrip("\xfehello") catch continue;
        admitted += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), admitted);

    try running.stop();
    try std.testing.expectEqual(@as(u64, 3), running.totals().sessions_accepted);
}

test "one worker stopping stops the rest" {
    if (!multi) return error.SkipZigTest;
    var running: RunningWorkers = undefined;
    try running.start(io, try workersConfig(fixtures.nowhere, 3));
    defer running.deinit();
    running.workers.proxies[1].stop();
    try running.task.await(io);
    running.stopped = true;
}

test "workers start and stop repeatedly" {
    for (0..5) |_| {
        var running: RunningWorkers = undefined;
        try running.start(io, try workersConfig(fixtures.nowhere, if (multi) 4 else 1));
        defer running.deinit();
        try running.stop();
    }
}

test "workers clean up after allocation failures" {
    try std.testing.checkAllAllocationFailures(gpa, struct {
        fn run(allocator: std.mem.Allocator) !void {
            const workers = try bifrost.Workers.create(allocator, io, try workersConfig(fixtures.nowhere, if (multi) 3 else 1), .off);
            workers.destroy();
        }
    }.run, .{});
}
