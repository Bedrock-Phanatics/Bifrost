const std = @import("std");
const bedwire = @import("bedwire");
const abi = @import("../plugin/abi.zig");
const Query = @import("../plugin/Handles.zig").Query;

const protocol = bedwire.protocol;
const packets = protocol.packets;
const Vec3f = protocol.Vec3f;
const PacketKind = bedwire.PacketKind;

const Gameplay = @This();

pub const max_entities = 1024;
const max_identifiers = 128;
const max_identifier_bytes = @typeInfo(@FieldType(abi.Entity, "identifier")).array.len;
const unknown_identifier = std.math.maxInt(u16);
const default_mode: i32 = @backingInt(protocol.types.GameType.default);

const attribute_names = [abi.AttributeKind.count][]const u8{
    "minecraft:health",
    "minecraft:absorption",
    "minecraft:player.hunger",
    "minecraft:player.saturation",
    "minecraft:player.exhaustion",
    "minecraft:movement",
    "minecraft:player.level",
    "minecraft:player.experience",
};

pub const Tracking = @import("../plugin/Plugins.zig").Tracking;

const Entity = struct {
    unique_id: i64,
    position: Vec3f,
    pitch: f32,
    yaw: f32,
    head_yaw: f32,
    identifier: u16,
};

state: abi.Gameplay = .{},
player_mode: i32 = default_mode,
world_mode: i32 = default_mode,
now_ms: u64 = 0,
entities: std.AutoHashMapUnmanaged(u64, Entity) = .empty,
entities_complete: bool = true,
identifier_bytes: std.ArrayList(u8) = .empty,
identifier_ends: std.ArrayList(u16) = .empty,

pub fn deinit(self: *Gameplay, gpa: std.mem.Allocator) void {
    self.entities.deinit(gpa);
    self.identifier_bytes.deinit(gpa);
    self.identifier_ends.deinit(gpa);
}

pub fn fromBackend(kind: ?PacketKind, tracking: Tracking) bool {
    return switch (kind orelse return false) {
        .respawn, .set_player_game_type, .update_player_game_type, .set_default_game_type, .update_attributes, .correct_player_move_prediction => tracking.player,
        .add_actor, .add_player, .add_item_actor, .add_painting, .remove_actor, .move_actor_absolute, .move_actor_delta => tracking.entities,
        .start_game, .move_player, .change_dimension => tracking.any(),
        else => false,
    };
}

pub fn fromPlayer(kind: ?PacketKind) bool {
    return kind == .player_auth_input or kind == .player_action;
}

