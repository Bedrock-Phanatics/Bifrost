const std = @import("std");
const bifrost = @import("bifrost");
const fixtures = @import("support/fixtures.zig");
const managed = @import("support/managed.zig");
const FailOnce = @import("support/FailOnce.zig");

const Running = fixtures.Running;
const Rig = @import("support/rig.zig").Rig;
const Player = managed.Player;
const gpa = std.testing.allocator;
const io = std.testing.io;
const IpAddress = std.Io.net.IpAddress;

test "a player moves from one backend to another" {
    var rig: Rig = undefined;
    try rig.start(.{});
    defer rig.deinit();
    try rig.expectOn(&rig.a);

    try rig.transfer(1);
    try rig.waitFor(.transfers_committed, 1);
    try rig.expectOn(&rig.b);
    try fixtures.waitFor(io, &rig.a.disconnects, 1);
    try std.testing.expectEqual(@as(u64, 1), rig.stats().transfers_started);
    try std.testing.expectEqual(@as(u32, 1), rig.b.chunk_requests.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), rig.b.spawns.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), rig.player.changes.items.len);
}

test "a player can bounce between backends" {
    var rig: Rig = undefined;
    try rig.start(.{});
    defer rig.deinit();

    for (1..5) |round| {
        try rig.transfer(round % 2);
        try rig.waitFor(.transfers_committed, round);
        try rig.expectOn(if (round % 2 == 1) &rig.b else &rig.a);
    }
    try std.testing.expectEqual(@as(u32, 3), rig.a.logins.load(.acquire));
    try std.testing.expectEqual(@as(u32, 2), rig.b.logins.load(.acquire));
}

test "an unreachable target leaves the player where it was" {
    const silent = try fixtures.silent(io);
    defer silent.close(io);
    var rig: Rig = undefined;
    try rig.start(.{ .target = silent.address });
    defer rig.deinit();

    try rig.transfer(1);
    try rig.waitFor(.transfers_failed_before_commit, 1);
    try rig.expectOn(&rig.a);
    try std.testing.expectEqual(@as(u64, 0), rig.stats().transfers_committed);
}

test "a target that drops the login is rolled back" {
    var rig: Rig = undefined;
    try rig.start(.{ .b = .kick_login });
    defer rig.deinit();

    try rig.transfer(1);
    try rig.waitFor(.transfers_failed_before_commit, 1);
    try rig.expectOn(&rig.a);
}

test "a stalled transfer times out and rolls back" {
    var rig: Rig = undefined;
    try rig.start(.{ .b = .silent_login, .phase_timeout_ms = 300 });
    defer rig.deinit();

    try rig.transfer(1);
    try rig.waitFor(.transfers_timed_out, 1);
    try rig.expectOn(&rig.a);
    try fixtures.waitFor(io, &rig.b.disconnects, 1);
}

test "a second request while one is in flight is rejected" {
    var rig: Rig = undefined;
    try rig.start(.{});
    defer rig.deinit();

    try rig.transfer(1);
    try rig.transfer(1);
    try rig.waitFor(.transfers_committed, 1);
    try rig.transfer(1);
    try rig.waitFor(.transfers_rejected, 2);
    try std.testing.expectEqual(@as(u64, 1), rig.stats().transfers_started);
    try rig.expectOn(&rig.b);
}

test "a dial left over from a timed out transfer is cancelled" {
    const silent = try fixtures.silent(io);
    defer silent.close(io);
    var rig: Rig = undefined;
    try rig.start(.{ .target = silent.address, .connect_timeout_ms = 5_000, .timeout_ms = 1_000, .phase_timeout_ms = 1_000 });
    defer rig.deinit();

    try rig.transfer(1);
    try rig.waitFor(.transfers_timed_out, 1);
    try rig.expectOn(&rig.a);
    try std.testing.expectEqual(@as(u64, 0), rig.stats().backends_connected - 1);
}

