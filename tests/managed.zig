const std = @import("std");
const bifrost = @import("bifrost");
const fixtures = @import("support/fixtures.zig");
const managed = @import("support/managed.zig");
const bedrock = @import("support/bedrock.zig");
const FailOnce = @import("support/FailOnce.zig");

const Running = fixtures.Running;
const gpa = std.testing.allocator;
const io = std.testing.io;
const current_version = bedrock.current_version;

const Setup = struct {
    proxy_key: managed.Ecdsa.KeyPair,
    keys: bifrost.KeySet,
    backend: managed.Backend,
    running: Running,

    fn start(self: *Setup, backend_trusts: managed.Ecdsa.PublicKey) !void {
        self.proxy_key = try managed.proxyKey(1);
        self.keys = try managed.keySet();
        errdefer self.keys.deinit();
        try self.backend.start(io, backend_trusts);
        errdefer self.backend.deinit();
        try self.running.start(io, try managed.config(&.{self.backend.address()}), self.options());
    }

    fn options(self: *Setup) bifrost.Proxy.Options {
        return .{ .auth = .{ .verify = &self.keys }, .proxy_key = self.proxy_key };
    }

    fn deinit(self: *Setup) void {
        self.running.deinit();
        self.backend.deinit();
        self.keys.deinit();
    }
};

fn trusted() !managed.Ecdsa.PublicKey {
    return (try managed.proxyKey(1)).public_key;
}

test "a managed player logs in to a backend as the proxy and relays game packets" {
    var setup: Setup = undefined;
    try setup.start(try trusted());
    defer setup.deinit();

    const player = try managed.Player.connect(io, setup.running.address(), 2);
    defer player.destroy();
    try player.login("Steve", "2535400000000001");
    try std.testing.expect(player.session.encrypted());
    try player.spawn();
    try player.echo("hello");
    try player.echo(&@as([3000]u8, @splat('x')));
    // Spans many datagrams and gets compressed
    try player.echo(&@as([64 * 1024]u8, @splat('y')));

    try std.testing.expectEqualStrings("Steve", setup.backend.name());
    try std.testing.expectEqual(@as(usize, 0), setup.backend.identity_xuid_len);
    try std.testing.expect(!setup.backend.identity_online);
    setup.running.stop();
    const stats = setup.running.stats();
    try std.testing.expectEqual(@as(u64, 1), stats.logins_verified);
    try std.testing.expectEqual(@as(u64, 1), stats.proxy_logins);
    try std.testing.expectEqual(@as(u64, 0), stats.handshakes_observed);
}

test "a forged login never reaches the backend" {
    var setup: Setup = undefined;
    try setup.start(try trusted());
    defer setup.deinit();

    const player = try managed.Player.connect(io, setup.running.address(), 2);
    defer player.destroy();
    try player.settings(current_version);
    try player.sendLogin("Steve", "2535400000000001", try managed.proxyKey(3));
    try player.awaitClosed();

    setup.running.stop();
    try std.testing.expectEqual(@as(u64, 1), setup.running.stats().logins_rejected);
    try std.testing.expectEqual(@as(u64, 0), setup.running.stats().proxy_logins);
    try std.testing.expectEqual(@as(u32, 0), setup.backend.logins.load(.acquire));
}

test "a client on another protocol version is turned away" {
    var setup: Setup = undefined;
    try setup.start(try trusted());
    defer setup.deinit();

    const player = try managed.Player.connect(io, setup.running.address(), 2);
    defer player.destroy();
    try std.testing.expectError(error.ConnectionClosed, player.settings(current_version + 1));
    try player.awaitClosed();
}

test "a backend that doesn't trust the proxy key refuses the player" {
    var setup: Setup = undefined;
    try setup.start((try managed.proxyKey(7)).public_key);
    defer setup.deinit();

    const player = try managed.Player.connect(io, setup.running.address(), 2);
    defer player.destroy();
    try player.settings(current_version);
    try player.sendLogin("Steve", "2535400000000001", player.key);
    try player.finishHandshake();
    try player.awaitClosed();

    setup.running.stop();
    try std.testing.expectEqual(@as(u64, 1), setup.running.stats().proxy_logins);
    try std.testing.expectEqual(@as(u32, 0), setup.backend.logins.load(.acquire));
}

test "a backend's refusal reaches the player before the link closes" {
    var setup: Setup = undefined;
    try setup.start(try trusted());
    defer setup.deinit();
    setup.backend.refuse = true;

    const player = try managed.Player.connect(io, setup.running.address(), 2);
    defer player.destroy();
    try std.testing.expectError(error.LoginRefused, player.login("Steve", "2535400000000001"));
    try player.awaitClosed();
}

test "the player leaving closes the backend session" {
    var setup: Setup = undefined;
    try setup.start(try trusted());
    defer setup.deinit();

    const player = try managed.Player.connect(io, setup.running.address(), 2);
    try player.login("Steve", "2535400000000001");
    try player.spawn();
    player.destroy();
    try fixtures.waitFor(io, &setup.backend.disconnects, 1);
    try setup.running.waitForStat(.links_closed, 1);
}

test "a backend disconnect closes the managed player" {
    var setup: Setup = undefined;
    try setup.start(try trusted());
    defer setup.deinit();

    const player = try managed.Player.connect(io, setup.running.address(), 2);
    defer player.destroy();
    try player.login("Steve", "2535400000000001");
    try player.spawn();
    var buffer: [16]u8 = undefined;
    try player.send(&.{try managed.rawPacket(&buffer, managed.game_packet_id, "kick")});
    try player.awaitClosed();
    try setup.running.waitForStat(.links_closed, 1);
}