// Packets the client was actually sent, after plugins and runtime ID translation
pub fn sent(self: *Gameplay, gpa: std.mem.Allocator, packet: protocol.BorrowedEnvelope) void {
    if (packet.value != .typed) return;
    const own = self.state.runtime_id;
    switch (packet.value.typed) {
        .start_game => |p| {
            self.state.runtime_id = p.runtime_id;
            self.state.unique_id = p.entity_id;
            self.state.dimension = p.settings.spawn_settings.dimension;
            self.player_mode = @backingInt(p.game_type);
            self.world_mode = @backingInt(p.settings.game_type);
            self.state.available |= abi.GameplayField.dimension | abi.GameplayField.game_mode | abi.GameplayField.effects;
            self.place(p.position, true);
            self.state.pitch = p.rotation.x;
            self.state.yaw = p.rotation.y;
        },
        .move_player => |p| if (p.player_runtime_id == own) {
            if (p.position_mode == .onlyheadrot) return;
            self.place(p.position, p.position_mode == .teleport or p.position_mode == .respawn);
            self.state.pitch = p.rotation.x;
            self.state.yaw = p.rotation.y;
            self.state.head_yaw = p.y_head_rotation;
        } else self.move(p.player_runtime_id, p.position, p.rotation.x, p.rotation.y, p.y_head_rotation),
        .respawn => |p| if (p.state == .readytospawn) self.place(p.position, false),
        .correct_player_move_prediction => |p| if (p.prediction_type == .player) self.place(p.pos, false),
        .change_dimension => |p| {
            self.state.dimension = p.dimension_id;
            self.place(p.position, true);
            self.clearEntities();
        },
        .set_player_game_type => |p| self.player_mode = @backingInt(p.player_game_type),
        .update_player_game_type => |p| if (p.target_player == self.state.unique_id) {
            self.player_mode = @backingInt(p.player_game_type);
        },
        .set_default_game_type => |p| self.world_mode = @backingInt(p.default_game_type),
        .update_attributes => |p| if (p.target_runtime_id == own) self.attributes(p.attribute_list),
        .add_actor => |p| self.spawn(gpa, p.target_runtime_id, p.target_actor_id, p.actor_type, p.position, p.rotation.x, p.rotation.y, p.y_head_rotation),
        .add_player => |p| self.spawn(gpa, p.target_runtime_id, p.abilities_data.target_player_raw_id, "minecraft:player", p.position, p.rotation.x, p.rotation.y, p.y_head_rotation),
        .add_item_actor => |p| self.spawn(gpa, p.target_runtime_id, p.target_actor_id, "minecraft:item", p.position, 0, 0, 0),
        .add_painting => |p| self.spawn(gpa, p.target_runtime_id, p.target_actor_id, "minecraft:painting", p.position, 0, 0, 0),
        .remove_actor => |p| {
            var it = self.entities.iterator();
            while (it.next()) |entry| if (entry.value_ptr.unique_id == p.target_actor_id) {
                self.entities.removeByPtr(entry.key_ptr);
                return;
            };
        },
        .move_actor_absolute => |p| {
            const data = p.move_data;
            self.move(data.actor_runtime_id, data.position, angle(data.rotation_x), angle(data.rotation_y), angle(data.rotation_y_head));
        },
        .move_actor_delta => |p| {
            const data = p.move_data;
            const entity = self.entities.getPtr(data.actor_runtime_id) orelse return;
            if (data.new_position_x) |x| entity.position.x = x;
            if (data.new_position_y) |y| entity.position.y = y;
            if (data.new_position_z) |z| entity.position.z = z;
            if (data.rotation_x) |x| entity.pitch = angle(@bitCast(x));
            if (data.rotation_y) |y| entity.yaw = angle(@bitCast(y));
            if (data.rotation_y_head) |head| entity.head_yaw = angle(@bitCast(head));
        },
        else => {},
    }
}

// What the player reported; the backend may still reject it
pub fn reported(self: *Gameplay, packet: protocol.BorrowedEnvelope) void {
    if (packet.value != .typed) return;
    switch (packet.value.typed) {
        .player_action => |p| if (p.action == .changedimensionack) {
            self.state.teleport_pending = 0;
        },
        .player_auth_input => |p| {
            var movement = self.state.movement & (abi.Movement.swimming | abi.Movement.gliding | abi.Movement.crawling | abi.Movement.flying);
            var handled = false;
            var inputs = p.input_data.iterator();
            while (inputs.next() catch null) |input| switch (input) {
                .sneaking => movement |= abi.Movement.sneaking,
                .sprinting => movement |= abi.Movement.sprinting,
                .jumping => movement |= abi.Movement.jumping,
                .isinclientpredictedvehicle => movement |= abi.Movement.in_vehicle,
                .startswimming => movement |= abi.Movement.swimming,
                .stopswimming => movement &= ~abi.Movement.swimming,
                .startgliding => movement |= abi.Movement.gliding,
                .stopgliding => movement &= ~abi.Movement.gliding,
                .startcrawling => movement |= abi.Movement.crawling,
                .stopcrawling => movement &= ~abi.Movement.crawling,
                .startflying => movement |= abi.Movement.flying,
                .stopflying => movement &= ~abi.Movement.flying,
                .handledteleport => handled = true,
                else => {},
            };
            self.state.movement = movement;
            self.state.available |= abi.GameplayField.movement | abi.GameplayField.velocity;
            self.state.velocity = vec(p.pos_delta);
            if (handled) self.state.teleport_pending = 0;
            if (self.state.teleport_pending != 0) return;
            self.state.position = vec(p.position);
            self.state.pitch = p.player_rotation.x;
            self.state.yaw = p.player_rotation.y;
            self.state.head_yaw = p.player_head_rotation;
            self.state.position_source = .client;
            self.state.position_at_ms = self.now_ms;
            self.state.available |= abi.GameplayField.position;
        },
        else => {},
    }
}

