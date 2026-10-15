const std = @import("std");
const bedwire = @import("bedwire");
const bifrost = @import("bifrost");
const sample = @import("sample");
const harness = @import("harness.zig");
const bench_options = @import("bench_options");

const abi = bifrost.plugin_abi;
const Packets = bifrost.Plugins.Packets;
const Current = bedwire.protocol.Current;

pub const Setup = enum {
    none,
    idle_10,
    one_raw,
    one_decoded,
    ten_ids,
    ten_hot,
    phase_miss,
    one_replace,
    two_replace,
    one_lazy,
    ten_independent,
    ten_shared,
    typed_replace,
    packet_filter,
    native_chat_reader,
    packet_filter_chat,

    pub fn describe(self: Setup) []const u8 {
        return switch (self) {
            .none => "0 plugins",
            .idle_10 => "10 plugins, no packet subscriptions",
            .one_raw => "1 raw subscriber on the hot packet",
            .one_decoded => "1 decoded subscriber on the hot packet",
            .ten_ids => "10 subscribers on different packet ids",
            .ten_hot => "10 subscribers on the same hot packet",
            .phase_miss => "1 before-game subscriber on the hot packet, in game",
            .one_replace => "1 subscriber replacing the hot packet",
            .two_replace => "2 subscribers chaining replacements",
            .one_lazy => "1 listener reading lazy typed fields",
            .ten_independent => "10 listeners decoding independently",
            .ten_shared => "10 listeners sharing typed fields",
            .typed_replace => "1 listener modifying typed text",
            .packet_filter => "1 C++ packet filter reading raw text",
            .native_chat_reader => "1 native listener reading chat fields",
            .packet_filter_chat => "1 C++ chat filter with player-name lookup",
        };
    }

    // Half the stream is the hot packet
    pub fn callbacksPerPacket(self: Setup) f64 {
        return switch (self) {
            .none, .idle_10, .phase_miss => 0,
            .one_raw, .one_decoded, .one_replace, .one_lazy, .typed_replace, .packet_filter, .native_chat_reader, .packet_filter_chat => 0.5,
            .ten_ids, .two_replace => 1,
            .ten_hot, .ten_independent, .ten_shared => 5,
        };
    }

    pub fn budgetNs(self: Setup) f64 {
        return switch (self) {
            .none, .idle_10, .phase_miss => 2,
            .one_decoded, .one_replace, .two_replace, .one_lazy, .typed_replace, .packet_filter, .native_chat_reader, .packet_filter_chat => 200,
            else => 100,
        };
    }
};

pub const relay_packet_id: u10 = 1020;
const text_packet_id: u10 = Current.packetId(.text).?;
const cold_ids = [_]u10{ 1, 2, 3, 4, 5, 6, 7, 8 };

var target_id: u10 = 0;
var instance: u8 = 0;
var name_buffer: [32]u8 = undefined;

fn named(plugin: *abi.Plugin, base: []const u8) void {
    instance +%= 1;
    plugin.name = .of(std.fmt.bufPrint(&name_buffer, "{s}{d}", .{ base, instance }) catch unreachable);
    plugin.plugin_version = .of("1");
}

fn pass(_: ?*anyopaque, _: *abi.Packet) callconv(.c) abi.PacketAction {
    return .pass;
}

fn copy(_: ?*anyopaque, packet: *abi.Packet) callconv(.c) abi.PacketAction {
    const bytes = packet.bytes.slice();
    @memcpy(packet.replacement.?[0..bytes.len], bytes);
    packet.replacement_len = bytes.len;
    return .replace;
}

fn idle(_: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
    named(plugin, "idle");
    return .ok;
}

fn raw(host: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
    named(plugin, "raw");
    plugin.capabilities = .{ .packets = true };
    return host.subscribe_packet(host.context, .from_player, target_id, .any, .{}, pass, null);
}

fn decoded(host: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
    named(plugin, "decoded");
    plugin.capabilities = .{ .packets = true };
    return host.subscribe_packet(host.context, .from_player, target_id, .any, .{ .validated = true }, pass, null);
}

fn beforeGame(host: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
    named(plugin, "before");
    plugin.capabilities = .{ .packets = true };
    return host.subscribe_packet(host.context, .from_player, target_id, .before_game, .{}, pass, null);
}

fn replacer(host: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
    named(plugin, "replacer");
    plugin.capabilities = .{ .packets = true };
    return host.subscribe_packet(host.context, .from_player, target_id, .any, .{}, copy, null);
}

