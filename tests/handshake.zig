const std = @import("std");
const bifrost = @import("bifrost");
const harness = @import("harness.zig");
const bedrock = @import("bedrock.zig");

const Proxy = bifrost.Proxy;
const EchoBackend = harness.EchoBackend;
const Player = harness.Player;
const gpa = std.testing.allocator;

const Rig = struct {
    threaded: std.Io.Threaded,
    backend: EchoBackend,
    backend_task: std.Io.Future(void),
    proxy: *Proxy,
    proxy_task: std.Io.Future(void),

    fn start(self: *Rig, replies: []const []const u8, auth: bifrost.Auth) !void {
        self.threaded = .init(gpa, .{});
        errdefer self.threaded.deinit();
        const rig_io = self.threaded.io();
        self.backend = try .start(rig_io);
        errdefer self.backend.listener.destroy();
        self.backend.replies = replies;
        self.backend_task = try rig_io.concurrent(EchoBackend.run, .{&self.backend});
        errdefer self.stopBackend();
        self.proxy = try Proxy.create(gpa, rig_io, try harness.testConfig(self.backend.address()), auth);
        errdefer self.proxy.destroy();
        self.proxy_task = try rig_io.concurrent(Proxy.run, .{self.proxy});
    }

    fn io(self: *Rig) std.Io {
        return self.threaded.io();
    }

    fn stopProxy(self: *Rig) void {
        self.proxy.stop();
        self.proxy_task.await(self.io());
    }

    fn stopBackend(self: *Rig) void {
        self.backend.stop.store(true, .release);
        self.backend_task.await(self.io());
    }

    fn deinit(self: *Rig) void {
        self.stopProxy();
        self.proxy.destroy();
        self.stopBackend();
        self.backend.listener.destroy();
        self.threaded.deinit();
    }
};

test "observes the clear handshake, then relays ciphertext untouched" {
    var frames: bedrock.Frames = try .init(bedrock.current_version);
    defer frames.deinit();
    var rig: Rig = undefined;
    try rig.start(&.{ frames.settings, frames.handshake }, .off);
    defer rig.deinit();

    var player: Player = try .connect(rig.io(), rig.proxy);
    defer player.deinit();
    try player.client.send(frames.request, .reliable_ordered, 0);
    try player.expect(frames.settings);
    try player.client.send(frames.login, .reliable_ordered, 0);
    try player.expect(frames.handshake);

    var ciphertext: [4096]u8 = undefined;
    for (&ciphertext, 0..) |*byte, i| byte.* = @truncate(i *% 31 +% 7);
    ciphertext[0] = 0xfe;
    try player.roundTrip(&ciphertext);

    rig.stopProxy();
    const stats = rig.proxy.stats;
    try std.testing.expectEqual(@as(u64, 1), stats.handshakes_observed);
    try std.testing.expectEqual(@as(u64, 0), stats.observer_gave_up);
    try std.testing.expectEqual(@as(u64, frames.request.len + frames.login.len + ciphertext.len), stats.bytes_to_backend);
    try std.testing.expectEqual(@as(u64, frames.settings.len + frames.handshake.len + ciphertext.len), stats.bytes_to_player);
}

test "an unfollowable handshake is still relayed when auth is off" {
    var frames: bedrock.Frames = try .init(bedrock.current_version + 1);
    defer frames.deinit();
    var rig: Rig = undefined;
    try rig.start(&.{frames.settings}, .off);
    defer rig.deinit();

    var player: Player = try .connect(rig.io(), rig.proxy);
    defer player.deinit();
    try player.client.send(frames.request, .reliable_ordered, 0);
    try player.expect(frames.settings);
    try player.roundTrip(frames.login);

    rig.stopProxy();
    try std.testing.expectEqual(@as(u64, 1), rig.proxy.stats.observer_gave_up);
    try std.testing.expectEqual(@as(u64, 0), rig.proxy.stats.handshakes_observed);
}

test "verify mode rejects a bad login before it reaches the backend" {
    var keys = try testKeys();
    defer keys.deinit();
    var frames: bedrock.Frames = try .init(bedrock.current_version);
    defer frames.deinit();
    var rig: Rig = undefined;
    try rig.start(&.{frames.settings}, .{ .verify = &keys });
    defer rig.deinit();

    var player: Player = try .connect(rig.io(), rig.proxy);
    defer player.deinit();
    try player.client.send(frames.request, .reliable_ordered, 0);
    try player.expect(frames.settings);
    try player.client.send(frames.login, .reliable_ordered, 0);
    try player.awaitClosed();

    rig.stopProxy();
    try std.testing.expectEqual(@as(u64, 1), rig.proxy.stats.logins_rejected);
    try std.testing.expectEqual(@as(u64, 0), rig.proxy.stats.auth_unavailable);
    try std.testing.expectEqual(@as(u32, 1), rig.backend.received.load(.acquire));
}

test "verify mode fails closed when the handshake can't be followed" {
    var keys = try testKeys();
    defer keys.deinit();
    var rig: Rig = undefined;
    try rig.start(&.{}, .{ .verify = &keys });
    defer rig.deinit();

    var player: Player = try .connect(rig.io(), rig.proxy);
    defer player.deinit();
    try player.client.send("\xfenot a batch", .reliable_ordered, 0);
    try player.awaitClosed();

    rig.stopProxy();
    try std.testing.expectEqual(@as(u64, 1), rig.proxy.stats.auth_unavailable);
    try std.testing.expectEqual(@as(u32, 0), rig.backend.received.load(.acquire));
}

/// A structurally valid JWKS; no real token will ever verify against it.
fn testKeys() !bifrost.KeySet {
    var modulus: [256]u8 = @splat(0xab);
    modulus[255] = 0x01;
    var encoded: [std.base64.url_safe_no_pad.Encoder.calcSize(256)]u8 = undefined;
    const n = std.base64.url_safe_no_pad.Encoder.encode(&encoded, &modulus);
    const json = try std.fmt.allocPrint(gpa, "{{\"keys\":[{{\"kty\":\"RSA\",\"kid\":\"test\",\"n\":\"{s}\",\"e\":\"AQAB\"}}]}}", .{n});
    defer gpa.free(json);
    return bifrost.KeySet.parse(gpa, json, .{});
}