// The client is moving to another backend's world, so nothing seen so far still holds
pub fn transferred(self: *Gameplay, now_ms: u64, dimension: i32, position: Vec3f, player_mode: i32, world_mode: i32) void {
    self.now_ms = now_ms;
    self.state.dimension = dimension;
    self.player_mode = player_mode;
    self.world_mode = world_mode;
    self.place(position, true);
    self.state.velocity = .{};
    self.state.available &= ~(abi.GameplayField.velocity | abi.GameplayField.attributes);
    self.state.attributes_available = 0;
    self.clearEntities();
    self.identifier_bytes.clearRetainingCapacity();
    self.identifier_ends.clearRetainingCapacity();
}

pub fn synced(self: *Gameplay) void {
    self.state.teleport_pending = 0;
}

pub fn gameMode(player_mode: i32, world_mode: i32) ?i32 {
    const mode = if (player_mode == default_mode) world_mode else player_mode;
    return if (mode < 0 or mode == default_mode) null else mode;
}

pub fn answer(self: *const Gameplay, query: Query, now_ms: u64, effects: anytype) abi.Status {
    switch (query) {
        .player => |out| {
            out.* = self.state;
            out.struct_size = @sizeOf(abi.Gameplay);
            out.sampled_at_ms = now_ms;
            if (gameMode(self.player_mode, self.world_mode)) |mode| out.game_mode = mode else out.available &= ~abi.GameplayField.game_mode;
            var it = effects.iterator(.{});
            while (it.next()) |effect| out.effects[effect / 64] |= @as(u64, 1) << @intCast(effect % 64);
        },
        .entity => |lookup| {
            const found = self.entities.get(lookup.runtime_id) orelse return .not_found;
            lookup.out.* = self.describe(lookup.runtime_id, found);
        },
        .entities => |list| {
            var it = self.entities.iterator();
            var written: usize = 0;
            while (written < list.out.len) : (written += 1) {
                const entry = it.next() orelse break;
                list.out[written] = self.describe(entry.key_ptr.*, entry.value_ptr.*);
            }
            list.total.* = self.entities.count();
            if (list.complete) |complete| complete.* = @intFromBool(self.entities_complete);
        },
    }
    return .ok;
}

fn describe(self: *const Gameplay, runtime_id: u64, found: Entity) abi.Entity {
    var out: abi.Entity = .{
        .runtime_id = runtime_id,
        .unique_id = found.unique_id,
        .position = vec(found.position),
        .pitch = found.pitch,
        .yaw = found.yaw,
        .head_yaw = found.head_yaw,
    };
    if (found.identifier != unknown_identifier) {
        const start = if (found.identifier == 0) 0 else self.identifier_ends.items[found.identifier - 1];
        const name = self.identifier_bytes.items[start..self.identifier_ends.items[found.identifier]];
        @memcpy(out.identifier[0..name.len], name);
        out.identifier_len = @intCast(name.len);
    }
    return out;
}

fn place(self: *Gameplay, position: Vec3f, teleport: bool) void {
    self.state.position = vec(position);
    self.state.position_source = .backend;
    self.state.position_at_ms = self.now_ms;
    self.state.available |= abi.GameplayField.position;
    if (teleport) self.state.teleport_pending = 1;
}

fn attributes(self: *Gameplay, list: anytype) void {
    var it = list.iterator();
    while (it.next() catch return) |attribute| {
        for (attribute_names, 0..) |name, i| if (std.mem.eql(u8, name, attribute.name)) {
            self.state.attributes[i] = .{ .min = attribute.min_value, .max = attribute.max_value, .current = attribute.current_value };
            self.state.attributes_available |= @as(u32, 1) << @intCast(i);
            self.state.available |= abi.GameplayField.attributes;
            break;
        };
    }
}

