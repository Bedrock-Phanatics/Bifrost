const std = @import("std");
const raknet = @import("raknet");
const Notify = @import("../net/Notify.zig");

const Dial = @This();

pub const ConnectError = @typeInfo(@typeInfo(@TypeOf(raknet.Client.connect)).@"fn".return_type.?).error_union.error_set;

done: std.atomic.Value(bool) = .init(false),
result: ConnectError!*raknet.Client = undefined,

pub fn run(self: *Dial, gpa: std.mem.Allocator, io: std.Io, address: std.Io.net.IpAddress, options: raknet.ClientOptions, notify: Notify) void {
    self.result = raknet.Client.connect(gpa, io, address, options);
    self.done.store(true, .release);
    notify.send();
}

pub fn finished(self: *const Dial) ?(ConnectError!*raknet.Client) {
    if (!self.done.load(.acquire)) return null;
    return self.result;
}
