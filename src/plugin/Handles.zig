const std = @import("std");
const abi = @import("abi.zig");

const Handles = @This();

pub const max_name_len = 64;

pub const Route = struct {
    context: *anyopaque,
    worker: u32 = 0,
    epoch: u64 = 0,
    link: u64,
    transfer: *const fn (context: *anyopaque, link: u64, backend: u32) abi.Status,
    network: ?*const fn (context: *anyopaque, link: u64, target: abi.PacketTarget, out: *abi.NetworkStats) abi.Status = null,
    io: ?std.Io = null,
};

const Slot = struct {
    generation: u32 = 1,
    route: ?Route = null,
    name: [max_name_len]u8 = undefined,
    name_len: u8 = 0,
    info: abi.PlayerInfo = .{},
    connected_ns: u64 = 0,
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
    slot.info = .{ .worker = to.worker };
    slot.connected_ns = if (to.io) |io| @import("Packets.zig").now(io) else 0;
    return handle(index, slot.generation);
}

pub fn release(self: *Handles, player: abi.Player) void {
    self.enter();
    defer self.leave();
    const index, const slot = self.find(player) orelse return;
    slot.route = null;
    if (slot.generation == std.math.maxInt(u32)) return;
    slot.generation += 1;
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

pub fn setIdentity(self: *Handles, player: abi.Player, name: []const u8, xuid: []const u8, uuid: []const u8, online: bool) void {
    self.enter();
    defer self.leave();
    _, const slot = self.find(player) orelse return;
    slot.info.state.authentication = .authenticated;
    slot.name_len = @intCast(@min(name.len, max_name_len));
    @memcpy(slot.name[0..slot.name_len], name[0..slot.name_len]);
    slot.info.online = @intFromBool(online);
    inline for (.{ "name", "xuid", "uuid" }, .{ name, xuid, uuid }) |field, bytes| {
        const buffer = &@field(slot.info, field);
        @field(slot.info, field ++ "_len") = if (bytes.len <= buffer.len) @intCast(bytes.len) else 0;
        if (bytes.len <= buffer.len) @memcpy(buffer[0..bytes.len], bytes);
    }
}

pub fn setState(self: *Handles, player: abi.Player, state: abi.PlayerState) ?abi.ConnectionPhase {
    self.enter();
    defer self.leave();
    _, const slot = self.find(player) orelse return null;
    const previous = slot.info.state.phase;
    slot.info.state = state;
    return previous;
}

pub fn copyInfo(self: *Handles, player: abi.Player, out: *abi.PlayerInfo) bool {
    const io, const started = copied: {
        self.enter();
        defer self.leave();
        _, const slot = self.find(player) orelse return false;
        out.* = slot.info;
        break :copied .{ slot.route.?.io, slot.connected_ns };
    };
    if (io) |clock| out.connection_duration_ms = (@import("Packets.zig").now(clock) -| started) / std.time.ns_per_ms;
    return true;
}

pub fn invalidatePackets(self: *Handles, player: abi.Player) void {
    self.enter();
    defer self.leave();
    _, const slot = self.find(player) orelse return;
    slot.route.?.epoch +%= 1;
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

test "player snapshots copy identity and state without retaining session memory" {
    const gpa = std.testing.allocator;
    var handles: Handles = .{};
    defer handles.deinit(gpa);
    var context: u8 = 0;
    const player = try handles.acquire(gpa, .{ .context = &context, .link = 1, .transfer = noTransfer, .io = std.testing.io });
    var info: abi.PlayerInfo = undefined;
    try std.testing.expect(handles.copyInfo(player, &info));
    try std.testing.expectEqual(@as(u32, 0), info.name_len);
    try std.testing.expectEqual(abi.AuthenticationState.pending, info.state.authentication);
    handles.setIdentity(player, "Steve", "123", "00000000-0000-0000-0000-000000000001", true);
    try std.testing.expect(handles.copyInfo(player, &info));
    try std.testing.expectEqualStrings("Steve", info.name[0..info.name_len]);
    try std.testing.expectEqualStrings("123", info.xuid[0..info.xuid_len]);
    try std.testing.expectEqual(@as(u32, 36), info.uuid_len);
    try std.testing.expectEqual(abi.AuthenticationState.authenticated, info.state.authentication);
    try std.testing.expectEqual(@as(u32, 1), info.online);
    handles.setIdentity(player, "Alex", "456", "", false);
    try std.testing.expectEqualStrings("Steve", info.name[0..info.name_len]);
    try std.testing.expectEqual(abi.ConnectionPhase.unknown, handles.setState(player, .{ .backend = 2, .mode = .managed, .phase = .in_game, .transfer = .syncing_client }).?);
    try std.testing.expect(handles.copyInfo(player, &info));
    try std.testing.expectEqual(@as(u32, 2), info.state.backend);
    try std.testing.expectEqual(abi.TransferState.syncing_client, info.state.transfer);
    handles.release(player);
    try std.testing.expect(!handles.copyInfo(player, &info));
    const next = try handles.acquire(gpa, .{ .context = &context, .link = 2, .transfer = noTransfer });
    try std.testing.expect(handles.copyInfo(next, &info));
    try std.testing.expectEqual(@as(u32, 0), info.name_len);
    try std.testing.expectEqual(@as(u32, 0), info.xuid_len);
}

test "generation exhaustion never revives a released player handle" {
    const gpa = std.testing.allocator;
    var handles: Handles = .{};
    defer handles.deinit(gpa);
    var context: u8 = 0;
    const first = try handles.acquire(gpa, .{ .context = &context, .link = 1, .transfer = noTransfer });
    handles.release(first);
    handles.slots.items[0].generation = std.math.maxInt(u32) - 1;
    const penultimate = try handles.acquire(gpa, .{ .context = &context, .link = 2, .transfer = noTransfer });
    handles.release(penultimate);
    const last = try handles.acquire(gpa, .{ .context = &context, .link = 3, .transfer = noTransfer });
    try std.testing.expectEqual(std.math.maxInt(u32), @as(u32, @truncate(last.id >> 32)));
    handles.setName(last, "Steve");
    handles.release(last);
    handles.release(last);
    const next = try handles.acquire(gpa, .{ .context = &context, .link = 4, .transfer = noTransfer });
    try std.testing.expect(first.id != next.id);
    try std.testing.expectEqual(@as(u32, 2), @as(u32, @truncate(next.id)));
    var name: [max_name_len]u8 = undefined;
    for ([_]abi.Player{ first, penultimate, last }) |retired| {
        try std.testing.expect(handles.route(retired) == null);
        try std.testing.expect(handles.copyName(retired, &name) == null);
        handles.invalidatePackets(retired);
    }
    try std.testing.expectEqual(@as(u64, 4), handles.route(next).?.link);
    try std.testing.expectEqual(@as(?usize, 0), handles.copyName(next, &name));
    handles.release(next);
    const reused = try handles.acquire(gpa, .{ .context = &context, .link = 5, .transfer = noTransfer });
    try std.testing.expectEqual(@as(u32, @truncate(next.id)), @as(u32, @truncate(reused.id)));
    try std.testing.expect(handles.route(next) == null and handles.route(first) == null);
    try std.testing.expectEqual(@as(u64, 5), handles.route(reused).?.link);
}

test "random acquire and release never resolve a released handle" {
    const gpa = std.testing.allocator;
    var handles: Handles = .{};
    defer handles.deinit(gpa);
    var context: u8 = 0;
    var live: std.ArrayList(abi.Player) = .empty;
    defer live.deinit(gpa);
    var dead: std.ArrayList(abi.Player) = .empty;
    defer dead.deinit(gpa);
    var prng: std.Random.DefaultPrng = .init(0x4a4d);
    for (0..20_000) |step| {
        const random = prng.random();
        if (live.items.len != 0 and random.boolean()) {
            const player = live.swapRemove(random.uintLessThan(usize, live.items.len));
            handles.release(player);
            try dead.append(gpa, player);
        } else {
            try live.append(gpa, try handles.acquire(gpa, .{ .context = &context, .link = step, .transfer = noTransfer }));
        }
    }
    for (live.items) |player| try std.testing.expect(handles.route(player) != null);
    for (dead.items) |player| try std.testing.expectEqual(@as(?Route, null), handles.route(player));
}
