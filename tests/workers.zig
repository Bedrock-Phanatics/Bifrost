const std = @import("std");
const bifrost = @import("bifrost");
const harness = @import("harness.zig");

const Proxy = bifrost.Proxy;
const Workers = bifrost.Workers;
const EchoBackend = harness.EchoBackend;
const Player = harness.Player;
const gpa = std.testing.allocator;

const Backend = struct {
    echo: EchoBackend,
    task: std.Io.Future(void),

    fn start(self: *Backend, io: std.Io) !void {
        self.echo = try .start(io);
        errdefer self.echo.listener.destroy();
        self.task = try io.concurrent(EchoBackend.run, .{&self.echo});
    }

    fn stop(self: *Backend, io: std.Io) void {
        self.echo.stop.store(true, .release);
        self.task.await(io);
        self.echo.listener.destroy();
    }
};

fn workerConfig(backend: *const EchoBackend, count: u8) !bifrost.Config {
    var config = try harness.testConfig(backend.address());
    config.workers = count;
    config.max_players = 64;
    return config;
}

fn idleConfig(count: u8) !bifrost.Config {
    var config = try harness.testConfig(harness.loopback);
    config.workers = count;
    return config;
}

fn connect(io: std.Io, workers: *const Workers) !Player {
    return .connect(io, workers.proxies[0]);
}

test "a single worker relays end to end" {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var backend: Backend = undefined;
    try backend.start(io);
    defer backend.stop(io);

    const workers = try Workers.create(gpa, io, try workerConfig(&backend.echo, 1), .off);
    defer workers.destroy();
    var run = try io.concurrent(Workers.run, .{workers});
    defer {
        workers.stop();
        run.await(io) catch {};
    }

    var player = try connect(io, workers);
    defer player.deinit();
    try player.roundTrip("\xfehello");
}

test "more than one worker is refused where reuse_port isn't supported" {
    if (bifrost.Config.multi_worker_supported) return error.SkipZigTest;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var config = try harness.testConfig(harness.loopback);
    config.workers = 2;
    try std.testing.expectError(error.InvalidLimit, Workers.create(gpa, threaded.io(), config, .off));
}

test "max_players is shared by proxies using one admission" {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var backend: Backend = undefined;
    try backend.start(io);
    defer backend.stop(io);

    var admission: bifrost.Admission = .init(2);
    var proxies: [2]*Proxy = undefined;
    var tasks: [2]std.Io.Future(void) = undefined;
    for (&proxies, &tasks, 0..) |*proxy, *task, i| {
        errdefer for (proxies[0..i], tasks[0..i]) |started, *started_task| {
            started.stop();
            started_task.await(io);
            started.destroy();
        };
        proxy.* = try Proxy.create(gpa, io, try harness.testConfig(backend.echo.address()), .{ .admission = &admission });
        task.* = try io.concurrent(Proxy.run, .{proxy.*});
    }
    defer for (&proxies, &tasks) |proxy, *task| {
        proxy.stop();
        task.await(io);
        proxy.destroy();
    };

    var first: Player = try .connect(io, proxies[0]);
    var first_alive = true;
    defer if (first_alive) first.deinit();
    try first.roundTrip("\xfehello");
    var second: Player = try .connect(io, proxies[1]);
    defer second.deinit();
    try second.roundTrip("\xfehello");

    var rejected: Player = try .connect(io, proxies[1]);
    defer rejected.deinit();
    try rejected.awaitClosed();

    first.deinit();
    first_alive = false;
    for (0..500) |_| {
        if (admission.active.load(.acquire) == 1) break;
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    var third: Player = try .connect(io, proxies[1]);
    defer third.deinit();
    try third.roundTrip("\xfehello");

    for (&proxies, &tasks) |proxy, *task| {
        proxy.stop();
        task.await(io);
    }
    try std.testing.expectEqual(@as(u64, 1), proxies[1].stats.sessions_rejected);
}

test "reuse_port workers share one port and spread players" {
    if (!bifrost.Config.multi_worker_supported) return error.SkipZigTest;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var backend: Backend = undefined;
    try backend.start(io);
    defer backend.stop(io);

    const workers = try Workers.create(gpa, io, try workerConfig(&backend.echo, 4), .off);
    defer workers.destroy();
    const port = workers.localAddress().getPort();
    try std.testing.expect(port != 0);
    for (workers.proxies) |proxy| try std.testing.expectEqual(port, proxy.localAddress().getPort());
    var run = try io.concurrent(Workers.run, .{workers});
    defer {
        workers.stop();
        run.await(io) catch {};
    }

    var players: [12]Player = undefined;
    var connected: usize = 0;
    defer for (players[0..connected]) |*player| player.deinit();
    for (&players) |*player| {
        player.* = try connect(io, workers);
        connected += 1;
    }
    for (&players) |*player| try player.roundTrip("\xfehello");

    workers.stop();
    try run.await(io);
    const totals = workers.totals();
    try std.testing.expectEqual(@as(u64, players.len), totals.sessions_accepted);
    var busy: usize = 0;
    for (workers.proxies) |proxy| busy += @intFromBool(proxy.stats.sessions_accepted != 0);
    try std.testing.expect(busy > 1);
}

test "global max_players holds across reuse_port workers" {
    if (!bifrost.Config.multi_worker_supported) return error.SkipZigTest;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var backend: Backend = undefined;
    try backend.start(io);
    defer backend.stop(io);

    var config = try workerConfig(&backend.echo, 4);
    config.max_players = 3;
    const workers = try Workers.create(gpa, io, config, .off);
    defer workers.destroy();
    var run = try io.concurrent(Workers.run, .{workers});
    defer {
        workers.stop();
        run.await(io) catch {};
    }

    var players: [8]Player = undefined;
    var connected: usize = 0;
    defer for (players[0..connected]) |*player| player.deinit();
    for (0..players.len) |_| {
        // raknet's own cap can turn players away before we do
        players[connected] = connect(io, workers) catch |err| switch (err) {
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

    workers.stop();
    try run.await(io);
    try std.testing.expectEqual(@as(u64, 3), workers.totals().sessions_accepted);
}

test "one worker stopping stops the rest" {
    if (!bifrost.Config.multi_worker_supported) return error.SkipZigTest;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const workers = try Workers.create(gpa, io, try idleConfig(3), .off);
    defer workers.destroy();
    var run = try io.concurrent(Workers.run, .{workers});
    workers.proxies[1].stop();
    try run.await(io);
}

test "workers start and stop repeatedly" {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const count: u8 = if (bifrost.Config.multi_worker_supported) 4 else 1;
    for (0..5) |_| {
        const workers = try Workers.create(gpa, io, try idleConfig(count), .off);
        defer workers.destroy();
        var run = try io.concurrent(Workers.run, .{workers});
        workers.stop();
        try run.await(io);
    }
}

test "workers clean up after allocation failures" {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const count: u8 = if (bifrost.Config.multi_worker_supported) 3 else 1;
    try std.testing.checkAllAllocationFailures(gpa, struct {
        fn run(allocator: std.mem.Allocator, io: std.Io, workers_count: u8) !void {
            var config = try harness.testConfig(harness.loopback);
            config.workers = workers_count;
            const workers = try Workers.create(allocator, io, config, .off);
            workers.destroy();
        }
    }.run, .{ threaded.io(), count });
}
