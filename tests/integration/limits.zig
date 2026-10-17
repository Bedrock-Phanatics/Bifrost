const std = @import("std");
const raknet = @import("raknet");
const bifrost = @import("bifrost");
const fixtures = @import("../support/fixtures.zig");
const managed = @import("../support/managed.zig");
const bedrock = @import("../support/bedrock.zig");
const Rig = @import("../support/rig.zig").Rig;

const Backend = fixtures.Backend;
const Running = fixtures.Running;
const Player = fixtures.Player;
const gpa = std.testing.allocator;
const io = std.testing.io;

fn queued(running: *const Running) usize {
    return running.proxy.budget.used.load(.monotonic);
}

test "a player that never logs in times out and frees its slot" {
    var backend: Backend = undefined;
    try backend.start(io, .{});
    defer backend.deinit();
    var proxy_config = try fixtures.config(&.{backend.address()});
    proxy_config.login_timeout_ms = 300;
    var running: Running = undefined;
    try running.start(io, proxy_config, .{});
    defer running.deinit();

    var player: Player = try .connect(io, running.address());
    defer player.deinit();
    try player.awaitClosed();
    try running.waitForStat(.links_closed, 1);
    running.stop();
    try std.testing.expectEqual(@as(u64, 1), running.stats().login_timeouts);
    try std.testing.expectEqual(@as(u32, 0), running.proxy.admission.active.load(.monotonic));
    try fixtures.waitFor(io, &backend.disconnects, 1);
}

test "queues within their own limits still share one budget" {
    const silent = try fixtures.silent(io);
    defer silent.close(io);
    var proxy_config = try fixtures.config(&.{silent.address});
    proxy_config.connect_timeout_ms = 60_000;
    proxy_config.max_players = 32;
    proxy_config.pending_bytes = 8 * 1024;
    proxy_config.total_pending_bytes = 16 * 1024;
    var running: Running = undefined;
    try running.start(io, proxy_config, .{});
    defer running.deinit();

    var payload: [1024]u8 = @splat(7);
    payload[0] = 0xfe;
    var players: [16]Player = undefined;
    var connected: usize = 0;
    defer for (players[0..connected]) |*player| player.deinit();
    for (&players) |*player| {
        player.* = try .connect(io, running.address());
        connected += 1;
        try player.send(&payload);
    }
    for (0..500) |_| {
        if (queued(&running) == 16 * 1024) break;
        try io.sleep(.fromMilliseconds(10), .awake);
    } else return error.WaitTimedOut;

    var extra: Player = try .connect(io, running.address());
    defer extra.deinit();
    try extra.send(&payload);
    try extra.awaitClosed();
    for (players[0..connected]) |*player| try std.testing.expect(!player.client.isClosed());
    try std.testing.expectEqual(@as(u64, 1), running.proxy.budget.refusals.load(.monotonic));

    for (players[0..connected]) |*player| player.deinit();
    connected = 0;
    try running.waitForStat(.links_closed, 17);
    try std.testing.expectEqual(@as(usize, 0), queued(&running));
}

test "connect and disconnect cycles return every queued byte" {
    const silent = try fixtures.silent(io);
    defer silent.close(io);
    var proxy_config = try fixtures.config(&.{silent.address});
    proxy_config.connect_timeout_ms = 60_000;
    var running: Running = undefined;
    try running.start(io, proxy_config, .{});
    defer running.deinit();

    var payload: [4000]u8 = @splat(3);
    payload[0] = 0xfe;
    for (0..20) |round| {
        var player: Player = try .connect(io, running.address());
        try player.send(&payload);
        try player.send(&payload);
        for (0..500) |_| {
            if (queued(&running) == 2 * payload.len) break;
            try io.sleep(.fromMilliseconds(5), .awake);
        } else return error.WaitTimedOut;
        player.deinit();
        try running.waitForStat(.links_closed, round + 1);
        try std.testing.expectEqual(@as(usize, 0), queued(&running));
    }
    running.stop();
    try std.testing.expectEqual(@as(u32, 0), running.proxy.admission.active.load(.monotonic));
}

const Collector = struct {
    next: u32 = 0,
    broken: bool = false,

    fn collect(context: *anyopaque, payload: raknet.BorrowedPayload) error{ApplicationFailure}!void {
        const self: *Collector = @ptrCast(@alignCast(context));
        if (payload.bytes.len < 5 or std.mem.readInt(u32, payload.bytes[1..5], .little) != self.next) self.broken = true;
        self.next += 1;
    }
};

test "a player that falls behind pauses its backend instead of losing packets" {
    const count = 600;
    var backend: Backend = undefined;
    try backend.start(io, .{ .burst_count = count, .burst_bytes = 2048 });
    defer backend.deinit();
    var running: Running = undefined;
    try running.start(io, try fixtures.config(&.{backend.address()}), .{});
    defer running.deinit();

    var player: Player = try .connect(io, running.address());
    defer player.deinit();
    try player.roundTrip("\xfehello");
    try player.send(fixtures.burst);
    // Not polling means no acks, so the proxy's queue to us fills up
    try io.sleep(.fromMilliseconds(1_500), .awake);
    try std.testing.expect(running.proxy.stats.snapshot().backlog_pauses >= 1);

    var collector: Collector = .{};
    const started = std.Io.Clock.awake.now(io);
    while (collector.next < count and started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 10_000) {
        _ = player.client.poll(fixtures.millis(10), &collector, Collector.collect) catch |err| switch (err) {
            error.Timeout => {},
            else => return err,
        };
    }
    try std.testing.expect(!collector.broken);
    try std.testing.expectEqual(@as(u32, count), collector.next);
    try player.roundTrip("\xfestill here");
    running.stop();
    try std.testing.expectEqual(@as(u64, 0), running.stats().slow_players);
}

