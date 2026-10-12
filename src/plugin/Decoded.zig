const std = @import("std");
const protocol = @import("bedwire").protocol;
const abi = @import("abi.zig");

pub const Error = error{ Unsupported, InvalidArgument };
pub const Value = union(enum) { text: abi.Text, chunk_radius: abi.ChunkRadius };

pub fn kind(packet_type: abi.PacketType) ?protocol.PacketKind {
    return switch (packet_type) {
        .text => .text,
        .chunk_radius => .request_chunk_radius,
        else => null,
    };
}

pub fn size(packet_type: abi.PacketType) usize {
    return switch (packet_type) {
        .text => @sizeOf(abi.Text),
        .chunk_radius => @sizeOf(abi.ChunkRadius),
        else => 0,
    };
}

pub fn decode(bytes: []const u8, packet_type: abi.PacketType, limits: protocol.DecodeLimits) Error!Value {
    const requested = kind(packet_type) orelse return error.Unsupported;
    const header = protocol.packet.decode(bytes, limits) catch return error.InvalidArgument;
    if (protocol.Current.packetKind(header.header.packet_id) != requested) return error.Unsupported;
    const decoded = protocol.Current.decodeBorrowed(bytes, limits) catch return error.InvalidArgument;
    return switch (decoded.value.typed) {
        .text => |text| blk: {
            var result: abi.Text = .{
                .localize = @intFromBool(text.localize),
                .xuid = .of(text.senders_xuid),
                .platform_id = .of(text.platform_id),
                .has_filtered_message = @intFromBool(text.filtered_message != null),
                .filtered_message = if (text.filtered_message) |filtered| .of(filtered) else .{},
            };
            switch (text.body) {
                .message_only => |body| {
                    result.message_type = @fromBackingInt(@backingInt(body.message_type));
                    result.message = .of(body.message);
                },
                .author_and_message => |body| {
                    result.message_type = @fromBackingInt(@backingInt(body.message_type));
                    result.source = .of(body.player_name);
                    result.message = .of(body.message);
                },
                .message_and_params => |body| {
                    result.message_type = @fromBackingInt(@backingInt(body.message_type));
                    result.message = .of(body.message);
                    var parameters = body.parameter_list.iterator();
                    while (parameters.next() catch return error.InvalidArgument) |parameter| {
                        if (result.parameter_count == result.parameters.len) return error.InvalidArgument;
                        result.parameters[result.parameter_count] = .of(parameter);
                        result.parameter_count += 1;
                    }
                },
            }
            break :blk .{ .text = result };
        },
        .request_chunk_radius => |radius| .{ .chunk_radius = .{ .radius = radius.chunk_radius, .max_radius = radius.max_chunk_radius } },
        else => error.Unsupported,
    };
}

pub fn copy(value: Value, out: *anyopaque) void {
    switch (value) {
        .text => |text| @as(*abi.Text, @ptrCast(@alignCast(out))).* = text,
        .chunk_radius => |radius| @as(*abi.ChunkRadius, @ptrCast(@alignCast(out))).* = radius,
    }
}

pub fn aligned(packet_type: abi.PacketType, ptr: *const anyopaque) bool {
    const alignment: usize = switch (packet_type) {
        .text => @alignOf(abi.Text),
        .chunk_radius => @alignOf(abi.ChunkRadius),
        else => return false,
    };
    return @intFromPtr(ptr) % alignment == 0;
}

