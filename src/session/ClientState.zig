const std = @import("std");
const bedwire = @import("bedwire");

const protocol = bedwire.protocol;
const packets = protocol.packets;
const Current = protocol.Current;

const ClientState = @This();

const max_entities = 4096;
const max_players = 1024;
const max_bosses = 64;
const max_objectives = 64;
const max_objective_bytes = 4096;
const max_effects = 256;
const hud_elements = 13;
const stop_rain = 3003;
const stop_thunder = 3004;
const start_rain = 3001;
const start_thunder = 3002;

entities: std.ArrayList(i64) = .empty,
players: std.ArrayList([16]u8) = .empty,
bosses: std.ArrayList(i64) = .empty,
objective_bytes: std.ArrayList(u8) = .empty,
objective_lengths: std.ArrayList(u16) = .empty,
effects: std.StaticBitSet(max_effects) = .empty,
container: ?struct { id: u8, kind: u8 } = null,
own_runtime_id: u64 = 0,
fog: bool = false,
input_locked: bool = false,
raining: bool = false,
thundering: bool = false,
hud_changed: bool = false,
camera_changed: bool = false,
untracked: bool = false,

pub fn deinit(self: *ClientState, gpa: std.mem.Allocator) void {
    self.entities.deinit(gpa);
    self.players.deinit(gpa);
    self.bosses.deinit(gpa);
    self.objective_bytes.deinit(gpa);
    self.objective_lengths.deinit(gpa);
}

pub fn tracks(kind: ?bedwire.PacketKind) bool {
    return switch (kind orelse return false) {
        .add_actor, .add_player, .add_item_actor, .add_painting, .remove_actor, .player_list, .mob_effect, .boss_event, .set_display_objective, .remove_objective, .container_open, .container_close, .player_fog, .update_client_input_locks, .level_event, .set_hud, .camera_instruction => true,
        else => false,
    };
}

pub fn observe(self: *ClientState, gpa: std.mem.Allocator, packet: protocol.BorrowedEnvelope) !void {
    if (packet.value != .typed) return;
    switch (packet.value.typed) {
        .add_actor => |p| try self.addEntity(gpa, p.target_actor_id),
        .add_player => |p| try self.addEntity(gpa, p.abilities_data.target_player_raw_id),
        .add_item_actor => |p| try self.addEntity(gpa, p.target_actor_id),
        .add_painting => |p| try self.addEntity(gpa, p.target_actor_id),
        .remove_actor => |p| remove(i64, &self.entities, p.target_actor_id),
        .player_list => |p| {
            var it = p.entries.iterator();
            while (try it.next()) |entry| switch (entry) {
                .add => |add| if (!contains([16]u8, self.players.items, add.uuid)) try self.append([16]u8, gpa, &self.players, add.uuid, max_players),
                .remove => |gone| remove([16]u8, &self.players, gone.uuid),
            };
        },
        .mob_effect => |p| if (p.target_runtime_id == self.own_runtime_id and p.effect_id >= 0 and p.effect_id < max_effects) {
            self.effects.setValue(@intCast(p.effect_id), p.event_id != .remove);
        },
        .boss_event => |p| switch (p.event_type) {
            .add => if (!contains(i64, self.bosses.items, p.target_actor_id)) try self.append(i64, gpa, &self.bosses, p.target_actor_id, max_bosses),
            .remove => remove(i64, &self.bosses, p.target_actor_id),
            else => {},
        },
        .set_display_objective => |p| try self.addObjective(gpa, p.objective_name),
        .remove_objective => |p| self.removeObjective(p.objective_name),
        .container_open => |p| self.container = .{ .id = p.container_id, .kind = p.container_type },
        .container_close => self.container = null,
        .player_fog => |p| self.fog = p.fog_stack.len != 0,
        .update_client_input_locks => |p| self.input_locked = p.input_lock_component_data != 0,
        .level_event => |p| switch (p.event_id) {
            start_rain => self.raining = true,
            stop_rain => self.raining = false,
            start_thunder => self.thundering = true,
            stop_thunder => self.thundering = false,
            else => {},
        },
        .set_hud => self.hud_changed = true,
        .camera_instruction => self.camera_changed = true,
        else => {},
    }
}

pub fn containerClosed(self: *ClientState) void {
    self.container = null;
}