test "a player that stays behind too long is disconnected" {
    var backend: Backend = undefined;
    try backend.start(io, .{ .burst_count = 600, .burst_bytes = 2048 });
    defer backend.deinit();
    var proxy_config = try fixtures.config(&.{backend.address()});
    proxy_config.slow_player_timeout_ms = 300;
    var running: Running = undefined;
    try running.start(io, proxy_config, .{});
    defer running.deinit();

    var player: Player = try .connect(io, running.address());
    defer player.deinit();
    try player.roundTrip("\xfehello");
    try player.send(fixtures.burst);
    try running.waitForStat(.slow_players, 1);
    try player.awaitClosed();
    try running.waitForStat(.links_closed, 1);
    try fixtures.waitFor(io, &backend.disconnects, 1);
}

const ManagedSetup = struct {
    keys: bifrost.KeySet,
    backend: managed.Backend,
    running: Running,

    fn start(self: *ManagedSetup, tune: *const fn (*bifrost.Config) void) !void {
        const proxy_key = try managed.proxyKey(1);
        self.keys = try managed.keySet();
        errdefer self.keys.deinit();
        try self.backend.start(io, proxy_key.public_key);
        errdefer self.backend.deinit();
        var proxy_config = try managed.config(&.{self.backend.address()});
        proxy_config.max_players = 16;
        tune(&proxy_config);
        try self.running.start(io, proxy_config, .{ .auth = .{ .verify = &self.keys }, .proxy_key = proxy_key });
    }

    fn deinit(self: *ManagedSetup) void {
        self.running.deinit();
        self.backend.deinit();
        self.keys.deinit();
    }
};

const Logins = struct {
    running: *Running,
    total: u64,

    fn settled(self: Logins) bool {
        const stats = self.running.proxy.stats.snapshot();
        return stats.logins_verified + stats.logins_throttled == self.total;
    }
};

test "a login flood is throttled before any signature is checked" {
    var setup: ManagedSetup = undefined;
    try setup.start(struct {
        fn tune(config: *bifrost.Config) void {
            config.logins_per_second = 1;
        }
    }.tune);
    defer setup.deinit();

    var players: [6]*managed.Player = undefined;
    var connected: usize = 0;
    defer for (players[0..connected]) |player| player.destroy();
    for (&players, 0..) |*player, i| {
        player.* = try managed.Player.connect(io, setup.running.address(), @intCast(2 + i));
        connected += 1;
        try player.*.settings(bedrock.current_version);
    }
    for (players) |player| try player.sendLogin("Steve", "2535400000000001", player.key);
    try fixtures.eventually(io, Logins{ .running = &setup.running, .total = players.len }, Logins.settled);

    const stats = setup.running.proxy.stats.snapshot();
    try std.testing.expect(stats.logins_throttled >= 2);
    try std.testing.expectEqual(@as(u64, 0), stats.logins_rejected);
    setup.running.stop();
    try std.testing.expectEqual(@as(u32, 0), setup.running.proxy.admission.active.load(.monotonic));
}

test "a compression bomb from a player in game ends that player only" {
    var setup: ManagedSetup = undefined;
    try setup.start(struct {
        fn tune(config: *bifrost.Config) void {
            config.player_bytes_per_second = 64 * 1024;
        }
    }.tune);
    defer setup.deinit();

    const bystander = try managed.Player.connect(io, setup.running.address(), 3);
    defer bystander.destroy();
    try bystander.login("Alex", "2535400000000002");
    try bystander.spawn();
    const player = try managed.Player.connect(io, setup.running.address(), 2);
    defer player.destroy();
    try player.login("Steve", "2535400000000001");
    try player.spawn();

    const zeros = try gpa.alloc(u8, 250 * 1024);
    defer gpa.free(zeros);
    @memset(zeros, 0);
    const storage = try gpa.alloc(u8, zeros.len + 8);
    defer gpa.free(storage);
    const packet = try managed.rawPacket(storage, managed.game_packet_id, zeros);
    for (0..8) |_| player.send(&.{ packet, packet, packet, packet }) catch break;
    try player.awaitClosed();

    try std.testing.expectEqual(@as(u64, 1), setup.running.proxy.stats.snapshot().player_floods);
    try bystander.echo("unaffected");
}

test "transfers beyond the per-worker cap are refused" {
    var rig: Rig = undefined;
    try rig.start(.{ .max_transfers = 1 });
    defer rig.deinit();
    // Round robin puts the second player on b
    const second = try managed.Player.connect(io, rig.running.address(), 3);
    defer second.destroy();
    try second.login("Alex", "2535400000000002");
    try second.spawn();
    rig.b.hold_spawn.store(true, .release);

    try rig.transfer(1);
    try fixtures.waitFor(io, &rig.b.logins, 2);
    try rig.running.proxy.requestTransfer(2, .of(0));
    try rig.running.waitForStat(.transfers_rejected, 1);
    try second.echo("still on b");
    try std.testing.expectEqual(@as(u64, 1), rig.stats().transfers_started);
    rig.b.hold_spawn.store(false, .release);
    try rig.waitFor(.transfers_committed, 1);
    try rig.expectOn(&rig.b);
}
