const std = @import("std");
const bedwire = @import("bedwire");
const test_options = @import("test_options");
const fixtures = @import("../support/fixtures.zig");
const managed = @import("../support/managed.zig");
const FailOnce = @import("../support/FailOnce.zig");
const Rig = @import("../support/rig.zig").Rig;

const Player = managed.Player;
const Vec3f = bedwire.protocol.Vec3f;
const io = std.testing.io;

const overworld = 0;
const nether = 1;
const spawn: Vec3f = .{ .x = 10, .y = 70, .z = 10 };
const far: Vec3f = .{ .x = 29_999_000, .y = 300, .z = -29_999_000 };

const Changes = struct {
    player: *Player,
    at_least: usize,

    fn reached(self: Changes) bool {
        return self.player.changes.items.len >= self.at_least;
    }
};

fn waitForChanges(rig: *Rig, at_least: usize) !void {
    try rig.pumpUntil(Changes{ .player = rig.player, .at_least = at_least }, Changes.reached);
}

fn moveTo(rig: *Rig, target: usize, round: u64) !void {
    try rig.transfer(target);
    try rig.waitFor(.transfers_committed, round);
    try rig.expectOn(if (target == 1) &rig.b else &rig.a);
}

fn expectLanded(player: *const Player, dimension: i32, position: Vec3f) !void {
    const last = player.changes.getLast();
    try std.testing.expectEqual(dimension, last.dimension_id);
    try std.testing.expectEqual(position, last.position);
}

fn pumpFor(player: *Player, ms: i64) !void {
    _ = try player.countGamePackets("", ms);
}

test "a same-dimension move detours once and lands on the target spawn" {
    for ([_]Vec3f{ spawn, far }) |position| {
        var rig: Rig = undefined;
        try rig.start(.{ .a_content = .{ .position = spawn }, .b_content = .{ .position = position } });
        defer rig.deinit();
        try moveTo(&rig, 1, 1);

        const player = rig.player;
        try std.testing.expectEqual(@as(usize, 2), player.changes.items.len);
        try std.testing.expectEqual(@as(i32, nether), player.changes.items[0].dimension_id);
        try expectLanded(player, overworld, position);
        try std.testing.expectEqual(@as(usize, 2), player.received(.level_chunk));
        try std.testing.expectEqual(@as(usize, 1), player.received(.chunk_radius_updated));
        try std.testing.expect(player.lastIndex(.level_chunk).? > player.lastIndex(.change_dimension).?);
    }
}

test "moving between dimensions needs no detour either way" {
    var rig: Rig = undefined;
    try rig.start(.{ .b_content = .{ .dimension = nether, .position = far } });
    defer rig.deinit();

    try moveTo(&rig, 1, 1);
    try std.testing.expectEqual(@as(usize, 1), rig.player.changes.items.len);
    try expectLanded(rig.player, nether, far);
    try moveTo(&rig, 0, 2);
    try std.testing.expectEqual(@as(usize, 2), rig.player.changes.items.len);
    try std.testing.expectEqual(overworld, rig.player.changes.items[1].dimension_id);
    try std.testing.expectEqual(@as(usize, 2), rig.player.received(.level_chunk));
}

test "the client's cache support reaches every backend" {
    for ([_]?bool{ true, false, null }) |cache| {
        var rig: Rig = undefined;
        try rig.start(.{ .cache = cache });
        defer rig.deinit();
        try moveTo(&rig, 1, 1);

        const reports: u32 = if (cache == null) 0 else 1;
        try std.testing.expectEqual(reports, rig.a.cache_reports.load(.acquire));
        try std.testing.expectEqual(reports, rig.b.cache_reports.load(.acquire));
        if (cache) |supported| try std.testing.expectEqual(supported, rig.b.cache_supported.load(.acquire));
    }
}

test "sub-chunk requests during and after the switch go to the target" {
    var rig: Rig = undefined;
    try rig.start(.{});
    defer rig.deinit();
    var buffer: [64]u8 = undefined;
    const request = try managed.typedPacket(&buffer, .{ .sub_chunk_request = .{
        .dimension_type = overworld,
        .sub_chunk_position_offset_list = .empty,
        .center_pos = .{ .x = 0, .y = 4, .z = 0 },
    } });

    rig.player.hold_acks = true;
    try rig.transfer(1);
    try waitForChanges(&rig, 1);
    try rig.player.send(&.{request});
    try fixtures.waitFor(io, &rig.b.sub_chunk_requests, 1);
    try rig.player.releaseAcks();
    try rig.waitFor(.transfers_committed, 1);
    try rig.player.send(&.{request});
    try fixtures.waitFor(io, &rig.b.sub_chunk_requests, 2);
    try std.testing.expectEqual(@as(u32, 0), rig.a.sub_chunk_requests.load(.acquire));
}

