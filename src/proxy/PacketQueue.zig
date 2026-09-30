const std = @import("std");
const Allocator = std.mem.Allocator;

const PacketQueue = @This();

packets: std.ArrayList([]u8) = .empty,
bytes: usize = 0,
max_packets: usize,
max_bytes: usize,

pub fn init(max_packets: usize, max_bytes: usize) PacketQueue {
    return .{ .max_packets = max_packets, .max_bytes = max_bytes };
}

pub fn deinit(self: *PacketQueue, gpa: Allocator) void {
    self.clear(gpa);
    self.packets.deinit(gpa);
}

pub fn push(self: *PacketQueue, gpa: Allocator, payload: []const u8) error{ QueueFull, OutOfMemory }!void {
    if (self.packets.items.len == self.max_packets or payload.len > self.max_bytes - self.bytes) return error.QueueFull;
    try self.packets.ensureUnusedCapacity(gpa, 1);
    self.packets.appendAssumeCapacity(try gpa.dupe(u8, payload));
    self.bytes += payload.len;
}

pub fn items(self: *const PacketQueue) []const []u8 {
    return self.packets.items;
}

pub fn clear(self: *PacketQueue, gpa: Allocator) void {
    for (self.packets.items) |packet| gpa.free(packet);
    self.packets.clearRetainingCapacity();
    self.bytes = 0;
}

test "push enforces packet and byte limits without partial state" {
    const gpa = std.testing.allocator;
    var queue: PacketQueue = .init(2, 5);
    defer queue.deinit(gpa);

    try queue.push(gpa, "abc");
    try std.testing.expectError(error.QueueFull, queue.push(gpa, "abc"));
    try queue.push(gpa, "de");
    try std.testing.expectError(error.QueueFull, queue.push(gpa, ""));
    try std.testing.expectEqual(@as(usize, 5), queue.bytes);
    try std.testing.expectEqualStrings("abc", queue.items()[0]);
    try std.testing.expectEqualStrings("de", queue.items()[1]);

    queue.clear(gpa);
    try std.testing.expectEqual(@as(usize, 0), queue.bytes);
    try queue.push(gpa, "fghij");
}

test "push releases nothing on allocation failure" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 1 });
    const gpa = failing.allocator();
    var queue: PacketQueue = .init(4, 64);
    defer queue.deinit(gpa);
    try std.testing.expectError(error.OutOfMemory, queue.push(gpa, "abc"));
    try std.testing.expectEqual(@as(usize, 0), queue.bytes);
    try std.testing.expectEqual(@as(usize, 0), queue.items().len);
}
