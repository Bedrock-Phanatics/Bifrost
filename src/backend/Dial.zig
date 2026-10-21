const std = @import("std");
const NetherNet = @import("../net/NetherNet.zig");
const Notify = @import("../net/Notify.zig");

const Dial = @This();

pub const Result = anyerror!*NetherNet.Connection;

done: std.atomic.Value(bool) = .init(false),
result: Result = undefined,

pub fn run(self: *Dial, transport: *const NetherNet, address: std.Io.net.IpAddress, notify: Notify) void {
    self.result = transport.dial(address);
    self.done.store(true, .release);
    notify.send();
}

pub fn finished(self: *const Dial) ?Result {
    if (!self.done.load(.acquire)) return null;
    return self.result;
}

/// Cancels a running dial and closes whatever it managed to open.
pub fn cancel(self: *Dial, task: *std.Io.Future(void), io: std.Io) void {
    task.cancel(io);
    if (self.finished()) |result| {
        if (result) |connection| connection.destroy() else |_| {}
    }
}
