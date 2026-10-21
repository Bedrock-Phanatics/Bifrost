const std = @import("std");
const bifrost = @import("bifrost");
const harness = @import("harness.zig");
const abi = bifrost.plugin_abi;
const Network = bifrost.Plugins.Network;

pub const Case = enum { player_info, network_snapshot, rate_sample, worker_post, disconnect_action, event_0, event_1, event_10 };
pub const Result = struct { case: Case, ns_per_call: f64, allocations_per_call: f64 };

var host: *const abi.Host = undefined;
var instance: u32 = 0;
var name: [32]u8 = undefined;
var events: usize = 0;

fn init(api: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
    instance += 1;
    plugin.name = .of(std.fmt.bufPrint(&name, "player-bench-{d}", .{instance}) catch unreachable);
    plugin.plugin_version = .of("1");
    plugin.capabilities.events = true;
    host = api;
    return if (events == 0) .ok else api.subscribe(api.context, .connection_phase_changed, onEvent, null);
}

fn onEvent(_: ?*anyopaque, event: *const abi.Event, _: ?*abi.TransferDecision) callconv(.c) void {
    std.mem.doNotOptimizeAway(event);
}
fn noTransfer(_: *anyopaque, _: u64, _: u32) abi.Status {
    return .ok;
}

const Runner = struct {
    api: *const abi.Host,
    io: std.Io,
    case: Case = .network_snapshot,
    loops: usize,
    elapsed: u64 = 0,
    failed: bool = false,

    fn network(context: *anyopaque, _: u64, _: abi.PacketTarget, out: *abi.NetworkStats) abi.Status {
        const self: *Runner = @ptrCast(@alignCast(context));
        out.* = .{ .mtu = 1200, .available = abi.NetworkMetric.queues, .sampled_at_ms = harness.nowNs(self.io) / std.time.ns_per_ms, .queued_bytes = 4096 };
        return .ok;
    }

    fn done(user: ?*anyopaque, result: *const abi.TaskResult) callconv(.c) void {
        const self: *Runner = @ptrCast(@alignCast(user.?));
        if (result.status != .ok) {
            self.failed = true;
            return;
        }
        self.measure(result.player);
    }

    fn measure(self: *Runner, player: abi.Player) void {
        var rates: Network.Rates = .{};
        var snapshot: abi.NetworkStats = .{};
        var info: abi.PlayerInfo = undefined;
        const started = harness.nowNs(self.io);
        for (0..self.loops) |i| switch (self.case) {
            .player_info => {
                if (self.api.player_info(self.api.context, player, &info, @sizeOf(abi.PlayerInfo)) != .ok) self.failed = true;
                std.mem.doNotOptimizeAway(info);
            },
            .network_snapshot => {
                if (self.api.network_stats(self.api.context, player, .player, &snapshot, @sizeOf(abi.NetworkStats)) != .ok) self.failed = true;
                std.mem.doNotOptimizeAway(snapshot);
            },
            .rate_sample => {
                snapshot.sampled_at_ms = i * 250;
                rates.sample(.{ .bytes_received = i * 1024, .messages_received = i }, &snapshot);
                std.mem.doNotOptimizeAway(snapshot);
            },
            else => unreachable,
        };
        self.elapsed = harness.nowNs(self.io) - started;
    }
};

const Sink = struct {
    delivered: usize = 0,
    pub fn message(_: *Sink, _: u64, _: []const u8) void {}
    pub fn packet(_: *Sink, _: u64, _: abi.PacketTarget, _: []const u8) abi.Status {
        return .unsupported;
    }
    pub fn action(self: *Sink, _: u64, _: bool, _: u32, _: []const u8) abi.Status {
        self.delivered += 1;
        return .ok;
    }
    fn done(user: ?*anyopaque, _: *const abi.TaskResult) callconv(.c) void {
        const self: *Sink = @ptrCast(@alignCast(user.?));
        self.delivered += 1;
    }
};

pub fn run(gpa: std.mem.Allocator, io: std.Io, quick: bool) ![8]Result {
    var heap: harness.CountingAllocator = .{ .backing = gpa };
    var results: [8]Result = undefined;
    const loops: usize = if (quick) 50_000 else 500_000;
    for (std.meta.tags(Case), &results) |case, *result| {
        var plugins: bifrost.Plugins = try .init(heap.allocator(), &.{}, .{ .slow_callback_ns = std.math.maxInt(u64) });
        defer plugins.deinit();
        events = if (case == .event_10) 10 else if (case == .event_1) 1 else 0;
        for (0..@max(events, 1)) |_| try plugins.add(init, null);
        var runner: Runner = .{ .api = host, .io = io, .loops = loops, .case = case };
        const player = try plugins.handles.acquire(heap.allocator(), .{ .context = &runner, .link = 1, .transfer = noTransfer, .network = Runner.network, .io = io });
        plugins.handles.setIdentity(player, "Steve", "2535400000000001", "00000000-0000-0000-0000-000000000001", true);
        var sink: Sink = .{};
        var times: [7]u64 = undefined;
        var allocations: u64 = 0;
        const baseline = heap.live.load(.monotonic);
        for (&times) |*time| {
            const before = heap.allocations.load(.monotonic);
            const started = harness.nowNs(io);
            switch (case) {
                .worker_post, .disconnect_action => {
                    for (0..loops) |_| {
                        const status = if (case == .worker_post) host.post(host.context, player, Sink.done, &sink) else host.disconnect(host.context, player, .{}, null, null);
                        if (status != .ok) return error.ActionRejected;
                        plugins.drain(0, io, &sink);
                    }
                    time.* = harness.nowNs(io) - started;
                    if (sink.delivered != loops) return error.MissingAction;
                    sink.delivered = 0;
                },
                .event_0, .event_1, .event_10 => {
                    for (0..loops) |_| plugins.emit(&.{ .kind = .connection_phase_changed, .player = player, .worker = 0 }, null);
                    time.* = harness.nowNs(io) - started;
                },
                else => {
                    if (host.post(host.context, player, Runner.done, &runner) != .ok) return error.PostRejected;
                    plugins.drain(0, io, &sink);
                    time.* = runner.elapsed;
                },
            }
            const count = heap.allocations.load(.monotonic) - before;
            allocations += count - @intFromBool(case == .player_info or case == .network_snapshot or case == .rate_sample);
            if (heap.live.load(.monotonic) != baseline or runner.failed) return error.InvalidBenchmark;
        }
        std.mem.sort(u64, &times, {}, std.sort.asc(u64));
        result.* = .{ .case = case, .ns_per_call = @as(f64, @floatFromInt(times[3])) / @as(f64, @floatFromInt(loops)), .allocations_per_call = @as(f64, @floatFromInt(allocations)) / @as(f64, @floatFromInt(loops * times.len)) };
    }
    return results;
}

test "relay benchmark player APIs validate accounting and cleanup" {
    const results = try run(std.testing.allocator, std.testing.io, true);
    for (results) |result| {
        const expected: f64 = if (result.case == .worker_post or result.case == .disconnect_action) 1 else 0;
        try std.testing.expectEqual(expected, result.allocations_per_call);
        try std.testing.expect(result.ns_per_call >= 0);
    }
}