pub fn reset(self: *ClientState, gpa: std.mem.Allocator, out: *std.ArrayList(u8), lengths: *std.ArrayList(u32)) !void {
    var emitter: Emitter = .{ .gpa = gpa, .out = out, .lengths = lengths };
    if (self.container) |container| try emitter.emit(.{ .container_close = .{ .container_id = container.id, .container_type = container.kind, .server_initiated_close = true } });
    for (self.entities.items) |id| try emitter.emit(.{ .remove_actor = .{ .target_actor_id = id } });
    if (self.players.items.len != 0) {
        const entries = try gpa.alloc(packets.player_list.PlayerListEntriesItem, self.players.items.len);
        defer gpa.free(entries);
        for (entries, self.players.items) |*entry, uuid| entry.* = .{ .remove = .{ .action = .remove, .uuid = uuid } };
        try emitter.emit(.{ .player_list = .{ .entries = .init(entries) } });
    }
    var effects = self.effects.iterator(.{});
    while (effects.next()) |effect| try emitter.emit(.{ .mob_effect = .{
        .target_runtime_id = self.own_runtime_id,
        .event_id = .remove,
        .effect_id = @intCast(effect),
        .effect_amplifier = 0,
        .show_particles = false,
        .effect_duration_ticks = 0,
        .tick = 0,
        .ambient = false,
    } });
    for (self.bosses.items) |id| try emitter.emit(.{ .boss_event = .{
        .target_actor_id = id,
        .event_type = .remove,
        .name = "",
        .filtered_name = "",
        .health_percent = 0,
        .color = .pink,
        .overlay = .progress,
    } });
    var offset: usize = 0;
    for (self.objective_lengths.items) |len| {
        try emitter.emit(.{ .remove_objective = .{ .objective_name = self.objective_bytes.items[offset..][0..len] } });
        offset += len;
    }
    if (self.fog) try emitter.emit(.{ .player_fog = .{ .fog_stack = .empty } });
    if (self.input_locked) try emitter.emit(.{ .update_client_input_locks = .{ .input_lock_component_data = 0 } });
    if (self.raining) try emitter.emit(.{ .level_event = .{ .event_id = stop_rain, .position = .{ .x = 0, .y = 0, .z = 0 }, .data = 0 } });
    if (self.thundering) try emitter.emit(.{ .level_event = .{ .event_id = stop_thunder, .position = .{ .x = 0, .y = 0, .z = 0 }, .data = 0 } });
    if (self.hud_changed) {
        var elements: [hud_elements]packets.set_hud.HudElement = undefined;
        for (&elements, 0..) |*element, i| element.* = @fromBackingInt(@intCast(i));
        try emitter.emit(.{ .set_hud = .{ .hud_element = .init(&elements), .hud_visible = .reset } });
    }
    if (self.camera_changed) try emitter.emit(.{ .camera_instruction = .{ .camera_instruction = .{
        .set = null,
        .clear = true,
        .fade = null,
        .target = null,
        .remove_target = null,
        .field_of_view = null,
        .spline = null,
        .attach_to_entity = null,
        .detach_from_entity = true,
    } } });
    try emitter.emit(.{ .stop_sound = .{ .sound_name = "", .stop_all_sounds = true, .stop_music_legacy = true } });
    self.forget();
}

fn forget(self: *ClientState) void {
    self.entities.clearRetainingCapacity();
    self.players.clearRetainingCapacity();
    self.bosses.clearRetainingCapacity();
    self.objective_bytes.clearRetainingCapacity();
    self.objective_lengths.clearRetainingCapacity();
    self.effects = .empty;
    self.container = null;
    self.fog = false;
    self.input_locked = false;
    self.raining = false;
    self.thundering = false;
    self.hud_changed = false;
    self.camera_changed = false;
    self.untracked = false;
}

fn addEntity(self: *ClientState, gpa: std.mem.Allocator, id: i64) !void {
    if (contains(i64, self.entities.items, id)) return;
    try self.append(i64, gpa, &self.entities, id, max_entities);
}

fn append(self: *ClientState, comptime T: type, gpa: std.mem.Allocator, list: *std.ArrayList(T), value: T, max: usize) !void {
    if (list.items.len == max) {
        self.untracked = true;
        return;
    }
    try list.append(gpa, value);
}

fn addObjective(self: *ClientState, gpa: std.mem.Allocator, name: []const u8) !void {
    if (self.findObjective(name) != null) return;
    if (self.objective_lengths.items.len == max_objectives or name.len > max_objective_bytes - self.objective_bytes.items.len) {
        self.untracked = true;
        return;
    }
    try self.objective_lengths.ensureUnusedCapacity(gpa, 1);
    try self.objective_bytes.appendSlice(gpa, name);
    self.objective_lengths.appendAssumeCapacity(@intCast(name.len));
}

fn removeObjective(self: *ClientState, name: []const u8) void {
    const found = self.findObjective(name) orelse return;
    self.objective_bytes.replaceRangeAssumeCapacity(found.offset, name.len, &.{});
    _ = self.objective_lengths.orderedRemove(found.index);
}

fn findObjective(self: *const ClientState, name: []const u8) ?struct { index: usize, offset: usize } {
    var offset: usize = 0;
    for (self.objective_lengths.items, 0..) |len, index| {
        if (std.mem.eql(u8, self.objective_bytes.items[offset..][0..len], name)) return .{ .index = index, .offset = offset };
        offset += len;
    }
    return null;
}

fn contains(comptime T: type, items: []const T, value: T) bool {
    for (items) |item| if (std.meta.eql(item, value)) return true;
    return false;
}

fn remove(comptime T: type, list: *std.ArrayList(T), value: T) void {
    for (list.items, 0..) |item, i| if (std.meta.eql(item, value)) {
        _ = list.swapRemove(i);
        return;
    };
}

