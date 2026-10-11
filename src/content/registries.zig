const std = @import("std");
const bedwire = @import("bedwire");
const nbt = @import("nbt.zig");

const protocol = bedwire.protocol;
const packets = protocol.packets;
const Hasher = std.hash.Wyhash;
const max_biome_names = 1024;

pub const Kind = enum { start_game, blocks, items, biomes, dimensions, actors };

pub const Fingerprint = struct {
    hashes: std.EnumArray(Kind, ?u64) = .initFill(null),

    pub fn get(self: *const Fingerprint, kind: Kind) ?u64 {
        return self.hashes.get(kind);
    }

    pub fn covers(self: *const Fingerprint, baseline: *const Fingerprint) bool {
        for (std.enums.values(Kind)) |kind| {
            if (baseline.get(kind) != null and self.get(kind) == null) return false;
        }
        return true;
    }

    pub fn difference(self: *const Fingerprint, baseline: *const Fingerprint) ?Kind {
        for (std.enums.values(Kind)) |kind| {
            if (self.get(kind) != baseline.get(kind)) return kind;
        }
        return null;
    }

    pub fn record(self: *Fingerprint, packet: protocol.BorrowedEnvelope) !void {
        if (packet.value != .typed) return;
        switch (packet.value.typed) {
            .start_game => |start| {
                self.hashes.set(.start_game, try startGame(start));
                self.hashes.set(.blocks, try blocks(start));
            },
            .item_registry => |registry| self.hashes.set(.items, try items(registry)),
            .biome_definition_list => |list| self.hashes.set(.biomes, try biomes(list)),
            .dimension_data => |data| self.hashes.set(.dimensions, try dimensions(data)),
            .available_actor_identifiers => |actors| self.hashes.set(.actors, try nbt.hash(actors.identifier_list)),
            else => {},
        }
    }
};

pub fn isRegistry(kind: ?bedwire.PacketKind) bool {
    return switch (kind orelse return false) {
        .start_game, .item_registry, .biome_definition_list, .dimension_data, .available_actor_identifiers => true,
        else => false,
    };
}

fn startGame(start: packets.start_game.Packet) !u64 {
    const settings = start.settings;
    var hasher: Hasher = .init(@backingInt(Kind.start_game));
    hasher.update(&.{
        @intFromBool(start.movement_settings.server_authoritative_block_breaking),
        @intFromBool(start.enable_item_stack_net_manager),
        @intFromBool(start.server_enabled_client_side_generation),
        @intFromBool(settings.education_features_enabled),
        @intFromBool(settings.is_hardcore),
    });
    hasher.update(std.mem.asBytes(&start.movement_settings.rewind_history_size));
    hasher.update(std.mem.asBytes(&settings.editor_world_type));
    hashString(&hasher, settings.base_game_version);
    if (start.server_enabled_client_side_generation) hasher.update(std.mem.asBytes(&settings.seed));
    hasher.update(std.mem.asBytes(&try nbt.hash(start.player_property_data)));
    var experiments: u64 = 0;
    var it = settings.experiments.toggles.iterator();
    while (try it.next()) |experiment| {
        if (!experiment.enabled) continue;
        experiments +%= Hasher.hash(3, experiment.name);
    }
    hasher.update(std.mem.asBytes(&experiments));
    return hasher.final();
}

fn blocks(start: packets.start_game.Packet) !u64 {
    var set: u64 = 0;
    var it = start.block_properties.iterator();
    while (try it.next()) |block| {
        var hasher: Hasher = .init(0);
        hashString(&hasher, block.block_name);
        hasher.update(std.mem.asBytes(&try nbt.hash(block.block_definition)));
        set +%= hasher.final();
    }
    var hasher: Hasher = .init(@backingInt(Kind.blocks));
    hasher.update(std.mem.asBytes(&set));
    hasher.update(&.{@intFromBool(start.block_network_ids_are_hashes)});
    hasher.update(std.mem.asBytes(&start.server_block_type_registry_checksum));
    return hasher.final();
}

fn items(registry: packets.item_registry.Packet) !u64 {
    var set: u64 = 0;
    var it = registry.item_data.iterator();
    while (try it.next()) |item| {
        var hasher: Hasher = .init(0);
        hashString(&hasher, item.item_name);
        hasher.update(std.mem.asBytes(&item.item_id));
        hasher.update(&.{@intFromBool(item.is_component_based)});
        hasher.update(std.mem.asBytes(&item.item_version));
        hasher.update(std.mem.asBytes(&try nbt.hash(item.item_component_data)));
        set +%= hasher.final();
    }
    return Hasher.hash(@backingInt(Kind.items), std.mem.asBytes(&set));
}

fn biomes(list: packets.biome_definition_list.Packet) !u64 {
    if (list.string_list.len > max_biome_names) return error.TooManyBiomes;
    var names: [max_biome_names][]const u8 = undefined;
    var strings = list.string_list.iterator();
    var count: usize = 0;
    while (try strings.next()) |name| : (count += 1) names[count] = name;

    var set: u64 = 0;
    var it = list.map_of_biome_names_to_data.iterator();
    while (try it.next()) |biome| {
        if (biome.key >= count) return error.InvalidBiome;
        var hasher: Hasher = .init(0);
        hashString(&hasher, names[biome.key]);
        hasher.update(std.mem.asBytes(&biome.value.id));
        set +%= hasher.final();
    }
    return Hasher.hash(@backingInt(Kind.biomes), std.mem.asBytes(&set));
}

