const std = @import("std");
const Work = @import("Work.zig");

const Pool = @This();

pub const max_threads = 64;

// Only used for futexes, which work from any thread
const io = std.Io.Threaded.global_single_threaded.io();

gpa: std.mem.Allocator,
context: *anyopaque,
run: *const fn (context: *anyopaque, task: *Work.Task) void,
threads: []std.Thread,
ring: []*Work.Task,
head: usize = 0,
len: usize = 0,
stopping: std.atomic.Value(bool) = .init(false),
lock: std.atomic.Value(bool) = .init(false),
signal: std.atomic.Value(u32) = .init(0),

pub fn create(gpa: std.mem.Allocator, threads: u32, capacity: u32, context: *anyopaque, run: *const fn (*anyopaque, *Work.Task) void) !*Pool {
    const self = try gpa.create(Pool);
    errdefer gpa.destroy(self);
    const ring = try gpa.alloc(*Work.Task, capacity);
    errdefer gpa.free(ring);
    const handles = try gpa.alloc(std.Thread, threads);
    errdefer gpa.free(handles);
    self.* = .{ .gpa = gpa, .context = context, .run = run, .threads = handles[0..0], .ring = ring };
    errdefer self.stop();
    for (handles) |*handle| {
        handle.* = try std.Thread.spawn(.{}, loop, .{self});
        self.threads.len += 1;
    }
    self.threads = handles;
    return self;
}

pub fn destroy(self: *Pool) void {
    std.debug.assert(self.stopping.load(.monotonic) and self.len == 0);
    self.gpa.free(self.threads);
    self.gpa.free(self.ring);
    self.gpa.destroy(self);
}

pub fn submit(self: *Pool, task: *Work.Task) bool {
    self.enter();
    const accepted = !self.stopping.load(.monotonic) and self.len < self.ring.len;
    if (accepted) {
        self.ring[(self.head + self.len) % self.ring.len] = task;
        self.len += 1;
    }
    self.leave();
    if (accepted) self.wake(1);
    return accepted;
}

pub fn stop(self: *Pool) void {
    self.enter();
    self.stopping.store(true, .release);
    self.leave();
    self.wake(std.math.maxInt(u32));
    for (self.threads) |thread| thread.join();
}

pub fn take(self: *Pool) ?*Work.Task {
    self.enter();
    defer self.leave();
    return self.pop();
}

fn pop(self: *Pool) ?*Work.Task {
    if (self.len == 0) return null;
    const task = self.ring[self.head];
    self.head = (self.head + 1) % self.ring.len;
    self.len -= 1;
    return task;
}

fn loop(self: *Pool) void {
    while (true) {
        const seen = self.signal.load(.acquire);
        self.enter();
        const stopping = self.stopping.load(.monotonic);
        const task = if (stopping) null else self.pop();
        self.leave();
        if (stopping) return;
        if (task) |next| self.run(self.context, next) else io.futexWaitUncancelable(u32, &self.signal.raw, seen);
    }
}

fn wake(self: *Pool, count: u32) void {
    _ = self.signal.fetchAdd(1, .release);
    io.futexWake(u32, &self.signal.raw, count);
}

fn enter(self: *Pool) void {
    while (self.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn leave(self: *Pool) void {
    self.lock.store(false, .release);
}
