const std = @import("std");
const bedwire = @import("bedwire");

const protocol = bedwire.protocol;
const actor_refs = protocol.actor_refs;

pub const Ids = struct {
    runtime: u64 = 0,
    unique: i64 = 0,
};

// The client keeps the ids its first backend gave it. Swapping both ways keeps
// the mapping a bijection, so no other actor can end up looking like the player.
pub const Swap = struct {
    client: Ids,
    backend: Ids,

    pub fn active(self: Swap) bool {
        return self.client.runtime != self.backend.runtime or self.client.unique != self.backend.unique;
    }

    pub fn runtime(self: Swap, id: u64) u64 {
        return swapped(u64, id, self.client.runtime, self.backend.runtime);
    }

    pub fn unique(self: Swap, id: i64) i64 {
        return swapped(i64, id, self.client.unique, self.backend.unique);
    }

    /// Null when the packet holds neither id; otherwise the re-encoded packet, allocated in `arena`.
    pub fn apply(self: Swap, arena: std.mem.Allocator, kind: ?bedwire.PacketKind, packet: []const u8, limits: protocol.DecodeLimits) !?[]const u8 {
        if (!actor_refs.packets.contains(kind orelse return null)) return null;
        var envelope = try protocol.typed.decode(packet, limits);
        if (!try actor_refs.rewrite(arena, &envelope.packet, self)) return null;
        const out = try arena.alloc(u8, try protocol.typed.encodedSize(envelope));
        var writer: protocol.Writer = .init(out);
        try protocol.typed.encode(&writer, envelope);
        return out;
    }
};

fn swapped(comptime T: type, id: T, a: T, b: T) T {
    return if (id == a) b else if (id == b) a else id;
}

fn encode(buffer: []u8, packet: protocol.typed.Packet) ![]const u8 {
    var writer: protocol.Writer = .init(buffer);
    try protocol.typed.encode(&writer, .{ .header = .{ .packet_id = protocol.registry.packetId(protocol.typed.packetKind(packet)).?, .sender_subclient = 1 }, .packet = packet });
    return writer.written();
}

fn swapPacket(arena: std.mem.Allocator, swap: Swap, packet: []const u8) !?protocol.typed.Envelope {
    const header = try protocol.packet.decode(packet, .{});
    const swapped_packet = try swap.apply(arena, protocol.registry.packetKind(header.header.packet_id), packet, .{}) orelse return null;
    return try protocol.typed.decode(swapped_packet, .{});
}

test "the player's ids swap both ways and other actors are left alone" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const swap: Swap = .{ .client = .{ .runtime = 1, .unique = -1 }, .backend = .{ .runtime = 300, .unique = 4000 } };
    var buffer: [128]u8 = undefined;

    const action: protocol.typed.Packet = .{ .player_action = .{ .player_runtime_id = 1, .action = .startdestroyblock, .block_position = .{ .x = 0, .y = 0, .z = 0 }, .result_pos = .{ .x = 0, .y = 0, .z = 0 }, .face = 0 } };
    const to_backend = (try swapPacket(gpa, swap, try encode(&buffer, action))).?;
    try std.testing.expectEqual(@as(u64, 300), to_backend.packet.player_action.player_runtime_id);
    try std.testing.expectEqual(@as(u2, 1), to_backend.header.sender_subclient);
    const back = (try swapPacket(gpa, swap, try encode(&buffer, to_backend.packet))).?;
    try std.testing.expectEqual(@as(u64, 1), back.packet.player_action.player_runtime_id);

    const other: protocol.typed.Packet = .{ .remove_actor = .{ .target_actor_id = 77 } };
    try std.testing.expectEqual(null, try swapPacket(gpa, swap, try encode(&buffer, other)));
    const unique: protocol.typed.Packet = .{ .remove_actor = .{ .target_actor_id = 4000 } };
    try std.testing.expectEqual(@as(i64, -1), (try swapPacket(gpa, swap, try encode(&buffer, unique))).?.packet.remove_actor.target_actor_id);

    const text = [_]u8{ 9, 0, 0 };
    try std.testing.expectEqual(null, try swap.apply(gpa, .text, &text, .{}));
    try std.testing.expectError(error.EndOfStream, swap.apply(gpa, .remove_actor, &.{14}, .{}));
}
