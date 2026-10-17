const std = @import("std");
const bedwire = @import("bedwire");
const bifrost = @import("bifrost");
const managed = @import("../support/managed.zig");
const sample = @import("../support/sample.zig");
const Rig = @import("../support/rig.zig").Rig;

const abi = bifrost.plugin_abi;
const protocol = bedwire.protocol;
const io = std.testing.io;
const gpa = std.testing.allocator;

const Tracker = struct {
    var api: *const abi.Host = undefined;
    var blind: *const abi.Host = undefined;
    var player: std.atomic.Value(u64) = .init(0);
    var status: std.atomic.Value(i32) = .init(-100);
    var blind_status: abi.Status = .ok;
    var state: abi.Gameplay = .{};
    var entities: [8]abi.Entity = undefined;
    var total: usize = 0;
    var complete: u32 = 0;
    var found: abi.Entity = .{};
    var found_status: abi.Status = .ok;
    var lookup: u64 = 0;

    fn init(host: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
        api = host;
        plugin.name = .of("tracker");
        plugin.plugin_version = .of("1");
        plugin.capabilities = .{ .events = true, .gameplay = true, .entities = true };
        return host.subscribe(host.context, .player_connected, connected, null);
    }

    fn initBlind(host: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
        blind = host;
        plugin.name = .of("blind");
        plugin.plugin_version = .of("1");
        plugin.capabilities = .{ .events = true };
        return .ok;
    }

    fn connected(_: ?*anyopaque, event: *const abi.Event, _: ?*abi.TransferDecision) callconv(.c) void {
        player.store(event.player.id, .release);
    }

    fn done(_: ?*anyopaque, result: *const abi.TaskResult) callconv(.c) void {
        var out = result.status;
        if (out == .ok) out = api.player_gameplay(api.context, result.player, &state, @sizeOf(abi.Gameplay));
        if (out == .ok) out = api.list_entities(api.context, result.player, &entities, entities.len, &total, &complete);
        found_status = api.find_entity(api.context, result.player, lookup, &found, @sizeOf(abi.Entity));
        var ignored: abi.Gameplay = undefined;
        blind_status = blind.player_gameplay(blind.context, result.player, &ignored, @sizeOf(abi.Gameplay));
        status.store(@backingInt(out), .release);
    }

    fn query(id: u64) !void {
        lookup = id;
        status.store(-100, .release);
        try std.testing.expectEqual(abi.Status.ok, api.post(api.context, handle(), done, null));
        for (0..500) |_| {
            if (status.load(.acquire) != -100) break;
            try io.sleep(.fromMilliseconds(10), .awake);
        }
        try std.testing.expectEqual(@as(i32, 0), status.load(.acquire));
        try std.testing.expectEqual(abi.Status.unsupported, blind_status);
    }

    fn handle() abi.Player {
        return .{ .id = player.load(.acquire) };
    }
};

fn authInput(buffer: []u8, position: protocol.Vec3f, flags: []const protocol.packets.player_auth_input.PlayerAuthInputInputData) ![]const u8 {
    return sample.typedPacket(buffer, .{ .player_auth_input = .{
        .player_rotation = .{ .x = 5, .y = 90 },
        .position = position,
        .move_vector = .{ .x = 0, .y = 1 },
        .player_head_rotation = 90,
        .input_data = .init(flags),
        .input_mode = .mouse,
        .play_mode = .normal,
        .new_interaction_model = .crosshair,
        .interact_rotation = .{ .x = 0, .y = 0 },
        .client_tick = 1,
        .pos_delta = .{ .x = 0.2, .y = 0, .z = 0 },
        .item_use_transaction = null,
        .item_stack_request = null,
        .player_block_actions = null,
        .vehicle_rotation = null,
        .client_predicted_vehicle = null,
        .analog_move_vector = .{ .x = 0, .y = 0 },
        .camera_orientation = .{ .x = 0, .y = 0, .z = 0 },
        .raw_move_vector = .{ .x = 0, .y = 1 },
    } });
}

fn health(buffer: []u8, runtime_id: u64, current: f32) ![]const u8 {
    const list = [_]protocol.packets.update_attributes.AttributeData{.{ .min_value = 0, .max_value = 20, .current_value = current, .default_min_value = 0, .default_max_value = 20, .default_value = 20, .name = "minecraft:health", .modifiers = .empty }};
    return sample.typedPacket(buffer, .{ .update_attributes = .{ .target_runtime_id = runtime_id, .attribute_list = .init(&list), .tick = 0 } });
}