fn readFields(user: ?*anyopaque, packet: *abi.Packet) callconv(.c) abi.PacketAction {
    const host: *const abi.Host = @ptrCast(@alignCast(user.?));
    var text: abi.Text = undefined;
    if (host.decode_packet(host.context, packet, .text, &text, @sizeOf(abi.Text)) == .ok) std.mem.doNotOptimizeAway(text);
    return .pass;
}

fn editFields(user: ?*anyopaque, packet: *abi.Packet) callconv(.c) abi.PacketAction {
    const host: *const abi.Host = @ptrCast(@alignCast(user.?));
    var text: abi.Text = undefined;
    if (host.decode_packet(host.context, packet, .text, &text, @sizeOf(abi.Text)) != .ok) return .pass;
    text.message = .of("changed by plugin");
    return if (host.encode_packet(host.context, packet, .text, &text, @sizeOf(abi.Text)) == .ok) .replace else .pass;
}

fn independent(_: ?*anyopaque, packet: *abi.Packet) callconv(.c) abi.PacketAction {
    const value = Packets.Decoded.decode(packet.bytes.slice(), .text, .{}) catch return .pass;
    std.mem.doNotOptimizeAway(value);
    return .pass;
}

fn lazy(host: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
    named(plugin, "fields");
    plugin.capabilities = .{ .packets = true };
    return host.subscribe_packet(host.context, .from_player, target_id, .any, .{ .fields = true }, readFields, @constCast(host));
}

fn independentDecoder(host: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
    named(plugin, "independent");
    plugin.capabilities = .{ .packets = true };
    return host.subscribe_packet(host.context, .from_player, target_id, .any, .{}, independent, null);
}

fn typedReplacer(host: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
    named(plugin, "typed");
    plugin.capabilities = .{ .packets = true };
    return host.subscribe_packet(host.context, .from_player, target_id, .any, .{ .fields = true }, editFields, @constCast(host));
}

pub fn load(plugins: *bifrost.Plugins, io: std.Io, setup: Setup, hot: u10) !void {
    target_id = hot;
    switch (setup) {
        .none => {},
        .idle_10 => for (0..10) |_| try plugins.add(idle, null),
        .one_raw => try plugins.add(raw, null),
        .one_decoded => try plugins.add(decoded, null),
        .ten_hot => for (0..10) |_| try plugins.add(raw, null),
        .phase_miss => try plugins.add(beforeGame, null),
        .one_replace => try plugins.add(replacer, null),
        .two_replace => for (0..2) |_| try plugins.add(replacer, null),
        .one_lazy, .native_chat_reader => try plugins.add(lazy, null),
        .ten_independent => for (0..10) |_| try plugins.add(independentDecoder, null),
        .ten_shared => for (0..10) |_| try plugins.add(lazy, null),
        .typed_replace => try plugins.add(typedReplacer, null),
        .packet_filter, .packet_filter_chat => {
            var dir = try std.Io.Dir.cwd().openDir(io, std.fs.path.dirname(bench_options.packet_filter) orelse ".", .{});
            defer dir.close(io);
            try bifrost.Plugins.Package.load(plugins, io, dir, std.fs.path.basename(bench_options.packet_filter));
        },
        .ten_ids => {
            try plugins.add(raw, null);
            for (cold_ids) |id| {
                target_id = id;
                try plugins.add(raw, null);
            }
            target_id = if (hot == text_packet_id) relay_packet_id else text_packet_id;
            try plugins.add(raw, null);
        },
    }
}

pub fn parse(text: []const u8) ?Setup {
    return std.meta.stringToEnum(Setup, text);
}

const Checker = struct {
    pub fn permits(_: Checker, _: abi.PacketType) bool {
        return true;
    }
    pub fn decode(_: Checker, bytes: []const u8, packet_type: abi.PacketType) Packets.Decoded.Error!Packets.Decoded.Value {
        return Packets.Decoded.decode(bytes, packet_type, .{});
    }
    pub fn valid(_: Checker, bytes: []const u8) bool {
        const header = bedwire.protocol.packet.decode(bytes, .{ .max_packet_bytes = 1 << 20 }) catch return false;
        if (Current.packetKind(header.header.packet_id) == null) return true;
        _ = Current.decodeBorrowed(bytes, .{}) catch return false;
        return true;
    }
};

pub const DispatchResult = struct {
    setup: Setup,
    ns_per_packet: f64,
    extra_ns: f64,
};

const stream_len = 4096;

