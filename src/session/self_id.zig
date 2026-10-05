const std = @import("std");
const bedwire = @import("bedwire");

// Packets that start with an actor runtime id; the client keeps the id its first backend gave it
pub fn leadsWithRuntimeId(kind: ?bedwire.PacketKind) bool {
    return switch (kind orelse return false) {
        .move_player, .set_actor_data, .set_actor_motion, .update_attributes, .actor_event, .move_actor_absolute, .move_actor_delta, .mob_effect, .player_action, .set_local_player_as_initialised => true,
        else => false,
    };
}

pub const Swap = struct {
    a: u64,
    b: u64,

    pub fn active(self: Swap) bool {
        return self.a != self.b;
    }

    pub fn apply(self: Swap, packet: []const u8, out: *std.ArrayList(u8)) !?[]const u8 {
        const header_len = try varintLen(packet);
        const id, const id_len = try varint(packet[header_len..]);
        const replacement = if (id == self.a) self.b else if (id == self.b) self.a else return null;
        var encoded: [10]u8 = undefined;
        const encoded_len = writeVarint(&encoded, replacement);
        const start = out.items.len;
        out.appendSliceAssumeCapacity(packet[0..header_len]);
        out.appendSliceAssumeCapacity(encoded[0..encoded_len]);
        out.appendSliceAssumeCapacity(packet[header_len + id_len ..]);
        return out.items[start..];
    }
};

pub const max_growth = 10;

fn varintLen(bytes: []const u8) !usize {
    return (try varint(bytes))[1];
}

fn varint(bytes: []const u8) !struct { u64, usize } {
    var value: u64 = 0;
    for (bytes[0..@min(bytes.len, 10)], 0..) |byte, i| {
        value |= @as(u64, byte & 0x7f) << @intCast(7 * i);
        if (byte & 0x80 == 0) return .{ value, i + 1 };
    }
    return error.MalformedPacket;
}

fn writeVarint(out: *[10]u8, value: u64) usize {
    var rest = value;
    var i: usize = 0;
    while (rest >= 0x80) : (i += 1) {
        out[i] = @as(u8, @truncate(rest)) | 0x80;
        rest >>= 7;
    }
    out[i] = @truncate(rest);
    return i + 1;
}

test "ids swap both ways and other packets are left alone" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, 64);
    const swap: Swap = .{ .a = 1, .b = 300 };

    const to_b = (try swap.apply(&.{ 0x13, 0x01, 0xaa }, &out)).?;
    try std.testing.expectEqualSlices(u8, &.{ 0x13, 0xac, 0x02, 0xaa }, to_b);
    const to_a = (try swap.apply(&.{ 0x13, 0xac, 0x02, 0xbb }, &out)).?;
    try std.testing.expectEqualSlices(u8, &.{ 0x13, 0x01, 0xbb }, to_a);
    try std.testing.expectEqual(@as(?[]const u8, null), try swap.apply(&.{ 0x13, 0x05 }, &out));
    try std.testing.expectError(error.MalformedPacket, swap.apply(&.{ 0x13, 0x80 }, &out));
}
