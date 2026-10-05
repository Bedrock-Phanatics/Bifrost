const std = @import("std");
const bifrost = @import("bifrost");
const fixtures = @import("support/fixtures.zig");
const sample = @import("support/sample.zig");
const Rig = @import("support/rig.zig").Rig;

const io = std.testing.io;
const Policy = @FieldType(bifrost.Config, "content_policy");

const custom: sample.Content = .{ .pack = "packs:shared", .custom_block = "custom:lamp", .custom_item = "custom:wand" };

fn expectCommitted(rig: *Rig) !void {
    try rig.transfer(1);
    try rig.running.waitForStat(.transfers_committed, 1);
    try rig.expectOn(&rig.b);
}

fn expectRefused(rig: *Rig, comptime reason: std.meta.FieldEnum(bifrost.Stats)) !void {
    try rig.transfer(1);
    try rig.running.waitForStat(.transfers_failed_before_commit, 1);
    try std.testing.expectEqual(@as(u64, 1), @field(rig.stats(), @tagName(reason)));
    try std.testing.expectEqual(@as(u64, 0), rig.stats().transfers_committed);
    try rig.expectOn(&rig.a);
}

test "matching packs and registries transfer under both policies" {
    for ([_]Policy{ .initial, .match }) |policy| {
        var rig: Rig = undefined;
        try rig.start(.{ .content_policy = policy, .a_content = custom, .b_content = custom });
        defer rig.deinit();
        try expectCommitted(&rig);
    }
}

test "a target without packs keeps the initial ones, unless packs must match" {
    {
        var rig: Rig = undefined;
        try rig.start(.{ .a_content = .{ .pack = "packs:lobby" } });
        defer rig.deinit();
        try expectCommitted(&rig);
    }
    var rig: Rig = undefined;
    try rig.start(.{ .content_policy = .match, .a_content = .{ .pack = "packs:lobby" } });
    defer rig.deinit();
    try expectRefused(&rig, .incompatible_packs);
}

test "a different pack stack is accepted only under the initial policy" {
    {
        var rig: Rig = undefined;
        try rig.start(.{ .a_content = .{ .pack = "packs:lobby" }, .b_content = .{ .pack = "packs:survival" } });
        defer rig.deinit();
        try expectCommitted(&rig);
    }
    var rig: Rig = undefined;
    try rig.start(.{ .content_policy = .match, .a_content = .{ .pack = "packs:lobby" }, .b_content = .{ .pack = "packs:survival" } });
    defer rig.deinit();
    try expectRefused(&rig, .incompatible_packs);
}

test "a changed custom block registry is refused" {
    var rig: Rig = undefined;
    try rig.start(.{ .a_content = .{ .custom_block = "custom:lamp" }, .b_content = .{ .custom_block = "custom:torch" } });
    defer rig.deinit();
    try expectRefused(&rig, .incompatible_blocks);
}

test "a changed custom item registry is refused" {
    var rig: Rig = undefined;
    try rig.start(.{ .a_content = .{ .custom_item = "custom:wand" }, .b_content = .{ .custom_item = "custom:staff" } });
    defer rig.deinit();
    try expectRefused(&rig, .incompatible_items);
}

test "a target with different client-locked StartGame state is refused" {
    var rig: Rig = undefined;
    try rig.start(.{ .a_content = .{ .authoritative_block_breaking = false }, .b_content = .{ .authoritative_block_breaking = true } });
    defer rig.deinit();
    try expectRefused(&rig, .incompatible_start_game);
}

test "a target that drops out during pack negotiation is rolled back" {
    var rig: Rig = undefined;
    try rig.start(.{ .b = .kick_packs, .a_content = custom, .b_content = custom });
    defer rig.deinit();
    try rig.transfer(1);
    try rig.running.waitForStat(.transfers_failed_before_commit, 1);
    try rig.expectOn(&rig.a);
    const stats = rig.stats();
    try std.testing.expectEqual(@as(u64, 0), stats.incompatible_packs + stats.incompatible_blocks + stats.incompatible_items);
}

test "repeated compatible transfers keep working" {
    var rig: Rig = undefined;
    try rig.start(.{ .content_policy = .match, .a_content = custom, .b_content = custom });
    defer rig.deinit();
    for (1..7) |round| {
        try rig.transfer(round % 2);
        try rig.running.waitForStat(.transfers_committed, round);
        try rig.expectOn(if (round % 2 == 1) &rig.b else &rig.a);
    }
    try std.testing.expectEqual(@as(u64, 0), rig.stats().transfers_failed_before_commit);
}
