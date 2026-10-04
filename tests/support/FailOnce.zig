const std = @import("std");

// FailingAllocator isn't thread-safe, and dials allocate on their own tasks
const FailOnce = @This();

child: std.mem.Allocator,
fail_at: usize,
count: std.atomic.Value(usize) = .init(0),

pub fn allocator(self: *FailOnce) std.mem.Allocator {
    return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
}

pub fn allocations(self: *const FailOnce) usize {
    return self.count.load(.acquire);
}

fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const self: *FailOnce = @ptrCast(@alignCast(context));
    if (self.count.fetchAdd(1, .acq_rel) == self.fail_at) return null;
    return self.child.rawAlloc(len, alignment, ret_addr);
}

fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *FailOnce = @ptrCast(@alignCast(context));
    return self.child.rawResize(memory, alignment, new_len, ret_addr);
}

fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self: *FailOnce = @ptrCast(@alignCast(context));
    return self.child.rawRemap(memory, alignment, new_len, ret_addr);
}

fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    const self: *FailOnce = @ptrCast(@alignCast(context));
    self.child.rawFree(memory, alignment, ret_addr);
}
