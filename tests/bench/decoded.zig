const std = @import("std");
const bifrost = @import("bifrost");
const sample = @import("sample");
const harness = @import("harness.zig");
const abi = bifrost.plugin_abi;
const Decoded = bifrost.Plugins.Packets.Decoded;

pub const Case = enum { raw, lazy, independent, shared, raw_replacement, typed_replacement };
pub const Result = struct { case: Case, ns_per_packet: f64 };

fn consume(value: Decoded.Value) usize {
    std.mem.doNotOptimizeAway(value);
    return switch (value) {
        .text => |text| text.message.len,
        .chunk_radius => |radius| radius.max_radius,
    };
}

pub fn run(gpa: std.mem.Allocator, io: std.Io, quick: bool) ![std.enums.values(Case).len]Result {
    const count = 4096;
    const rounds: usize = if (quick) 100 else 500;
    var storage: std.ArrayList(u8) = .empty;
    defer storage.deinit(gpa);
    var bounds: [count][2]usize = undefined;
    for (&bounds, 0..) |*bound, i| {
        var buffer: [256]u8 = undefined;
        var message: [80]u8 = undefined;
        const bytes = try sample.typedPacket(&buffer, .{ .text = .{
            .localize = false,
            .body = .{ .author_and_message = .{ .message_type = .chat, .player_name = "Steve", .message = try std.fmt.bufPrint(&message, "hello there, this is message {d}", .{i}) } },
            .senders_xuid = "2535400000000001",
            .platform_id = "",
            .filtered_message = null,
        } });
        bound.* = .{ storage.items.len, bytes.len };
        try storage.appendSlice(gpa, bytes);
    }
    var out: [64 * 1024]u8 = undefined;
    var results: [std.enums.values(Case).len]Result = undefined;
    for (std.enums.values(Case), &results) |case, *result| {
        var samples: [7]f64 = undefined;
        for (&samples) |*ns| {
            var kept: usize = 0;
            const started = harness.nowNs(io);
            for (0..rounds) |_| for (bounds) |bound| {
                const bytes = storage.items[bound[0]..][0..bound[1]];
                std.mem.doNotOptimizeAway(bytes);
                switch (case) {
                    .raw => kept += bytes.len,
                    .lazy => kept += consume(try Decoded.decode(bytes, .text, .{})),
                    .independent => for (0..10) |_| {
                        std.mem.doNotOptimizeAway(bytes);
                        kept += consume(try Decoded.decode(bytes, .text, .{}));
                    },
                    .shared => {
                        const value = try Decoded.decode(bytes, .text, .{});
                        for (0..10) |_| kept += consume(value);
                    },
                    .raw_replacement => {
                        @memcpy(out[0..bytes.len], bytes);
                        std.mem.doNotOptimizeAway(out[0..bytes.len]);
                        kept += bytes.len;
                    },
                    .typed_replacement => {
                        const value = try Decoded.decode(bytes, .text, .{});
                        const header = (try @import("bedwire").protocol.packet.decode(bytes, .{})).header;
                        const len = try Decoded.encode(header, .text, &value.text, &out);
                        kept += len;
                        std.mem.doNotOptimizeAway(out[0..len]);
                    },
                }
            };
            std.mem.doNotOptimizeAway(kept);
            ns.* = @as(f64, @floatFromInt(harness.nowNs(io) - started)) / @as(f64, @floatFromInt(rounds * count));
        }
        std.mem.sort(f64, &samples, {}, std.sort.asc(f64));
        result.* = .{ .case = case, .ns_per_packet = samples[samples.len / 2] };
    }
    return results;
}
