const std = @import("std");
const bedwire = @import("bedwire");
const Outbox = @import("../session/Outbox.zig");

const protocol = bedwire.protocol;
const Vec3f = protocol.Vec3f;

const Handoff = @This();

pub const overworld: i32 = 0;
pub const nether: i32 = 1;
pub const the_end: i32 = 2;

const blank_radius_blocks = 8;

pub const Target = struct {
    dimension: i32,
    position: Vec3f,
};

pub const Progress = enum { sent_target, arrived };

target: Target,
via: ?i32,
step: enum { via, target, arrived },

// Same-dimension moves detour so the client drops its old chunks
pub fn begin(current: i32, target: Target, outbox: *Outbox) !Handoff {
    const via: ?i32 = if (current != target.dimension) null else if (target.dimension == nether) overworld else nether;
    if (via) |dimension| {
        try changeDimension(outbox, dimension, target.position);
        try blankWorld(outbox, dimension, target.position);
    } else try changeDimension(outbox, target.dimension, target.position);
    return .{ .target = target, .via = via, .step = if (via == null) .target else .via };
}

pub fn acknowledged(self: *Handoff, outbox: *Outbox) !Progress {
    switch (self.step) {
        .via => {
            try changeDimension(outbox, self.target.dimension, self.target.position);
            self.step = .target;
            return .sent_target;
        },
        .target, .arrived => {
            self.step = .arrived;
            return .arrived;
        },
    }
}

pub fn waitingForTarget(self: *const Handoff) bool {
    return self.step == .via;
}

fn changeDimension(outbox: *Outbox, dimension: i32, position: Vec3f) !void {
    try outbox.emit(.{ .change_dimension = .{ .dimension_id = dimension, .position = position, .respawn = false, .loading_screen_id = null } });
}

fn blankWorld(outbox: *Outbox, dimension: i32, position: Vec3f) !void {
    const block: protocol.BlockPosition = .{ .x = blockOf(position.x), .y = blockOf(position.y), .z = blockOf(position.z) };
    try outbox.emit(.{ .network_chunk_publisher_update = .{ .new_position_for_view = block, .new_radius_for_view = blank_radius_blocks, .server_built_chunks_list = .empty } });
    var payload: [2 * 24 + 1]u8 = undefined;
    try outbox.emit(.{ .level_chunk = .{
        .chunk_position = .{ .x = block.x >> 4, .z = block.z >> 4 },
        .dimension_id = dimension,
        .sub_chunks_count = 0,
        .client_request_sub_chunk_limit = null,
        .cache_enabled = false,
        .cache_metadata = .empty,
        .serialized_chunk_data = emptyChunk(&payload, dimension),
    } });
}

fn blockOf(coordinate: f32) i32 {
    if (!std.math.isFinite(coordinate)) return 0;
    return std.math.lossyCast(i32, @floor(coordinate));
}

// One single-value biome palette per section, then no border blocks
fn emptyChunk(buffer: *[2 * 24 + 1]u8, dimension: i32) []const u8 {
    const sections: usize, const biome: u8 = switch (dimension) {
        nether => .{ 8, 8 },
        the_end => .{ 16, 9 },
        else => .{ 24, 1 },
    };
    for (0..sections) |i| buffer[2 * i ..][0..2].* = .{ 1, biome << 1 };
    buffer[2 * sections] = 0;
    return buffer[0 .. 2 * sections + 1];
}

pub fn isAck(packet: protocol.BorrowedEnvelope) bool {
    if (packet.value != .typed or packet.value.typed != .player_action) return false;
    return packet.value.typed.player_action.action == .changedimensionack;
}

fn sent(outbox: *Outbox, kinds: []bedwire.PacketKind, dimensions: []i32) !usize {
    var packets: [8][]const u8 = undefined;
    var changes: usize = 0;
    for (outbox.slices(0, &packets), 0..) |packet, i| {
        const decoded = try protocol.Current.decodeBorrowed(packet, .{});
        kinds[i] = decoded.kind.?;
        if (decoded.value.typed == .change_dimension) {
            dimensions[changes] = decoded.value.typed.change_dimension.dimension_id;
            changes += 1;
        }
    }
    outbox.bytes.clearRetainingCapacity();
    outbox.lengths.clearRetainingCapacity();
    return changes;
}

test "a move within one dimension detours through another" {
    var outbox: Outbox = .init(std.testing.allocator);
    defer outbox.deinit();
    var kinds: [8]bedwire.PacketKind = undefined;
    var dimensions: [4]i32 = undefined;

    var handoff = try begin(overworld, .{ .dimension = overworld, .position = .{ .x = 10, .y = 64, .z = -20 } }, &outbox);
    try std.testing.expectEqual(@as(usize, 1), try sent(&outbox, &kinds, &dimensions));
    try std.testing.expectEqual(nether, dimensions[0]);
    try std.testing.expectEqual(bedwire.PacketKind.network_chunk_publisher_update, kinds[1]);
    try std.testing.expectEqual(bedwire.PacketKind.level_chunk, kinds[2]);
    try std.testing.expect(handoff.waitingForTarget());

    try std.testing.expectEqual(Progress.sent_target, try handoff.acknowledged(&outbox));
    try std.testing.expectEqual(@as(usize, 1), try sent(&outbox, &kinds, &dimensions));
    try std.testing.expectEqual(overworld, dimensions[0]);
    try std.testing.expectEqual(Progress.arrived, try handoff.acknowledged(&outbox));
    try std.testing.expectEqual(Progress.arrived, try handoff.acknowledged(&outbox));
    try std.testing.expectEqual(@as(usize, 0), outbox.count());

    _ = try begin(nether, .{ .dimension = nether, .position = .{ .x = 0, .y = 0, .z = 0 } }, &outbox);
    _ = try sent(&outbox, &kinds, &dimensions);
    try std.testing.expectEqual(overworld, dimensions[0]);
}

test "a move to another dimension goes straight there" {
    var outbox: Outbox = .init(std.testing.allocator);
    defer outbox.deinit();
    var kinds: [8]bedwire.PacketKind = undefined;
    var dimensions: [4]i32 = undefined;
    var handoff = try begin(overworld, .{ .dimension = nether, .position = .{ .x = 0, .y = 70, .z = 0 } }, &outbox);
    try std.testing.expectEqual(@as(usize, 1), outbox.count());
    _ = try sent(&outbox, &kinds, &dimensions);
    try std.testing.expectEqual(nether, dimensions[0]);
    try std.testing.expect(!handoff.waitingForTarget());
    try std.testing.expectEqual(Progress.arrived, try handoff.acknowledged(&outbox));
}

test "a hostile spawn position still gives a valid blank chunk" {
    var outbox: Outbox = .init(std.testing.allocator);
    defer outbox.deinit();
    _ = try begin(the_end, .{ .dimension = the_end, .position = .{ .x = std.math.nan(f32), .y = std.math.inf(f32), .z = -1e30 } }, &outbox);
    try std.testing.expectEqual(@as(usize, 3), outbox.count());
}
