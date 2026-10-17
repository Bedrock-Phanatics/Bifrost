const std = @import("std");

const Rate = @This();

per_second: u64,
capacity: u64,
milli: u64,
last_ms: u64 = 0,

pub const unlimited: Rate = .{ .per_second = std.math.maxInt(u64), .capacity = std.math.maxInt(u64), .milli = std.math.maxInt(u64) };

pub fn init(per_second: u32, burst: u64) Rate {
    const capacity = burst *| 1000;
    return .{ .per_second = per_second, .capacity = capacity, .milli = capacity };
}

// Always lets one maximum-size batch through
pub fn bytes(per_second: u32) Rate {
    if (per_second == 0) return .unlimited;
    return .init(per_second, @max(4 * @as(u64, per_second), 4 * 1024 * 1024));
}

pub fn take(self: *Rate, now_ms: u64, amount: u64) bool {
    if (now_ms > self.last_ms) {
        self.milli = @min(self.capacity, self.milli +| (now_ms - self.last_ms) *| self.per_second);
        self.last_ms = now_ms;
    }
    const cost = amount *| 1000;
    if (cost > self.milli) return false;
    self.milli -= cost;
    return true;
}

test "spends the burst, then refills at the rate" {
    var rate: Rate = .init(10, 20);
    for (0..20) |_| try std.testing.expect(rate.take(1_000, 1));
    try std.testing.expect(!rate.take(1_000, 1));
    try std.testing.expect(!rate.take(1_050, 1));
    try std.testing.expect(rate.take(1_100, 1));
    try std.testing.expect(!rate.take(1_100, 1));
    try std.testing.expect(rate.take(60_000, 20));
    try std.testing.expect(!rate.take(60_000, 1));
}

test "a clock going backwards or huge amounts never overflow" {
    var rate: Rate = .init(std.math.maxInt(u32), std.math.maxInt(u64));
    try std.testing.expect(rate.take(std.math.maxInt(u64), std.math.maxInt(u64) / 2000));
    try std.testing.expect(!rate.take(0, std.math.maxInt(u64)));
    var small: Rate = .init(1, 1);
    try std.testing.expect(small.take(5, 1));
    try std.testing.expect(!small.take(4, 1));
    var open: Rate = .unlimited;
    try std.testing.expect(open.take(0, 4 * 1024 * 1024 * 1024));
}
