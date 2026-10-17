const std = @import("std");
const bedwire = @import("bedwire");
const bifrost = @import("bifrost");
const sample = @import("sample");
const harness = @import("harness.zig");

const abi = bifrost.plugin_abi;
const Gameplay = bifrost.Managed.Gameplay;
const protocol = bedwire.protocol;
const Current = protocol.Current;

pub const Case = enum { header_only, auth_input, move_delta, move_absolute, untracked_kind, spawn_remove, query_player, list_entities };
pub const Result = struct { case: Case, ns_per_call: f64, allocations_per_call: f64 };
pub const Memory = struct { entities: usize, heap_bytes: u64 };

const limits: protocol.DecodeLimits = .{};

pub fn run(gpa: std.mem.Allocator, io: std.Io, quick: bool) !struct { results: [std.enums.values(Case).len]Result, memory: Memory } {
    var heap: harness.CountingAllocator = .{ .backing = gpa };
    const loops: usize = if (quick) 20_000 else 200_000;
    var buffers: [4][256]u8 = undefined;
    const inputs = [_]protocol.packets.player_auth_input.PlayerAuthInputInputData{ .sprinting, .up, .jumping, .verticalcollision };
    const auth = try sample.typedPacket(&buffers[0], .{ .player_auth_input = .{
        .player_rotation = .{ .x = 5, .y = 90 },
        .position = .{ .x = 10, .y = 65, .z = 10 },
        .move_vector = .{ .x = 0, .y = 1 },
        .player_head_rotation = 90,
        .input_data = .init(&inputs),
        .input_mode = .mouse,
        .play_mode = .normal,
        .new_interaction_model = .crosshair,
        .interact_rotation = .{ .x = 0, .y = 0 },
        .client_tick = 1234,
        .pos_delta = .{ .x = 0.2, .y = 0, .z = 0 },
        .item_use_transaction = null,
        .item_stack_request = null,
        .player_block_actions = null,
        .vehicle_rotation = null,
        .client_predicted_vehicle = null,
        .analog_move_vector = .{ .x = 0, .y = 1 },
        .camera_orientation = .{ .x = 0, .y = 0, .z = 1 },
        .raw_move_vector = .{ .x = 0, .y = 1 },
    } });
    const delta = try sample.typedPacket(&buffers[1], .{ .move_actor_delta = .{ .move_data = .{ .actor_runtime_id = 600, .new_position_x = 1, .new_position_y = null, .new_position_z = 3, .rotation_x = null, .rotation_y = 12, .rotation_y_head = 12, .is_on_ground = true, .force_move = false, .force_move_local_entity = false, .force_completion = false, .ticks = 99 } } });
    const absolute = try sample.typedPacket(&buffers[2], .{ .move_actor_absolute = .{ .move_data = .{ .actor_runtime_id = 600, .header = 1, .position = .{ .x = 1, .y = 2, .z = 3 }, .rotation_x = 0, .rotation_y = 64, .rotation_y_head = 64 } } });

    var state: Gameplay = .{};
    defer state.deinit(heap.allocator());
    const before_entities = heap.live.load(.monotonic);
    for (0..Gameplay.max_entities) |i| state.sent(heap.allocator(), envelope(painting(i + 100)));
    const memory: Memory = .{ .entities = state.entities.count(), .heap_bytes = heap.live.load(.monotonic) - before_entities };
    if (memory.entities != Gameplay.max_entities) return error.InvalidBenchmark;

    var list: [Gameplay.max_entities]abi.Entity = undefined;
    var results: [std.enums.values(Case).len]Result = undefined;
    for (std.enums.values(Case), &results) |case, *result| {
        var times: [7]u64 = undefined;
        var allocations: u64 = 0;
        for (&times) |*time| {
            const before = heap.allocations.load(.monotonic);
            const started = harness.nowNs(io);
            for (0..loops) |i| switch (case) {
                .header_only => std.mem.doNotOptimizeAway(try protocol.packet.decode(auth, limits)),
                .auth_input => {
                    const header = try protocol.packet.decode(auth, limits);
                    if (Gameplay.fromPlayer(Current.packetKind(header.header.packet_id))) state.reported(try Current.decodeBorrowed(auth, limits));
                },
                .move_delta, .move_absolute => {
                    const bytes = if (case == .move_delta) delta else absolute;
                    const header = try protocol.packet.decode(bytes, limits);
                    if (Gameplay.fromBackend(Current.packetKind(header.header.packet_id), .{ .entities = true })) state.sent(heap.allocator(), try Current.decodeBorrowed(bytes, limits));
                },
                .untracked_kind => {
                    const header = try protocol.packet.decode(delta, limits);
                    std.mem.doNotOptimizeAway(Gameplay.fromBackend(Current.packetKind(header.header.packet_id), .{}));
                },
                .spawn_remove => {
                    state.sent(heap.allocator(), envelope(.{ .remove_actor = .{ .target_actor_id = @intCast(100 + i % Gameplay.max_entities) } }));
                    state.sent(heap.allocator(), envelope(painting(100 + i % Gameplay.max_entities)));
                },
                .query_player => {
                    var out: abi.Gameplay = undefined;
                    _ = state.answer(.{ .player = &out }, 1, std.StaticBitSet(256).empty);
                    std.mem.doNotOptimizeAway(out);
                },
                .list_entities => {
                    var total: usize = 0;
                    _ = state.answer(.{ .entities = .{ .out = &list, .total = &total, .complete = null } }, 1, std.StaticBitSet(256).empty);
                    std.mem.doNotOptimizeAway(list[total - 1]);
                },
            };
            time.* = harness.nowNs(io) - started;
            allocations += heap.allocations.load(.monotonic) - before;
        }
        if (state.entities.count() != Gameplay.max_entities) return error.InvalidBenchmark;
        std.mem.sort(u64, &times, {}, std.sort.asc(u64));
        result.* = .{ .case = case, .ns_per_call = @as(f64, @floatFromInt(times[3])) / @as(f64, @floatFromInt(loops)), .allocations_per_call = @as(f64, @floatFromInt(allocations)) / @as(f64, @floatFromInt(loops * times.len)) };
    }
    return .{ .results = results, .memory = memory };
}

fn painting(id: u64) protocol.typed.Packet {
    return .{ .add_painting = .{ .target_actor_id = @intCast(id), .target_runtime_id = id, .position = .{ .x = 0, .y = 0, .z = 0 }, .direction = 0, .motif = "Kebab" } };
}

fn envelope(value: protocol.typed.Packet) protocol.BorrowedEnvelope {
    return .{ .header = .{ .packet_id = 0 }, .kind = null, .payload = &.{}, .value = .{ .typed = value } };
}

test "relay benchmark gameplay tracking stays bounded and allocation free" {
    const outcome = try run(std.testing.allocator, std.testing.io, true);
    for (outcome.results) |result| try std.testing.expectEqual(@as(f64, 0), result.allocations_per_call);
    try std.testing.expect(outcome.memory.heap_bytes < 128 * 1024);
}
