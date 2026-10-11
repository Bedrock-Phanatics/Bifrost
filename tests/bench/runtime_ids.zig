const std = @import("std");
const bedwire = @import("bedwire");
const bifrost = @import("bifrost");
const sample = @import("sample");
const harness = @import("harness.zig");

const self_id = bifrost.Managed.self_id;
const Current = bedwire.protocol.Current;
const zero: bedwire.protocol.Vec3f = .{ .x = 0, .y = 0, .z = 0 };

pub const Case = enum {
    identity,
    other_actors,
    own_ids,

    pub fn describe(self: Case) []const u8 {
        return switch (self) {
            .identity => "no transfer yet, or the same ids",
            .other_actors => "swap active, actor packets name other actors",
            .own_ids => "swap active, actor packets name the player",
        };
    }
};

pub const Result = struct {
    case: Case,
    ns_per_packet: f64,
    extra_ns: f64,
};

const stream_len = 4096;
const player = 7;

// Half the stream can carry actor ids, like a busy server's movement and metadata traffic
fn stream(gpa: std.mem.Allocator, storage: *std.ArrayList(u8), bounds: *[stream_len][2]usize, kinds: *[stream_len]?bedwire.PacketKind, target: u64) !void {
    var payload: [64]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = @truncate(i * 31 + 7);
    for (bounds, kinds, 0..) |*bound, *kind, i| {
        var buffer: [256]u8 = undefined;
        const bytes = switch (i % 4) {
            0 => try sample.typedPacket(&buffer, .{ .move_player = .{ .player_runtime_id = target, .position = zero, .rotation = .{ .x = 0, .y = 0 }, .y_head_rotation = 0, .position_mode = .normal, .on_ground = true, .riding_runtime_id = 0, .teleport_data = null, .tick = 1234 } }),
            1 => try sample.typedPacket(&buffer, .{ .set_actor_motion = .{ .target_runtime_id = target, .motion = .{ .x = 0.1, .y = 0, .z = 0.1 }, .tick = 1234 } }),
            2 => try sample.typedPacket(&buffer, .{ .text = .{
                .localize = false,
                .body = .{ .message_only = .{ .message_type = .raw, .message = "hello there, how are things going" } },
                .senders_xuid = "",
                .platform_id = "",
                .filtered_message = null,
            } }),
            else => try sample.rawPacket(&buffer, 1020, &payload),
        };
        kind.* = Current.packetKind((try bedwire.protocol.packet.decode(bytes, .{})).header.packet_id);
        bound.* = .{ storage.items.len, bytes.len };
        try storage.appendSlice(gpa, bytes);
    }
}

pub fn run(gpa: std.mem.Allocator, io: std.Io, quick: bool) ![std.enums.values(Case).len]Result {
    const rounds: usize = if (quick) 50 else 300;
    var results: [std.enums.values(Case).len]Result = undefined;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for (std.enums.values(Case), &results) |case, *result| {
        var storage: std.ArrayList(u8) = .empty;
        defer storage.deinit(gpa);
        var bounds: [stream_len][2]usize = undefined;
        var kinds: [stream_len]?bedwire.PacketKind = undefined;
        try stream(gpa, &storage, &bounds, &kinds, if (case == .own_ids) player else 900);
        const swap: self_id.Swap = .{
            .client = .{ .runtime = player, .unique = player },
            .backend = if (case == .identity) .{ .runtime = player, .unique = player } else .{ .runtime = 5000, .unique = 5000 },
        };

        var samples: [7]f64 = undefined;
        for (&samples) |*sample_ns| {
            var kept: usize = 0;
            const started = harness.nowNs(io);
            for (0..rounds) |_| {
                for (bounds, kinds) |bound, kind| {
                    var packet: []const u8 = storage.items[bound[0]..][0..bound[1]];
                    if (swap.active()) packet = try swap.apply(arena.allocator(), kind, packet, .{}) orelse packet;
                    kept += packet.len;
                }
                _ = arena.reset(.retain_capacity);
            }
            std.mem.doNotOptimizeAway(kept);
            sample_ns.* = @as(f64, @floatFromInt(harness.nowNs(io) - started)) / @as(f64, @floatFromInt(rounds * stream_len));
        }
        std.mem.sort(f64, &samples, {}, std.sort.asc(f64));
        const median = samples[samples.len / 2];
        result.* = .{ .case = case, .ns_per_packet = median, .extra_ns = 0 };
    }
    for (&results) |*result| result.extra_ns = result.ns_per_packet - results[0].ns_per_packet;
    return results;
}
