const std = @import("std");
const IpAddress = std.Io.net.IpAddress;

const Backend = @This();

// Room for a bracketed IPv6 address with its port, the default name
pub const max_name_len = 48;

pub const Id = enum(u8) {
    _,

    pub fn of(position: usize) Id {
        return @fromBackingInt(@intCast(position));
    }

    pub fn index(self: Id) usize {
        return @backingInt(self);
    }
};

address: IpAddress,
name_len: u8,
name_storage: [max_name_len]u8,

pub const InitError = error{ InvalidPort, InvalidName };

pub fn init(name_text: ?[]const u8, address: IpAddress) InitError!Backend {
    if (address.getPort() == 0) return error.InvalidPort;
    var self: Backend = .{ .address = address, .name_len = 0, .name_storage = undefined };
    const text = name_text orelse std.fmt.bufPrint(&self.name_storage, "{f}", .{address}) catch return error.InvalidName;
    if (!validName(text)) return error.InvalidName;
    std.mem.copyForwards(u8, &self.name_storage, text);
    self.name_len = @intCast(text.len);
    return self;
}

pub fn name(self: *const Backend) []const u8 {
    return self.name_storage[0..self.name_len];
}

pub fn validName(text: []const u8) bool {
    if (text.len == 0 or text.len > max_name_len) return false;
    for (text) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.', ':', '[', ']' => {},
        else => return false,
    };
    return true;
}

pub fn format(self: Backend, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var buffer: [max_name_len]u8 = undefined;
    const address_text = std.fmt.bufPrint(&buffer, "{f}", .{self.address}) catch "";
    if (std.mem.eql(u8, address_text, self.name())) return w.writeAll(self.name());
    try w.print("{s} ({f})", .{ self.name(), self.address });
}

test "unnamed backends are named after their address" {
    const v4 = try init(null, .{ .ip4 = .loopback(19133) });
    try std.testing.expectEqualStrings("127.0.0.1:19133", v4.name());
    const v6 = try init(null, try IpAddress.parseLiteral("[ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff]:65535"));
    try std.testing.expectEqualStrings("[ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff]:65535", v6.name());
}

test "format shows the address only when it isn't the name" {
    var buffer: [96]u8 = undefined;
    try std.testing.expectEqualStrings("127.0.0.1:1", try std.fmt.bufPrint(&buffer, "{f}", .{try init(null, .{ .ip4 = .loopback(1) })}));
    try std.testing.expectEqualStrings("lobby (127.0.0.1:1)", try std.fmt.bufPrint(&buffer, "{f}", .{try init("lobby", .{ .ip4 = .loopback(1) })}));
}

test "names are bounded and plain" {
    const address: IpAddress = .{ .ip4 = .loopback(1) };
    try std.testing.expectEqualStrings("lobby-1", (try init("lobby-1", address)).name());
    try std.testing.expectError(error.InvalidName, init("", address));
    try std.testing.expectError(error.InvalidName, init("has space", address));
    try std.testing.expectError(error.InvalidName, init(&@as([max_name_len + 1]u8, @splat('a')), address));
    try std.testing.expectError(error.InvalidPort, init("lobby", .{ .ip4 = .loopback(0) }));
}
