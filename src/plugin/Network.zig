const std = @import("std");
const Peer = @import("../net/Peer.zig");
const abi = @import("abi.zig");

// libdatachannel's C API has no SCTP round trip or loss counters, so only queues and rates are reported
pub fn snapshot(peer: *Peer, now_ms: u64) abi.NetworkStats {
    const stats = peer.connection.callbackStats();
    return .{
        .mtu = 1200,
        .available = abi.NetworkMetric.queues,
        .sampled_at_ms = now_ms,
        .queued_bytes = peer.buffered(),
        .queued_packets_high_water = stats.queue_high_water_entries,
    };
}

pub const Traffic = struct {
    messages_received: u64 = 0,
    messages_sent: u64 = 0,
    bytes_received: u64 = 0,
    bytes_sent: u64 = 0,

    pub fn of(connection: anytype) Traffic {
        return .{
            .messages_received = connection.received_messages,
            .messages_sent = connection.sent_messages,
            .bytes_received = connection.received_bytes,
            .bytes_sent = connection.sent_bytes,
        };
    }
};

pub const Rates = struct {
    previous: ?Traffic = null,
    since_ms: u64 = 0,

    pub fn sample(self: *Rates, traffic: Traffic, out: *abi.NetworkStats) void {
        const previous = self.previous orelse {
            self.previous = traffic;
            self.since_ms = out.sampled_at_ms;
            return;
        };
        const elapsed = out.sampled_at_ms -| self.since_ms;
        if (elapsed < 250) return;
        self.previous = traffic;
        self.since_ms = out.sampled_at_ms;
        out.available |= abi.NetworkMetric.rates;
        out.rate_interval_ms = elapsed;
        out.incoming_packets_per_second = perSecond(traffic.messages_received -| previous.messages_received, elapsed);
        out.outgoing_packets_per_second = perSecond(traffic.messages_sent -| previous.messages_sent, elapsed);
        out.incoming_bytes_per_second = perSecond(traffic.bytes_received -| previous.bytes_received, elapsed);
        out.outgoing_bytes_per_second = perSecond(traffic.bytes_sent -| previous.bytes_sent, elapsed);
    }
};

fn perSecond(delta: u64, elapsed_ms: u64) u64 {
    return @intCast(@min(std.math.maxInt(u64), @as(u128, delta) * 1000 / elapsed_ms));
}

test "rates need two samples a quarter second apart" {
    var rates: Rates = .{};
    var out: abi.NetworkStats = .{ .sampled_at_ms = 1000 };
    rates.sample(.{}, &out);
    try std.testing.expectEqual(@as(u64, 0), out.available & abi.NetworkMetric.rates);
    out.sampled_at_ms = 1100;
    rates.sample(.{ .bytes_received = 100 }, &out);
    try std.testing.expectEqual(@as(u64, 0), out.available & abi.NetworkMetric.rates);
    out.sampled_at_ms = 1500;
    rates.sample(.{ .bytes_received = 1000, .messages_received = 10 }, &out);
    try std.testing.expectEqual(@as(u64, 2000), out.incoming_bytes_per_second);
    try std.testing.expectEqual(@as(u64, 20), out.incoming_packets_per_second);
    try std.testing.expectEqual(@as(u64, 500), out.rate_interval_ms);
    out.sampled_at_ms = 2000;
    rates.sample(.{ .bytes_received = std.math.maxInt(u64) }, &out);
    try std.testing.expect(out.incoming_bytes_per_second > 0);
}
