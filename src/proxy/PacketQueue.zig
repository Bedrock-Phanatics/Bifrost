const std = @import("std");
const Budget = @import("Budget.zig");
const Allocator = std.mem.Allocator;

const PacketQueue = @This();

packets: std.ArrayList([]u8) = .empty,
bytes: usize = 0,
max_packets: usize,
max_bytes: usize,
budget: ?*Budget,

pub fn init(max_packets: usize, max_bytes: usize, budget: ?*Budget) PacketQueue {
    return .{ .max_packets = max_packets, .max_bytes = max_bytes, .budget = budget };
}

pub fn deinit(self: *PacketQueue, gpa: Allocator) void {
    self.clear(gpa);
    self.packets.deinit(gpa);
}

pub fn push(self: *PacketQueue, gpa: Allocator, payload: []const u8) error{ QueueFull, Overloaded, OutOfMemory }!void {
    if (self.packets.items.len == self.max_packets or payload.len > self.max_bytes - self.bytes) return error.QueueFull;
    if (self.budget) |budget| if (!budget.reserve(payload.len)) return error.Overloaded;
    errdefer if (self.budget) |budget| budget.release(payload.len);
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
    if (self.budget) |budget| budget.release(self.bytes);
    self.bytes = 0;
}

test "push enforces packet and byte limits without partial state" {
    const gpa = std.testing.allocator;
    var queue: PacketQueue = .init(2, 5, null);
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
    var budget: Budget = .init(64);
    var queue: PacketQueue = .init(4, 64, &budget);
    defer queue.deinit(gpa);
    try std.testing.expectError(error.OutOfMemory, queue.push(gpa, "abc"));
    try std.testing.expectEqual(@as(usize, 0), queue.bytes);
    try std.testing.expectEqual(@as(usize, 0), queue.items().len);
    try std.testing.expectEqual(@as(usize, 0), budget.used.load(.monotonic));
}

test "thousands of queues within their own limits still share one budget" {
    const gpa = std.testing.allocator;
    var budget: Budget = .init(1024 * 1024);
    const queues = try gpa.alloc(PacketQueue, 4096);
    defer gpa.free(queues);
    for (queues) |*queue| queue.* = .init(64, 4096, &budget);
    defer for (queues) |*queue| queue.deinit(gpa);
    const packet: [512]u8 = @splat(1);
    var refused: usize = 0;
    for (0..2) |_| for (queues) |*queue| {
        queue.push(gpa, &packet) catch |err| {
            try std.testing.expectEqual(error.Overloaded, err);
            refused += 1;
        };
    };
    try std.testing.expectEqual(budget.limit, budget.used.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 2 * 4096 - budget.limit / packet.len), refused);
    for (queues) |*queue| queue.clear(gpa);
    try std.testing.expectEqual(@as(usize, 0), budget.used.load(.monotonic));
    for (queues[0..8]) |*queue| try queue.push(gpa, &packet);
}