fn spawn(self: *Gameplay, gpa: std.mem.Allocator, runtime_id: u64, unique_id: i64, identifier: []const u8, position: Vec3f, pitch: f32, yaw: f32, head_yaw: f32) void {
    if (runtime_id == self.state.runtime_id) return;
    if (self.entities.count() >= max_entities and !self.entities.contains(runtime_id)) {
        self.entities_complete = false;
        return;
    }
    self.entities.put(gpa, runtime_id, .{
        .unique_id = unique_id,
        .position = position,
        .pitch = pitch,
        .yaw = yaw,
        .head_yaw = head_yaw,
        .identifier = self.intern(gpa, identifier),
    }) catch {
        self.entities_complete = false;
    };
}

fn move(self: *Gameplay, runtime_id: u64, position: Vec3f, pitch: f32, yaw: f32, head_yaw: f32) void {
    const found = self.entities.getPtr(runtime_id) orelse return;
    found.position = position;
    found.pitch = pitch;
    found.yaw = yaw;
    found.head_yaw = head_yaw;
}

fn clearEntities(self: *Gameplay) void {
    self.entities.clearRetainingCapacity();
    self.entities_complete = true;
}

fn intern(self: *Gameplay, gpa: std.mem.Allocator, name: []const u8) u16 {
    if (name.len == 0 or name.len > max_identifier_bytes) return unknown_identifier;
    var start: usize = 0;
    for (self.identifier_ends.items, 0..) |end, i| {
        if (std.mem.eql(u8, self.identifier_bytes.items[start..end], name)) return @intCast(i);
        start = end;
    }
    if (self.identifier_ends.items.len == max_identifiers) return unknown_identifier;
    self.identifier_ends.ensureUnusedCapacity(gpa, 1) catch return unknown_identifier;
    self.identifier_bytes.appendSlice(gpa, name) catch return unknown_identifier;
    self.identifier_ends.appendAssumeCapacity(@intCast(self.identifier_bytes.items.len));
    return @intCast(self.identifier_ends.items.len - 1);
}

fn angle(byte: u8) f32 {
    return @as(f32, @floatFromInt(byte)) * (360.0 / 256.0);
}

fn vec(v: Vec3f) abi.Vec3 {
    return .{ .x = v.x, .y = v.y, .z = v.z };
}

const testing = std.testing;
const Input = packets.player_auth_input.PlayerAuthInputInputData;
const no_effects = std.StaticBitSet(256).empty;

fn envelope(value: protocol.typed.Packet) protocol.BorrowedEnvelope {
    return .{ .header = .{ .packet_id = 0 }, .kind = null, .payload = &.{}, .value = .{ .typed = value } };
}

fn backend(state: *Gameplay, value: protocol.typed.Packet) void {
    state.sent(testing.allocator, envelope(value));
}

fn report(state: *Gameplay, position: Vec3f, flags: []const Input) void {
    state.reported(envelope(.{ .player_auth_input = .{
        .player_rotation = .{ .x = 10, .y = 20 },
        .position = position,
        .move_vector = .{ .x = 0, .y = 0 },
        .player_head_rotation = 30,
        .input_data = .init(flags),
        .input_mode = .mouse,
        .play_mode = .normal,
        .new_interaction_model = .crosshair,
        .interact_rotation = .{ .x = 0, .y = 0 },
        .client_tick = 1,
        .pos_delta = .{ .x = 0.25, .y = 0, .z = 0 },
        .item_use_transaction = null,
        .item_stack_request = null,
        .player_block_actions = null,
        .vehicle_rotation = null,
        .client_predicted_vehicle = null,
        .analog_move_vector = .{ .x = 0, .y = 0 },
        .camera_orientation = .{ .x = 0, .y = 0, .z = 0 },
        .raw_move_vector = .{ .x = 0, .y = 0 },
    } }));
}

fn painting(runtime_id: u64, unique_id: i64) protocol.typed.Packet {
    return .{ .add_painting = .{ .target_actor_id = unique_id, .target_runtime_id = runtime_id, .position = .{ .x = 1, .y = 2, .z = 3 }, .direction = 0, .motif = "Kebab" } };
}