test "what the old backend showed is cleared once, before the new world" {
    var rig: Rig = undefined;
    try rig.start(.{});
    defer rig.deinit();
    var buffer: [16]u8 = undefined;
    try rig.player.send(&.{try managed.rawPacket(&buffer, managed.game_packet_id, "scene")});
    const Scene = struct {
        fn shown(player: *Player) bool {
            return player.received(.mob_effect) == 1;
        }
    };
    try rig.pumpUntil(rig.player, Scene.shown);
    try std.testing.expectEqual(@as(usize, managed.Backend.scene_entities), rig.player.received(.add_painting));

    try moveTo(&rig, 1, 1);
    const player = rig.player;
    try std.testing.expectEqual(@as(usize, managed.Backend.scene_entities), player.received(.remove_actor));
    try std.testing.expectEqual(@as(usize, 1), player.received(.container_close));
    try std.testing.expectEqual(@as(usize, 1), player.received(.remove_objective));
    try std.testing.expectEqual(@as(usize, 2), player.received(.boss_event));
    try std.testing.expectEqual(@as(usize, 2), player.received(.mob_effect));
    const first_change = std.mem.indexOfScalar(bedwire.PacketKind, player.kinds.items, .change_dimension).?;
    try std.testing.expect(player.lastIndex(.remove_actor).? < first_change);

    try moveTo(&rig, 0, 2);
    try std.testing.expectEqual(@as(usize, managed.Backend.scene_entities), player.received(.remove_actor));
    try std.testing.expectEqual(@as(usize, 1), player.received(.container_close));
}

test "a client ack before the target spawns waits for the spawn" {
    var rig: Rig = undefined;
    try rig.start(.{});
    defer rig.deinit();
    rig.b.hold_spawn.store(true, .release);

    try rig.transfer(1);
    try waitForChanges(&rig, 2);
    try fixtures.waitFor(io, &rig.b.chunk_requests, 1);
    try pumpFor(rig.player, 200);
    try std.testing.expectEqual(@as(u64, 0), rig.stats().transfers_committed);
    try std.testing.expectEqual(@as(u32, 0), rig.b.spawns.load(.acquire));

    rig.b.hold_spawn.store(false, .release);
    try rig.waitFor(.transfers_committed, 1);
    try rig.expectOn(&rig.b);
    try std.testing.expectEqual(@as(u32, 1), rig.b.spawns.load(.acquire));
}

test "a target spawn before the client acks waits for the ack" {
    var rig: Rig = undefined;
    try rig.start(.{});
    defer rig.deinit();
    rig.player.hold_acks = true;

    try rig.transfer(1);
    try waitForChanges(&rig, 1);
    try fixtures.waitFor(io, &rig.b.chunk_requests, 1);
    try pumpFor(rig.player, 200);
    try std.testing.expectEqual(@as(usize, 1), rig.player.changes.items.len);
    try std.testing.expectEqual(@as(usize, 0), rig.player.received(.chunk_radius_updated));
    try std.testing.expectEqual(@as(u64, 0), rig.stats().transfers_committed);
    try std.testing.expectEqual(@as(u32, 0), rig.b.spawns.load(.acquire));

    try rig.player.releaseAcks();
    try rig.waitFor(.transfers_committed, 1);
    try rig.expectOn(&rig.b);
    try std.testing.expectEqual(@as(u32, 1), rig.b.spawns.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), rig.player.received(.level_chunk));
}

test "a target that spawns before sending its world still lands once" {
    var rig: Rig = undefined;
    try rig.start(.{ .b = .spawn_first });
    defer rig.deinit();
    try moveTo(&rig, 1, 1);
    try std.testing.expectEqual(@as(usize, 2), rig.player.received(.level_chunk));
    try std.testing.expectEqual(@as(u32, 1), rig.b.spawns.load(.acquire));
}

test "a target that drops right after the switch disconnects the player" {
    var rig: Rig = undefined;
    try rig.start(.{});
    defer rig.deinit();
    rig.b.hold_spawn.store(true, .release);

    try rig.transfer(1);
    try waitForChanges(&rig, 2);
    try fixtures.waitFor(io, &rig.b.chunk_requests, 1);
    rig.b.drop_all.store(true, .release);
    try rig.running.waitForStat(.transfers_failed_after_commit, 1);
    try rig.player.awaitClosed();
    try std.testing.expectEqual(@as(u64, 0), rig.stats().transfers_committed);
}