fn dimensions(data: packets.dimension_data.Packet) !u64 {
    var set: u64 = 0;
    var it = data.definitions.iterator();
    while (try it.next()) |definition| {
        const value = definition.value;
        var hasher: Hasher = .init(0);
        hashString(&hasher, definition.key);
        hasher.update(std.mem.asBytes(&value.minimum_y));
        hasher.update(std.mem.asBytes(&value.height_range));
        hasher.update(std.mem.asBytes(&value.generator_type));
        hasher.update(std.mem.asBytes(&value.dimension_type));
        set +%= hasher.final();
    }
    return Hasher.hash(@backingInt(Kind.dimensions), std.mem.asBytes(&set));
}

fn hashString(hasher: *Hasher, text: []const u8) void {
    hasher.update(std.mem.asBytes(&@as(u32, @intCast(@min(text.len, std.math.maxInt(u32))))));
    hasher.update(text);
}

fn fingerprintOf(value: protocol.typed.Packet) !Fingerprint {
    var fingerprint: Fingerprint = .{};
    try fingerprint.record(.{ .header = .{ .packet_id = 0 }, .kind = null, .payload = &.{}, .value = .{ .typed = value } });
    return fingerprint;
}

fn testItem(name: []const u8, id: i16, components: []const u8) packets.item_registry.ItemData {
    return .{ .item_name = name, .item_id = id, .is_component_based = true, .item_version = .datadriven, .item_component_data = components };
}

fn testBiome(key: u16, id: u16) packets.biome_definition_list.PacketMapOfBiomeNamesToDataEntry {
    return .{ .key = key, .value = .{
        .id = id,
        .temperature = 0.5,
        .downfall = 0.5,
        .foliage_snow = 0,
        .depth = 0,
        .scale = 0,
        .map_water_color_argb = 0,
        .rain = true,
        .tags = null,
        .chunk_gen_data = null,
    } };
}

test "item registries compare by meaning, not order" {
    const ab = [_]u8{ 10, 0, 1, 1, 'a', 5, 1, 1, 'b', 6, 0 };
    const ba = [_]u8{ 10, 0, 1, 1, 'b', 6, 1, 1, 'a', 5, 0 };
    const first = [_]packets.item_registry.ItemData{ testItem("custom:wand", 1000, &ab), testItem("custom:staff", 1001, &ab) };
    const reordered = [_]packets.item_registry.ItemData{ testItem("custom:staff", 1001, &ba), testItem("custom:wand", 1000, &ba) };
    const renumbered = [_]packets.item_registry.ItemData{ testItem("custom:wand", 1001, &ab), testItem("custom:staff", 1000, &ab) };
    const a = try fingerprintOf(.{ .item_registry = .{ .item_data = .init(&first) } });
    const b = try fingerprintOf(.{ .item_registry = .{ .item_data = .init(&reordered) } });
    const c = try fingerprintOf(.{ .item_registry = .{ .item_data = .init(&renumbered) } });
    try std.testing.expectEqual(@as(?Kind, null), a.difference(&b));
    try std.testing.expectEqual(@as(?Kind, .items), a.difference(&c));
}

test "biomes compare by name and id, wherever the names sit" {
    const names = [_][]const u8{ "plains", "desert" };
    const swapped = [_][]const u8{ "desert", "plains" };
    const entries = [_]packets.biome_definition_list.PacketMapOfBiomeNamesToDataEntry{ testBiome(0, 1), testBiome(1, 2) };
    const moved = [_]packets.biome_definition_list.PacketMapOfBiomeNamesToDataEntry{ testBiome(1, 1), testBiome(0, 2) };
    const renumbered = [_]packets.biome_definition_list.PacketMapOfBiomeNamesToDataEntry{ testBiome(0, 2), testBiome(1, 1) };
    const a = try fingerprintOf(.{ .biome_definition_list = .{ .map_of_biome_names_to_data = .init(&entries), .string_list = .init(&names) } });
    const b = try fingerprintOf(.{ .biome_definition_list = .{ .map_of_biome_names_to_data = .init(&moved), .string_list = .init(&swapped) } });
    const c = try fingerprintOf(.{ .biome_definition_list = .{ .map_of_biome_names_to_data = .init(&renumbered), .string_list = .init(&names) } });
    try std.testing.expectEqual(@as(?Kind, null), a.difference(&b));
    try std.testing.expectEqual(@as(?Kind, .biomes), a.difference(&c));

    const dangling = [_]packets.biome_definition_list.PacketMapOfBiomeNamesToDataEntry{testBiome(5, 1)};
    try std.testing.expectError(error.InvalidBiome, fingerprintOf(.{ .biome_definition_list = .{ .map_of_biome_names_to_data = .init(&dangling), .string_list = .init(&names) } }));
}

test "a registry only one side sent counts as a difference" {
    const list = [_]packets.item_registry.ItemData{testItem("custom:wand", 1000, &.{ 10, 0, 0 })};
    const with_items = try fingerprintOf(.{ .item_registry = .{ .item_data = .init(&list) } });
    const empty: Fingerprint = .{};
    try std.testing.expectEqual(@as(?Kind, .items), empty.difference(&with_items));
    try std.testing.expect(!empty.covers(&with_items));
    try std.testing.expect(with_items.covers(&empty));
}
