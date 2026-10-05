const std = @import("std");
const abi = @import("abi.zig");

const log = std.log.scoped(.plugin);

pub const id_count = 1024;
pub const max_replacement = 64 * 1024;
// Room for two replacements, so a chain can read one while writing the next
pub const scratch_bytes = 2 * max_replacement;
const slow_warning_interval_ns = 10 * std.time.ns_per_s;

// Each worker writes only its own entry
pub const Metrics = struct {
    calls: std.atomic.Value(u64) align(std.atomic.cache_line) = .init(0),
    total_ns: std.atomic.Value(u64) = .init(0),
    max_ns: std.atomic.Value(u64) = .init(0),
    errors: std.atomic.Value(u64) = .init(0),
    last_warning_ns: u64 = 0,

    pub fn add(self: *Metrics, field: enum { calls, errors }, amount: u64) void {
        const counter = switch (field) {
            .calls => &self.calls,
            .errors => &self.errors,
        };
        counter.store(counter.load(.monotonic) + amount, .monotonic);
    }

    pub fn timed(self: *Metrics, elapsed_ns: u64) void {
        self.add(.calls, 1);
        self.total_ns.store(self.total_ns.load(.monotonic) + elapsed_ns, .monotonic);
        if (elapsed_ns > self.max_ns.load(.monotonic)) self.max_ns.store(elapsed_ns, .monotonic);
    }
};

pub const Subscriber = struct {
    callback: abi.PacketFn,
    user: ?*anyopaque,
    phase: abi.PacketPhase,
    validated: bool,
    name: []const u8,
    metrics: []Metrics,
};

pub const Registration = struct {
    direction: abi.Direction,
    id: u16,
    subscriber: Subscriber,
};

const Range = struct {
    start: u32 = 0,
    len: u32 = 0,
};

pub const Table = struct {
    ranges: [id_count]Range = @splat(.{}),
    subscribers: []Subscriber = &.{},

    pub fn deinit(self: *Table, gpa: std.mem.Allocator) void {
        gpa.free(self.subscribers);
        self.* = .{};
    }

    pub fn build(gpa: std.mem.Allocator, direction: abi.Direction, registrations: []const Registration) !Table {
        var table: Table = .{};
        var total: usize = 0;
        for (registrations) |item| if (item.direction == direction) {
            table.ranges[item.id].len += 1;
            total += 1;
        };
        table.subscribers = try gpa.alloc(Subscriber, total);
        var start: u32 = 0;
        for (&table.ranges) |*range| {
            range.start = start;
            start += range.len;
            range.len = 0;
        }
        for (registrations) |item| if (item.direction == direction) {
            const range = &table.ranges[item.id];
            table.subscribers[range.start + range.len] = item.subscriber;
            range.len += 1;
        };
        return table;
    }
};

pub const Call = struct {
    io: std.Io,
    worker: u32,
    player: abi.Player,
    direction: abi.Direction,
    in_game: bool,
    slow_ns: u64,
};

pub const Result = union(enum) {
    pass,
    cancel,
    replace: []const u8,
};

pub fn run(table: *const Table, call: Call, bytes: []const u8, scratch: []u8, checker: anytype) Result {
    const id = packetId(bytes) orelse return .pass;
    const range = table.ranges[id];
    if (range.len == 0) return .pass;
    std.debug.assert(scratch.len >= scratch_bytes);

    var current = bytes;
    var valid: ?bool = null;
    var next_half: usize = 0;
    for (table.subscribers[range.start..][0..range.len]) |*subscriber| {
        switch (subscriber.phase) {
            .in_game => if (!call.in_game) continue,
            .before_game => if (call.in_game) continue,
            else => {},
        }
        if (subscriber.validated) {
            if (valid == null) valid = checker.valid(current);
            if (!valid.?) continue;
        }
        const out = scratch[next_half * max_replacement ..][0..max_replacement];
        var packet: abi.Packet = .{
            .direction = call.direction,
            .id = id,
            .worker = call.worker,
            .player = call.player,
            .bytes = .of(current),
            .replacement = out.ptr,
            .replacement_capacity = out.len,
        };
        const started = now(call.io);
        const action = subscriber.callback(subscriber.user, &packet);
        const elapsed = now(call.io) -| started;
        const metrics = &subscriber.metrics[call.worker];
        metrics.timed(elapsed);
        if (elapsed >= call.slow_ns) warnSlow(metrics, subscriber.name, id, elapsed, call.io);
        switch (action) {
            .pass => {},
            .cancel => return .cancel,
            .replace => {
                const len = packet.replacement_len;
                if (len == 0 or len > out.len or packetId(out[0..len]) == null or !checker.valid(out[0..len])) {
                    metrics.add(.errors, 1);
                    continue;
                }
                current = out[0..len];
                valid = true;
                next_half ^= 1;
            },
            else => metrics.add(.errors, 1),
        }
    }
    if (current.ptr == bytes.ptr) return .pass;
    if (current.ptr != scratch.ptr) std.mem.copyForwards(u8, scratch[0..current.len], current);
    return .{ .replace = scratch[0..current.len] };
}

