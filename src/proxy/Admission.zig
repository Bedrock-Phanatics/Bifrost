const std = @import("std");
const IpAddress = std.Io.net.IpAddress;

const Admission = @This();

pub const Refusal = error{ ServerFull, TooManyFromAddress };

gpa: std.mem.Allocator,
limit: u32,
per_address: u32,
active: std.atomic.Value(u32) = .init(0),
mutex: std.Io.Mutex = .init,
by_address: std.AutoArrayHashMapUnmanaged([16]u8, u32) = .empty,

pub fn init(gpa: std.mem.Allocator, limit: u32, per_address: u32) error{OutOfMemory}!Admission {
    var self: Admission = .{ .gpa = gpa, .limit = limit, .per_address = per_address };
    // Every entry holds a player, so this never has to grow while players connect
    if (per_address != 0) try self.by_address.ensureTotalCapacity(gpa, limit);
    return self;
}

pub fn deinit(self: *Admission) void {
    self.by_address.deinit(self.gpa);
}

pub fn enter(self: *Admission, io: std.Io, address: IpAddress) Refusal!void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    const active = self.active.load(.monotonic);
    if (active >= self.limit) return error.ServerFull;
    if (self.per_address != 0) {
        const entry = self.by_address.getOrPutAssumeCapacity(key(address));
        if (!entry.found_existing) entry.value_ptr.* = 0;
        if (entry.value_ptr.* >= self.per_address) return error.TooManyFromAddress;
        entry.value_ptr.* += 1;
    }
    self.active.store(active + 1, .monotonic);
}

pub fn leave(self: *Admission, io: std.Io, address: IpAddress) void {
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    if (self.per_address != 0) {
        const entry = self.by_address.getEntry(key(address)).?;
        entry.value_ptr.* -= 1;
        if (entry.value_ptr.* == 0) _ = self.by_address.swapRemove(key(address));
    }
    self.active.store(self.active.load(.monotonic) - 1, .monotonic);
}

fn key(address: IpAddress) [16]u8 {
    return switch (address) {
        .ip4 => |ip4| [_]u8{0} ** 10 ++ [_]u8{ 0xff, 0xff } ++ ip4.bytes,
        .ip6 => |ip6| ip6.bytes,
    };
}

test "never admits past the global limit" {
    const io = std.testing.io;
    var admission: Admission = try .init(std.testing.allocator, 2, 0);
    defer admission.deinit();
    const player: IpAddress = .{ .ip4 = .loopback(1) };
    try admission.enter(io, player);
    try admission.enter(io, player);
    try std.testing.expectError(error.ServerFull, admission.enter(io, player));
    admission.leave(io, player);
    try admission.enter(io, player);
}

test "caps players per address, ignoring the port" {
    const io = std.testing.io;
    var admission: Admission = try .init(std.testing.allocator, 10, 2);
    defer admission.deinit();
    const home: IpAddress = .{ .ip4 = .{ .bytes = .{ 10, 0, 0, 1 }, .port = 1 } };
    const same_home: IpAddress = .{ .ip4 = .{ .bytes = .{ 10, 0, 0, 1 }, .port = 2 } };
    const elsewhere: IpAddress = .{ .ip4 = .{ .bytes = .{ 10, 0, 0, 2 }, .port = 1 } };

    try admission.enter(io, home);
    try admission.enter(io, same_home);
    try std.testing.expectError(error.TooManyFromAddress, admission.enter(io, home));
    try admission.enter(io, elsewhere);
    admission.leave(io, home);
    try admission.enter(io, same_home);

    for (0..2) |_| admission.leave(io, home);
    admission.leave(io, elsewhere);
    try std.testing.expectEqual(@as(usize, 0), admission.by_address.count());
    try std.testing.expectEqual(@as(u32, 0), admission.active.load(.monotonic));
}

test "admitting never allocates" {
    const io = std.testing.io;
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{});
    var admission: Admission = try .init(failing.allocator(), 64, 1);
    defer admission.deinit();
    failing.fail_index = failing.alloc_index;
    for (0..64) |i| try admission.enter(io, .{ .ip4 = .{ .bytes = .{ 10, 0, 0, @intCast(i) }, .port = 1 } });
    for (0..64) |i| admission.leave(io, .{ .ip4 = .{ .bytes = .{ 10, 0, 0, @intCast(i) }, .port = 1 } });
}
