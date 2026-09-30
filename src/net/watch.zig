const std = @import("std");

pub const Notify = struct {
    context: *anyopaque,
    call: *const fn (*anyopaque) void,

    pub fn send(self: Notify) void {
        self.call(self.context);
    }
};

pub fn Watch(comptime T: type) type {
    return struct {
        const Self = @This();

        ready: std.atomic.Value(bool) = .init(false),
        future: ?std.Io.Future(void) = null,
        deadline: ?u64 = null,

        pub fn arm(self: *Self, io: std.Io, target: *T, notify: Notify) std.Io.ConcurrentError!void {
            const deadline = target.nextDeadline();
            if (self.future != null) {
                if (self.ready.load(.acquire)) return;
                const earlier = if (deadline) |due| self.deadline == null or due < self.deadline.? else false;
                if (!earlier) return;
                self.cancel(io);
            }
            self.future = try io.concurrent(run, .{ &self.ready, target, target.pollTimeout(.none), notify });
            self.deadline = deadline;
        }

        pub fn take(self: *Self, io: std.Io) bool {
            if (!self.ready.swap(false, .acquire)) return false;
            if (self.future) |*future| future.await(io);
            self.future = null;
            return true;
        }

        pub fn cancel(self: *Self, io: std.Io) void {
            if (self.future) |*future| future.cancel(io);
            self.future = null;
            self.ready.store(false, .monotonic);
        }

        fn run(ready: *std.atomic.Value(bool), target: *const T, timeout: std.Io.Timeout, notify: Notify) void {
            target.waitReadable(timeout) catch |err| if (err == error.Canceled) return;
            ready.store(true, .release);
            notify.send();
        }
    };
}
