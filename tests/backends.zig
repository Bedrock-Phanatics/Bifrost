const std = @import("std");
const raknet = @import("raknet");
const bifrost = @import("bifrost");
const fixtures = @import("support/fixtures.zig");

const Backend = fixtures.Backend;
const Running = fixtures.Running;
const RunningWorkers = fixtures.RunningWorkers;
const Player = fixtures.Player;
const gpa = std.testing.allocator;
const io = std.testing.io;

fn listing(players: u32) ![]u8 {
    return std.fmt.allocPrint(gpa, "MCPE;Backend;944;1.26.0;{d};100;1;Sub;Survival;1;19132;19133;", .{players});
}

fn startWorkers(running: *RunningWorkers, backends: []const *Backend) !void {
    var addresses: [8]std.Io.net.IpAddress = undefined;
    for (backends, 0..) |backend, i| addresses[i] = backend.address();
    var workers_config = try fixtures.config(addresses[0..backends.len]);
    workers_config.max_players = 64;
    workers_config.health_interval_ms = 1_000;
    workers_config.health_timeout_ms = 200;
    try running.start(io, workers_config);
}

fn expectAdvertised(running: *RunningWorkers, players: u32) !void {
    var buffer: [1024]u8 = undefined;
    for (0..400) |_| {
        const pong = try raknet.ping(io, running.address(), &buffer, 500);
        var fields = std.mem.splitScalar(u8, pong.advertisement, ';');
        for (0..5) |_| _ = fields.next();
        try std.testing.expectEqualStrings("64", fields.next().?);
        if (bifrost.advertisedPlayers(pong.advertisement) == players) return;
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    return error.AdvertisementNeverUpdated;
}

fn statusIs(running: *RunningWorkers, index: usize, status: bifrost.Health.Status) !void {
    const Check = struct { running: *RunningWorkers, index: usize, status: bifrost.Health.Status };
    try fixtures.eventually(io, Check{ .running = running, .index = index, .status = status }, struct {
        fn check(c: Check) bool {
            return c.running.workers.health.status(c.index) == c.status;
        }
    }.check);
}

test "players are spread round-robin across backends" {
    var backends: [2]Backend = undefined;
    try backends[0].start(io, .{});
    defer backends[0].deinit();
    try backends[1].start(io, .{});
    defer backends[1].deinit();
    var running: Running = undefined;
    try running.start(io, try fixtures.config(&.{ backends[0].address(), backends[1].address() }), .{});
    defer running.deinit();

    var players: [4]Player = undefined;
    for (&players) |*player| player.* = try .connect(io, running.address());
    defer for (&players) |*player| player.deinit();
    for (&players) |*player| try player.roundTrip("\xfehello");
    for (&backends) |*backend| try std.testing.expectEqual(@as(u32, 2), backend.connects.load(.acquire));
}

test "the server list shows the summed players of healthy backends" {
    const seven = try listing(7);
    defer gpa.free(seven);
    const five = try listing(5);
    defer gpa.free(five);
    var first: Backend = undefined;
    try first.start(io, .{ .advertisement = seven });
    defer first.deinit();
    var second: Backend = undefined;
    try second.start(io, .{ .advertisement = five });
    defer second.deinit();

    var running: RunningWorkers = undefined;
    try startWorkers(&running, &.{ &first, &second });
    defer running.deinit();
    try expectAdvertised(&running, 12);

    const nine = try listing(9);
    defer gpa.free(nine);
    try second.listener.setAdvertisement(nine);
    try expectAdvertised(&running, 16);
}

test "a dead backend is skipped, then used again once it recovers" {
    const one = try listing(1);
    defer gpa.free(one);
    const two = try listing(2);
    defer gpa.free(two);
    var live: Backend = undefined;
    try live.start(io, .{ .advertisement = one });
    defer live.deinit();
    var dead: Backend = undefined;
    try dead.start(io, .{ .advertisement = two, .serving = false });
    defer dead.deinit();

    var running: RunningWorkers = undefined;
    try startWorkers(&running, &.{ &live, &dead });
    defer running.deinit();
    try statusIs(&running, 0, .healthy);
    try statusIs(&running, 1, .unhealthy);
    try expectAdvertised(&running, 1);

    var players: [4]Player = undefined;
    var connected: usize = 0;
    defer for (players[0..connected]) |*player| player.deinit();
    for (&players) |*player| {
        player.* = try .connect(io, running.address());
        connected += 1;
        try player.roundTrip("\xfehello");
    }
    try std.testing.expectEqual(@as(u32, 4), live.connects.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), dead.connects.load(.acquire));

    try dead.serve();
    try statusIs(&running, 1, .healthy);
    try expectAdvertised(&running, 3);
}

test "players are turned away quickly when every backend is down" {
    var dead: Backend = undefined;
    try dead.start(io, .{ .serving = false });
    defer dead.deinit();
    var running: RunningWorkers = undefined;
    try startWorkers(&running, &.{&dead});
    defer running.deinit();
    try statusIs(&running, 0, .unhealthy);
    try expectAdvertised(&running, 0);

    var player: Player = try .connect(io, running.address());
    defer player.deinit();
    const started = std.Io.Clock.awake.now(io);
    try player.awaitClosed();
    try std.testing.expect(started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 2_000);
}

test "a failed dial marks the backend down before the next ping" {
    const silent = try fixtures.silent(io);
    defer silent.close(io);
    const proxy_config = try fixtures.config(&.{silent.address});
    var health: bifrost.Health = .init(proxy_config.backends(), 60_000, 100);
    var running: Running = undefined;
    try running.start(io, proxy_config, .{ .health = &health });
    defer running.deinit();

    var player: Player = try .connect(io, running.address());
    defer player.deinit();
    try player.awaitClosed();
    try std.testing.expectEqual(bifrost.Health.Status.unhealthy, health.status(0));
}
