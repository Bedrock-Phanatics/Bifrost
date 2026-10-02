const std = @import("std");
const Link = @import("Link.zig");
const Notify = @import("../net/Notify.zig");

const Scheduler = @This();

io: std.Io,
wake: std.Io.Event = .unset,
ready: std.atomic.Value(?*Link) = .init(null),

pub fn schedule(self: *Scheduler, link: *Link) void {
    if (link.queued.swap(true, .acq_rel)) return;
    var head = self.ready.load(.monotonic);
    while (true) {
        link.next_ready = head;
        head = self.ready.cmpxchgWeak(head, link, .release, .monotonic) orelse return;
    }
}

pub fn takeReady(self: *Scheduler) ?*Link {
    return self.ready.swap(null, .acquire);
}

pub fn hasReady(self: *const Scheduler) bool {
    return self.ready.load(.monotonic) != null;
}

pub fn wakeNotify(self: *Scheduler) Notify {
    return .{ .context = self, .call = wakeOnly };
}

pub fn linkNotify(link: *Link) Notify {
    return .{ .context = link, .call = notifyLink };
}

fn wakeOnly(context: *anyopaque) void {
    const self: *Scheduler = @ptrCast(@alignCast(context));
    self.wake.set(self.io);
}

fn notifyLink(context: *anyopaque) void {
    const link: *Link = @ptrCast(@alignCast(context));
    const self = link.env.scheduler;
    self.schedule(link);
    self.wake.set(self.io);
}
