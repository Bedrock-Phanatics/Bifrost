const std = @import("std");
const raknet = @import("raknet");
const abi = @import("abi.zig");

pub fn snapshot(stats: raknet.SessionStatistics, now_ms: u64) abi.NetworkStats {
    var out: abi.NetworkStats = .{
        .mtu = stats.mtu,
        .available = abi.NetworkMetric.reliability | abi.NetworkMetric.queues,
        .sampled_at_ms = now_ms,
        .retransmission_timeout_ms = stats.retransmission_timeout_ms,
        .acknowledged_datagrams = stats.acknowledged_datagrams,
        .lost_datagrams = stats.lost_datagrams,
        .retransmitted_datagrams = stats.retransmitted_datagrams,
        .ack_records_received = stats.ack_records_received,
        .nack_records_received = stats.nack_records_received,
        .ack_records_sent = stats.ack_records_sent,
        .nack_records_sent = stats.nack_records_sent,
        .queued_packets = stats.queued_packets,
        .queued_bytes = stats.queued_payload_bytes,
        .queued_packets_high_water = stats.queued_packets_high_water,
        .recovery_packets = stats.recovery_packets,
        .recovery_bytes = stats.recovery_payload_bytes,
        .ordered_packets = stats.ordered_packets,
        .ordered_bytes = stats.ordered_payload_bytes,
        .in_flight_bytes = stats.in_flight_bytes,
        .congestion_window_bytes = stats.congestion_window_bytes,
    };
    if (stats.smoothed_rtt_ms) |rtt| {
        out.available |= abi.NetworkMetric.rtt;
        out.rtt_ms = rtt;
    }
    const total = @as(u128, stats.acknowledged_datagrams) + stats.lost_datagrams;
    if (total != 0) {
        out.available |= abi.NetworkMetric.loss_estimate;
        out.loss_estimate_ppm = @intCast(@as(u128, stats.lost_datagrams) * 1_000_000 / total);
    }
    return out;
}

pub const Rates = struct {
    previous: ?[4]u64 = null,
    since_ms: u64 = 0,

    pub fn sample(self: *Rates, traffic: raknet.advanced.net.Traffic, out: *abi.NetworkStats) void {
        const values = [4]u64{ traffic.datagrams_received, traffic.datagrams_sent, traffic.bytes_received, traffic.bytes_sent };
        const previous = self.previous;
        const elapsed = out.sampled_at_ms -| self.since_ms;
        if (previous == null) {
            self.previous = values;
            self.since_ms = out.sampled_at_ms;
            return;
        }
        if (elapsed < 250) return;
        self.previous = values;
        self.since_ms = out.sampled_at_ms;
        out.available |= abi.NetworkMetric.rates;
        out.rate_interval_ms = elapsed;
        inline for (values, previous.?, .{ "incoming_packets_per_second", "outgoing_packets_per_second", "incoming_bytes_per_second", "outgoing_bytes_per_second" }) |value, before, result| {
            const delta = value -| before;
            @field(out, result) = @intCast(@min(std.math.maxInt(u64), @as(u128, delta) * 1000 / elapsed));
        }
    }
};

test "network snapshots distinguish missing metrics and handle high latency and loss" {
    var core = try raknet.advanced.session.Core.init(std.testing.allocator, 1400, .{});
    defer core.deinit();
    var stats = core.statistics();
    var out = snapshot(stats, 1000);
    try std.testing.expectEqual(@as(u64, abi.NetworkMetric.reliability | abi.NetworkMetric.queues), out.available);
    stats.smoothed_rtt_ms = 1200;
    stats.acknowledged_datagrams = 3;
    stats.lost_datagrams = 1;
    stats.retransmitted_datagrams = 4;
    stats.queued_packets = 64;
    out = snapshot(stats, 2000);
    try std.testing.expectEqual(@as(u64, 1200), out.rtt_ms);
    try std.testing.expectEqual(@as(u32, 250_000), out.loss_estimate_ppm);
    try std.testing.expectEqual(@as(u64, 4), out.retransmitted_datagrams);
    try std.testing.expectEqual(@as(u64, 64), out.queued_packets);
    try std.testing.expectEqual(@as(u64, 0), out.available & (abi.NetworkMetric.jitter | abi.NetworkMetric.duplicates | abi.NetworkMetric.out_of_order | abi.NetworkMetric.anomalies | abi.NetworkMetric.rates));
    stats.acknowledged_datagrams = std.math.maxInt(u64);
    stats.lost_datagrams = std.math.maxInt(u64);
    try std.testing.expectEqual(@as(u32, 500_000), snapshot(stats, 3000).loss_estimate_ppm);

    var rates: Rates = .{};
    out = snapshot(core.statistics(), 1000);
    rates.sample(.{}, &out);
    try std.testing.expectEqual(@as(u64, 0), out.available & abi.NetworkMetric.rates);
    out.sampled_at_ms = 1100;
    rates.sample(.{ .bytes_received = 100 }, &out);
    try std.testing.expectEqual(@as(u64, 0), out.available & abi.NetworkMetric.rates);
    out.sampled_at_ms = 1500;
    rates.sample(.{ .bytes_received = 1000, .datagrams_received = 10 }, &out);
    try std.testing.expectEqual(@as(u64, 2000), out.incoming_bytes_per_second);
    try std.testing.expectEqual(@as(u64, 20), out.incoming_packets_per_second);
    try std.testing.expectEqual(@as(u64, 500), out.rate_interval_ms);
}

test "network snapshots follow RakNet delayed acknowledgments and retransmission timeouts" {
    const Discard = struct {
        fn message(_: *anyopaque, _: raknet.BorrowedPayload) !void {}
    };
    var config: raknet.Config = .{};
    config.timing.maximum_rto_ms = 10_000;
    var core = try raknet.advanced.session.Core.init(std.testing.allocator, 1400, config);
    defer core.deinit();
    try core.trackSent(0, "wire", 4, 100);
    var buffer: [32]u8 = undefined;
    const ack = try raknet.advanced.protocol.datagram.encodeControl(.ack, &.{.{ .first = 0, .last = 0 }}, &buffer);
    var context: u8 = 0;
    _ = try core.processIncoming(ack, 1600, &context, Discard.message);
    var out = snapshot(core.statistics(), 1600);
    try std.testing.expectEqual(@as(u64, 1500), out.rtt_ms);
    try std.testing.expectEqual(@as(u64, 1), out.acknowledged_datagrams);
    try std.testing.expectEqual(@as(u32, 0), out.loss_estimate_ppm);
    try core.trackSent(1, "lost", 4, 1700);
    var due: [1]raknet.advanced.reliability.recovery.Due = undefined;
    const expired = 1700 + out.retransmission_timeout_ms;
    try std.testing.expectEqual(@as(usize, 1), core.collectRetransmissions(expired, &due, 1).items.len);
    out = snapshot(core.statistics(), expired);
    try std.testing.expectEqual(@as(u64, 1), out.lost_datagrams);
    try std.testing.expectEqual(@as(u64, 1), out.retransmitted_datagrams);
    try std.testing.expectEqual(@as(u32, 500_000), out.loss_estimate_ppm);
    try std.testing.expectEqual(@as(u64, 1), out.recovery_packets);
}
