const std = @import("std");
const protocol = @import("bedwire").protocol;
const abi = @import("abi.zig");
const Work = @import("Work.zig");
pub const Decoded = @import("Decoded.zig");

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
    fields: bool = false,
    context: ?*anyopaque = null,
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
    fields_before_game: bool = false,
    fields_in_game: bool = false,
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
            range.fields_before_game = range.fields_before_game or (item.subscriber.fields and item.subscriber.phase != .in_game);
            range.fields_in_game = range.fields_in_game or (item.subscriber.fields and item.subscriber.phase != .before_game);
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
    const fields = if (call.in_game) range.fields_in_game else range.fields_before_game;
    return if (fields) dispatch(true, table, call, id, bytes, scratch, checker) else dispatch(false, table, call, id, bytes, scratch, checker);
}

fn dispatch(comptime fields: bool, table: *const Table, call: Call, id: u10, bytes: []const u8, scratch: []u8, checker: anytype) Result {
    const range = table.ranges[id];
    if (range.len == 0) return .pass;
    std.debug.assert(scratch.len >= scratch_bytes);
    const outer = Work.enter();
    defer Work.hosted = outer;

    var current = bytes;
    var valid: ?bool = null;
    var next_half: usize = 0;
    var cache: Cache = .{};
    const decoded_type = if (fields) supportedType(id) else null;
    const Thunk = struct {
        fn decode(context: *const anyopaque, input: []const u8, packet_type: abi.PacketType) Decoded.Error!Decoded.Value {
            const value: *const @TypeOf(checker) = @ptrCast(@alignCast(context));
            if (comptime @hasDecl(@TypeOf(checker), "decode")) return value.decode(input, packet_type);
            return error.Unsupported;
        }

        fn permits(context: *const anyopaque, packet_type: abi.PacketType) bool {
            const value: *const @TypeOf(checker) = @ptrCast(@alignCast(context));
            if (comptime @hasDecl(@TypeOf(checker), "permits")) return value.permits(packet_type);
            return false;
        }
    };
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
                valid = if (decoded_type) |kind| cache.load(Thunk.decode, &checker, current, kind) == .ok else checker.valid(current);
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
        var access: Access = undefined;
        if (fields and subscriber.fields) access = .{ .packet = &packet, .context = subscriber.context, .bytes = current, .out = out, .packet_type = decoded_type, .cache = &cache, .decoder = Thunk.decode, .permits = Thunk.permits, .decoder_context = &checker };
        const started = clock orelse now(call.io);
        const action = if (fields and subscriber.fields) access.call(subscriber) else subscriber.callback(subscriber.user, &packet);
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
                if (header == null or header.? & (id_count - 1) != id or header != packetHeader(bytes)) {
                    metrics.add(.errors, 1);
                    continue;
                }
                var replacement_cache: Cache = .{};
                const replacement_valid = if (decoded_type) |kind| replacement_cache.load(Thunk.decode, &checker, out[0..len], kind) == .ok else checker.valid(out[0..len]);
                if (!replacement_valid) {
                    metrics.add(.errors, 1);
                    continue;
                }
                if (fields) cache = replacement_cache;
                current = out[0..len];
                valid = true;
                next_half ^= 1;
            },
            else => metrics.add(.errors, 1),
        }
    }
    return if (current.ptr == bytes.ptr) .pass else .{ .replace = current };
}

const DecodeFn = *const fn (*const anyopaque, []const u8, abi.PacketType) Decoded.Error!Decoded.Value;
const Cache = struct {
    status: ?abi.Status = null,
    value: Decoded.Value = undefined,

    fn load(self: *Cache, decoder: DecodeFn, context: *const anyopaque, bytes: []const u8, packet_type: abi.PacketType) abi.Status {
        if (self.status) |status| return status;
        self.value = decoder(context, bytes, packet_type) catch |err| {
            self.status = statusOf(err);
            return self.status.?;
        };
        self.status = .ok;
        return .ok;
    }
};