pub fn encode(header: protocol.packet.Header, packet_type: abi.PacketType, data: *const anyopaque, out: []u8) Error!usize {
    const requested = kind(packet_type) orelse return error.Unsupported;
    if (protocol.Current.packetKind(header.packet_id) != requested) return error.Unsupported;
    if (!aligned(packet_type, data) or overlaps(data, size(packet_type), out)) return error.InvalidArgument;
    var parameters: [4][]const u8 = undefined;
    switch (packet_type) {
        .text => {
            const text: *const abi.Text = @ptrCast(@alignCast(data));
            if (text.localize > 1 or text.has_filtered_message > 1 or text.parameter_count > text.parameters.len) return error.InvalidArgument;
            const message = try string(text.message, 65536, out);
            const source = try string(text.source, 256, out);
            const xuid = try string(text.xuid, 64, out);
            const platform = try string(text.platform_id, 256, out);
            const filtered = try string(text.filtered_message, 65536, out);
            if (text.has_filtered_message == 0 and filtered.len != 0) return error.InvalidArgument;
            const message_type: protocol.packets.text.TextPacketType = if (@backingInt(text.message_type) <= 11) @fromBackingInt(@intCast(@backingInt(text.message_type))) else return error.InvalidArgument;
            var body: protocol.packets.text.TextBody = undefined;
            switch (text.message_type) {
                .chat, .whisper, .announcement => {
                    if (text.parameter_count != 0) return error.InvalidArgument;
                    body = .{ .author_and_message = .{ .message_type = message_type, .player_name = source, .message = message } };
                },
                .translate, .popup, .jukebox_popup => {
                    if (source.len != 0) return error.InvalidArgument;
                    for (text.parameters[0..text.parameter_count], parameters[0..text.parameter_count]) |parameter, *target| target.* = try string(parameter, 65536, out);
                    body = .{ .message_and_params = .{ .message_type = message_type, .message = message, .parameter_list = .init(parameters[0..text.parameter_count]) } };
                },
                else => {
                    if (source.len != 0 or text.parameter_count != 0) return error.InvalidArgument;
                    body = .{ .message_only = .{ .message_type = message_type, .message = message } };
                },
            }
            return write(header, protocol.packets.text.Packet{ .localize = text.localize != 0, .body = body, .senders_xuid = xuid, .platform_id = platform, .filtered_message = if (text.has_filtered_message != 0) filtered else null }, out);
        },
        .chunk_radius => {
            const radius: *const abi.ChunkRadius = @ptrCast(@alignCast(data));
            if (radius.max_radius > 255) return error.InvalidArgument;
            return write(header, protocol.packets.request_chunk_radius.Packet{ .chunk_radius = radius.radius, .max_chunk_radius = @intCast(radius.max_radius) }, out);
        },
        else => return error.Unsupported,
    }
}

fn write(header: protocol.packet.Header, packet: anytype, out: []u8) Error!usize {
    var counter: protocol.CountingWriter = .{};
    counter.writeVarU32(header.toWire()) catch return error.InvalidArgument;
    packet.encode(&counter) catch return error.InvalidArgument;
    if (counter.cursor > out.len) return error.InvalidArgument;
    var writer = protocol.Writer.init(out);
    writer.writeVarU32(header.toWire()) catch return error.InvalidArgument;
    packet.encode(&writer) catch return error.InvalidArgument;
    return writer.written().len;
}

fn string(value: abi.Str, maximum: usize, out: []u8) Error![]const u8 {
    if (value.len > maximum or (value.len != 0 and value.ptr == null)) return error.InvalidArgument;
    const bytes = value.slice();
    if (overlaps(bytes.ptr, bytes.len, out)) return error.InvalidArgument;
    return bytes;
}

pub fn overlaps(ptr: *const anyopaque, len: usize, buffer: []const u8) bool {
    if (len == 0 or buffer.len == 0) return false;
    const start = @intFromPtr(ptr);
    const target = @intFromPtr(buffer.ptr);
    return if (start <= target) target - start < len else start - target < buffer.len;
}

