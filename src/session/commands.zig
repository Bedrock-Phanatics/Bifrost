const std = @import("std");
const bedwire = @import("bedwire");
const Plugins = @import("../plugin/Plugins.zig");

const protocol = bedwire.protocol;
const Current = protocol.Current;
const wire = protocol.packets.available_commands;
const Packet = wire.Packet;
const Command = wire.Command;

const log = std.log.scoped(.managed);

// RAWTEXT | ARG_FLAG_VALID
const raw_text: u32 = 0x100000 | 70;
const permissions = [_][]const u8{ "any", "gamedirectors", "admin", "host", "owner" };
const args_overload = [_]wire.CommandOverload{.{
    .is_chaining = false,
    .parameter_data = .init(&.{.{ .name = "args", .parse_symbol = raw_text, .is_optional = true, .options = 0 }}),
}};

pub fn merge(arena: std.mem.Allocator, plugins: *const Plugins, backend: ?[]const u8, max_bytes: usize, decode_limits: protocol.DecodeLimits) ![]const u8 {
    var packet: Packet = .{
        .enum_values = .empty,
        .chained_subcommand_values = .empty,
        .post_fixes = .empty,
        .enum_data = .empty,
        .chained_subcommand_data = .empty,
        .commands = .empty,
        .soft_enums = .empty,
        .constraints = .empty,
    };
    var commands: std.ArrayList(Command) = .empty;
    var capacity: usize = 64;
    if (backend) |bytes| {
        const decoded = try Current.decodeBorrowed(bytes, decode_limits);
        if (decoded.value != .typed or decoded.value.typed != .available_commands) return error.InvalidPacket;
        packet = decoded.value.typed.available_commands;
        try commands.ensureTotalCapacity(arena, packet.commands.len + plugins.commands.count());
        var it = packet.commands.iterator();
        while (try it.next()) |command| {
            if (owned(plugins, command.name)) {
                log.debug("plugin command /{s} replaces the backend's", .{command.name});
                continue;
            }
            commands.appendAssumeCapacity(command);
        }
        capacity += bytes.len;
    }

    const start = commands.items.len;
    var names = plugins.commands.iterator();
    while (names.next()) |entry| {
        const command = entry.value_ptr;
        try commands.append(arena, .{
            .name = entry.key_ptr.*,
            .description = command.description(),
            .flags = 0,
            .permission_level = permissions[@backingInt(command.permission)],
            .alias_enum = -1,
            .command_data_chained_subcommand_indexes = .empty,
            .overloads = .init(&args_overload),
        });
        capacity += entry.key_ptr.len + command.description_len + 64;
    }
    std.mem.sort(Command, commands.items[start..], {}, byName);
    packet.commands = .init(commands.items);

    const buffer = try arena.alloc(u8, @min(capacity, max_bytes));
    var writer = protocol.Writer.init(buffer);
    try protocol.typed.encode(&writer, .{ .header = .{ .packet_id = Current.packetId(.available_commands).? }, .packet = .{ .available_commands = packet } });
    return writer.written();
}

fn owned(plugins: *const Plugins, name: []const u8) bool {
    if (name.len > Plugins.max_command_len) return false;
    var buffer: [Plugins.max_command_len]u8 = undefined;
    return plugins.commands.contains(std.ascii.lowerString(&buffer, name));
}

fn byName(_: void, a: Command, b: Command) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

const testing = std.testing;
const abi = @import("../plugin/abi.zig");

fn onCommand(_: ?*anyopaque, _: *const abi.Command) callconv(.c) void {}

fn registerCommands(host: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
    plugin.name = .of("commands");
    plugin.plugin_version = .of("1.0.0");
    plugin.capabilities = .{ .commands = true };
    const hub: abi.CommandInfo = .{ .name = .of("Hub"), .description = .of("Back to the lobby"), .permission = .admin, .callback = onCommand };
    if (host.register_command_info(host.context, &hub) != .ok) return .failed;
    return host.register_command(host.context, .of("spawn"), onCommand, null);
}

const enum_flag = 0x200000;

fn backendCommand(name: []const u8, alias_enum: i32, overloads: []const wire.CommandOverload) Command {
    return .{
        .name = name,
        .description = "from the backend",
        .flags = 0,
        .permission_level = "any",
        .alias_enum = alias_enum,
        .command_data_chained_subcommand_indexes = .empty,
        .overloads = .init(overloads),
    };
}

fn encode(buffer: []u8, packet: Packet) ![]const u8 {
    var writer = protocol.Writer.init(buffer);
    try protocol.typed.encode(&writer, .{ .header = .{ .packet_id = Current.packetId(.available_commands).? }, .packet = .{ .available_commands = packet } });
    return writer.written();
}

fn backendPacket(buffer: []u8) ![]const u8 {
    const mode_overload = [_]wire.CommandOverload{.{
        .is_chaining = false,
        .parameter_data = .init(&.{.{ .name = "mode", .parse_symbol = 0x100000 | enum_flag | 0, .is_optional = false, .options = 0 }}),
    }};
    return encode(buffer, .{
        .enum_values = .init(&.{ "survival", "creative", "teleport" }),
        .chained_subcommand_values = .empty,
        .post_fixes = .init(&.{"L"}),
        .enum_data = .init(&.{
            .{ .name = "GameMode", .values = .init(&.{ 0, 1 }) },
            .{ .name = "TpAliases", .values = .init(&.{2}) },
        }),
        .chained_subcommand_data = .empty,
        .commands = .init(&.{
            backendCommand("gamemode", -1, &mode_overload),
            backendCommand("tp", 1, &.{}),
            backendCommand("HUB", -1, &.{}),
        }),
        .soft_enums = .init(&.{.{ .enum_name = "Warps", .enum_options = .init(&.{"spawn"}) }}),
        .constraints = .init(&.{.{ .enum_value_symbol = 1, .enum_symbol = 0, .constraint_indices = &.{1} }}),
    });
}