const Access = struct {
    packet: *abi.Packet,
    context: ?*anyopaque,
    bytes: []const u8,
    out: []u8,
    packet_type: ?abi.PacketType,
    cache: *Cache,
    decoder: DecodeFn,
    permits: *const fn (*const anyopaque, abi.PacketType) bool,
    decoder_context: *const anyopaque,

    fn call(self: *Access, subscriber: *const Subscriber) abi.PacketAction {
        const outer = active;
        active = self;
        defer active = outer;
        return subscriber.callback(subscriber.user, self.packet);
    }
};

threadlocal var active: ?*Access = null;

fn supportedType(id: u10) ?abi.PacketType {
    return switch (protocol.Current.packetKind(id) orelse return null) {
        .text => .text,
        .request_chunk_radius => .chunk_radius,
        else => null,
    };
}

fn statusOf(err: Decoded.Error) abi.Status {
    return switch (err) {
        error.Unsupported => .unsupported,
        error.InvalidArgument => .invalid_argument,
    };
}

pub fn decodePacket(context: *anyopaque, packet: ?*const abi.Packet, packet_type: abi.PacketType, out: ?*anyopaque, capacity: usize) callconv(.c) abi.Status {
    const access = active orelse return .wrong_thread;
    if (access.context != context) return .wrong_thread;
    if (packet == null or packet != access.packet) return .stale_handle;
    if (access.packet_type != packet_type) return .unsupported;
    const target = out orelse return .invalid_argument;
    if (capacity < Decoded.size(packet_type) or !Decoded.aligned(packet_type, target)) return .invalid_argument;
    if (Decoded.overlaps(target, Decoded.size(packet_type), access.bytes) or Decoded.overlaps(target, Decoded.size(packet_type), access.out)) return .invalid_argument;
    if (!access.permits(access.decoder_context, packet_type)) return .invalid_argument;
    const status = access.cache.load(access.decoder, access.decoder_context, access.bytes, packet_type);
    if (status == .ok) Decoded.copy(access.cache.value, target);
    return status;
}

