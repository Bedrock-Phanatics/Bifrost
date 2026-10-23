const std = @import("std");
const Budget = @import("../proxy/Budget.zig");

const Queue = @This();

bytes: std.ArrayList(u8) = .empty,
lengths: std.ArrayList(u32) = .empty,
max_packets: usize,
max_bytes: usize,
budget: ?*Budget = null,

pub fn push(self: *Queue, gpa: std.mem.Allocator, packet: []const u8) !void {
    if (self.lengths.items.len == self.max_packets or packet.len > self.max_bytes - self.bytes.items.len) return error.QueueFull;
    if (self.budget) |budget| if (!budget.reserve(packet.len)) return error.Overloaded;
    errdefer if (self.budget) |budget| budget.release(packet.len);
    try self.lengths.ensureUnusedCapacity(gpa, 1);
    try self.bytes.appendSlice(gpa, packet);
    self.lengths.appendAssumeCapacity(@intCast(packet.len));
}

// Half the limits, so a batch still fits after the sender is told to wait.
pub fn nearlyFull(self: *const Queue) bool {
    return self.lengths.items.len >= self.max_packets / 2 or self.bytes.items.len >= self.max_bytes / 2;
}

pub fn slices(self: *const Queue, out: [][]const u8) []const []const u8 {
    var offset: usize = 0;
    for (self.lengths.items, out[0..self.lengths.items.len]) |len, *slice| {
        slice.* = self.bytes.items[offset..][0..len];
        offset += len;
    }
    return out[0..self.lengths.items.len];
}

pub fn deinit(self: *Queue, gpa: std.mem.Allocator) void {
    self.clear();
    self.bytes.deinit(gpa);
    self.lengths.deinit(gpa);
}

pub fn clear(self: *Queue) void {
    if (self.budget) |budget| budget.release(self.bytes.items.len);
    self.bytes.clearRetainingCapacity();
    self.lengths.clearRetainingCapacity();
}

test "held packets count against the shared budget until cleared" {
    const gpa = std.testing.allocator;
    var budget: Budget = .init(8);
    var queue: Queue = .{ .max_packets = 4, .max_bytes = 64, .budget = &budget };
    defer queue.deinit(gpa);
    try queue.push(gpa, "abcde");
    try std.testing.expectError(error.Overloaded, queue.push(gpa, "fghi"));
    try queue.push(gpa, "fgh");
    try std.testing.expectEqual(@as(usize, 8), budget.used.load(.monotonic));
    queue.clear();
    try std.testing.expectEqual(@as(usize, 0), budget.used.load(.monotonic));
    try queue.push(gpa, "ab");
}

test "nearly full means half the packets or half the bytes" {
    const gpa = std.testing.allocator;
    var queue: Queue = .{ .max_packets = 4, .max_bytes = 16 };
    defer queue.deinit(gpa);
    try queue.push(gpa, "a");
    try std.testing.expect(!queue.nearlyFull());
    try queue.push(gpa, "b");
    try std.testing.expect(queue.nearlyFull());
    queue.clear();
    try queue.push(gpa, "abcdefgh");
    try std.testing.expect(queue.nearlyFull());
}
