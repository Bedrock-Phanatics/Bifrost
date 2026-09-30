const std = @import("std");
const zio = @import("zio");
const bifrost = @import("bifrost");
const harness = @import("harness.zig");

const Proxy = bifrost.Proxy;
const EchoBackend = harness.EchoBackend;
const Player = harness.Player;
const loopback = harness.loopback;
const testConfig = harness.testConfig;
const waitFor = harness.waitFor;
const gpa = std.testing.allocator;

test "relays both directions and tears down the backend when the player leaves" {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    try relayScenario(threaded.io());
}

test "relays under the zio runtime" {
    const rt = try zio.Runtime.init(gpa, .{});
    defer rt.deinit();
    try relayScenario(rt.io());
}

fn relayScenario(io: std.Io) !void {
    var backend: EchoBackend = try .start(io);
    defer backend.listener.destroy();
    var backend_task = try io.concurrent(EchoBackend.run, .{&backend});
    defer {
        backend.stop.store(true, .release);
        backend_task.await(io);
    }

    const proxy = try Proxy.create(gpa, io, try testConfig(backend.listener.socket.value.address));
    defer proxy.destroy();
    var proxy_task = try io.concurrent(Proxy.run, .{proxy});
    defer {
        proxy.stop();
        proxy_task.await(io);
    }

    var player: Player = try .connect(io, proxy);
    errdefer player.deinit();
    try player.roundTrip("\xfehello");
    const large = try gpa.alloc(u8, 20_000);
    defer gpa.free(large);
    for (large, 0..) |*byte, i| byte.* = @truncate(i);
    large[0] = 0xfe; // RakNet treats low first bytes as control packets
    try player.roundTrip(large);
    player.deinit();

    try waitFor(io, &backend.disconnects, 1);
    proxy.stop();
    proxy_task.await(io);
    try std.testing.expectEqual(@as(u64, 1), proxy.stats.sessions_accepted);
    try std.testing.expectEqual(@as(u64, 1), proxy.stats.links_closed);
    try std.testing.expectEqual(@as(u64, 20_006), proxy.stats.bytes_to_backend);
    try std.testing.expectEqual(@as(u64, 20_006), proxy.stats.bytes_to_player);
}

test "closes the player when the backend is unreachable" {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const silent = try loopback.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer silent.close(io);

    const proxy = try Proxy.create(gpa, io, try testConfig(silent.address));
    defer proxy.destroy();
    var proxy_task = try io.concurrent(Proxy.run, .{proxy});
    defer {
        proxy.stop();
        proxy_task.await(io);
    }

    var player: Player = try .connect(io, proxy);
    defer player.deinit();
    try player.client.send("\xfequeued", .reliable_ordered, 0);
    try player.awaitClosed();

    proxy.stop();
    proxy_task.await(io);
    try std.testing.expectEqual(@as(u64, 1), proxy.stats.backend_failures);
    try std.testing.expectEqual(@as(u64, 1), proxy.stats.links_closed);
}

test "stop cancels in-flight dials and frees every link" {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const silent = try loopback.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer silent.close(io);

    var config = try testConfig(silent.address);
    config.connect_timeout_ms = 60_000;
    const proxy = try Proxy.create(gpa, io, config);
    defer proxy.destroy();
    var proxy_task = try io.concurrent(Proxy.run, .{proxy});

    var players: [3]Player = undefined;
    for (&players) |*player| player.* = try .connect(io, proxy);
    defer for (&players) |*player| player.deinit();
    for (&players) |*player| try player.client.send("\xfequeued", .reliable_ordered, 0);
    try io.sleep(.fromMilliseconds(100), .awake);

    const started = std.Io.Clock.awake.now(io);
    proxy.stop();
    proxy_task.await(io);
    const elapsed = started.durationTo(std.Io.Clock.awake.now(io));
    try std.testing.expect(elapsed.toMilliseconds() < 5_000);
    try std.testing.expectEqual(@as(u64, 3), proxy.stats.sessions_accepted);
    try std.testing.expectEqual(@as(u64, 0), proxy.stats.backends_connected);
    for (&players) |*player| try player.awaitClosed();
}

test "stop is safe before run and destroy is idempotent with it" {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const proxy = try Proxy.create(gpa, threaded.io(), try testConfig(loopback));
    proxy.stop();
    proxy.run();
    proxy.destroy();
}

test "example config parses" {
    var diag: bifrost.Diagnostic = .{};
    const config = bifrost.parseConfig(gpa, @embedFile("example_config"), &diag) catch |err| {
        std.debug.print("{f}\n", .{diag});
        return err;
    };
    try std.testing.expectEqual(@as(usize, 2), config.backends().len);
}