test "leaving at every login stage frees the managed link" {
    var setup: Setup = undefined;
    try setup.start(try trusted());
    defer setup.deinit();

    for (0..5) |stage| {
        const player = try managed.Player.connect(io, setup.running.address(), 2);
        if (stage >= 1) try player.settings(current_version);
        if (stage >= 2) try player.sendLogin("Steve", "2535400000000001", player.key);
        if (stage >= 3) try player.finishHandshake();
        if (stage >= 4) try player.awaitLoginStatus();
        player.destroy();
        try setup.running.waitForStat(.links_closed, stage + 1);
    }
    setup.running.stop();
    try std.testing.expectEqual(@as(u64, 5), setup.running.stats().sessions_accepted);
}

test "leaving while the backend dial is pending cancels it" {
    const silent = try fixtures.silent(io);
    defer silent.close(io);
    var keys = try managed.keySet();
    defer keys.deinit();
    var proxy_config = try managed.config(&.{silent.address});
    proxy_config.connect_timeout_ms = 60_000;
    var running: Running = undefined;
    try running.start(io, proxy_config, .{ .auth = .{ .verify = &keys }, .proxy_key = try managed.proxyKey(1) });
    defer running.deinit();

    // The player's handshake doesn't wait for the backend
    const player = try managed.Player.connect(io, running.address(), 2);
    try player.settings(current_version);
    try player.sendLogin("Steve", "2535400000000001", player.key);
    try player.finishHandshake();
    player.destroy();
    try running.waitForStat(.links_closed, 1);

    running.stop();
    try std.testing.expectEqual(@as(u64, 0), running.stats().backends_connected);
    try std.testing.expectEqual(@as(u64, 0), running.stats().proxy_logins);
}

test "stopping the proxy frees managed links in every state" {
    var setup: Setup = undefined;
    try setup.start(try trusted());
    defer setup.deinit();

    const playing = try managed.Player.connect(io, setup.running.address(), 2);
    defer playing.destroy();
    try playing.login("Steve", "2535400000000001");
    try playing.spawn();
    const joining = try managed.Player.connect(io, setup.running.address(), 3);
    defer joining.destroy();
    try joining.settings(current_version);

    setup.running.stop();
    try std.testing.expectEqual(@as(u64, 2), setup.running.stats().links_closed);
    try playing.awaitClosed();
    try joining.awaitClosed();
}

test "passthrough ignores the proxy key and relays bytes untouched" {
    var backend: fixtures.Backend = undefined;
    try backend.start(io, .{});
    defer backend.deinit();
    var running: Running = undefined;
    try running.start(io, try fixtures.config(&.{backend.address()}), .{ .proxy_key = try managed.proxyKey(1) });
    defer running.deinit();

    var player: fixtures.Player = try .connect(io, running.address());
    defer player.deinit();
    try player.roundTrip("\xfenot a bedrock batch");

    running.stop();
    try std.testing.expectEqual(@as(u64, 0), running.stats().proxy_logins);
    try std.testing.expectEqual(@as(u64, "\xfenot a bedrock batch".len), running.stats().bytes_to_backend);
}

test "managed mode needs a proxy key and verified logins" {
    var keys = try managed.keySet();
    defer keys.deinit();
    const proxy_config = try managed.config(&.{fixtures.nowhere});
    try std.testing.expectError(error.MissingProxyKey, bifrost.Proxy.create(gpa, io, proxy_config, .{ .auth = .{ .verify = &keys } }));
    try std.testing.expectError(error.ManagedNeedsVerifiedLogins, bifrost.Proxy.create(gpa, io, proxy_config, .{ .proxy_key = try managed.proxyKey(1) }));
}

test "managed proxies clean up after allocation failures" {
    var keys = try managed.keySet();
    defer keys.deinit();
    try std.testing.checkAllAllocationFailures(gpa, struct {
        fn run(allocator: std.mem.Allocator, key_set: *const bifrost.KeySet) !void {
            const proxy = try bifrost.Proxy.create(allocator, io, try managed.config(&.{fixtures.nowhere}), .{
                .auth = .{ .verify = key_set },
                .proxy_key = try managed.proxyKey(1),
            });
            proxy.destroy();
        }
    }.run, .{&keys});
}

test "an allocation failure anywhere in a managed login fails cleanly" {
    var keys = try managed.keySet();
    defer keys.deinit();
    const proxy_key = try managed.proxyKey(1);
    var backend: managed.Backend = undefined;
    try backend.start(io, proxy_key.public_key);
    defer backend.deinit();
    const options: bifrost.Proxy.Options = .{ .auth = .{ .verify = &keys }, .proxy_key = proxy_key };
    const proxy_config = try managed.config(&.{backend.address()});

    // Fail each allocation of a full session, one at a time
    var counting: FailOnce = .{ .child = gpa, .fail_at = std.math.maxInt(usize) };
    try std.testing.expect(try playThrough(&counting, proxy_config, options));
    for (0..counting.allocations()) |fail_at| {
        var failing: FailOnce = .{ .child = gpa, .fail_at = fail_at };
        _ = try playThrough(&failing, proxy_config, options);
    }
}

fn playThrough(allocator: *FailOnce, proxy_config: bifrost.Config, options: bifrost.Proxy.Options) !bool {
    var running: Running = undefined;
    running.startWith(io, allocator.allocator(), proxy_config, options) catch return false;
    defer running.deinit();
    const player = managed.Player.connect(io, running.address(), 2) catch return false;
    defer player.destroy();
    player.timeout_ms = 1_000;
    player.login("Steve", "2535400000000001") catch return false;
    player.spawn() catch return false;
    player.echo("hello") catch return false;
    return true;
}