test "native decoded text variants round trip without allocating or losing headers" {
    var buffer: [1024]u8 = undefined;
    const header: protocol.packet.Header = .{ .packet_id = protocol.Current.packetId(.text).?, .sender_subclient = 2, .target_subclient = 3 };
    for (0..12) |tag| {
        var text: abi.Text = .{ .message_type = @fromBackingInt(@intCast(tag)), .message = .of("hello"), .localize = 1, .xuid = .of("123"), .platform_id = .of("platform"), .has_filtered_message = 1, .filtered_message = .of("") };
        switch (text.message_type) {
            .chat, .whisper, .announcement => text.source = .of("Steve"),
            .translate, .popup, .jukebox_popup => {
                text.parameter_count = 2;
                text.parameters[0] = .of("one");
                text.parameters[1] = .of("two");
            },
            else => {},
        }
        const bytes = buffer[0..try encode(header, .text, &text, &buffer)];
        const result = (try decode(bytes, .text, .{})).text;
        try std.testing.expectEqual(header.toWire(), (try protocol.packet.decode(bytes, .{})).header.toWire());
        try std.testing.expectEqual(text.message_type, result.message_type);
        try std.testing.expectEqual(text.localize, result.localize);
        try std.testing.expectEqual(text.has_filtered_message, result.has_filtered_message);
        try std.testing.expectEqual(text.parameter_count, result.parameter_count);
        inline for (.{ "source", "message", "xuid", "platform_id", "filtered_message" }) |field| try std.testing.expectEqualSlices(u8, @field(text, field).slice(), @field(result, field).slice());
        for (text.parameters[0..text.parameter_count], result.parameters[0..result.parameter_count]) |expected, actual| try std.testing.expectEqualSlices(u8, expected.slice(), actual.slice());
        const message = result.message.slice();
        try std.testing.expect(@intFromPtr(message.ptr) >= @intFromPtr(bytes.ptr) and @intFromPtr(message.ptr) - @intFromPtr(bytes.ptr) + message.len <= bytes.len);
        try std.testing.expectError(error.InvalidArgument, decode(bytes[0 .. bytes.len - 1], .text, .{}));
    }
}

test "native numeric fields preserve signed boundaries" {
    var buffer: [16]u8 = undefined;
    const header: protocol.packet.Header = .{ .packet_id = protocol.Current.packetId(.request_chunk_radius).? };
    for ([_]i32{ std.math.minInt(i32), -1, 0, 8, std.math.maxInt(i32) }) |radius| {
        const value: abi.ChunkRadius = .{ .radius = radius, .max_radius = 255 };
        const bytes = buffer[0..try encode(header, .chunk_radius, &value, &buffer)];
        const decoded = (try decode(bytes, .chunk_radius, .{})).chunk_radius;
        try std.testing.expectEqual(value.radius, decoded.radius);
        try std.testing.expectEqual(value.max_radius, decoded.max_radius);
        try std.testing.expectError(error.Unsupported, decode(bytes, .text, .{}));
    }
    const invalid: abi.ChunkRadius = .{ .radius = 8, .max_radius = 256 };
    try std.testing.expectError(error.InvalidArgument, encode(header, .chunk_radius, &invalid, &buffer));
}

test "native text encoding rejects invalid data and output aliasing before writing" {
    var out: [128]u8 = @splat(0xaa);
    const header: protocol.packet.Header = .{ .packet_id = protocol.Current.packetId(.text).? };
    var text: abi.Text = .{ .message = .of("hello") };
    text.localize = 2;
    try std.testing.expectError(error.InvalidArgument, encode(header, .text, &text, &out));
    text.localize = 0;
    text.message = .{ .len = 1 };
    try std.testing.expectError(error.InvalidArgument, encode(header, .text, &text, &out));
    text.message = .of(&.{0xff});
    try std.testing.expectError(error.InvalidArgument, encode(header, .text, &text, &out));
    text.message = .of(out[0..1]);
    try std.testing.expectError(error.InvalidArgument, encode(header, .text, &text, &out));
    text.message = .of("hello");
    text.parameter_count = 5;
    try std.testing.expectError(error.InvalidArgument, encode(header, .text, &text, &out));
    text.parameter_count = 0;
    try std.testing.expectError(error.InvalidArgument, encode(header, .text, &text, out[0..2]));
    try std.testing.expectEqualSlices(u8, &@as([128]u8, @splat(0xaa)), &out);
    try std.testing.expectError(error.InvalidArgument, decode(&.{ 9, 0xff }, .text, .{}));
    try std.testing.expectError(error.Unsupported, decode(&.{ 9, 0 }, @fromBackingInt(99), .{}));
}
