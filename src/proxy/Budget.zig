const std = @import("std");

const Budget = @This();

limit: usize,
used: std.atomic.Value(usize) = .init(0),
refusals: std.atomic.Value(u64) = .init(0),

pub fn init(limit: usize) Budget {
    return .{ .limit = limit };
}

pub fn reserve(self: *Budget, amount: usize) bool {
    var current = self.used.load(.monotonic);
    while (amount <= self.limit - current) {
        current = self.used.cmpxchgWeak(current, current + amount, .monotonic, .monotonic) orelse return true;
    }
    _ = self.refusals.fetchAdd(1, .monotonic);
    return false;
}

pub fn release(self: *Budget, amount: usize) void {
    const before = self.used.fetchSub(amount, .monotonic);
    std.debug.assert(before >= amount);
}

test "reservations never pass the limit and release exactly" {
    var budget: Budget = .init(10);
    try std.testing.expect(budget.reserve(0));
    try std.testing.expect(budget.reserve(6));
    try std.testing.expect(!budget.reserve(5));
    try std.testing.expect(budget.reserve(4));
    try std.testing.expect(!budget.reserve(1));
    try std.testing.expect(!budget.reserve(std.math.maxInt(usize)));
    budget.release(6);
    try std.testing.expect(budget.reserve(6));
    budget.release(10);
    try std.testing.expectEqual(@as(usize, 0), budget.used.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 3), budget.refusals.load(.monotonic));
}

test "threads sharing a budget stay within it and drain to zero" {
    const Worker = struct {
        fn run(budget: *Budget, seed: u64, peak: *std.atomic.Value(usize)) void {
            var random: std.Random.DefaultPrng = .init(seed);
            var held: [16]usize = @splat(0);
            for (0..20_000) |i| {
                const slot = i % held.len;
                if (held[slot] != 0) {
                    budget.release(held[slot]);
                    held[slot] = 0;
                }
                // One thread alone can pass the limit, so refusals happen even if the threads never overlap
                const amount = random.random().uintAtMost(usize, 600);
                if (budget.reserve(amount)) held[slot] = amount;
                _ = peak.fetchMax(budget.used.load(.monotonic), .monotonic);
            }
            for (held) |amount| budget.release(amount);
        }
    };
    var budget: Budget = .init(4096);
    var peak: std.atomic.Value(usize) = .init(0);
    var threads: [8]std.Thread = undefined;
    for (&threads, 0..) |*thread, i| thread.* = try .spawn(.{}, Worker.run, .{ &budget, i, &peak });
    for (threads) |thread| thread.join();
    try std.testing.expectEqual(@as(usize, 0), budget.used.load(.monotonic));
    try std.testing.expect(peak.load(.monotonic) <= budget.limit);
    try std.testing.expect(budget.refusals.load(.monotonic) > 0);
}
