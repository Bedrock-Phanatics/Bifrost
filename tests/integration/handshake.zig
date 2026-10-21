const std = @import("std");
const bifrost = @import("bifrost");
const fixtures = @import("../support/fixtures.zig");
const bedrock = @import("../support/bedrock.zig");
const managed = @import("../support/managed.zig");

const Backend = fixtures.Backend;
const Running = fixtures.Running;
const Player = fixtures.Player;
const gpa = std.testing.allocator;
const io = std.testing.io;

test "observes the login, then relays everything after it untouched" {
    var frames: bedrock.Frames = try .init(bedrock.current_version);
    defer frames.deinit();
    var backend: Backend = undefined;
    try backend.start(io, .{ .replies = &.{ frames.settings, frames.status } });
    defer backend.deinit();
    var running: Running = undefined;
    try running.start(io, try fixtures.config(&.{backend.address()}), .{});
    defer running.deinit();

    var player: Player = try .connect(io, running.address());
    defer player.deinit();
    try player.send(frames.request);
    try player.expect(frames.settings);
    try player.send(frames.login);
    try player.expect(frames.status);

    var opaque_bytes: [4096]u8 = undefined;
    for (&opaque_bytes, 0..) |*byte, i| byte.* = @truncate(i *% 31 +% 7);
    try player.roundTrip(&opaque_bytes);

    running.stop();
    const stats = running.stats();
    try std.testing.expectEqual(@as(u64, 1), stats.logins_observed);
    try std.testing.expectEqual(@as(u64, 0), stats.observer_gave_up);
    try std.testing.expectEqual(@as(u64, frames.request.len + frames.login.len + opaque_bytes.len), stats.bytes_to_backend);
    try std.testing.expectEqual(@as(u64, frames.settings.len + frames.status.len + opaque_bytes.len), stats.bytes_to_player);
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
    try std.testing.expectEqual(@as(u64, 0), running.stats().logins_observed);
}

test "verify mode turns away players that can't prove a key" {
    var keys = try managed.keySet();
    defer keys.deinit();
    var backend: Backend = undefined;
    try backend.start(io, .{});
    defer backend.deinit();
    var running: Running = undefined;
    try running.start(io, try fixtures.config(&.{backend.address()}), .{ .auth = .{ .verify = &keys } });
    defer running.deinit();

    try std.testing.expectError(error.HttpFailure, Player.connect(io, running.address()));
    try std.testing.expectEqual(@as(u32, 0), backend.connects.load(.acquire));
}

test "verify mode rejects a bad login before it reaches the backend" {
    var keys = try managed.keySet();
    defer keys.deinit();
    var frames: bedrock.Frames = try .init(bedrock.current_version);
    defer frames.deinit();
    var backend: Backend = undefined;
    try backend.start(io, .{ .replies = &.{frames.settings} });
    defer backend.deinit();
    var running: Running = undefined;
    try running.start(io, try fixtures.config(&.{backend.address()}), .{ .auth = .{ .verify = &keys } });
    defer running.deinit();

    var player: Player = try .connectAs(io, running.address(), try managed.proxyKey(2));
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

// Without Minecraft encryption a sniffed Login would otherwise let anyone in as that player
test "verify mode only accepts a login signed with the key the connection proved" {
    var keys = try managed.keySet();
    defer keys.deinit();
    var frames: bedrock.Frames = try .init(bedrock.current_version);
    defer frames.deinit();
    const owner = try managed.proxyKey(2);
    const login = try bedrock.loginFrame(owner, "Steve", "2535400000000001", std.Io.Clock.real.now(io).toSeconds());
    defer gpa.free(login);
    var backend: Backend = undefined;
    try backend.start(io, .{ .replies = &.{ frames.settings, frames.settings } });
    defer backend.deinit();
    var running: Running = undefined;
    try running.start(io, try fixtures.config(&.{backend.address()}), .{ .auth = .{ .verify = &keys } });
    defer running.deinit();

    var thief: Player = try .connectAs(io, running.address(), try managed.proxyKey(3));
    defer thief.deinit();
    try thief.send(frames.request);
    try thief.expect(frames.settings);
    try thief.send(login);
    try thief.awaitClosed();

    var player: Player = try .connectAs(io, running.address(), owner);
    defer player.deinit();
    try player.send(frames.request);
    try player.expect(frames.settings);
    try player.roundTrip(login);

    running.stop();
    const stats = running.stats();
    try std.testing.expectEqual(@as(u64, 1), stats.logins_rejected);
    try std.testing.expectEqual(@as(u64, 1), stats.logins_verified);
}

test "verify mode fails closed when the handshake can't be followed" {
    var keys = try managed.keySet();
    defer keys.deinit();
    const silent = try fixtures.silent(io);
    defer silent.close(io);
    var running: Running = undefined;
    try running.start(io, try fixtures.config(&.{silent.address}), .{ .auth = .{ .verify = &keys } });
    defer running.deinit();

    var player: Player = try .connectAs(io, running.address(), try managed.proxyKey(2));
    defer player.deinit();
    try player.send("not a batch");
    try player.awaitClosed();

    running.stop();
    try std.testing.expectEqual(@as(u64, 1), running.stats().auth_unavailable);
    try std.testing.expectEqual(@as(u64, 0), running.stats().bytes_to_backend);
}