fn snapshot(state: *const Gameplay) abi.Gameplay {
    var out: abi.Gameplay = undefined;
    std.debug.assert(state.answer(.{ .player = &out }, 99, no_effects) == .ok);
    return out;
}

fn find(state: *const Gameplay, runtime_id: u64, out: *abi.Entity) abi.Status {
    return state.answer(.{ .entity = .{ .runtime_id = runtime_id, .out = out } }, 0, no_effects);
}

// The start_game from protocol-zig's corpus that the integration tests also use
const start_game_hex = "0bffffffffffffffffff01ffffffffffffffffff010a09fe2f49712131c9f7d74f49eb3107c8fcb2e0c7ffffffffffffffff010000d392fba6010c02010afeffffff0fc4db9aaa09feffffff0f00020000feffffff0f020103343732a1df5cc969754fc801000102080101000200000000010668c3a96c6c6f0001000003ae80974c010000010101010000000130000000809abf562600126d696e6563726166743a73746f6e6531313705537465766501010000060008537465766533393909e697a5e69cace8aa9e0339373800bc90f98201010000000000000000ffffffff0f0301300a000105782079207a200005782079207a0a000107f09f9982206f6bac0001300a00000968c3a96c6c6f3338380109e697a5e69cace8aa9e0a0000b1514ca91695eb8a6f96a16dfc9c80dd5b802003d0fe7379010100000668c3a96c6c6f05782079207a0ce697a5e69cace8aa9e32343100";

fn joined(state: *Gameplay) !void {
    const source = comptime blk: {
        @setEvalBranchQuota(10_000);
        var bytes: [start_game_hex.len / 2]u8 = undefined;
        _ = std.fmt.hexToBytes(&bytes, start_game_hex) catch unreachable;
        break :blk bytes;
    };
    var start = (try protocol.Current.decodeBorrowed(&source, .{})).value.typed.start_game;
    start.runtime_id = 7;
    start.entity_id = -7;
    start.game_type = .default;
    start.settings.game_type = .adventure;
    start.settings.spawn_settings.dimension = 0;
    start.position = .{ .x = 1, .y = 2, .z = 3 };
    backend(state, .{ .start_game = start });
}

test "only tracked kinds are decoded" {
    try testing.expect(!fromBackend(.move_actor_delta, .{}));
    try testing.expect(!fromBackend(.move_player, .{}));
    try testing.expect(!fromPlayer(.text));
    try testing.expect(!fromBackend(.update_attributes, .{ .entities = true }));
    try testing.expect(fromBackend(.move_actor_delta, .{ .entities = true }));
    try testing.expect(!fromBackend(.move_actor_delta, .{ .player = true }));
    try testing.expect(fromBackend(.update_attributes, .{ .player = true }));
    try testing.expect(fromPlayer(.player_auth_input));
    try testing.expect(!fromBackend(.text, .{ .player = true, .entities = true }));
    try testing.expect(!fromBackend(null, .{ .player = true, .entities = true }));
}

test "nothing is claimed before the player joins" {
    var state: Gameplay = .{};
    defer state.deinit(testing.allocator);
    const out = snapshot(&state);
    try testing.expectEqual(@as(u64, 0), out.available);
    try testing.expectEqual(abi.PositionSource.none, out.position_source);
    try testing.expectEqual(@as(u64, 99), out.sampled_at_ms);
}

