const std = @import("std");

const online_field = 4;
const max_field = 5;

pub fn players(advertisement: []const u8) ?u32 {
    var fields = std.mem.splitScalar(u8, advertisement, ';');
    const edition = fields.first();
    if (!std.mem.eql(u8, edition, "MCPE") and !std.mem.eql(u8, edition, "MCEE")) return null;
    for (1..online_field) |_| _ = fields.next() orelse return null;
    const text = fields.next() orelse return null;
    return std.fmt.parseInt(u32, text, 10) catch null;
}

pub fn render(dest: []u8, template: []const u8, online: u32, max: u32) error{NoSpaceLeft}![]const u8 {
    var writer: std.Io.Writer = .fixed(dest);
    var fields = std.mem.splitScalar(u8, template, ';');
    var index: usize = 0;
    while (fields.next()) |field| : (index += 1) {
        if (index != 0) writer.writeByte(';') catch return error.NoSpaceLeft;
        const result = switch (index) {
            online_field => writer.print("{d}", .{online}),
            max_field => writer.print("{d}", .{max}),
            else => writer.writeAll(field),
        };
        result catch return error.NoSpaceLeft;
    }
    return writer.buffered();
}

test "players reads the online count" {
    try std.testing.expectEqual(@as(?u32, 12), players("MCPE;Lobby;944;1.26.0;12;100;123;Sub;Survival;1;19132;19133;"));
    try std.testing.expectEqual(@as(?u32, 0), players("MCEE;Edu;944;1.26.0;0;20;"));
}

test "players rejects malformed advertisements" {
    try std.testing.expectEqual(@as(?u32, null), players(""));
    try std.testing.expectEqual(@as(?u32, null), players("MCPE;backend"));
    try std.testing.expectEqual(@as(?u32, null), players("JAVA;a;1;1;5;10;"));
    try std.testing.expectEqual(@as(?u32, null), players("MCPE;a;1;1;-5;10;"));
    try std.testing.expectEqual(@as(?u32, null), players("MCPE;a;1;1;4294967296;10;"));
    try std.testing.expectEqual(@as(?u32, null), players("MCPE;a;1;1;lots;10;"));
}

test "render replaces only the player fields" {
    var buffer: [128]u8 = undefined;
    const template = "MCPE;MyProxy;944;1.26.0;0;100;77;Sub;Survival;1;19132;19133;";
    try std.testing.expectEqualStrings(
        "MCPE;MyProxy;944;1.26.0;4294967295;4096;77;Sub;Survival;1;19132;19133;",
        try render(&buffer, template, std.math.maxInt(u32), 4096),
    );
    try std.testing.expectEqualStrings("MCPE;short", try render(&buffer, "MCPE;short", 5, 10));
    try std.testing.expectError(error.NoSpaceLeft, render(buffer[0..10], template, 1, 1));
}