const Emitter = struct {
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    lengths: *std.ArrayList(u32),

    fn emit(self: *Emitter, packet: protocol.typed.Packet) !void {
        const envelope: protocol.typed.Envelope = .{ .header = .{ .packet_id = Current.packetId(protocol.typed.packetKind(packet)).? }, .packet = packet };
        const size = try protocol.typed.encodedSize(envelope);
        try self.lengths.ensureUnusedCapacity(self.gpa, 1);
        try self.out.ensureUnusedCapacity(self.gpa, size);
        var writer = protocol.Writer.init(self.out.unusedCapacitySlice()[0..size]);
        try protocol.typed.encode(&writer, envelope);
        self.out.items.len += size;
        self.lengths.appendAssumeCapacity(@intCast(size));
    }
};

fn observed(state: *ClientState, value: protocol.typed.Packet) !void {
    try state.observe(std.testing.allocator, .{ .header = .{ .packet_id = 0 }, .kind = null, .payload = &.{}, .value = .{ .typed = value } });
}

fn resetKinds(state: *ClientState, kinds: []bedwire.PacketKind) ![]bedwire.PacketKind {
    const gpa = std.testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    var lengths: std.ArrayList(u32) = .empty;
    defer lengths.deinit(gpa);
    try state.reset(gpa, &bytes, &lengths);
    var offset: usize = 0;
    for (lengths.items, 0..) |len, i| {
        kinds[i] = (try Current.decodeBorrowed(bytes.items[offset..][0..len], .{})).kind.?;
        offset += len;
    }
    return kinds[0..lengths.items.len];
}

test "everything a backend left behind is undone once" {
    var state: ClientState = .{ .own_runtime_id = 7 };
    defer state.deinit(std.testing.allocator);
    try observed(&state, .{ .remove_actor = .{ .target_actor_id = 99 } });
    try observed(&state, .{ .container_open = .{ .container_id = 3, .container_type = 0, .position = .{ .x = 0, .y = 0, .z = 0 }, .target_actor_id = -1 } });
    try observed(&state, .{ .mob_effect = .{ .target_runtime_id = 7, .event_id = .add, .effect_id = 1, .effect_amplifier = 0, .show_particles = true, .effect_duration_ticks = 100, .tick = 0, .ambient = false } });
    try observed(&state, .{ .mob_effect = .{ .target_runtime_id = 8, .event_id = .add, .effect_id = 2, .effect_amplifier = 0, .show_particles = true, .effect_duration_ticks = 100, .tick = 0, .ambient = false } });
    try observed(&state, .{ .boss_event = .{ .target_actor_id = 5, .event_type = .add, .name = "boss", .filtered_name = "", .health_percent = 1, .color = .red, .overlay = .progress } });
    try observed(&state, .{ .set_display_objective = .{ .display_slot_name = "sidebar", .objective_name = "kills", .objective_display_name = "Kills", .criteria_name = "dummy", .sort_order = 0 } });
    try observed(&state, .{ .set_display_objective = .{ .display_slot_name = "list", .objective_name = "deaths", .objective_display_name = "Deaths", .criteria_name = "dummy", .sort_order = 0 } });
    try observed(&state, .{ .remove_objective = .{ .objective_name = "kills" } });
    try observed(&state, .{ .level_event = .{ .event_id = start_rain, .position = .{ .x = 0, .y = 0, .z = 0 }, .data = 0 } });
    try observed(&state, .{ .update_client_input_locks = .{ .input_lock_component_data = 2 } });

    var kinds: [16]bedwire.PacketKind = undefined;
    try std.testing.expectEqualSlices(bedwire.PacketKind, &.{
        .container_close, .mob_effect, .boss_event, .remove_objective, .update_client_input_locks, .level_event, .stop_sound,
    }, try resetKinds(&state, &kinds));
    try std.testing.expectEqualSlices(bedwire.PacketKind, &.{.stop_sound}, try resetKinds(&state, &kinds));
}

test "a closed container is not closed again" {
    var state: ClientState = .{};
    defer state.deinit(std.testing.allocator);
    try observed(&state, .{ .container_open = .{ .container_id = 3, .container_type = 0, .position = .{ .x = 0, .y = 0, .z = 0 }, .target_actor_id = -1 } });
    state.containerClosed();
    var kinds: [4]bedwire.PacketKind = undefined;
    try std.testing.expectEqualSlices(bedwire.PacketKind, &.{.stop_sound}, try resetKinds(&state, &kinds));
}

test "tracking stops at its bounds and says so" {
    var state: ClientState = .{};
    defer state.deinit(std.testing.allocator);
    for (0..max_bosses + 1) |id| try observed(&state, .{ .boss_event = .{ .target_actor_id = @intCast(id), .event_type = .add, .name = "", .filtered_name = "", .health_percent = 1, .color = .red, .overlay = .progress } });
    try std.testing.expectEqual(@as(usize, max_bosses), state.bosses.items.len);
    try std.testing.expect(state.untracked);
}