test "positions follow the backend, then the client once a teleport is handled" {
    var state: Gameplay = .{};
    defer state.deinit(testing.allocator);
    state.now_ms = 5;
    try joined(&state);
    var out = snapshot(&state);
    try testing.expectEqual(abi.PositionSource.backend, out.position_source);
    try testing.expectEqual(@as(f32, 2), out.position.y);
    try testing.expectEqual(@as(u32, 1), out.teleport_pending);
    try testing.expectEqual(@as(u64, 7), out.runtime_id);
    try testing.expectEqual(@as(i32, 2), out.game_mode);
    try testing.expectEqual(@as(u64, 0), out.available & abi.GameplayField.velocity);

    state.now_ms = 6;
    report(&state, .{ .x = 50, .y = 60, .z = 70 }, &.{});
    out = snapshot(&state);
    try testing.expectEqual(@as(f32, 2), out.position.y);
    try testing.expectEqual(@as(f32, 0.25), out.velocity.x);
    report(&state, .{ .x = 1.5, .y = 2, .z = 3 }, &.{.handledteleport});
    out = snapshot(&state);
    try testing.expectEqual(abi.PositionSource.client, out.position_source);
    try testing.expectEqual(@as(f32, 1.5), out.position.x);
    try testing.expectEqual(@as(f32, 20), out.yaw);
    try testing.expectEqual(@as(f32, 30), out.head_yaw);
    try testing.expectEqual(@as(u64, 6), out.position_at_ms);
    try testing.expectEqual(@as(u32, 0), out.teleport_pending);

    backend(&state, .{ .move_player = .{ .player_runtime_id = 7, .position = .{ .x = 9, .y = 9, .z = 9 }, .rotation = .{ .x = 1, .y = 2 }, .y_head_rotation = 3, .position_mode = .teleport, .on_ground = true, .riding_runtime_id = 0, .teleport_data = null, .tick = 0 } });
    out = snapshot(&state);
    try testing.expectEqual(abi.PositionSource.backend, out.position_source);
    try testing.expectEqual(@as(u32, 1), out.teleport_pending);
    backend(&state, .{ .move_player = .{ .player_runtime_id = 7, .position = .{ .x = 0, .y = 0, .z = 0 }, .rotation = .{ .x = 0, .y = 0 }, .y_head_rotation = 0, .position_mode = .onlyheadrot, .on_ground = true, .riding_runtime_id = 0, .teleport_data = null, .tick = 0 } });
    try testing.expectEqual(@as(f32, 9), snapshot(&state).position.x);
    backend(&state, .{ .correct_player_move_prediction = .{ .prediction_type = .vehicle, .pos = .{ .x = 4, .y = 4, .z = 4 }, .pos_delta = .{ .x = 0, .y = 0, .z = 0 }, .rotation = .{ .x = 0, .y = 0 }, .vehicle_angular_velocity = null, .on_ground = true, .tick = 0 } });
    try testing.expectEqual(@as(f32, 9), snapshot(&state).position.x);
}

test "dimension changes hold client positions until acknowledged and drop entities" {
    var state: Gameplay = .{};
    defer state.deinit(testing.allocator);
    try joined(&state);
    report(&state, .{ .x = 0, .y = 0, .z = 0 }, &.{.handledteleport});
    backend(&state, painting(3, 3));
    backend(&state, .{ .change_dimension = .{ .dimension_id = 1, .position = .{ .x = 8, .y = 70, .z = 8 }, .respawn = false, .loading_screen_id = null } });
    report(&state, .{ .x = 100, .y = 0, .z = 0 }, &.{});
    var out = snapshot(&state);
    try testing.expectEqual(@as(i32, 1), out.dimension);
    try testing.expectEqual(@as(f32, 8), out.position.x);
    try testing.expectEqual(@as(usize, 0), state.entities.count());
    state.reported(envelope(.{ .player_action = .{ .player_runtime_id = 7, .action = .changedimensionack, .block_position = .{ .x = 0, .y = 0, .z = 0 }, .result_pos = .{ .x = 0, .y = 0, .z = 0 }, .face = 0 } }));
    report(&state, .{ .x = 9, .y = 70, .z = 8 }, &.{});
    out = snapshot(&state);
    try testing.expectEqual(@as(f32, 9), out.position.x);
    try testing.expectEqual(abi.PositionSource.client, out.position_source);
}

