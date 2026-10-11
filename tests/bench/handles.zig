const std = @import("std");
const bifrost = @import("bifrost");
const harness = @import("harness.zig");

const abi = bifrost.plugin_abi;
const Handles = bifrost.Plugins.Handles;

pub const Result = struct {
    threads: usize,
    churn: bool,
    ns_per_lookup: f64,
    lookups_per_s: f64,
};

const live_players = 1024;

var stop: std.atomic.Value(bool) = .init(false);
var context: u8 = 0;

fn noTransfer(_: *anyopaque, _: u64, _: u32) abi.Status {
    return .ok;
}

fn lookup(handles: *Handles, players: []const abi.Player, seed: u64, count: *u64) void {
    var prng: std.Random.DefaultPrng = .init(seed);
    var found: u64 = 0;
    var done: u64 = 0;
    while (!stop.load(.monotonic)) {
        for (0..256) |_| found += @intFromBool(handles.route(players[prng.random().uintLessThan(usize, players.len)]) != null);
        done += 256;
    }
    std.mem.doNotOptimizeAway(found);
    count.* = done;
}

fn churn(handles: *Handles, gpa: std.mem.Allocator) void {
    while (!stop.load(.monotonic)) {
        const player = handles.acquire(gpa, .{ .context = &context, .link = 0, .transfer = noTransfer }) catch return;
        handles.setName(player, "Steve");
        handles.release(player);
    }
}

fn measure(gpa: std.mem.Allocator, io: std.Io, threads: usize, with_churn: bool, ms: i64) !Result {
    var handles: Handles = .{};
    defer handles.deinit(gpa);
    var players: [live_players]abi.Player = undefined;
    for (&players, 0..) |*player, i| player.* = try handles.acquire(gpa, .{ .context = &context, .link = i, .transfer = noTransfer });

    stop.store(false, .release);
    var counts: [8]u64 = @splat(0);
    var workers: [8]std.Thread = undefined;
    for (workers[0..threads], counts[0..threads], 0..) |*worker, *count, i| worker.* = try std.Thread.spawn(.{}, lookup, .{ &handles, &players, i + 1, count });
    const churner = if (with_churn) try std.Thread.spawn(.{}, churn, .{ &handles, gpa }) else null;
    const started = harness.nowNs(io);
    harness.sleepMs(io, ms);
    stop.store(true, .release);
    const elapsed = harness.nowNs(io) - started;
    for (workers[0..threads]) |worker| worker.join();
    if (churner) |thread| thread.join();

    var total: u64 = 0;
    for (counts[0..threads]) |count| total += count;
    const seconds = @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_s;
    const per_thread = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(threads));
    return .{
        .threads = threads,
        .churn = with_churn,
        .ns_per_lookup = @as(f64, @floatFromInt(elapsed)) / per_thread,
        .lookups_per_s = @as(f64, @floatFromInt(total)) / seconds,
    };
}

pub fn run(gpa: std.mem.Allocator, io: std.Io, quick: bool) ![8]Result {
    const ms: i64 = if (quick) 200 else 1000;
    var results: [8]Result = undefined;
    var index: usize = 0;
    for ([_]bool{ false, true }) |with_churn| for ([_]usize{ 1, 2, 4, 8 }) |threads| {
        results[index] = try measure(gpa, io, threads, with_churn, ms);
        index += 1;
    };
    return results;
}
