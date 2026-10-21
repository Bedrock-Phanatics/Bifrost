const std = @import("std");
const bifrost = @import("bifrost");
const fixtures = @import("../support/fixtures.zig");

const Backend = fixtures.Backend;
const Running = fixtures.Running;
const RunningWorkers = fixtures.RunningWorkers;
const Player = fixtures.Player;
const gpa = std.testing.allocator;
const io = std.testing.io;

fn workersConfig(backend: std.Io.net.IpAddress, count: u8) !bifrost.Config {
    var result = try fixtures.config(&.{backend});
    result.workers = count;
    result.max_players = 64;
    return result;
}

test "max_players is shared by proxies using one admission" {
    var backend: Backend = undefined;
    try backend.start(io, .{});
    defer backend.deinit();
    var admission: bifrost.Admission = try .init(gpa, 2, 0);
    defer admission.deinit();
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

test "workers share one listener and spread players" {
    var backend: Backend = undefined;
    try backend.start(io, .{});
    defer backend.deinit();
    var running: RunningWorkers = undefined;
    try running.start(io, try workersConfig(backend.address(), 4));
    defer running.deinit();

    try std.testing.expect(running.address().getPort() != 0);

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

test "global max_players holds across workers" {
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
        // A turned-away player can lose the race and see its dial fail instead of its first echo
        players[connected] = Player.connect(io, running.address()) catch continue;
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
        try running.start(io, try workersConfig(fixtures.nowhere, 4));
        defer running.deinit();
        try running.stop();
    }
}

test "workers clean up after allocation failures" {
    try std.testing.checkAllAllocationFailures(gpa, struct {
        fn run(allocator: std.mem.Allocator) !void {
            const workers = try bifrost.Workers.create(allocator, io, try workersConfig(fixtures.nowhere, 3), .{ .identity = fixtures.identity(io) });
            workers.destroy();
        }
    }.run, .{});
}

test "max_players_per_ip turns away extra players from one address" {
    var backend: Backend = undefined;
    try backend.start(io, .{});
    defer backend.deinit();
    var proxy_config = try fixtures.config(&.{backend.address()});
    proxy_config.max_players_per_ip = 2;
    var running: Running = undefined;
    try running.start(io, proxy_config, .{});
    defer running.deinit();

    var players: [2]Player = undefined;
    for (&players) |*player| player.* = try .connect(io, running.address());
    defer for (&players) |*player| player.deinit();
    for (&players) |*player| try player.roundTrip("\xfehello");

    var extra: Player = try .connect(io, running.address());
    defer extra.deinit();
    try extra.awaitClosed();

    running.stop();
    try std.testing.expectEqual(@as(u64, 2), running.stats().sessions_accepted);
    try std.testing.expectEqual(@as(u64, 1), running.stats().sessions_rejected);
}

fn scrape(address: std.Io.net.IpAddress, request: []const u8, buffer: []u8) ![]const u8 {
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var write_buffer: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll(request);
    try writer.interface.flush();
    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    const len = try reader.interface.readSliceShort(buffer);
    return buffer[0..len];
}

test "the metrics endpoint serves Prometheus text and refuses other paths" {
    var backend: Backend = undefined;
    try backend.start(io, .{});
    defer backend.deinit();
    var metrics_config = try workersConfig(backend.address(), 1);
    metrics_config.metrics_bind = fixtures.loopback;
    var running: RunningWorkers = undefined;
    try running.start(io, metrics_config);
    defer running.deinit();

    var player: Player = try .connect(io, running.address());
    defer player.deinit();
    try player.roundTrip("\xfehello");

    const address = running.workers.metricsAddress().?;
    var buffer: [64 * 1024]u8 = undefined;
    const page = try scrape(address, "GET /metrics HTTP/1.1\r\nHost: test\r\n\r\n", &buffer);
    try std.testing.expect(std.mem.startsWith(u8, page, "HTTP/1.1 200 OK\r\n"));
    for ([_][]const u8{
        "bifrost_players_online 1\n",
        "bifrost_messages_total{direction=\"to_backend\"} 1\n",
        "bifrost_messages_total{direction=\"to_player\"} 1\n",
        "bifrost_backend_dial_seconds_count 1\n",
        "bifrost_turn_seconds_bucket{le=\"+Inf\"}",
        "bifrost_backend_up{backend=\"",
    }) |line| if (std.mem.indexOf(u8, page, line) == null) {
        std.debug.print("missing {s} in:\n{s}\n", .{ line, page });
        return error.MissingMetric;
    };

    const missing = try scrape(address, "GET / HTTP/1.1\r\n\r\n", &buffer);
    try std.testing.expect(std.mem.startsWith(u8, missing, "HTTP/1.1 404 Not Found\r\n"));
    try running.stop();
}