test "hundreds of round trips keep transfer time and memory flat" {
    const rounds = 200;
    const warm_up = 20;
    var counting: FailOnce = .{ .child = std.testing.allocator, .fail_at = std.math.maxInt(usize), .armed = .init(false) };
    var rig: Rig = undefined;
    try rig.start(.{ .allocator = counting.allocator() });
    defer rig.deinit();

    var durations: [rounds]u64 = undefined;
    var settled: usize = 0;
    for (1..rounds + 1) |round| {
        const started = std.Io.Clock.awake.now(io);
        try moveTo(&rig, round % 2, round);
        durations[round - 1] = @intCast(started.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds());
        if (round == warm_up) settled = counting.liveBytes();
    }
    const stats = rig.stats();
    try std.testing.expectEqual(@as(u64, 0), stats.transfers_failed_before_commit + stats.transfers_failed_after_commit + stats.transfers_timed_out);
    try std.testing.expectEqual(@as(usize, 2 * rounds), rig.player.changes.items.len);
    const live = counting.liveBytes();

    std.mem.sort(u64, &durations, {}, std.sort.asc(u64));
    if (test_options.report) std.debug.print("\n{d} transfers: p50 {d:.2} ms, p99 {d:.2} ms, live bytes {d} after {d} rounds, {d} after {d}\n", .{
        rounds,
        millis(durations[rounds / 2]),
        millis(durations[rounds * 99 / 100]),
        settled,
        warm_up,
        live,
        rounds,
    });
    try std.testing.expect(live <= settled + 64 * 1024);
}

fn millis(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

test "eight players moving at once keep transfer time and memory flat" {
    const rounds = 50;
    const warm_up = 5;
    var counting: FailOnce = .{ .child = std.testing.allocator, .fail_at = std.math.maxInt(usize), .armed = .init(false) };
    var rig: Rig = undefined;
    try rig.start(.{ .allocator = counting.allocator() });
    defer rig.deinit();
    var players: [8]*Player = undefined;
    players[0] = rig.player;
    var joined: usize = 1;
    defer for (players[1..joined]) |player| player.destroy();
    for (players[1..], 3..) |*player, seed| {
        player.* = try Player.connect(io, rig.running.address(), @intCast(seed));
        joined += 1;
        try player.*.login("Alex", "2535400000000002");
        try player.*.spawn();
        // RakNet here never pings, so idle players would hit its 10 s timeout during slow Debug joins
        for (players[0..joined]) |active| try active.echo("keepalive");
    }
    for (players) |player| player.timeout_ms = 2;

    var durations: [rounds]u64 = undefined;
    var settled: usize = 0;
    for (1..rounds + 1) |round| {
        const started = std.Io.Clock.awake.now(io);
        // Joins alternate between backends, so player n started on backend (n - 1) % 2
        for (1..players.len + 1) |id| try rig.running.proxy.requestTransfer(id, .of((id - 1 + round) % 2));
        const target = round * players.len;
        for (0..5_000) |_| {
            if (rig.stats().transfers_committed >= target) break;
            for (players) |player| player.pump() catch |err| if (err != error.NoMessage) return err;
        } else return error.WaitTimedOut;
        durations[round - 1] = @intCast(started.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds());
        if (round == warm_up) settled = counting.liveBytes();
    }
    const stats = rig.stats();
    try std.testing.expectEqual(@as(u64, 0), stats.transfers_failed_before_commit + stats.transfers_failed_after_commit + stats.transfers_timed_out + stats.transfers_rejected);
    for (players) |player| player.timeout_ms = 5_000;
    for (players) |player| try player.echo("still here");
    const live = counting.liveBytes();

    std.mem.sort(u64, &durations, {}, std.sort.asc(u64));
    if (test_options.report) std.debug.print("\n{d} rounds of 8 concurrent transfers: p50 {d:.2} ms, p95 {d:.2} ms, p99 {d:.2} ms, live bytes {d} after {d} rounds, {d} after {d}\n", .{
        rounds,
        millis(durations[rounds / 2]),
        millis(durations[rounds * 95 / 100]),
        millis(durations[rounds * 99 / 100]),
        settled,
        warm_up,
        live,
        rounds,
    });
    try std.testing.expect(live <= settled + 64 * 1024);
}