pub fn encodePacket(context: *anyopaque, packet: ?*abi.Packet, packet_type: abi.PacketType, data: ?*const anyopaque, size: usize) callconv(.c) abi.Status {
    const access = active orelse return .wrong_thread;
    if (access.context != context) return .wrong_thread;
    if (packet == null or packet != access.packet) return .stale_handle;
    if (access.packet_type != packet_type) return .unsupported;
    const source = data orelse return .invalid_argument;
    if (size < Decoded.size(packet_type) or !Decoded.aligned(packet_type, source)) return .invalid_argument;
    if (!access.permits(access.decoder_context, packet_type)) return .invalid_argument;
    const header = protocol.packet.decode(access.bytes, .{ .max_packet_bytes = @max(access.bytes.len, 1) }) catch return .invalid_argument;
    const len = Decoded.encode(header.header, packet_type, source, access.out) catch |err| return statusOf(err);
    access.packet.replacement_len = len;
    return .ok;
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

const DecodeProbe = struct {
    mode: enum { read, replace, corrupt, pass, cancel } = .read,
    expected: []const u8 = "original",
    replacement: []const u8 = "changed",
    status: abi.Status = .ok,
    failed: bool = false,
    saved: ?*const abi.Packet = null,

    fn onPacket(user: ?*anyopaque, packet: *abi.Packet) callconv(.c) abi.PacketAction {
        const self: *DecodeProbe = @ptrCast(@alignCast(user.?));
        self.saved = packet;
        if (self.mode == .pass) return .pass;
        var text: abi.Text = .{ .message = .of("untouched") };
        const result = decodePacket(self, packet, .text, &text, @sizeOf(abi.Text));
        if (result != self.status) self.failed = true;
        if (result == .ok and !std.mem.eql(u8, text.message.slice(), self.expected)) self.failed = true;
        if (result != .ok and !std.mem.eql(u8, text.message.slice(), "untouched")) self.failed = true;
        var copied = packet.*;
        if (decodePacket(self, &copied, .text, &text, @sizeOf(abi.Text)) != .stale_handle) self.failed = true;
        if (decodePacket(@ptrFromInt(1), packet, .text, &text, @sizeOf(abi.Text)) != .wrong_thread) self.failed = true;
        if (decodePacket(self, packet, .chunk_radius, &text, @sizeOf(abi.Text)) != .unsupported) self.failed = true;
        if (decodePacket(self, packet, .text, &text, 1) != .invalid_argument) self.failed = true;
        if (decodePacket(self, packet, .text, packet.replacement.?, packet.replacement_capacity) != .invalid_argument) self.failed = true;
        switch (self.mode) {
            .read => return .pass,
            .cancel => return .cancel,
            .replace => {
                text = .{ .message = .of(self.replacement) };
                // ABI metadata written by a plugin is not the host's source of truth.
                packet.bytes = .{};
                packet.replacement = null;
                packet.replacement_capacity = 0;
                if (encodePacket(self, packet, .text, &text, @sizeOf(abi.Text)) != .ok) self.failed = true;
                return .replace;
            },
            .corrupt => {
                packet.replacement.?[0] = 9;
                packet.replacement.?[1] = 0xff;
                packet.replacement_len = 2;
                return .replace;
            },
            .pass => unreachable,
        }
    }
};

const DecodeChecker = struct {
    calls: *u32,
    allowed: bool = true,

    pub fn permits(self: DecodeChecker, _: abi.PacketType) bool {
        return self.allowed;
    }
    pub fn decode(self: DecodeChecker, bytes: []const u8, packet_type: abi.PacketType) Decoded.Error!Decoded.Value {
        self.calls.* += 1;
        if (!self.allowed) return error.InvalidArgument;
        return Decoded.decode(bytes, packet_type, .{});
    }
    pub fn valid(self: DecodeChecker, bytes: []const u8) bool {
        _ = self.decode(bytes, .text) catch return false;
        return true;
    }
};

fn decodedRegistration(probe: *DecodeProbe, validated: bool, metrics: []Metrics) Registration {
    return .{ .direction = .from_player, .id = 9, .subscriber = .{ .callback = DecodeProbe.onPacket, .user = probe, .context = probe, .phase = .any, .validated = validated, .fields = true, .name = "decoded", .metrics = metrics } };
}

test "native fields are lazy, shared with validation, refreshed by replacement and callback scoped" {
    const gpa = testing.allocator;
    var metrics: [1]Metrics = .{.{}};
    var probes: [5]DecodeProbe = .{ .{ .mode = .pass }, .{}, .{ .mode = .replace }, .{ .expected = "changed" }, .{ .expected = "changed", .mode = .cancel } };
    var registrations: [5]Registration = undefined;
    for (&registrations, &probes, 0..) |*registration, *probe, i| registration.* = decodedRegistration(probe, i == 1 or i == 3, &metrics);
    var table: Table = try .build(gpa, .from_player, &registrations);
    defer table.deinit(gpa);
    const scratch = try gpa.alloc(u8, scratch_bytes);
    defer gpa.free(scratch);
    var buffer: [64]u8 = undefined;
    const text: abi.Text = .{ .message = .of("original") };
    const bytes = buffer[0..try Decoded.encode(.{ .packet_id = 9 }, .text, &text, &buffer)];
    const call: Call = .{ .io = testing.io, .worker = 0, .player = .{ .id = 1 }, .direction = .from_player, .in_game = true, .slow_ns = std.math.maxInt(u64) };
    var checks: u32 = 0;
    try testing.expectEqual(Result.cancel, runBytes(&table, call, bytes, scratch, DecodeChecker{ .calls = &checks }));
    try testing.expectEqual(@as(u32, 2), checks);
    for (probes) |probe| try testing.expect(!probe.failed);
    var out: abi.Text = undefined;
    try testing.expectEqual(abi.Status.wrong_thread, decodePacket(&probes[4], probes[4].saved, .text, &out, @sizeOf(abi.Text)));

    table.ranges[9].len = 1;
    checks = 0;
    try testing.expectEqual(Result.pass, runBytes(&table, call, bytes, scratch, DecodeChecker{ .calls = &checks }));
    try testing.expectEqual(@as(u32, 0), checks);
}

test "typed packet modifiers cycle scratch buffers and preserve the last accepted decoded fields" {
    const gpa = testing.allocator;
    var metrics: [1]Metrics = .{.{}};
    var probes: [6]DecodeProbe = .{
        .{ .mode = .replace, .replacement = "first" },
        .{ .mode = .replace, .expected = "first", .replacement = "second" },
        .{ .mode = .replace, .expected = "second", .replacement = "third" },
        .{ .mode = .corrupt, .expected = "third" },
        .{ .expected = "third" },
        .{ .expected = "third" },
    };
    var registrations: [probes.len]Registration = undefined;
    for (&registrations, &probes, 0..) |*registration, *probe, i| registration.* = decodedRegistration(probe, i == probes.len - 1, &metrics);
    var table: Table = try .build(gpa, .from_player, &registrations);
    defer table.deinit(gpa);
    const scratch = try gpa.alloc(u8, scratch_bytes);
    defer gpa.free(scratch);
    var buffer: [64]u8 = undefined;
    const text: abi.Text = .{ .message = .of("original") };
    const bytes = buffer[0..try Decoded.encode(.{ .packet_id = 9 }, .text, &text, &buffer)];
    const call: Call = .{ .io = testing.io, .worker = 0, .player = .{ .id = 1 }, .direction = .from_player, .in_game = true, .slow_ns = std.math.maxInt(u64) };
    var checks: u32 = 0;
    const result = runBytes(&table, call, bytes, scratch, DecodeChecker{ .calls = &checks }).replace;
    try testing.expectEqualStrings("third", (try Decoded.decode(result, .text, .{})).text.message.slice());
    try testing.expectEqualStrings("original", (try Decoded.decode(bytes, .text, .{})).text.message.slice());
    try testing.expectEqual(@as(u32, 5), checks);
    try testing.expectEqual(@as(u64, probes.len), metrics[0].calls.load(.monotonic));
    try testing.expectEqual(@as(u64, 1), metrics[0].errors.load(.monotonic));
    for (probes) |probe| try testing.expect(!probe.failed);
}

test "invalid native replacements preserve decoded fields and malformed decodes are cached" {
    const gpa = testing.allocator;
    var metrics: [1]Metrics = .{.{}};
    var probes: [3]DecodeProbe = .{ .{}, .{ .mode = .corrupt }, .{} };
    var registrations: [3]Registration = undefined;
    for (&registrations, &probes) |*registration, *probe| registration.* = decodedRegistration(probe, false, &metrics);
    var table: Table = try .build(gpa, .from_player, &registrations);
    defer table.deinit(gpa);
    const scratch = try gpa.alloc(u8, scratch_bytes);
    defer gpa.free(scratch);
    var buffer: [64]u8 = undefined;
    const text: abi.Text = .{ .message = .of("original") };
    const bytes = buffer[0..try Decoded.encode(.{ .packet_id = 9 }, .text, &text, &buffer)];
    const call: Call = .{ .io = testing.io, .worker = 0, .player = .{ .id = 1 }, .direction = .from_player, .in_game = true, .slow_ns = std.math.maxInt(u64) };
    var checks: u32 = 0;
    try testing.expectEqual(Result.pass, runBytes(&table, call, bytes, scratch, DecodeChecker{ .calls = &checks }));
    try testing.expectEqual(@as(u32, 2), checks);
    for (probes) |probe| try testing.expect(!probe.failed);
    try testing.expectEqual(@as(u64, 1), metrics[0].errors.load(.monotonic));

    probes[1].mode = .read;
    for (&probes) |*probe| probe.status = .invalid_argument;
    checks = 0;
    try testing.expectEqual(Result.pass, runBytes(&table, call, &.{ 9, 0xff }, scratch, DecodeChecker{ .calls = &checks }));
    try testing.expectEqual(@as(u32, 1), checks);
    for (probes) |probe| try testing.expect(!probe.failed);
    checks = 0;
    try testing.expectEqual(Result.pass, runBytes(&table, call, bytes, scratch, DecodeChecker{ .calls = &checks, .allowed = false }));
    try testing.expectEqual(@as(u32, 0), checks);
    for (probes) |probe| try testing.expect(!probe.failed);
}

test "native decode state stays local to concurrent workers" {
    const Parallel = struct {
        failed: [2]bool = @splat(false),
        checks: [2]u32 = @splat(0),

        fn read(user: ?*anyopaque, packet: *abi.Packet) callconv(.c) abi.PacketAction {
            const self: *@This() = @ptrCast(@alignCast(user.?));
            var text: abi.Text = undefined;
            const expected = if (packet.worker == 0) "first" else "second";
            if (decodePacket(self, packet, .text, &text, @sizeOf(abi.Text)) != .ok or !std.mem.eql(u8, text.message.slice(), expected)) self.failed[packet.worker] = true;
            return .pass;
        }

        fn runWorker(self: *@This(), table: *const Table, worker: u32, bytes: []const u8, scratch: []u8) void {
            const call: Call = .{ .io = testing.io, .worker = worker, .player = .{ .id = worker + 1 }, .direction = .from_player, .in_game = true, .slow_ns = std.math.maxInt(u64) };
            for (0..1000) |_| if (runBytes(table, call, bytes, scratch, DecodeChecker{ .calls = &self.checks[worker] }) != .pass) {
                self.failed[worker] = true;
            };
            var text: abi.Text = undefined;
            if (decodePacket(self, null, .text, &text, @sizeOf(abi.Text)) != .wrong_thread) self.failed[worker] = true;
        }
    };
    var parallel: Parallel = .{};
    var metrics: [2]Metrics = .{ .{}, .{} };
    var table: Table = try .build(testing.allocator, .from_player, &.{.{ .direction = .from_player, .id = 9, .subscriber = .{ .callback = Parallel.read, .user = &parallel, .context = &parallel, .phase = .any, .validated = false, .fields = true, .name = "parallel", .metrics = &metrics } }});
    defer table.deinit(testing.allocator);
    const scratch = try testing.allocator.alloc(u8, 2 * scratch_bytes);
    defer testing.allocator.free(scratch);
    var buffers: [2][64]u8 = undefined;
    var threads: [2]?std.Thread = @splat(null);
    defer for (threads) |thread| if (thread) |running| running.join();
    for (&threads, &buffers, 0..) |*thread, *buffer, i| {
        const text: abi.Text = .{ .message = .of(if (i == 0) "first" else "second") };
        const bytes = buffer[0..try Decoded.encode(.{ .packet_id = 9 }, .text, &text, buffer)];
        thread.* = try std.Thread.spawn(.{}, Parallel.runWorker, .{ &parallel, &table, @as(u32, @intCast(i)), bytes, scratch[i * scratch_bytes ..][0..scratch_bytes] });
    }
    for (&threads) |*thread| {
        thread.*.?.join();
        thread.* = null;
    }
    for (parallel.failed, parallel.checks, &metrics) |failed, checks, *metric| {
        try testing.expect(!failed);
        try testing.expectEqual(@as(u32, 1000), checks);
        try testing.expectEqual(@as(u64, 1000), metric.calls.load(.monotonic));
    }
}

test "fields subscriptions in another phase keep the raw validation path" {
    var metrics: [1]Metrics = .{.{}};
    var probe: DecodeProbe = .{ .mode = .pass };
    var registration = decodedRegistration(&probe, false, &metrics);
    registration.subscriber.phase = .before_game;
    var table: Table = try .build(testing.allocator, .from_player, &.{ registration, .{ .direction = .from_player, .id = 9, .subscriber = phased(Script.pass, 1, .in_game, true, &metrics) } });
    defer table.deinit(testing.allocator);
    const scratch = try testing.allocator.alloc(u8, scratch_bytes);
    defer testing.allocator.free(scratch);
    const call: Call = .{ .io = testing.io, .worker = 0, .player = .{ .id = 1 }, .direction = .from_player, .in_game = true, .slow_ns = std.math.maxInt(u64) };
    var checks: u32 = 0;
    Script.log_len = 0;
    try testing.expectEqual(Result.pass, runBytes(&table, call, &.{ 9, 0 }, scratch, Counted{ .calls = &checks }));
    try testing.expectEqualSlices(u8, &.{1}, Script.take());
    try testing.expectEqual(@as(u32, 1), checks);
}