test "gameplay and entity tracking follow the client across moves, spawns and a transfer" {
    var plugins: bifrost.Plugins = try .init(gpa, &.{}, .{});
    defer plugins.deinit();
    try plugins.add(Tracker.init, null);
    try plugins.add(Tracker.initBlind, null);
    var rig: Rig = undefined;
    try rig.start(.{ .plugins = &plugins, .b_content = .{ .dimension = 1, .position = .{ .x = 100, .y = 70, .z = -5 } } });
    defer rig.deinit();
    plugins.backends = rig.running.proxy.config.backends();
    const own = sample.runtimeId();

    var state: abi.Gameplay = undefined;
    try std.testing.expectEqual(abi.Status.wrong_thread, Tracker.api.player_gameplay(Tracker.api.context, Tracker.handle(), &state, @sizeOf(abi.Gameplay)));
    try Tracker.query(0);
    try std.testing.expectEqual(own, Tracker.state.runtime_id);
    try std.testing.expectEqual(abi.PositionSource.backend, Tracker.state.position_source);
    try std.testing.expect(Tracker.state.available & abi.GameplayField.game_mode != 0);
    try std.testing.expectEqual(@as(u32, 1), Tracker.state.teleport_pending);
    try std.testing.expectEqual(abi.Status.not_found, Tracker.found_status);

    var buffers: [4][256]u8 = undefined;
    try rig.player.send(&.{try authInput(&buffers[0], .{ .x = 3, .y = 65, .z = 4 }, &.{ .handledteleport, .sprinting })});
    try rig.expectOn(&rig.a);
    try Tracker.query(0);
    try std.testing.expectEqual(abi.PositionSource.client, Tracker.state.position_source);
    try std.testing.expectEqual(abi.Vec3{ .x = 3, .y = 65, .z = 4 }, Tracker.state.position);
    try std.testing.expectEqual(@as(f32, 90), Tracker.state.yaw);
    try std.testing.expectEqual(abi.Movement.sprinting, Tracker.state.movement);
    try std.testing.expect(Tracker.state.position_at_ms <= Tracker.state.sampled_at_ms);

    try rig.player.relay(&.{
        try sample.typedPacket(&buffers[0], .{ .add_painting = .{ .target_actor_id = 500, .target_runtime_id = 500, .position = .{ .x = 1, .y = 2, .z = 3 }, .direction = 0, .motif = "Kebab" } }),
        try sample.typedPacket(&buffers[1], .{ .move_actor_absolute = .{ .move_data = .{ .actor_runtime_id = 500, .header = 0, .position = .{ .x = 7, .y = 8, .z = 9 }, .rotation_x = 0, .rotation_y = 64, .rotation_y_head = 0 } } }),
        try health(&buffers[2], own, 11),
        try sample.typedPacket(&buffers[3], .{ .set_player_game_type = .{ .player_game_type = .creative } }),
    });
    try Tracker.query(500);
    try std.testing.expectEqual(@as(usize, 1), Tracker.total);
    try std.testing.expectEqual(@as(u32, 1), Tracker.complete);
    try std.testing.expectEqual(abi.Status.ok, Tracker.found_status);
    try std.testing.expectEqual(abi.Vec3{ .x = 7, .y = 8, .z = 9 }, Tracker.found.position);
    try std.testing.expectEqual(@as(f32, 90), Tracker.found.yaw);
    try std.testing.expectEqualStrings("minecraft:painting", Tracker.found.identifier[0..Tracker.found.identifier_len]);
    try std.testing.expectEqual(@as(f32, 11), Tracker.state.attributes[@backingInt(abi.AttributeKind.health)].current);
    try std.testing.expectEqual(@as(i32, 1), Tracker.state.game_mode);

    // The target hands out its own runtime id, which the client must never see
    const target_id: u64 = if (own == 4242) 4243 else 4242;
    rig.b.runtime_id.store(target_id, .release);
    try rig.transfer(1);
    try rig.waitFor(.transfers_committed, 1);
    try rig.expectOn(&rig.b);
    try std.testing.expect(rig.player.received(.set_player_game_type) >= 1);
    try Tracker.query(500);
    try std.testing.expectEqual(own, Tracker.state.runtime_id);
    try std.testing.expectEqual(@as(usize, 0), Tracker.total);
    try std.testing.expectEqual(abi.Status.not_found, Tracker.found_status);
    try std.testing.expectEqual(@as(i32, 1), Tracker.state.dimension);
    try std.testing.expectEqual(abi.Vec3{ .x = 100, .y = 70, .z = -5 }, Tracker.state.position);
    try std.testing.expectEqual(@as(u32, 0), Tracker.state.teleport_pending);
    try std.testing.expectEqual(@as(u64, 0), Tracker.state.available & abi.GameplayField.attributes);

    try rig.player.relay(&.{
        try health(&buffers[0], target_id, 6),
        try sample.typedPacket(&buffers[1], .{ .mob_effect = .{ .target_runtime_id = target_id, .event_id = .add, .effect_id = 3, .effect_amplifier = 0, .show_particles = false, .effect_duration_ticks = 100, .tick = 0, .ambient = false } }),
    });
    try Tracker.query(0);
    try std.testing.expectEqual(@as(f32, 6), Tracker.state.attributes[@backingInt(abi.AttributeKind.health)].current);
    try std.testing.expectEqual(@as(u64, 1 << 3), Tracker.state.effects[0]);

    const player = Tracker.handle();
    rig.player.destroy();
    rig.player = try managed.Player.connect(io, rig.running.address(), 3);
    for (0..500) |_| {
        if (plugins.handles.route(player) == null) break;
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    try std.testing.expectEqual(abi.Status.stale_handle, Tracker.api.player_gameplay(Tracker.api.context, player, &state, @sizeOf(abi.Gameplay)));
    try std.testing.expectEqual(abi.Status.stale_handle, Tracker.api.post(Tracker.api.context, player, Tracker.done, null));
}

test "tracking only runs when a loaded plugin declares it" {
    var plugins: bifrost.Plugins = try .init(gpa, &.{}, .{});
    defer plugins.deinit();
    try plugins.add(Tracker.initBlind, null);
    try std.testing.expect(!plugins.tracking.any());
    plugins.deinit();
    plugins = try .init(gpa, &.{}, .{});
    try plugins.add(Tracker.init, null);
    try std.testing.expect(plugins.tracking.player and plugins.tracking.entities);
}
