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

fn measure(comptime spawn: anytype, gpa: std.mem.Allocator, io: std.Io, threads: usize, with_churn: bool, ms: i64) !Result {
    var handles: Handles = .{};
    defer handles.deinit(gpa);
    var players: [live_players]abi.Player = undefined;
    for (&players, 0..) |*player, i| player.* = try handles.acquire(gpa, .{ .context = &context, .link = i, .transfer = noTransfer });

    stop.store(false, .release);
    var counts: [8]u64 = @splat(0);
    var workers: [8]std.Thread = undefined;
    var started_workers: usize = 0;
    errdefer {
        stop.store(true, .release);
        for (workers[0..started_workers]) |worker| worker.join();
    }
    for (workers[0..threads], counts[0..threads], 0..) |*worker, *count, i| {
        worker.* = try spawn(.{}, lookup, .{ &handles, &players, i + 1, count });
        started_workers += 1;
    }
    const churner = if (with_churn) try spawn(.{}, churn, .{ &handles, gpa }) else null;
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
        results[index] = try measure(std.Thread.spawn, gpa, io, threads, with_churn, ms);
        index += 1;
    };
    return results;
}

test "handle benchmark joins threads after a spawn failure" {
    const Fault = struct {
        var fail_at: usize = 0;
        var attempts: usize = 0;
        var exited: std.atomic.Value(u32) = .init(0);

        fn spawn(config: std.Thread.SpawnConfig, comptime function: anytype, args: anytype) std.Thread.SpawnError!std.Thread {
            _ = function;
            _ = args;
            const attempt = attempts;
            attempts += 1;
            if (attempt == fail_at) return error.ThreadQuotaExceeded;
            return std.Thread.spawn(config, wait, .{});
        }

        fn wait() void {
            while (!stop.load(.acquire)) std.atomic.spinLoopHint();
            _ = exited.fetchAdd(1, .release);
        }
    };

    for (0..5) |fail_at| {
        Fault.fail_at = fail_at;
        Fault.attempts = 0;
        Fault.exited.store(0, .monotonic);
        try std.testing.expectError(error.ThreadQuotaExceeded, measure(Fault.spawn, std.testing.allocator, std.testing.io, 4, true, 1));
        try std.testing.expect(stop.load(.acquire));
        try std.testing.expectEqual(@as(u32, @intCast(fail_at)), Fault.exited.load(.acquire));
    }
}
