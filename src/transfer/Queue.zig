const std = @import("std");

const Queue = @This();

bytes: std.ArrayList(u8) = .empty,
lengths: std.ArrayList(u32) = .empty,
max_packets: usize,
max_bytes: usize,

pub fn push(self: *Queue, gpa: std.mem.Allocator, packet: []const u8) !void {
    if (self.lengths.items.len == self.max_packets or packet.len > self.max_bytes - self.bytes.items.len) return error.QueueFull;
    try self.lengths.ensureUnusedCapacity(gpa, 1);
    try self.bytes.appendSlice(gpa, packet);
    self.lengths.appendAssumeCapacity(@intCast(packet.len));
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
    self.bytes.deinit(gpa);
    self.lengths.deinit(gpa);
}

pub fn clear(self: *Queue) void {
    self.bytes.clearRetainingCapacity();
    self.lengths.clearRetainingCapacity();
}
