const std = @import("std");
const abi = @import("abi.zig");
const Notify = @import("../net/Notify.zig");
const Packets = @import("Packets.zig");

pub const max_message_bytes = 1024;

// True while we're the ones calling into a plugin
pub threadlocal var hosted: bool = false;

pub fn enter() bool {
    const outer = hosted;
    hosted = true;
    return outer;
}

pub const Done = struct {
    done: abi.TaskDoneFn,
    user: ?*anyopaque,
    player: abi.Player,
    name: []const u8,
    metrics: []Packets.Metrics,
};

pub const Task = struct {
    run: abi.TaskFn,
    outstanding: *std.atomic.Value(u32),
    then: Done,
};

pub const Message = struct {
    player: abi.Player,
    len: usize,
    text: [max_message_bytes]u8,
};

pub const Item = union(enum) {
    task: *Task,
    message: *Message,
    post: *Done,
};

// Anyone can post, only the owning worker takes
pub const Queue = struct {
    lock: std.atomic.Value(bool) = .init(false),
    items: std.ArrayList(Item) = .empty,
    taken: std.ArrayList(Item) = .empty,
    closed: bool = false,
    notify: ?Notify = null,

    pub fn init(gpa: std.mem.Allocator, capacity: usize) !Queue {
        var queue: Queue = .{};
        errdefer queue.deinit(gpa);
        try queue.items.ensureTotalCapacity(gpa, capacity);
        try queue.taken.ensureTotalCapacity(gpa, capacity);
        return queue;
    }

    pub fn deinit(self: *Queue, gpa: std.mem.Allocator) void {
        self.items.deinit(gpa);
        self.taken.deinit(gpa);
    }

    // Callers bound the total, so this never grows
    pub fn post(self: *Queue, item: Item) bool {
        self.enter();
        const open = !self.closed;
        if (open) self.items.appendAssumeCapacity(item);
        self.leave();
        if (open) if (self.notify) |notify| notify.send();
        return open;
    }

    pub fn close(self: *Queue) void {
        self.enter();
        self.closed = true;
        self.leave();
    }

    pub fn take(self: *Queue) []const Item {
        self.taken.clearRetainingCapacity();
        self.enter();
        std.mem.swap(std.ArrayList(Item), &self.items, &self.taken);
        self.leave();
        return self.taken.items;
    }

    fn enter(self: *Queue) void {
        while (self.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    fn leave(self: *Queue) void {
        self.lock.store(false, .release);
    }
};

pub fn reserve(counter: *std.atomic.Value(u32), limit: u32) bool {
    var current = counter.load(.monotonic);
    while (current < limit) {
        current = counter.cmpxchgWeak(current, current + 1, .acq_rel, .monotonic) orelse return true;
    }
    return false;
}

pub fn release(counter: *std.atomic.Value(u32)) void {
    _ = counter.fetchSub(1, .acq_rel);
}

test "a queue hands everything posted so far to its worker" {
    const gpa = std.testing.allocator;
    var queue: Queue = try .init(gpa, 4);
    defer queue.deinit(gpa);
    var message: Message = undefined;
    try std.testing.expect(queue.post(.{ .message = &message }));
    try std.testing.expect(queue.post(.{ .message = &message }));
    try std.testing.expectEqual(@as(usize, 2), queue.take().len);
    try std.testing.expect(queue.post(.{ .message = &message }));
    queue.close();
    try std.testing.expect(!queue.post(.{ .message = &message }));
    try std.testing.expectEqual(@as(usize, 1), queue.take().len);
    try std.testing.expectEqual(@as(usize, 0), queue.take().len);

    var counter: std.atomic.Value(u32) = .init(0);
    try std.testing.expect(reserve(&counter, 2));
    try std.testing.expect(reserve(&counter, 2));
    try std.testing.expect(!reserve(&counter, 2));
    release(&counter);
    try std.testing.expect(reserve(&counter, 2));
}