test "leaving or stopping the proxy mid-transfer frees the target in every phase" {
    const Phase = enum { dialing, logging_in, joining };
    for (std.enums.values(Phase)) |phase| for ([_]bool{ false, true }) |stop_proxy| {
        const silent = try fixtures.silent(io);
        defer silent.close(io);
        var rig: Rig = undefined;
        try rig.start(switch (phase) {
            .dialing => .{ .target = silent.address, .connect_timeout_ms = 5_000 },
            .logging_in => .{ .b = .silent_login },
            .joining => .{ .b = .silent_stack },
        });
        defer rig.deinit();

        try rig.transfer(1);
        switch (phase) {
            .dialing => try rig.waitFor(.transfers_started, 1),
            .logging_in => try fixtures.waitFor(io, &rig.b.logins, 1),
            .joining => try fixtures.waitFor(io, &rig.b.handshakes, 1),
        }
        if (stop_proxy) {
            rig.running.stop();
        } else {
            rig.player.destroy();
            rig.player = try Player.connect(io, rig.running.address(), 3);
            try rig.waitFor(.links_closed, 1);
        }
        try std.testing.expectEqual(@as(u64, 1), rig.stats().transfers_failed_before_commit);
        if (phase != .dialing) try fixtures.waitFor(io, &rig.b.disconnects, 1);
    };
}

test "the old backend is silent once the player has moved" {
    var rig: Rig = undefined;
    try rig.start(.{ .a = .chatter });
    defer rig.deinit();
    try std.testing.expect(try rig.player.countGamePackets("chatter", 200) > 0);

    try rig.transfer(1);
    try rig.waitFor(.transfers_committed, 1);
    _ = try rig.player.countGamePackets("chatter", 100);
    try std.testing.expectEqual(@as(usize, 0), try rig.player.countGamePackets("chatter", 500));
    try rig.expectOn(&rig.b);
}

test "target packets sent before the switch reach the player after it" {
    var rig: Rig = undefined;
    try rig.start(.{ .b = .welcome });
    defer rig.deinit();

    try rig.transfer(1);
    try rig.waitFor(.transfers_committed, 1);
    var buffer: [64]u8 = undefined;
    try std.testing.expectStringEndsWith(try rig.player.nextGamePacket(&buffer), "welcome");
    try rig.expectOn(&rig.b);
}

test "a target that overflows the queue is rolled back and its packets dropped" {
    var rig: Rig = undefined;
    try rig.start(.{ .b = .flood });
    defer rig.deinit();

    try rig.transfer(1);
    try rig.waitFor(.transfers_failed_before_commit, 1);
    try std.testing.expectEqual(@as(usize, 0), try rig.player.countGamePackets("flood", 200));
    try rig.expectOn(&rig.a);
}

test "an allocation failure anywhere in a transfer fails cleanly" {
    const proxy_key = try managed.proxyKey(1);
    var keys = try managed.keySet();
    defer keys.deinit();
    var a: managed.Backend = undefined;
    try a.start(io, proxy_key.public_key);
    defer a.deinit();
    var b: managed.Backend = undefined;
    try b.start(io, proxy_key.public_key);
    defer b.deinit();
    const options: bifrost.Proxy.Options = .{ .auth = .{ .verify = &keys }, .proxy_key = proxy_key };
    const proxy_config = try managed.config(&.{ a.address(), b.address() });

    var counting: FailOnce = .{ .child = gpa, .fail_at = std.math.maxInt(usize), .armed = .init(false) };
    try std.testing.expect(try transferWith(&counting, proxy_config, options));
    for (0..counting.allocations()) |fail_at| {
        var failing: FailOnce = .{ .child = gpa, .fail_at = fail_at, .armed = .init(false) };
        _ = try transferWith(&failing, proxy_config, options);
    }
}

fn transferWith(allocator: *FailOnce, proxy_config: bifrost.Config, options: bifrost.Proxy.Options) !bool {
    var running: Running = undefined;
    try running.startWith(io, allocator.allocator(), proxy_config, options);
    defer running.deinit();
    const player = try Player.connect(io, running.address(), 2);
    defer player.destroy();
    try player.login("Steve", "2535400000000001");
    try player.spawn();
    try player.echo("in game");
    allocator.armed.store(true, .release);
    defer allocator.armed.store(false, .release);
    player.timeout_ms = 1_000;
    try running.proxy.requestTransfer(1, .of(1));
    for (0..300) |_| {
        const stats = running.proxy.stats.snapshot();
        const ended = stats.transfers_committed + stats.transfers_failed_before_commit +
            stats.transfers_failed_after_commit + stats.transfers_timed_out + stats.transfers_rejected;
        if (ended != 0) break;
        player.timeout_ms = 10;
        player.pump() catch |err| switch (err) {
            error.NoMessage => {},
            else => break,
        };
    }
    player.timeout_ms = 1_000;
    const committed = running.proxy.stats.snapshot().transfers_committed == 1;
    player.echo("after") catch {};
    return committed;
}