pub fn dispatch(gpa: std.mem.Allocator, io: std.Io, quick: bool) ![std.enums.values(Setup).len]DispatchResult {
    var storage: std.ArrayList(u8) = .empty;
    defer storage.deinit(gpa);
    var bounds: [stream_len][2]usize = undefined;
    var chat_bounds: [stream_len][2]usize = undefined;
    var payload: [64]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = @truncate(i * 31 + 7);
    for (&bounds, 0..) |*bound, i| {
        var buffer: [256]u8 = undefined;
        const bytes = if (i % 2 == 0) try sample.typedPacket(&buffer, .{ .text = .{
            .localize = false,
            .body = .{ .message_only = .{ .message_type = .raw, .message = "hello there, how are things going" } },
            .senders_xuid = "",
            .platform_id = "",
            .filtered_message = null,
        } }) else try sample.rawPacket(&buffer, relay_packet_id, &payload);
        bound.* = .{ storage.items.len, bytes.len };
        try storage.appendSlice(gpa, bytes);
        const chat = if (i % 2 == 0) try sample.typedPacket(&buffer, .{ .text = .{
            .localize = false,
            .body = .{ .author_and_message = .{ .message_type = .chat, .player_name = "Steve", .message = "hello there, how are things going" } },
            .senders_xuid = "",
            .platform_id = "",
            .filtered_message = null,
        } }) else try sample.rawPacket(&buffer, relay_packet_id, &payload);
        chat_bounds[i] = .{ storage.items.len, chat.len };
        try storage.appendSlice(gpa, chat);
    }
    const scratch = try gpa.alloc(u8, Packets.scratch_bytes);
    defer gpa.free(scratch);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const rounds: usize = if (quick) 200 else 1000;
    var results: [std.enums.values(Setup).len]DispatchResult = undefined;
    for (std.enums.values(Setup), &results) |setup, *result| {
        var plugins: bifrost.Plugins = try .init(gpa, &.{}, .{ .slow_callback_ns = std.math.maxInt(u64) });
        defer plugins.deinit();
        try load(&plugins, io, setup, text_packet_id);
        var player_context: u8 = 0;
        const player = try plugins.handles.acquire(gpa, .{
            .context = &player_context,
            .link = 0,
            .transfer = struct {
                fn transfer(_: *anyopaque, _: u64, _: u32) abi.Status {
                    return .unsupported;
                }
            }.transfer,
        });
        plugins.handles.setName(player, "Steve");
        var table = plugins.packetTable(.from_player);
        const call: Packets.Call = .{ .io = io, .worker = 0, .player = player, .direction = .from_player, .in_game = true, .slow_ns = std.math.maxInt(u64) };
        const selected_bounds = if (setup == .native_chat_reader or setup == .packet_filter_chat) &chat_bounds else &bounds;
        if (call.in_game) if (table) |hooks| {
            if (!hooks.in_game) table = null;
        };

        var samples: [7]f64 = undefined;
        for (&samples) |*sample_ns| {
            var kept: usize = 0;
            const started = harness.nowNs(io);
            for (0..rounds) |_| {
                defer _ = arena.reset(.retain_capacity);
                for (selected_bounds) |bound| {
                    const bytes = storage.items[bound[0]..][0..bound[1]];
                    var packet = bytes;
                    if (table) |hooks| if (Packets.packetId(bytes)) |id| if (hooks.wants(id, call.in_game)) {
                        switch (Packets.run(hooks, call, id, bytes, scratch, Checker{})) {
                            .pass => {},
                            .cancel => continue,
                            .replace => |replacement| packet = try arena.allocator().dupe(u8, replacement),
                        }
                    };
                    kept += packet.len;
                }
            }
            std.mem.doNotOptimizeAway(kept);
            sample_ns.* = @as(f64, @floatFromInt(harness.nowNs(io) - started)) / @as(f64, @floatFromInt(rounds * stream_len));
        }
        std.mem.sort(f64, &samples, {}, std.sort.asc(f64));
        result.* = .{ .setup = setup, .ns_per_packet = samples[samples.len / 2], .extra_ns = 0 };
    }
    for (&results) |*result| result.extra_ns = result.ns_per_packet - results[0].ns_per_packet;
    return results;
}

const CallbackProbe = struct {
    io: std.Io,
    callback: abi.PacketFn,
    user: ?*anyopaque,
    samples: []u64,
    used: usize = 0,
    recording: bool = false,
    failed: bool = false,

    fn call(user: ?*anyopaque, packet: *abi.Packet) callconv(.c) abi.PacketAction {
        const self: *CallbackProbe = @ptrCast(@alignCast(user.?));
        if (!self.recording) return self.callback(self.user, packet);
        const started = harness.nowNs(self.io);
        const action = self.callback(self.user, packet);
        const ended = harness.nowNs(self.io);
        if (ended < started or self.used == self.samples.len) {
            self.failed = true;
        } else {
            self.samples[self.used] = ended - started;
            self.used += 1;
        }
        return action;
    }
};

