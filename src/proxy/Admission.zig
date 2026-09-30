const std = @import("std");

const Admission = @This();

limit: u32,
active: std.atomic.Value(u32) = .init(0),

pub fn init(limit: u32) Admission {
    return .{ .limit = limit };
}

pub fn tryEnter(self: *Admission) bool {
    var active = self.active.load(.monotonic);
    while (active < self.limit) {
        active = self.active.cmpxchgWeak(active, active + 1, .acq_rel, .monotonic) orelse return true;
    }
    return false;
}

pub fn leave(self: *Admission) void {
    const previous = self.active.fetchSub(1, .release);
    std.debug.assert(previous != 0);
}

test "never admits past the limit" {
    var admission: Admission = .init(2);
    try std.testing.expect(admission.tryEnter());
    try std.testing.expect(admission.tryEnter());
    try std.testing.expect(!admission.tryEnter());
    admission.leave();
    try std.testing.expect(admission.tryEnter());
}
