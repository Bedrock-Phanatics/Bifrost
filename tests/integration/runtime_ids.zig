const std = @import("std");
const bedwire = @import("bedwire");
const managed = @import("../support/managed.zig");
const sample = @import("../support/sample.zig");
const Rig = @import("../support/rig.zig").Rig;

const protocol = bedwire.protocol;
const EntityLink = protocol.types.EntityLink;
const typedPacket = sample.typedPacket;
const zero: protocol.Vec3f = .{ .x = 0, .y = 0, .z = 0 };

// The client keeps the first backend's ids; the second backend picks others
const client_runtime = 10;
const client_unique = 10;
const target_runtime = 2000;
const target_unique = -2000;
const other = 500;

fn startOnTarget(rig: *Rig) !void {
    try rig.start(.{
        .a_content = .{ .runtime_id = client_runtime, .unique_id = client_unique },
        .b_content = .{ .runtime_id = target_runtime, .unique_id = target_unique },
    });
    errdefer rig.deinit();
    try rig.transfer(1);
    try rig.waitFor(.transfers_committed, 1);
    try rig.expectOn(&rig.b);
}

fn link(a: i64, b: i64) EntityLink {
    return .{ .target_a = a, .target_b = b, .type = .riding, .immediate = false, .passenger_initiated = false, .vehicle_angular_velocity = 0 };
}

fn movePlayer(buffer: []u8, runtime_id: u64, riding: u64) ![]const u8 {
    return typedPacket(buffer, .{ .move_player = .{ .player_runtime_id = runtime_id, .position = zero, .rotation = .{ .x = 0, .y = 0 }, .y_head_rotation = 0, .position_mode = .normal, .on_ground = true, .riding_runtime_id = riding, .teleport_data = null, .tick = 0 } });
}

fn animate(buffer: []u8, runtime_id: u64) ![]const u8 {
    return typedPacket(buffer, .{ .animate = .{ .action = .swing, .target_actor_runtime_id = runtime_id, .data = 0, .swing_source = null } });
}

fn emote(buffer: []u8, runtime_id: u64) ![]const u8 {
    return typedPacket(buffer, .{ .emote = .{ .actor_runtime_id = runtime_id, .emote_id = "wave", .emote_length_ticks = 20, .xuid = "", .platform_id = "", .flags = 0 } });
}

fn playerAction(buffer: []u8, runtime_id: u64) ![]const u8 {
    return typedPacket(buffer, .{ .player_action = .{ .player_runtime_id = runtime_id, .action = .startdestroyblock, .block_position = .{ .x = 0, .y = 0, .z = 0 }, .result_pos = .{ .x = 0, .y = 0, .z = 0 }, .face = 0 } });
}

fn abilities(unique_id: i64) protocol.types.AbilityData {
    return .{ .target_player_raw_id = unique_id, .player_permissions = .member, .command_permissions = .any, .layers = .empty };
}

