const std = @import("std");
const bifrost = @import("bifrost");
const harness = @import("harness.zig");

pub const Result = struct {
    players: usize,
    ns_per_lookup: f64,
    index_heap: u64,
};

pub fn run(gpa: std.mem.Allocator, io: std.Io, quick: bool) ![4]Result {
    var heap: harness.CountingAllocator = .{ .backing = gpa };
    const allocator = heap.allocator();
    var results: [4]Result = undefined;
    const rounds: usize = if (quick) 65536 else 524288;
    for ([_]usize{ 1, 64, 512, 4096 }, &results) |count, *result| {
        const links = try allocator.alloc(bifrost.Proxy.Link, count);
        defer allocator.free(links);
        const baseline = heap.live.load(.monotonic);
        var proxy: bifrost.Proxy = undefined;
        proxy.links = .empty;
        defer proxy.links.deinit(allocator);
        try proxy.links.ensureTotalCapacity(allocator, count);
        for (links, 0..) |*link, i| {
            link.id = i + 1;
            link.managed = null;
            proxy.links.putAssumeCapacityNoClobber(link.id, link);
        }
        var ids: [4096]u64 = undefined;
        var prng: std.Random.DefaultPrng = .init(1);
        for (&ids) |*id| id.* = prng.random().uintLessThan(u64, count) + 1;
        const allocations = heap.allocations.load(.monotonic);
        for (ids) |id| if (proxy.packet(id, .player, "") != .unsupported) return error.LookupFailed;
        var times: [7]u64 = undefined;
        for (&times) |*elapsed| {
            std.mem.doNotOptimizeAway(&proxy);
            const started = harness.nowNs(io);
            for (0..rounds) |i| if (proxy.packet(ids[i % ids.len], .player, "") != .unsupported) return error.LookupFailed;
            elapsed.* = harness.nowNs(io) - started;
        }
        if (heap.allocations.load(.monotonic) != allocations) return error.LookupAllocated;
        std.mem.sort(u64, &times, {}, std.sort.asc(u64));
        result.* = .{
            .players = count,
            .ns_per_lookup = @as(f64, @floatFromInt(times[times.len / 2])) / @as(f64, @floatFromInt(rounds)),
            .index_heap = heap.live.load(.monotonic) - baseline,
        };
    }
    return results;
}
