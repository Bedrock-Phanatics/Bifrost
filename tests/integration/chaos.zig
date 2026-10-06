const std = @import("std");
const fixtures = @import("../support/fixtures.zig");
const managed = @import("../support/managed.zig");
const Rig = @import("../support/rig.zig").Rig;

const Player = managed.Player;
const io = std.testing.io;

const Changes = struct {
    player: *Player,
    at_least: usize,

    fn reached(self: Changes) bool {
        return self.player.changes.items.len >= self.at_least;
    }
};

const Dropped = struct {
    fn done(backend: *managed.Backend) bool {
        return !backend.drop_all.load(.acquire);
    }
};

fn waitForChanges(rig: *Rig, at_least: usize) !void {
    try rig.pumpUntil(Changes{ .player = rig.player, .at_least = at_least }, Changes.reached);
}

test "the origin dropping before the switch ends the session and frees the target" {
    var rig: Rig = undefined;
    try rig.start(.{ .b = .silent_login });
    defer rig.deinit();

    try rig.transfer(1);
    try fixtures.waitFor(io, &rig.b.logins, 1);
    rig.a.drop_all.store(true, .release);
    try rig.running.waitForStat(.transfers_failed_before_commit, 1);
    try rig.player.awaitClosed();
    try fixtures.waitFor(io, &rig.b.disconnects, 1);
    try std.testing.expectEqual(@as(u64, 0), rig.stats().transfers_committed);
}

test "the origin dropping after the switch doesn't disturb the player" {
    var rig: Rig = undefined;
    try rig.start(.{});
    defer rig.deinit();
    rig.b.hold_spawn.store(true, .release);

    try rig.transfer(1);
    try waitForChanges(&rig, 2);
    rig.a.drop_all.store(true, .release);
    try fixtures.eventually(io, &rig.a, Dropped.done);
    rig.b.hold_spawn.store(false, .release);
    try rig.waitFor(.transfers_committed, 1);
    try rig.expectOn(&rig.b);
}

test "a client that never acknowledges the switch times out and is disconnected" {
    var rig: Rig = undefined;
    try rig.start(.{ .phase_timeout_ms = 1_000 });
    defer rig.deinit();
    rig.player.hold_acks = true;

    try rig.transfer(1);
    try rig.running.waitForStat(.transfers_timed_out, 1);
    try rig.player.awaitClosed();
    try std.testing.expectEqual(@as(u64, 0), rig.stats().transfers_committed);
    try fixtures.waitFor(io, &rig.b.disconnects, 1);
}

test "a target that stalls pack negotiation times out and the player stays" {
    var rig: Rig = undefined;
    try rig.start(.{ .b = .silent_stack, .phase_timeout_ms = 300 });
    defer rig.deinit();

    try rig.transfer(1);
    try rig.waitFor(.transfers_timed_out, 1);
    try rig.expectOn(&rig.a);
    try fixtures.waitFor(io, &rig.b.disconnects, 1);
}

test "health changing mid-transfer only affects new requests" {
    var rig: Rig = undefined;
    try rig.start(.{ .health = true });
    defer rig.deinit();
    rig.b.hold_spawn.store(true, .release);

    try rig.transfer(1);
    try waitForChanges(&rig, 2);
    rig.health.markFailed(.of(1));
    rig.b.hold_spawn.store(false, .release);
    try rig.waitFor(.transfers_committed, 1);
    try rig.expectOn(&rig.b);

    rig.health.markFailed(.of(0));
    try rig.transfer(0);
    try rig.waitFor(.transfers_rejected, 1);
    try rig.expectOn(&rig.b);
}

test "stopping the proxy while the client syncs frees both backends" {
    var rig: Rig = undefined;
    try rig.start(.{});
    defer rig.deinit();
    rig.player.hold_acks = true;

    try rig.transfer(1);
    try waitForChanges(&rig, 1);
    rig.running.stop();
    try std.testing.expectEqual(@as(u64, 1), rig.stats().transfers_failed_after_commit);
    try fixtures.waitFor(io, &rig.a.disconnects, 1);
    try fixtures.waitFor(io, &rig.b.disconnects, 1);
}

test "a target that breaks the join order is rolled back" {
    for ([_]managed.Backend.Mode{ .early_start, .double_stack }) |mode| {
        var rig: Rig = undefined;
        try rig.start(.{ .b = mode });
        defer rig.deinit();
        try rig.transfer(1);
        try rig.waitFor(.transfers_failed_before_commit, 1);
        try rig.expectOn(&rig.a);
        try fixtures.waitFor(io, &rig.b.disconnects, 1);
    }
}

test "a backend whose packets break the session is told at once" {
    var rig: Rig = undefined;
    try rig.start(.{});
    defer rig.deinit();
    try rig.transfer(1);
    try rig.waitFor(.transfers_committed, 1);

    var buffer: [16]u8 = undefined;
    try rig.player.send(&.{try managed.rawPacket(&buffer, managed.game_packet_id, "late")});
    try rig.player.awaitClosed();
    try fixtures.waitFor(io, &rig.b.disconnects, 1);
}