fn expectValid(arena: std.mem.Allocator, bytes: []const u8) !struct { Packet, []Command } {
    const decoded = try Current.decodeBorrowed(bytes, .{});
    const packet = decoded.value.typed.available_commands;
    const values = try packet.enum_values.toOwnedSlice(arena);
    const enums = try packet.enum_data.toOwnedSlice(arena);
    for (enums) |data| {
        var it = data.values.iterator();
        while (try it.next()) |index| try testing.expect(index < values.len);
    }
    const list = try packet.commands.toOwnedSlice(arena);
    for (list) |command| {
        try testing.expect(command.alias_enum == -1 or command.alias_enum < enums.len);
        var overloads = command.overloads.iterator();
        while (try overloads.next()) |overload| {
            var params = overload.parameter_data.iterator();
            while (try params.next()) |param| if (param.parse_symbol & enum_flag != 0) try testing.expect(param.parse_symbol & 0xffff < enums.len);
        }
    }
    return .{ packet, list };
}

fn find(list: []const Command, name: []const u8) ?Command {
    for (list) |command| if (std.mem.eql(u8, command.name, name)) return command;
    return null;
}

test "plugin commands go out alone when the backend has no list" {
    var plugins: Plugins = try .init(testing.allocator, &.{}, .{});
    defer plugins.deinit();
    try plugins.add(registerCommands, null);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const packet, const list = try expectValid(arena.allocator(), try merge(arena.allocator(), &plugins, null, 1 << 20, .{}));
    try testing.expectEqual(@as(usize, 0), packet.enum_values.len + packet.enum_data.len + packet.soft_enums.len);
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("hub", list[0].name);
    try testing.expectEqualStrings("Back to the lobby", list[0].description);
    try testing.expectEqualStrings("admin", list[0].permission_level);
    try testing.expectEqualStrings("spawn", list[1].name);
    try testing.expectEqualStrings("any", list[1].permission_level);
    const overloads = try list[1].overloads.toOwnedSlice(arena.allocator());
    const params = try overloads[0].parameter_data.toOwnedSlice(arena.allocator());
    try testing.expectEqual(raw_text, params[0].parse_symbol);
    try testing.expect(params[0].is_optional);
}

test "plugin commands join the backend's list, keep its tables and replace a backend command of the same name" {
    var plugins: Plugins = try .init(testing.allocator, &.{}, .{});
    defer plugins.deinit();
    try plugins.add(registerCommands, null);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buffer: [1024]u8 = undefined;
    const backend = try backendPacket(&buffer);

    const packet, const list = try expectValid(arena.allocator(), try merge(arena.allocator(), &plugins, backend, 1 << 20, .{}));
    const original, _ = try expectValid(arena.allocator(), backend);
    try testing.expectEqualSlices(u8, original.enum_values.data.wire, packet.enum_values.data.wire);
    try testing.expectEqualSlices(u8, original.enum_data.data.wire, packet.enum_data.data.wire);
    try testing.expectEqualSlices(u8, original.soft_enums.data.wire, packet.soft_enums.data.wire);
    try testing.expectEqualSlices(u8, original.constraints.data.wire, packet.constraints.data.wire);
    try testing.expectEqual(@as(usize, 4), list.len);
    try testing.expectEqual(@as(i32, 1), find(list, "tp").?.alias_enum);
    try testing.expectEqual(@as(usize, 1), find(list, "gamemode").?.overloads.len);
    try testing.expect(find(list, "HUB") == null);
    try testing.expectEqualStrings("Back to the lobby", find(list, "hub").?.description);
    try testing.expect(find(list, "spawn") != null);
}

test "a malformed, truncated or oversized list is refused, never half merged" {
    var plugins: Plugins = try .init(testing.allocator, &.{}, .{});
    defer plugins.deinit();
    try plugins.add(registerCommands, null);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buffer: [1024]u8 = undefined;
    const backend = try backendPacket(&buffer);

    try testing.expectError(error.NoSpaceLeft, merge(arena.allocator(), &plugins, backend, backend.len, .{}));
    for (1..backend.len) |len| {
        if (merge(arena.allocator(), &plugins, backend[0..len], 1 << 20, .{})) |_| return error.TestUnexpectedResult else |_| {}
    }

    var copy: [1024]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(0xc0de);
    for (0..5000) |_| {
        const random = prng.random();
        const bytes = copy[0..backend.len];
        @memcpy(bytes, backend);
        for (0..1 + random.uintLessThan(usize, 4)) |_| bytes[random.uintLessThan(usize, bytes.len)] = random.int(u8);
        const merged = merge(arena.allocator(), &plugins, bytes, 1 << 20, .{}) catch continue;
        const decoded = try Current.decodeBorrowed(merged, .{});
        const list = try decoded.value.typed.available_commands.commands.toOwnedSlice(arena.allocator());
        try testing.expect(find(list, "hub") != null and find(list, "spawn") != null);
    }
}
