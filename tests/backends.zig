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

const Silent = struct {
    sockets: [4]std.Io.net.Socket = undefined,
    len: usize = 0,

    fn open(self: *Silent, count: usize) !void {
        while (self.len < count) : (self.len += 1) self.sockets[self.len] = try fixtures.silent(io);
    }

    fn close(self: *Silent) void {
        for (self.sockets[0..self.len]) |socket| socket.close(io);
    }

    fn config(self: *const Silent, live: []const std.Io.net.IpAddress) !bifrost.Config {
        var addresses: [8]std.Io.net.IpAddress = undefined;
        for (self.sockets[0..self.len], 0..) |socket, i| addresses[i] = socket.address;
        @memcpy(addresses[self.len..][0..live.len], live);
        return fixtures.config(addresses[0 .. self.len + live.len]);
    }
};

test "a backend that dies after its health check fails over to the next one" {
    var first: Backend = undefined;
    try first.start(io, .{});
    defer first.deinit();
    var second: Backend = undefined;
    try second.start(io, .{});
    defer second.deinit();
    const proxy_config = try fixtures.config(&.{ first.address(), second.address() });
    var health: bifrost.Health = .init(proxy_config.backends(), 60_000, 100);
    try health.checkAll(io);
    try std.testing.expectEqual(@as(usize, 2), health.healthyCount());
    first.pause();

    var running: Running = undefined;
    try running.start(io, proxy_config, .{ .health = &health });
    defer running.deinit();
    var player: Player = try .connect(io, running.address());
    defer player.deinit();
    // Sent mid-dial, so it has to survive the retry
    try player.send("\xfequeued");
    try player.expect("\xfequeued");
    try player.roundTrip("\xfehello");

    try std.testing.expectEqual(bifrost.Health.Status.unhealthy, health.status(0));
    try std.testing.expectEqual(bifrost.Health.Status.healthy, health.status(1));
    try std.testing.expectEqual(@as(u32, 1), second.connects.load(.acquire));
    running.stop();
    try std.testing.expectEqual(@as(u64, 1), running.stats().backend_failures);
    try std.testing.expectEqual(@as(u64, 1), running.stats().backends_connected);
}

test "a player skips several dead backends before reaching a live one" {
    var silent: Silent = .{};
    defer silent.close();
    try silent.open(2);
    var live: Backend = undefined;
    try live.start(io, .{});
    defer live.deinit();
    var running: Running = undefined;
    try running.start(io, try silent.config(&.{live.address()}), .{});
    defer running.deinit();

    var player: Player = try .connect(io, running.address());
    defer player.deinit();
    try player.send("\xfequeued");
    try player.expect("\xfequeued");
    try player.roundTrip("\xfehello");

    running.stop();
    try std.testing.expectEqual(@as(u32, 1), live.connects.load(.acquire));
    try std.testing.expectEqual(@as(u64, 2), running.stats().backend_failures);
    try std.testing.expectEqual(@as(u64, 1), running.stats().backends_connected);
}

test "each backend is dialed once and attempts are capped when all fail" {
    // No health checks, so only the tried set stops repeat dials
    for ([_][2]usize{ .{ 2, 2 }, .{ 4, 3 } }) |case| {
        var silent: Silent = .{};
        defer silent.close();
        try silent.open(case[0]);
        var running: Running = undefined;
        try running.start(io, try silent.config(&.{}), .{});
        defer running.deinit();

        var player: Player = try .connect(io, running.address());
        defer player.deinit();
        try player.send("\xfequeued");
        try player.awaitClosed();
        try running.waitForStat(.links_closed, 1);

        running.stop();
        try std.testing.expectEqual(@as(u64, case[1]), running.stats().backend_failures);
        try std.testing.expectEqual(@as(u64, 0), running.stats().backends_connected);
    }
}

test "a player leaving mid-retry cancels the retry dial" {
    var silent: Silent = .{};
    defer silent.close();
    try silent.open(2);
    var running: Running = undefined;
    try running.start(io, try silent.config(&.{}), .{});
    defer running.deinit();

    var player: Player = try .connect(io, running.address());
    try running.waitForStat(.backend_failures, 1);
    player.deinit();
    try running.waitForStat(.links_closed, 1);

    running.stop();
    try std.testing.expectEqual(@as(u64, 1), running.stats().backend_failures);
}

test "stopping mid-retry cancels the retry dial" {
    var silent: Silent = .{};
    defer silent.close();
    try silent.open(2);
    var proxy_config = try silent.config(&.{});
    proxy_config.connect_timeout_ms = 1_000;
    var running: Running = undefined;
    try running.start(io, proxy_config, .{});
    defer running.deinit();

    var player: Player = try .connect(io, running.address());
    defer player.deinit();
    try running.waitForStat(.backend_failures, 1);

    const started = std.Io.Clock.awake.now(io);
    running.stop();
    try std.testing.expect(started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 500);
    try std.testing.expectEqual(@as(u64, 1), running.stats().backend_failures);
    try std.testing.expectEqual(@as(u64, 1), running.stats().links_closed);
    try player.awaitClosed();
}