pub fn callbackSamples(gpa: std.mem.Allocator, io: std.Io, setup: Setup, count: usize) ![]u64 {
    if (count == 0 or count > 1 << 20) return error.InvalidSampleCount;
    var plugins: bifrost.Plugins = try .init(gpa, &.{}, .{ .slow_callback_ns = std.math.maxInt(u64) });
    defer plugins.deinit();
    try load(&plugins, io, setup, text_packet_id);
    const table = plugins.packetTable(.from_player) orelse return error.MissingSubscribers;
    const range = table.ranges[text_packet_id];
    const subscribers = table.subscribers[range.start..][0..range.len];
    var probes: [10]CallbackProbe = undefined;
    if (subscribers.len == 0 or subscribers.len > probes.len) return error.InvalidSubscribers;
    const values = try gpa.alloc(u64, count * subscribers.len);
    errdefer gpa.free(values);
    for (subscribers, probes[0..subscribers.len], 0..) |*subscriber, *probe, i| {
        probe.* = .{ .io = io, .callback = subscriber.callback, .user = subscriber.user, .samples = values[i * count ..][0..count] };
        subscriber.callback = CallbackProbe.call;
        subscriber.user = probe;
    }
    defer for (subscribers, probes[0..subscribers.len]) |*subscriber, probe| {
        subscriber.callback = probe.callback;
        subscriber.user = probe.user;
    };
    var player_context: u8 = 0;
    const player = try plugins.handles.acquire(gpa, .{
        .context = &player_context,
        .link = 0,
        .transfer = struct {
            fn transfer(_: *anyopaque, _: u64, _: u32) abi.Status {
                return .unsupported;
            }
        }.transfer,
    });
    plugins.handles.setName(player, "Steve");
    var buffer: [256]u8 = undefined;
    const bytes = try sample.typedPacket(&buffer, .{ .text = .{
        .localize = false,
        .body = .{ .author_and_message = .{ .message_type = .chat, .player_name = "Steve", .message = "hello there, how are things going" } },
        .senders_xuid = "",
        .platform_id = "",
        .filtered_message = null,
    } });
    const scratch = try gpa.alloc(u8, Packets.scratch_bytes);
    defer gpa.free(scratch);
    const call: Packets.Call = .{ .io = io, .worker = 0, .player = player, .direction = .from_player, .in_game = true, .slow_ns = std.math.maxInt(u64) };
    const replacing = setup == .one_replace or setup == .two_replace or setup == .typed_replace;
    for (0..1024 + count) |i| {
        if (i == 1024) for (probes[0..subscribers.len]) |*probe| {
            probe.recording = true;
        };
        switch (Packets.run(table, call, text_packet_id, bytes, scratch, Checker{})) {
            .pass => if (replacing) return error.MissingReplacement,
            .cancel => return error.UnexpectedCancellation,
            .replace => |replacement| {
                if (!replacing) return error.UnexpectedReplacement;
                if (setup == .typed_replace) {
                    const value = try Packets.Decoded.decode(replacement, .text, .{});
                    if (!std.mem.eql(u8, value.text.message.slice(), "changed by plugin")) return error.InvalidReplacement;
                } else if (!std.mem.eql(u8, bytes, replacement)) return error.InvalidReplacement;
            },
        }
    }
    for (subscribers, probes[0..subscribers.len]) |subscriber, probe| {
        if (probe.failed or probe.used != count or subscriber.metrics[0].errors.load(.monotonic) != 0) return error.InvalidCallbackSamples;
    }
    return values;
}

test "relay benchmark callback samples preserve typed scope and replacement chains" {
    for ([_]Setup{ .one_raw, .one_lazy, .ten_independent, .ten_shared, .one_replace, .two_replace, .typed_replace, .packet_filter_chat }) |setup| {
        const values = try callbackSamples(std.testing.allocator, std.testing.io, setup, 4);
        defer std.testing.allocator.free(values);
        const listeners: usize = switch (setup) {
            .ten_independent, .ten_shared => 10,
            .two_replace => 2,
            else => 1,
        };
        try std.testing.expectEqual(4 * listeners, values.len);
    }
    try std.testing.expectError(error.InvalidSampleCount, callbackSamples(std.testing.allocator, std.testing.io, .one_raw, 0));
}