pub fn packetId(bytes: []const u8) ?u10 {
    var value: u32 = 0;
    for (bytes[0..@min(bytes.len, 5)], 0..) |byte, i| {
        value |= @as(u32, byte & 0x7f) << @intCast(7 * i);
        if (byte & 0x80 == 0) return @intCast(value & (id_count - 1));
    }
    return null;
}

fn warnSlow(metrics: *Metrics, name: []const u8, id: u10, elapsed_ns: u64, io: std.Io) void {
    const at = now(io);
    if (metrics.last_warning_ns != 0 and at -| metrics.last_warning_ns < slow_warning_interval_ns) return;
    metrics.last_warning_ns = at;
    log.warn("plugin {s} took {d} us on packet {d}", .{ name, elapsed_ns / std.time.ns_per_us, id });
}

fn now(io: std.Io) u64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

const testing = std.testing;

const AllValid = struct {
    fn valid(_: AllValid, bytes: []const u8) bool {
        return bytes.len > 1 and bytes[1] != 0xff;
    }
};

const Script = struct {
    var log_buffer: [8]u8 = undefined;
    var log_len: usize = 0;

    fn tag(user: ?*anyopaque) u8 {
        return @intCast(@intFromPtr(user));
    }

    fn pass(user: ?*anyopaque, _: *abi.Packet) callconv(.c) abi.PacketAction {
        log_buffer[log_len] = tag(user);
        log_len += 1;
        return .pass;
    }

    fn cancel(user: ?*anyopaque, packet: *abi.Packet) callconv(.c) abi.PacketAction {
        _ = pass(user, packet);
        return .cancel;
    }

    fn append(user: ?*anyopaque, packet: *abi.Packet) callconv(.c) abi.PacketAction {
        _ = pass(user, packet);
        const bytes = packet.bytes.slice();
        const out = packet.replacement.?[0..packet.replacement_capacity];
        @memcpy(out[0..bytes.len], bytes);
        out[bytes.len] = tag(user);
        packet.replacement_len = bytes.len + 1;
        return .replace;
    }

    fn corrupt(user: ?*anyopaque, packet: *abi.Packet) callconv(.c) abi.PacketAction {
        _ = pass(user, packet);
        packet.replacement.?[0] = 0x05;
        packet.replacement.?[1] = 0xff;
        packet.replacement_len = 2;
        return .replace;
    }
};

fn testSubscriber(callback: abi.PacketFn, tag: u8, metrics: []Metrics) Subscriber {
    return .{ .callback = callback, .user = @ptrFromInt(tag), .phase = .any, .validated = false, .name = "test", .metrics = metrics };
}

test "subscribers for a packet run in order, chain replacements and stop at a cancel" {
    const gpa = testing.allocator;
    var metrics: [1]Metrics = .{.{}};
    var table: Table = try .build(gpa, .from_player, &.{
        .{ .direction = .from_player, .id = 5, .subscriber = testSubscriber(Script.append, 1, &metrics) },
        .{ .direction = .from_backend, .id = 5, .subscriber = testSubscriber(Script.cancel, 9, &metrics) },
        .{ .direction = .from_player, .id = 5, .subscriber = testSubscriber(Script.corrupt, 2, &metrics) },
        .{ .direction = .from_player, .id = 5, .subscriber = testSubscriber(Script.append, 3, &metrics) },
        .{ .direction = .from_player, .id = 7, .subscriber = testSubscriber(Script.cancel, 4, &metrics) },
    });
    defer table.deinit(gpa);
    const scratch = try gpa.alloc(u8, scratch_bytes);
    defer gpa.free(scratch);
    const call: Call = .{ .io = testing.io, .worker = 0, .player = .{ .id = 1 }, .direction = .from_player, .in_game = true, .slow_ns = std.math.maxInt(u64) };

    Script.log_len = 0;
    const result = run(&table, call, &.{ 0x05, 0xaa }, scratch, AllValid{});
    try testing.expectEqualSlices(u8, &.{ 0x05, 0xaa, 1, 3 }, result.replace);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, Script.log_buffer[0..Script.log_len]);
    try testing.expectEqual(@as(u64, 1), metrics[0].errors.load(.monotonic));
    try testing.expectEqual(@as(u64, 3), metrics[0].calls.load(.monotonic));

    try testing.expectEqual(Result.cancel, run(&table, call, &.{ 0x07, 0x00 }, scratch, AllValid{}));
    try testing.expectEqual(Result.pass, run(&table, call, &.{ 0x06, 0x00 }, scratch, AllValid{}));
    try testing.expectEqual(Result.pass, run(&table, call, &.{0x85}, scratch, AllValid{}));
}
