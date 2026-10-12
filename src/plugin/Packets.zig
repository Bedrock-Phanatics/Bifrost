const std = @import("std");
const protocol = @import("bedwire").protocol;
const abi = @import("abi.zig");
const Work = @import("Work.zig");

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
    before_game: bool = false,
    in_game: bool = false,
};

pub const Table = struct {
    ranges: [id_count]Range = @splat(.{}),
    subscribers: []Subscriber = &.{},
    in_game: bool = false,

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
            range.before_game = range.before_game or item.subscriber.phase != .in_game;
            range.in_game = range.in_game or item.subscriber.phase != .before_game;
            table.in_game = table.in_game or range.in_game;
        };
        return table;
    }

    pub fn wants(self: *const Table, id: u10, in_game: bool) bool {
        const range = self.ranges[id];
        return if (in_game) range.in_game else range.before_game;
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

// The replacement lives in scratch until the next run
pub fn run(table: *const Table, call: Call, id: u10, bytes: []const u8, scratch: []u8, checker: anytype) Result {
    const range = table.ranges[id];
    if (range.len == 0) return .pass;
    std.debug.assert(scratch.len >= scratch_bytes);
    const outer = Work.enter();
    defer Work.hosted = outer;

    var current = bytes;
    var valid: ?bool = null;
    var next_half: usize = 0;
    // One clock read ends a callback and starts the next, unless validation ran in between
    var clock: ?u64 = null;
    for (table.subscribers[range.start..][0..range.len]) |*subscriber| {
        switch (subscriber.phase) {
            .in_game => if (!call.in_game) continue,
            .before_game => if (call.in_game) continue,
            else => {},
        }
        if (subscriber.validated) {
            if (valid == null) {
                valid = checker.valid(current);
                clock = null;
            }
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
        const started = clock orelse now(call.io);
        const action = subscriber.callback(subscriber.user, &packet);
        const ended = now(call.io);
        clock = ended;
        const elapsed = ended -| started;
        const metrics = &subscriber.metrics[call.worker];
        metrics.timed(elapsed);
        if (elapsed >= call.slow_ns) {
            warnSlow(metrics, subscriber.name, elapsed, call.io, "on packet {d}", .{id});
            clock = null;
        }
        switch (action) {
            .pass => {},
            .cancel => return .cancel,
            .replace => {
                clock = null;
                const len = packet.replacement_len;
                const header = if (len != 0 and len <= out.len) packetHeader(out[0..len]) else null;
                if (header == null or header.? & (id_count - 1) != id or header != packetHeader(bytes) or !checker.valid(out[0..len])) {
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
    return if (current.ptr == bytes.ptr) .pass else .{ .replace = current };
}

pub fn packetId(bytes: []const u8) ?u10 {
    return @intCast((packetHeader(bytes) orelse return null) & (id_count - 1));
}

fn packetHeader(bytes: []const u8) ?u14 {
    const envelope = protocol.packet.decode(bytes, .{ .max_packet_bytes = @max(bytes.len, 1) }) catch return null;
    return @bitCast(envelope.header);
}

pub fn warnSlow(metrics: *Metrics, name: []const u8, elapsed_ns: u64, io: std.Io, comptime what: []const u8, args: anytype) void {
    const at = now(io);
    if (metrics.last_warning_ns != 0 and at -| metrics.last_warning_ns < slow_warning_interval_ns) return;
    metrics.last_warning_ns = at;
    log.warn("plugin {s} took {d} us " ++ what, .{ name, elapsed_ns / std.time.ns_per_us } ++ args);
}

pub fn now(io: std.Io) u64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

const testing = std.testing;

test "packet ids use canonical bounded protocol headers" {
    var buffer: [8]u8 = undefined;
    for (0..0x4000) |value| {
        var writer = protocol.Writer.init(&buffer);
        try writer.writeVarU32(@intCast(value));
        try testing.expectEqual(@as(?u10, @intCast(value & (id_count - 1))), packetId(writer.written()));
    }
    const malformed = [_][]const u8{
        &.{},                   &.{0x80},                           &.{ 0x85, 0x00 },                   &.{ 0x80, 0x80, 0x01 },
        &.{ 0xff, 0xff, 0x7f }, &.{ 0x85, 0x80, 0x80, 0x80, 0x10 }, &.{ 0xff, 0xff, 0xff, 0xff, 0xff },
    };
    for (malformed) |bytes| try testing.expectEqual(@as(?u10, null), packetId(bytes));
}

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
        return write(user, packet, &.{ 0x05, 0xff });
    }

    fn retag(user: ?*anyopaque, packet: *abi.Packet) callconv(.c) abi.PacketAction {
        return write(user, packet, &.{ 0x06, 0x00 });
    }

    fn unterminated(user: ?*anyopaque, packet: *abi.Packet) callconv(.c) abi.PacketAction {
        return write(user, packet, &.{0x85});
    }

    fn noncanonical(user: ?*anyopaque, packet: *abi.Packet) callconv(.c) abi.PacketAction {
        return write(user, packet, &.{ 0x85, 0x00, 0xaa });
    }

    fn overflow(user: ?*anyopaque, packet: *abi.Packet) callconv(.c) abi.PacketAction {
        return write(user, packet, &.{ 0x85, 0x80, 0x80, 0x80, 0x10, 0xaa });
    }

    fn reroute(user: ?*anyopaque, packet: *abi.Packet) callconv(.c) abi.PacketAction {
        return write(user, packet, &.{ 0x85, 0x08, 0xaa });
    }

    fn empty(user: ?*anyopaque, packet: *abi.Packet) callconv(.c) abi.PacketAction {
        return write(user, packet, &.{});
    }

    fn oversize(user: ?*anyopaque, packet: *abi.Packet) callconv(.c) abi.PacketAction {
        _ = write(user, packet, &.{ 0x05, 0x00 });
        packet.replacement_len = packet.replacement_capacity + 1;
        return .replace;
    }

    fn write(user: ?*anyopaque, packet: *abi.Packet, bytes: []const u8) abi.PacketAction {
        _ = pass(user, packet);
        @memcpy(packet.replacement.?[0..bytes.len], bytes);
        packet.replacement_len = bytes.len;
        return .replace;
    }

    fn take() []const u8 {
        defer log_len = 0;
        return log_buffer[0..log_len];
    }
};

const Counted = struct {
    calls: *u32,

    fn valid(self: Counted, bytes: []const u8) bool {
        self.calls.* += 1;
        return AllValid.valid(.{}, bytes);
    }
};

fn testSubscriber(callback: abi.PacketFn, tag: u8, metrics: []Metrics) Subscriber {
    return phased(callback, tag, .any, false, metrics);
}

fn phased(callback: abi.PacketFn, tag: u8, phase: abi.PacketPhase, validated: bool, metrics: []Metrics) Subscriber {
    return .{ .callback = callback, .user = @ptrFromInt(tag), .phase = phase, .validated = validated, .name = "test", .metrics = metrics };
}

fn runBytes(table: *const Table, call: Call, bytes: []const u8, scratch: []u8, checker: anytype) Result {
    return run(table, call, packetId(bytes) orelse return .pass, bytes, scratch, checker);
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
    const result = runBytes(&table, call, &.{ 0x05, 0xaa }, scratch, AllValid{});
    try testing.expectEqualSlices(u8, &.{ 0x05, 0xaa, 1, 3 }, result.replace);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, Script.log_buffer[0..Script.log_len]);
    try testing.expectEqual(@as(u64, 1), metrics[0].errors.load(.monotonic));
    try testing.expectEqual(@as(u64, 3), metrics[0].calls.load(.monotonic));

    try testing.expectEqual(Result.cancel, runBytes(&table, call, &.{ 0x07, 0x00 }, scratch, AllValid{}));
    try testing.expectEqual(Result.pass, runBytes(&table, call, &.{ 0x06, 0x00 }, scratch, AllValid{}));
    try testing.expectEqual(Result.pass, runBytes(&table, call, &.{0x85}, scratch, AllValid{}));
}

const Chaos = struct {
    var prng: std.Random.DefaultPrng = .init(0);

    fn act(_: ?*anyopaque, packet: *abi.Packet) callconv(.c) abi.PacketAction {
        const random = prng.random();
        switch (random.uintLessThan(u8, 4)) {
            0 => return .pass,
            1 => return .cancel,
            2 => {
                packet.replacement_len = random.uintAtMost(usize, packet.replacement_capacity + 16);
                random.bytes(packet.replacement.?[0..@min(packet.replacement_len, packet.replacement_capacity)]);
                return .replace;
            },
            else => return @fromBackingInt(@intCast(random.int(u32))),
        }
    }
};

const Coin = struct {
    fn valid(_: Coin, bytes: []const u8) bool {
        return bytes.len % 3 != 0;
    }
};

test "dispatch survives arbitrary packets and plugin answers" {
    const gpa = testing.allocator;
    var metrics: [1]Metrics = .{.{}};
    var registrations: [8]Registration = undefined;
    for (&registrations, 0..) |*item, i| item.* = .{ .direction = .from_player, .id = @intCast(i % 3), .subscriber = testSubscriber(Chaos.act, 0, &metrics) };
    var table: Table = try .build(gpa, .from_player, &registrations);
    defer table.deinit(gpa);
    const scratch = try gpa.alloc(u8, scratch_bytes);
    defer gpa.free(scratch);
    const call: Call = .{ .io = testing.io, .worker = 0, .player = .{ .id = 1 }, .direction = .from_player, .in_game = true, .slow_ns = std.math.maxInt(u64) };

    var prng: std.Random.DefaultPrng = .init(0x5eed);
    var bytes: [300]u8 = undefined;
    for (0..20_000) |_| {
        const random = prng.random();
        const packet = bytes[0..random.uintAtMost(usize, bytes.len)];
        random.bytes(packet);
        if (packet.len != 0 and random.boolean()) packet[0] = random.uintLessThan(u8, 3);
        switch (runBytes(&table, call, packet, scratch, Coin{})) {
            .pass, .cancel => {},
            .replace => |replacement| {
                try testing.expect(replacement.len <= max_replacement and replacement.len != 0);
                try testing.expect(@intFromPtr(replacement.ptr) >= @intFromPtr(scratch.ptr) and @intFromPtr(replacement.ptr) + replacement.len <= @intFromPtr(scratch.ptr) + scratch.len);
                try testing.expectEqual(packetId(packet), packetId(replacement));
            },
        }
    }
}

test "replacements that change the packet id, are empty, oversized or malformed are ignored" {
    const gpa = testing.allocator;
    var metrics: [1]Metrics = .{.{}};
    var table: Table = try .build(gpa, .from_player, &.{
        .{ .direction = .from_player, .id = 5, .subscriber = testSubscriber(Script.retag, 1, &metrics) },
        .{ .direction = .from_player, .id = 5, .subscriber = testSubscriber(Script.oversize, 2, &metrics) },
        .{ .direction = .from_player, .id = 5, .subscriber = testSubscriber(Script.empty, 3, &metrics) },
        .{ .direction = .from_player, .id = 5, .subscriber = testSubscriber(Script.unterminated, 4, &metrics) },
        .{ .direction = .from_player, .id = 5, .subscriber = testSubscriber(Script.append, 5, &metrics) },
    });
    defer table.deinit(gpa);
    const scratch = try gpa.alloc(u8, scratch_bytes);
    defer gpa.free(scratch);
    const call: Call = .{ .io = testing.io, .worker = 0, .player = .{ .id = 1 }, .direction = .from_player, .in_game = true, .slow_ns = std.math.maxInt(u64) };

    Script.log_len = 0;
    try testing.expectEqualSlices(u8, &.{ 0x05, 0xaa, 5 }, runBytes(&table, call, &.{ 0x05, 0xaa }, scratch, AllValid{}).replace);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, Script.take());
    try testing.expectEqual(@as(u64, 4), metrics[0].errors.load(.monotonic));
}

test "subscribers run only in their phase, and validation is decoded once per packet version" {
    const gpa = testing.allocator;
    var metrics: [1]Metrics = .{.{}};
    var table: Table = try .build(gpa, .from_player, &.{
        .{ .direction = .from_player, .id = 5, .subscriber = phased(Script.pass, 1, .before_game, false, &metrics) },
        .{ .direction = .from_player, .id = 5, .subscriber = phased(Script.pass, 2, .in_game, true, &metrics) },
        .{ .direction = .from_player, .id = 5, .subscriber = phased(Script.pass, 3, .any, true, &metrics) },
        .{ .direction = .from_player, .id = 5, .subscriber = phased(Script.append, 4, .any, false, &metrics) },
        .{ .direction = .from_player, .id = 5, .subscriber = phased(Script.pass, 5, .any, true, &metrics) },
        .{ .direction = .from_player, .id = 6, .subscriber = phased(Script.pass, 6, .before_game, false, &metrics) },
    });
    defer table.deinit(gpa);
    try testing.expect(table.in_game and table.wants(5, true) and table.wants(5, false));
    try testing.expect(!table.wants(6, true) and table.wants(6, false) and !table.wants(7, false));
    const scratch = try gpa.alloc(u8, scratch_bytes);
    defer gpa.free(scratch);
    var call: Call = .{ .io = testing.io, .worker = 0, .player = .{ .id = 1 }, .direction = .from_player, .in_game = false, .slow_ns = std.math.maxInt(u64) };
    var checks: u32 = 0;

    Script.log_len = 0;
    try testing.expectEqualSlices(u8, &.{ 0x05, 0xaa, 4 }, runBytes(&table, call, &.{ 0x05, 0xaa }, scratch, Counted{ .calls = &checks }).replace);
    try testing.expectEqualSlices(u8, &.{ 1, 3, 4, 5 }, Script.take());
    try testing.expectEqual(@as(u32, 2), checks);

    call.in_game = true;
    checks = 0;
    try testing.expectEqual(Result.pass, runBytes(&table, call, &.{ 0x05, 0xff }, scratch, Counted{ .calls = &checks }));
    try testing.expectEqualSlices(u8, &.{4}, Script.take());
    try testing.expectEqual(@as(u32, 2), checks);

    var before: Table = try .build(gpa, .from_player, &.{.{ .direction = .from_player, .id = 5, .subscriber = phased(Script.pass, 1, .before_game, false, &metrics) }});
    defer before.deinit(gpa);
    try testing.expect(!before.in_game);
}

test "invalid replacement headers preserve the packet and its cached validation" {
    const gpa = testing.allocator;
    var metrics: [1]Metrics = .{.{}};
    var table: Table = try .build(gpa, .from_player, &.{
        .{ .direction = .from_player, .id = 5, .subscriber = phased(Script.pass, 1, .any, true, &metrics) },
        .{ .direction = .from_player, .id = 5, .subscriber = testSubscriber(Script.noncanonical, 2, &metrics) },
        .{ .direction = .from_player, .id = 5, .subscriber = testSubscriber(Script.overflow, 3, &metrics) },
        .{ .direction = .from_player, .id = 5, .subscriber = testSubscriber(Script.reroute, 4, &metrics) },
        .{ .direction = .from_player, .id = 5, .subscriber = phased(Script.pass, 5, .any, true, &metrics) },
    });
    defer table.deinit(gpa);
    const scratch = try gpa.alloc(u8, scratch_bytes);
    defer gpa.free(scratch);
    const call: Call = .{ .io = testing.io, .worker = 0, .player = .{ .id = 1 }, .direction = .from_player, .in_game = true, .slow_ns = std.math.maxInt(u64) };
    var checks: u32 = 0;
    Script.log_len = 0;
    try testing.expectEqual(Result.pass, runBytes(&table, call, &.{ 0x05, 0xaa }, scratch, Counted{ .calls = &checks }));
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5 }, Script.take());
    try testing.expectEqual(@as(u32, 1), checks);
    try testing.expectEqual(@as(u64, 3), metrics[0].errors.load(.monotonic));
}

