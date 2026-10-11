const std = @import("std");
const bedwire = @import("bedwire");
const bifrost = @import("bifrost");
const sample = @import("sample");
const harness = @import("harness.zig");

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

    pub fn describe(self: Setup) []const u8 {
        return switch (self) {
            .none => "0 plugins",
            .idle_10 => "10 plugins, no packet subscriptions",
            .one_raw => "1 raw subscriber on the hot packet",
            .one_decoded => "1 decoded subscriber on the hot packet",
            .ten_ids => "10 subscribers on different packet ids",
            .ten_hot => "10 subscribers on the same hot packet",
        };
    }

    // Half the stream is the hot packet
    pub fn callbacksPerPacket(self: Setup) f64 {
        return switch (self) {
            .none, .idle_10 => 0,
            .one_raw, .one_decoded => 0.5,
            .ten_ids => 1,
            .ten_hot => 5,
        };
    }

    pub fn budgetNs(self: Setup) f64 {
        return switch (self) {
            .none, .idle_10 => 2,
            .one_decoded => 200,
            else => 100,
        };
    }
};

pub const relay_packet_id: u10 = 1020;
const text_packet_id: u10 = Current.packetId(.text).?;
const cold_ids = [_]u10{ 1, 2, 3, 4, 5, 6, 7, 8 };

var target_id: u10 = 0;

fn pass(_: ?*anyopaque, _: *abi.Packet) callconv(.c) abi.PacketAction {
    return .pass;
}

fn idle(_: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
    plugin.name = .of("idle");
    plugin.plugin_version = .of("1");
    return .ok;
}

fn raw(host: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
    plugin.name = .of("raw");
    plugin.plugin_version = .of("1");
    plugin.capabilities = .{ .packets = true };
    return host.subscribe_packet(host.context, .from_player, target_id, .any, .{}, pass, null);
}

fn decoded(host: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
    plugin.name = .of("decoded");
    plugin.plugin_version = .of("1");
    plugin.capabilities = .{ .packets = true };
    return host.subscribe_packet(host.context, .from_player, target_id, .any, .{ .validated = true }, pass, null);
}

pub fn load(plugins: *bifrost.Plugins, setup: Setup, hot: u10) !void {
    target_id = hot;
    switch (setup) {
        .none => {},
        .idle_10 => for (0..10) |_| try plugins.add(idle, null),
        .one_raw => try plugins.add(raw, null),
        .one_decoded => try plugins.add(decoded, null),
        .ten_hot => for (0..10) |_| try plugins.add(raw, null),
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
    }
    const scratch = try gpa.alloc(u8, Packets.scratch_bytes);
    defer gpa.free(scratch);

    const rounds: usize = if (quick) 200 else 1000;
    var results: [std.enums.values(Setup).len]DispatchResult = undefined;
    for (std.enums.values(Setup), &results) |setup, *result| {
        var plugins: bifrost.Plugins = try .init(gpa, &.{}, .{ .slow_callback_ns = std.math.maxInt(u64) });
        defer plugins.deinit();
        try load(&plugins, setup, text_packet_id);
        const table = plugins.packetTable(.from_player);
        const call: Packets.Call = .{ .io = io, .worker = 0, .player = .{ .id = 1 }, .direction = .from_player, .in_game = true, .slow_ns = std.math.maxInt(u64) };

        var samples: [7]f64 = undefined;
        for (&samples) |*sample_ns| {
            var kept: usize = 0;
            const started = harness.nowNs(io);
            for (0..rounds) |_| for (bounds) |bound| {
                const bytes = storage.items[bound[0]..][0..bound[1]];
                if (table) |hooks| switch (Packets.run(hooks, call, bytes, scratch, Checker{})) {
                    .cancel => continue,
                    else => {},
                };
                kept += bytes.len;
            };
            std.mem.doNotOptimizeAway(kept);
            sample_ns.* = @as(f64, @floatFromInt(harness.nowNs(io) - started)) / @as(f64, @floatFromInt(rounds * stream_len));
        }
        std.mem.sort(f64, &samples, {}, std.sort.asc(f64));
        result.* = .{ .setup = setup, .ns_per_packet = samples[samples.len / 2], .extra_ns = 0 };
    }
    for (&results) |*result| result.extra_ns = result.ns_per_packet - results[0].ns_per_packet;
    return results;
}