test "game mode, attributes, effects and movement are the client's latest view" {
    var state: Gameplay = .{};
    defer state.deinit(testing.allocator);
    try joined(&state);
    backend(&state, .{ .set_default_game_type = .{ .default_game_type = .creative } });
    try testing.expectEqual(@as(i32, 1), snapshot(&state).game_mode);
    backend(&state, .{ .update_player_game_type = .{ .player_game_type = .spectator, .target_player = -8, .tick = 0 } });
    try testing.expectEqual(@as(i32, 1), snapshot(&state).game_mode);
    backend(&state, .{ .update_player_game_type = .{ .player_game_type = .spectator, .target_player = -7, .tick = 0 } });
    try testing.expectEqual(@as(i32, 6), snapshot(&state).game_mode);
    backend(&state, .{ .set_player_game_type = .{ .player_game_type = .survival } });
    try testing.expectEqual(@as(i32, 0), snapshot(&state).game_mode);

    const list = [_]packets.update_attributes.AttributeData{
        .{ .min_value = 0, .max_value = 20, .current_value = 13, .default_min_value = 0, .default_max_value = 20, .default_value = 20, .name = "minecraft:health", .modifiers = .empty },
        .{ .min_value = 0, .max_value = 1, .current_value = 0.1, .default_min_value = 0, .default_max_value = 1, .default_value = 0.1, .name = "minecraft:movement", .modifiers = .empty },
        .{ .min_value = 0, .max_value = 1, .current_value = 1, .default_min_value = 0, .default_max_value = 1, .default_value = 1, .name = "custom:mana", .modifiers = .empty },
    };
    backend(&state, .{ .update_attributes = .{ .target_runtime_id = 8, .attribute_list = .init(&list), .tick = 0 } });
    try testing.expectEqual(@as(u32, 0), snapshot(&state).attributes_available);
    backend(&state, .{ .update_attributes = .{ .target_runtime_id = 7, .attribute_list = .init(&list), .tick = 0 } });
    var out = snapshot(&state);
    const health = @backingInt(abi.AttributeKind.health);
    try testing.expectEqual(@as(u32, 1) << health | @as(u32, 1) << @backingInt(abi.AttributeKind.movement), out.attributes_available);
    try testing.expectEqual(@as(f32, 13), out.attributes[health].current);
    try testing.expectEqual(@as(f32, 20), out.attributes[health].max);

    var effects = no_effects;
    effects.set(1);
    effects.set(70);
    _ = state.answer(.{ .player = &out }, 0, effects);
    try testing.expectEqual(@as(u64, 1 << 1), out.effects[0]);
    try testing.expectEqual(@as(u64, 1 << 6), out.effects[1]);

    report(&state, .{ .x = 0, .y = 0, .z = 0 }, &.{ .sneaking, .startgliding, .startflying });
    try testing.expectEqual(abi.Movement.sneaking | abi.Movement.gliding | abi.Movement.flying, snapshot(&state).movement);
    report(&state, .{ .x = 0, .y = 0, .z = 0 }, &.{ .sprinting, .stopgliding });
    try testing.expectEqual(abi.Movement.sprinting | abi.Movement.flying, snapshot(&state).movement);
}