test "replacement chains preserve split-screen headers at the capacity boundary" {
    const gpa = testing.allocator;
    var metrics: [1]Metrics = .{.{}};
    var table: Table = try .build(gpa, .from_player, &.{
        .{ .direction = .from_player, .id = 5, .subscriber = testSubscriber(Script.append, 1, &metrics) },
        .{ .direction = .from_player, .id = 5, .subscriber = testSubscriber(Script.append, 2, &metrics) },
    });
    defer table.deinit(gpa);
    const scratch = try gpa.alloc(u8, scratch_bytes);
    defer gpa.free(scratch);
    const bytes = try gpa.alloc(u8, max_replacement - 2);
    defer gpa.free(bytes);
    @memset(bytes, 0xaa);
    bytes[0] = 0x85;
    bytes[1] = 0x68;
    const call: Call = .{ .io = testing.io, .worker = 0, .player = .{ .id = 1 }, .direction = .from_player, .in_game = true, .slow_ns = std.math.maxInt(u64) };
    Script.log_len = 0;
    const result = runBytes(&table, call, bytes, scratch, AllValid{}).replace;
    try testing.expectEqual(@as(usize, max_replacement), result.len);
    try testing.expectEqualSlices(u8, bytes, result[0..bytes.len]);
    try testing.expectEqualSlices(u8, &.{ 1, 2 }, result[bytes.len..]);
    try testing.expectEqualSlices(u8, &.{ 1, 2 }, Script.take());
    try testing.expectEqual(@as(u64, 0), metrics[0].errors.load(.monotonic));
}
