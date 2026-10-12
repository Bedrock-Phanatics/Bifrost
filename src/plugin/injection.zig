const protocol = @import("bedwire").protocol;
const abi = @import("abi.zig");

pub const max_packet_bytes = 65536;

pub fn validate(target: abi.PacketTarget, bytes: []const u8) abi.Status {
    if (target != .player and target != .backend) return .invalid_argument;
    if (bytes.len == 0 or bytes.len > max_packet_bytes) return .invalid_argument;
    const limits: protocol.DecodeLimits = .{ .max_packet_bytes = max_packet_bytes };
    const packet = protocol.packet.decode(bytes, limits) catch return .invalid_argument;
    if (packet.header.sender_subclient != 0 or packet.header.target_subclient != 0) return .unsupported;
    switch (protocol.Current.packetKind(packet.header.packet_id) orelse return .unsupported) {
        .text => {},
        .request_chunk_radius => if (target != .backend) return .unsupported,
        else => return .unsupported,
    }
    const decoded = protocol.Current.decodeBorrowed(bytes, limits) catch return .invalid_argument;
    if (decoded.value.typed == .request_chunk_radius and decoded.value.typed.request_chunk_radius.chunk_radius < 0) return .invalid_argument;
    return .ok;
}

test "packet injection validates supported packets and truncated input" {
    const testing = @import("std").testing;
    const text = [_]u8{ 9, 0, 0, 0, 2, 'h', 'i', 0, 0, 0 };
    for (0..text.len) |len| try testing.expectEqual(abi.Status.invalid_argument, validate(.player, text[0..len]));
    try testing.expectEqual(abi.Status.ok, validate(.player, &text));
    try testing.expectEqual(abi.Status.ok, validate(.backend, &text));
    try testing.expectEqual(abi.Status.invalid_argument, validate(@fromBackingInt(7), &text));
    try testing.expectEqual(abi.Status.unsupported, validate(.player, &.{ 69, 16, 12 }));
    try testing.expectEqual(abi.Status.ok, validate(.backend, &.{ 69, 16, 12 }));
    try testing.expectEqual(abi.Status.invalid_argument, validate(.backend, &.{ 69, 1, 12 }));
    try testing.expectEqual(abi.Status.unsupported, validate(.player, &.{ 1, 0 }));
    try testing.expectEqual(abi.Status.unsupported, validate(.player, &.{ 0x89, 8, 0, 0, 0, 0, 0, 0 }));
    var oversized: [max_packet_bytes + 1]u8 = @splat(0);
    oversized[0] = 9;
    try testing.expectEqual(abi.Status.invalid_argument, validate(.player, &oversized));
    const Decoded = @import("Decoded.zig");
    const message: [max_packet_bytes - 10]u8 = @splat('x');
    const text_fields: abi.Text = .{ .message = .of(&message) };
    const len = try Decoded.encode(.{ .packet_id = 9 }, .text, &text_fields, oversized[0..max_packet_bytes]);
    try testing.expectEqual(@as(usize, max_packet_bytes), len);
    try testing.expectEqual(abi.Status.ok, validate(.player, oversized[0..len]));
    try testing.expectEqual(abi.Status.invalid_argument, validate(.player, oversized[0 .. len - 1]));
    var buffer: [4]u8 = undefined;
    for (0..65536) |value| {
        @memcpy(&buffer, &@as([4]u8, @bitCast(@as(u32, @intCast(value)))));
        _ = validate(.player, &buffer);
        _ = validate(.backend, &buffer);
    }
}