test "server packets show the client its first ids, nested or not" {
    var rig: Rig = undefined;
    try startOnTarget(&rig);
    defer rig.deinit();

    var buffers: [11][512]u8 = undefined;
    const links = [_]EntityLink{link(target_unique, other)};
    try rig.player.relay(&.{
        try movePlayer(&buffers[0], target_runtime, other),
        try typedPacket(&buffers[1], .{ .add_actor = .{
            .target_actor_id = other,
            .target_runtime_id = other,
            .actor_type = "minecraft:horse",
            .position = zero,
            .velocity = zero,
            .rotation = .{ .x = 0, .y = 0 },
            .y_head_rotation = 0,
            .y_body_rotation = 0,
            .attributes_list = .empty,
            .actor_data = .empty,
            .synched_properties = .{ .int_entries_list = .empty, .float_entries_list = .empty },
            .actor_links = .init(&links),
        } }),
        try typedPacket(&buffers[2], .{ .set_actor_link = .{ .link = link(other, target_unique) } }),
        try typedPacket(&buffers[3], .{ .set_actor_data = .{ .target_runtime_id = target_runtime, .actor_data = .empty, .synched_properties = .{ .int_entries_list = .empty, .float_entries_list = .empty }, .tick = 0 } }),
        try animate(&buffers[4], target_runtime),
        try emote(&buffers[5], other),
        try typedPacket(&buffers[6], .{ .take_item_actor = .{ .item_runtime_id = other, .actor_runtime_id = target_runtime } }),
        // An actor on the target that happens to share the client's id
        try typedPacket(&buffers[7], .{ .mob_effect = .{ .target_runtime_id = client_runtime, .event_id = .add, .effect_id = 1, .effect_amplifier = 0, .show_particles = true, .effect_duration_ticks = 100, .tick = 0, .ambient = false } }),
        try typedPacket(&buffers[8], .{ .add_player = .{
            .uuid = @splat(1),
            .player_name = "Alex",
            .target_runtime_id = other,
            .platform_chat_id = "",
            .position = zero,
            .velocity = zero,
            .rotation = .{ .x = 0, .y = 0 },
            .y_head_rotation = 0,
            .carried_item = .{ .id = 0, .stack_size = 0, .aux_value = 0, .net_id_variant = null, .block_runtime_id = 0, .user_data_buffer = "" },
            .player_game_type = .survival,
            .entity_data = .empty,
            .synched_properties = .{ .int_entries_list = .empty, .float_entries_list = .empty },
            .abilities_data = abilities(other),
            .actor_links = .init(&links),
            .device_id = "",
            .build_platform = .unknown,
        } }),
        try typedPacket(&buffers[9], .{ .update_abilities = .{ .data = abilities(target_unique) } }),
    });

    const player = rig.player;
    const move = try player.last(.move_player);
    try std.testing.expectEqual(@as(u64, client_runtime), move.player_runtime_id);
    try std.testing.expectEqual(@as(u64, other), move.riding_runtime_id);

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const actor = try player.last(.add_actor);
    try std.testing.expectEqual(@as(u64, other), actor.target_runtime_id);
    try std.testing.expectEqual(@as(i64, other), actor.target_actor_id);
    const actor_links = try actor.actor_links.toOwnedSlice(arena.allocator());
    try std.testing.expectEqual(@as(i64, client_unique), actor_links[0].target_a);
    try std.testing.expectEqual(@as(i64, other), actor_links[0].target_b);

    const set_link = (try player.last(.set_actor_link)).link;
    try std.testing.expectEqual(@as(i64, other), set_link.target_a);
    try std.testing.expectEqual(@as(i64, client_unique), set_link.target_b);
    try std.testing.expectEqual(@as(u64, client_runtime), (try player.last(.set_actor_data)).target_runtime_id);
    try std.testing.expectEqual(@as(u64, client_runtime), (try player.last(.animate)).target_actor_runtime_id);
    try std.testing.expectEqual(@as(u64, other), (try player.last(.emote)).actor_runtime_id);

    const take = try player.last(.take_item_actor);
    try std.testing.expectEqual(@as(u64, other), take.item_runtime_id);
    try std.testing.expectEqual(@as(u64, client_runtime), take.actor_runtime_id);
    try std.testing.expectEqual(@as(u64, target_runtime), (try player.last(.mob_effect)).target_runtime_id);

    const add_player = try player.last(.add_player);
    try std.testing.expectEqual(@as(u64, other), add_player.target_runtime_id);
    try std.testing.expectEqual(@as(i64, other), add_player.abilities_data.target_player_raw_id);
    try std.testing.expectEqual(@as(i64, client_unique), (try add_player.actor_links.toOwnedSlice(arena.allocator()))[0].target_a);
    try std.testing.expectEqual(@as(i64, client_unique), (try player.last(.update_abilities)).data.target_player_raw_id);
}

