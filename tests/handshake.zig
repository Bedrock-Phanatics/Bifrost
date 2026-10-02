const std = @import("std");
const bifrost = @import("bifrost");
const fixtures = @import("support/fixtures.zig");
const bedrock = @import("support/bedrock.zig");

const Backend = fixtures.Backend;
const Running = fixtures.Running;
const Player = fixtures.Player;
const gpa = std.testing.allocator;
const io = std.testing.io;

test "observes the clear handshake, then relays ciphertext untouched" {
    var frames: bedrock.Frames = try .init(bedrock.current_version);
    defer frames.deinit();
    var backend: Backend = undefined;
    try backend.start(io, .{ .replies = &.{ frames.settings, frames.handshake } });
    defer backend.deinit();
    var running: Running = undefined;
    try running.start(io, try fixtures.config(&.{backend.address()}), .{});
    defer running.deinit();

    var player: Player = try .connect(io, running.address());
    defer player.deinit();
    try player.send(frames.request);
    try player.expect(frames.settings);
    try player.send(frames.login);
    try player.expect(frames.handshake);

    var ciphertext: [4096]u8 = undefined;
    for (&ciphertext, 0..) |*byte, i| byte.* = @truncate(i *% 31 +% 7);
    ciphertext[0] = 0xfe;
    try player.roundTrip(&ciphertext);

    running.stop();
    const stats = running.stats();
    try std.testing.expectEqual(@as(u64, 1), stats.handshakes_observed);
    try std.testing.expectEqual(@as(u64, 0), stats.observer_gave_up);
    try std.testing.expectEqual(@as(u64, frames.request.len + frames.login.len + ciphertext.len), stats.bytes_to_backend);
    try std.testing.expectEqual(@as(u64, frames.settings.len + frames.handshake.len + ciphertext.len), stats.bytes_to_player);
}

test "an unfollowable handshake is still relayed when auth is off" {
    var frames: bedrock.Frames = try .init(bedrock.current_version + 1);
    defer frames.deinit();
    var backend: Backend = undefined;
    try backend.start(io, .{ .replies = &.{frames.settings} });
    defer backend.deinit();
    var running: Running = undefined;
    try running.start(io, try fixtures.config(&.{backend.address()}), .{});
    defer running.deinit();

    var player: Player = try .connect(io, running.address());
    defer player.deinit();
    try player.send(frames.request);
    try player.expect(frames.settings);
    try player.roundTrip(frames.login);

    running.stop();
    try std.testing.expectEqual(@as(u64, 1), running.stats().observer_gave_up);
    try std.testing.expectEqual(@as(u64, 0), running.stats().handshakes_observed);
}

test "verify mode rejects a bad login before it reaches the backend" {
    var keys = try testKeys();
    defer keys.deinit();
    var frames: bedrock.Frames = try .init(bedrock.current_version);
    defer frames.deinit();
    var backend: Backend = undefined;
    try backend.start(io, .{ .replies = &.{frames.settings} });
    defer backend.deinit();
    var running: Running = undefined;
    try running.start(io, try fixtures.config(&.{backend.address()}), .{ .auth = .{ .verify = &keys } });
    defer running.deinit();

    var player: Player = try .connect(io, running.address());
    defer player.deinit();
    try player.send(frames.request);
    try player.expect(frames.settings);
    try player.send(frames.login);
    try player.awaitClosed();

    running.stop();
    try std.testing.expectEqual(@as(u64, 1), running.stats().logins_rejected);
    try std.testing.expectEqual(@as(u64, 0), running.stats().auth_unavailable);
    try std.testing.expectEqual(@as(u32, 1), backend.received.load(.acquire));
}

test "verify mode fails closed when the handshake can't be followed" {
    var keys = try testKeys();
    defer keys.deinit();
    const silent = try fixtures.silent(io);
    defer silent.close(io);
    var running: Running = undefined;
    try running.start(io, try fixtures.config(&.{silent.address}), .{ .auth = .{ .verify = &keys } });
    defer running.deinit();

    var player: Player = try .connect(io, running.address());
    defer player.deinit();
    try player.send("\xfenot a batch");
    try player.awaitClosed();

    running.stop();
    try std.testing.expectEqual(@as(u64, 1), running.stats().auth_unavailable);
    try std.testing.expectEqual(@as(u64, 0), running.stats().bytes_to_backend);
}

// Parses fine, but nothing will ever verify against it
fn testKeys() !bifrost.KeySet {
    var modulus: [256]u8 = @splat(0xab);
    modulus[255] = 0x01;
    var encoded: [std.base64.url_safe_no_pad.Encoder.calcSize(256)]u8 = undefined;
    const n = std.base64.url_safe_no_pad.Encoder.encode(&encoded, &modulus);
    const json = try std.fmt.allocPrint(gpa, "{{\"keys\":[{{\"kty\":\"RSA\",\"kid\":\"test\",\"n\":\"{s}\",\"e\":\"AQAB\"}}]}}", .{n});
    defer gpa.free(json);
    return bifrost.KeySet.parse(gpa, json, .{});
}
