const std = @import("std");
const abi = @import("abi.zig");

const Handles = @This();

pub const max_name_len = 64;

pub const Route = struct {
    context: *anyopaque,
    link: u64,
    transfer: *const fn (context: *anyopaque, link: u64, backend: u32) abi.Status,
};

const Slot = struct {
    generation: u32 = 1,
    route: ?Route = null,
    name: [max_name_len]u8 = undefined,
    name_len: u8 = 0,
};

lock: std.atomic.Value(bool) = .init(false),
slots: std.ArrayList(Slot) = .empty,
free: std.ArrayList(u32) = .empty,

pub fn deinit(self: *Handles, gpa: std.mem.Allocator) void {
    self.slots.deinit(gpa);
    self.free.deinit(gpa);
}

pub fn acquire(self: *Handles, gpa: std.mem.Allocator, to: Route) !abi.Player {
    self.enter();
    defer self.leave();
    try self.free.ensureTotalCapacity(gpa, self.slots.items.len + 1);
    const index = self.free.pop() orelse index: {
        if (self.slots.items.len == std.math.maxInt(u32)) return error.TooManyPlayers;
        try self.slots.append(gpa, .{});
        break :index @as(u32, @intCast(self.slots.items.len - 1));
    };
    const slot = &self.slots.items[index];
    slot.route = to;
    slot.name_len = 0;
    return handle(index, slot.generation);
}

pub fn release(self: *Handles, player: abi.Player) void {
    self.enter();
    defer self.leave();
    const index, const slot = self.find(player) orelse return;
    slot.route = null;
    slot.generation +%= 1;
    if (slot.generation == 0) slot.generation = 1;
    self.free.appendAssumeCapacity(index);
}

pub fn setName(self: *Handles, player: abi.Player, name: []const u8) void {
    self.enter();
    defer self.leave();
    _, const slot = self.find(player) orelse return;
    const len = @min(name.len, max_name_len);
    @memcpy(slot.name[0..len], name[0..len]);
    slot.name_len = @intCast(len);
}

pub fn copyName(self: *Handles, player: abi.Player, out: []u8) ?usize {
    self.enter();
    defer self.leave();
    _, const slot = self.find(player) orelse return null;
    const len = @min(out.len, slot.name_len);
    @memcpy(out[0..len], slot.name[0..len]);
    return slot.name_len;
}

pub fn route(self: *Handles, player: abi.Player) ?Route {
    self.enter();
    defer self.leave();
    _, const slot = self.find(player) orelse return null;
    return slot.route;
}

fn find(self: *Handles, player: abi.Player) ?struct { u32, *Slot } {
    const low: u32 = @truncate(player.id);
    if (low == 0 or low > self.slots.items.len) return null;
    const slot = &self.slots.items[low - 1];
    if (slot.route == null or slot.generation != @as(u32, @truncate(player.id >> 32))) return null;
    return .{ low - 1, slot };
}

fn handle(index: u32, generation: u32) abi.Player {
    return .{ .id = @as(u64, generation) << 32 | (index + 1) };
}

fn enter(self: *Handles) void {
    while (self.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn leave(self: *Handles) void {
    self.lock.store(false, .release);
}

fn noTransfer(_: *anyopaque, _: u64, _: u32) abi.Status {
    return .ok;
}

test "a released handle goes stale even after its slot is reused" {
    const gpa = std.testing.allocator;
    var handles: Handles = .{};
    defer handles.deinit(gpa);
    var context: u8 = 0;
    const route_a: Route = .{ .context = &context, .link = 1, .transfer = noTransfer };

    const first = try handles.acquire(gpa, route_a);
    handles.setName(first, "Steve");
    var name: [3]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, 5), handles.copyName(first, &name));
    try std.testing.expectEqualStrings("Ste", &name);

    handles.release(first);
    handles.release(first);
    try std.testing.expectEqual(@as(?Route, null), handles.route(first));
    const second = try handles.acquire(gpa, .{ .context = &context, .link = 2, .transfer = noTransfer });
    try std.testing.expect(first.id != second.id);
    try std.testing.expectEqual(@as(?usize, null), handles.copyName(first, &name));
    try std.testing.expectEqual(@as(u64, 2), handles.route(second).?.link);
    try std.testing.expectEqual(@as(?Route, null), handles.route(.{}));
    try std.testing.expectEqual(@as(?Route, null), handles.route(.{ .id = 99 }));
}