test "entities follow spawns, moves and removals and stop at their bound" {
    var state: Gameplay = .{};
    defer state.deinit(testing.allocator);
    try joined(&state);
    backend(&state, painting(7, -7));
    try testing.expectEqual(@as(usize, 0), state.entities.count());
    backend(&state, painting(30, -30));
    backend(&state, .{ .move_actor_absolute = .{ .move_data = .{ .actor_runtime_id = 30, .header = 0, .position = .{ .x = 5, .y = 6, .z = 7 }, .rotation_x = 64, .rotation_y = 128, .rotation_y_head = 0 } } });
    backend(&state, .{ .move_actor_delta = .{ .move_data = .{ .actor_runtime_id = 30, .new_position_x = null, .new_position_y = 10, .new_position_z = null, .rotation_x = null, .rotation_y = -64, .rotation_y_head = null, .is_on_ground = true, .force_move = false, .force_move_local_entity = false, .force_completion = false, .ticks = 0 } } });
    backend(&state, .{ .move_actor_delta = .{ .move_data = .{ .actor_runtime_id = 31, .new_position_x = 1, .new_position_y = null, .new_position_z = null, .rotation_x = null, .rotation_y = null, .rotation_y_head = null, .is_on_ground = true, .force_move = false, .force_move_local_entity = false, .force_completion = false, .ticks = 0 } } });

    var found: abi.Entity = undefined;
    try testing.expectEqual(abi.Status.ok, find(&state, 30, &found));
    try testing.expectEqual(@as(i64, -30), found.unique_id);
    try testing.expectEqual(abi.Vec3{ .x = 5, .y = 10, .z = 7 }, found.position);
    try testing.expectEqual(@as(f32, 90), found.pitch);
    try testing.expectEqual(@as(f32, 270), found.yaw);
    try testing.expectEqualStrings("minecraft:painting", found.identifier[0..found.identifier_len]);
    try testing.expectEqual(abi.Status.not_found, find(&state, 31, &found));

    const long: [max_identifier_bytes + 1]u8 = @splat('a');
    backend(&state, .{ .add_actor = .{ .target_actor_id = -31, .target_runtime_id = 31, .actor_type = &long, .position = .{ .x = 0, .y = 0, .z = 0 }, .velocity = .{ .x = 0, .y = 0, .z = 0 }, .rotation = .{ .x = 0, .y = 0 }, .y_head_rotation = 0, .y_body_rotation = 0, .attributes_list = .empty, .actor_data = .empty, .synched_properties = .{ .int_entries_list = .empty, .float_entries_list = .empty }, .actor_links = .empty } });
    try testing.expectEqual(abi.Status.ok, find(&state, 31, &found));
    try testing.expectEqual(@as(u32, 0), found.identifier_len);

    backend(&state, .{ .remove_actor = .{ .target_actor_id = -30 } });
    try testing.expectEqual(abi.Status.not_found, find(&state, 30, &found));

    for (0..max_entities + 10) |i| backend(&state, painting(i + 100, @intCast(i + 100)));
    try testing.expectEqual(@as(usize, max_entities), state.entities.count());
    try testing.expectEqual(@as(usize, 1), state.identifier_ends.items.len);
    var some: [4]abi.Entity = undefined;
    var total: usize = 0;
    var complete: u32 = 1;
    try testing.expectEqual(abi.Status.ok, state.answer(.{ .entities = .{ .out = &some, .total = &total, .complete = &complete } }, 0, no_effects));
    try testing.expectEqual(@as(usize, max_entities), total);
    try testing.expectEqual(@as(u32, 0), complete);
    try testing.expect(some[3].runtime_id != 0);

    state.transferred(40, 2, .{ .x = 0, .y = 64, .z = 0 }, 1, 0);
    try testing.expectEqual(abi.Status.ok, state.answer(.{ .entities = .{ .out = &.{}, .total = &total, .complete = &complete } }, 0, no_effects));
    try testing.expectEqual(@as(usize, 0), total);
    try testing.expectEqual(@as(u32, 1), complete);
    const out = snapshot(&state);
    try testing.expectEqual(@as(i32, 2), out.dimension);
    try testing.expectEqual(@as(i32, 1), out.game_mode);
    try testing.expectEqual(@as(u64, 40), out.position_at_ms);
    try testing.expectEqual(@as(u32, 1), out.teleport_pending);
    try testing.expectEqual(@as(u64, 0), out.available & (abi.GameplayField.attributes | abi.GameplayField.velocity));
    state.synced();
    try testing.expectEqual(@as(u32, 0), snapshot(&state).teleport_pending);
}

test "spawn storage failures leave the entity list marked incomplete" {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    var state: Gameplay = .{};
    defer state.deinit(failing.allocator());
    state.sent(failing.allocator(), envelope(painting(3, 3)));
    try testing.expect(!state.entities_complete);
    try testing.expectEqual(@as(usize, 0), state.entities.count());
}

test "the output layouts are the documented sizes" {
    try testing.expectEqual(232, @sizeOf(abi.Gameplay));
    try testing.expectEqual(112, @sizeOf(abi.Entity));
}

test "the game mode sent on transfer is always concrete" {
    try testing.expectEqual(@as(?i32, 1), gameMode(1, 0));
    try testing.expectEqual(@as(?i32, 2), gameMode(default_mode, 2));
    try testing.expectEqual(@as(?i32, null), gameMode(default_mode, default_mode));
    try testing.expectEqual(@as(?i32, null), gameMode(-1, 0));
}