test "player packets reach the backend with its own ids" {
    var rig: Rig = undefined;
    try startOnTarget(&rig);
    defer rig.deinit();
    rig.b.seen_runtime.clear();
    rig.b.seen_unique.clear();

    var buffers: [8][256]u8 = undefined;
    try rig.player.send(&.{
        try playerAction(&buffers[0], client_runtime),
        try animate(&buffers[1], client_runtime),
        try emote(&buffers[2], client_runtime),
        try movePlayer(&buffers[3], client_runtime, other),
        try typedPacket(&buffers[4], .{ .interact = .{ .action = .interactupdate, .target_runtime_id = other, .position = null } }),
        // The client's view of the target actor that shares its id
        try typedPacket(&buffers[5], .{ .interact = .{ .action = .interactupdate, .target_runtime_id = target_runtime, .position = null } }),
        try typedPacket(&buffers[6], .{ .actor_pick_request = .{ .actor_id = client_unique, .max_slots = 1, .with_data = false } }),
        try typedPacket(&buffers[7], .{ .command_request = .{ .command = "/say hi", .origin = .{ .type = "player", .uuid = @splat(0), .request_id = "", .player_id = client_unique }, .is_internal = false, .version = "latest" } }),
    });
    try rig.expectOn(&rig.b);

    try std.testing.expect(rig.b.seen_runtime.contains(target_runtime));
    try std.testing.expect(rig.b.seen_runtime.contains(other));
    try std.testing.expect(rig.b.seen_runtime.contains(client_runtime));
    try std.testing.expect(rig.b.seen_unique.contains(@bitCast(@as(i64, target_unique))));
    try std.testing.expect(!rig.b.seen_unique.contains(@bitCast(@as(i64, client_unique))));
    try std.testing.expectEqual(@as(usize, 7), rig.b.seen_runtime.len.load(.acquire));
}

test "a hundred transfers to backends with fresh ids keep the client's view stable" {
    var rig: Rig = undefined;
    try rig.start(.{ .a_content = .{ .runtime_id = client_runtime, .unique_id = client_unique } });
    defer rig.deinit();

    var buffers: [2][128]u8 = undefined;
    for (1..101) |round| {
        const target = round % 2;
        const backend = if (target == 1) &rig.b else &rig.a;
        const runtime_id: u64 = 5000 + round;
        backend.runtime_id.store(runtime_id, .release);
        backend.unique_id.store(-@as(i64, @intCast(runtime_id)), .release);
        try rig.transfer(target);
        try rig.waitFor(.transfers_committed, round);
        try rig.expectOn(backend);

        backend.seen_runtime.clear();
        try rig.player.send(&.{try playerAction(&buffers[0], client_runtime)});
        try rig.expectOn(backend);
        try std.testing.expect(backend.seen_runtime.contains(runtime_id));
        try std.testing.expect(!backend.seen_runtime.contains(client_runtime));

        try rig.player.relay(&.{try animate(&buffers[1], runtime_id)});
        try std.testing.expectEqual(@as(u64, client_runtime), (try rig.player.last(.animate)).target_actor_runtime_id);
    }
}

test "effects a later backend put on the player are cleared when they leave it" {
    var rig: Rig = undefined;
    try startOnTarget(&rig);
    defer rig.deinit();

    var buffer: [128]u8 = undefined;
    try rig.player.relay(&.{try typedPacket(&buffer, .{ .mob_effect = .{ .target_runtime_id = target_runtime, .event_id = .add, .effect_id = 3, .effect_amplifier = 0, .show_particles = true, .effect_duration_ticks = 100, .tick = 0, .ambient = false } })});
    try rig.transfer(0);
    try rig.waitFor(.transfers_committed, 2);
    try rig.expectOn(&rig.a);

    const cleared = try rig.player.last(.mob_effect);
    try std.testing.expectEqual(.remove, cleared.event_id);
    try std.testing.expectEqual(@as(i32, 3), cleared.effect_id);
    try std.testing.expectEqual(@as(u64, client_runtime), cleared.target_runtime_id);
}
