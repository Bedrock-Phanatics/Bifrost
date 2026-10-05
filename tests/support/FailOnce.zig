const std = @import("std");

// FailingAllocator isn't thread-safe, and dials allocate on their own tasks
const FailOnce = @This();

child: std.mem.Allocator,
fail_at: usize,
count: std.atomic.Value(usize) = .init(0),
armed: std.atomic.Value(bool) = .init(true),
live: std.atomic.Value(usize) = .init(0),

pub fn allocator(self: *FailOnce) std.mem.Allocator {
    return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
}

pub fn allocations(self: *const FailOnce) usize {
    return self.count.load(.acquire);
}

pub fn liveBytes(self: *const FailOnce) usize {
    return self.live.load(.acquire);
}

fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const self: *FailOnce = @ptrCast(@alignCast(context));
    if (self.armed.load(.acquire) and self.count.fetchAdd(1, .acq_rel) == self.fail_at) return null;
    const memory = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
    _ = self.live.fetchAdd(len, .acq_rel);
    return memory;
}

fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    const self: *FailOnce = @ptrCast(@alignCast(context));
    if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
    self.moved(memory.len, new_len);
    return true;
}

fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const self: *FailOnce = @ptrCast(@alignCast(context));
    const remapped = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
    self.moved(memory.len, new_len);
    return remapped;
}

fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    const self: *FailOnce = @ptrCast(@alignCast(context));
    self.child.rawFree(memory, alignment, ret_addr);
    _ = self.live.fetchSub(memory.len, .acq_rel);
}

fn moved(self: *FailOnce, old_len: usize, new_len: usize) void {
    if (new_len > old_len) _ = self.live.fetchAdd(new_len - old_len, .acq_rel) else _ = self.live.fetchSub(old_len - new_len, .acq_rel);
}
