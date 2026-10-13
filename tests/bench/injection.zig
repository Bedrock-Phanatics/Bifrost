const std = @import("std");
const bifrost = @import("bifrost");
const sample = @import("sample");
const harness = @import("harness.zig");
const abi = bifrost.plugin_abi;
const Scheduler = @FieldType(bifrost.Proxy, "scheduler");

pub const Result = struct {
    bytes: usize,
    ns_per_packet: f64,
    allocations_per_packet: f64,
    queued_heap: u64,
    retained_heap: u64,
    cpu_ns_per_packet: ?f64,
    resident_kb: ?u64,
    peak_resident_kb: ?u64,
};

var host: ?*const abi.Host = null;

fn init(api: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
    plugin.name = .of("injection-bench");
    plugin.plugin_version = .of("1");
    plugin.capabilities = .{ .packets = true };
    host = api;
    return .ok;
}

fn noTransfer(_: *anyopaque, _: u64, _: u32) abi.Status {
    return .ok;
}

const Sink = struct {
    delivered: usize = 0,
    pub fn message(_: *Sink, _: u64, _: []const u8) void {}
    pub fn packet(self: *Sink, _: u64, _: abi.PacketTarget, bytes: []const u8) abi.Status {
        std.mem.doNotOptimizeAway(bytes);
        self.delivered += 1;
        return .ok;
    }
};

const batch = 32;

fn enqueue(player: abi.Player, bytes: []const u8, scheduler: *Scheduler) !void {
    const api = host.?;
    for (0..batch) |_| if (api.send_packet(api.context, player, .player, .of(bytes), null, null) != .ok) return error.InjectionRejected;
    if (!scheduler.wake.isSet()) return error.MissingWake;
    scheduler.wake.reset();
}

pub fn run(gpa: std.mem.Allocator, io: std.Io, quick: bool) ![4]Result {
    var heap: harness.CountingAllocator = .{ .backing = gpa };
    var plugins: bifrost.Plugins = try .init(heap.allocator(), &.{}, .{});
    defer plugins.deinit();
    try plugins.add(init, null);
    var scheduler: Scheduler = .{ .io = io };
    plugins.attachWorker(0, scheduler.wakeNotify());
    var sink: Sink = .{};
    const player = try plugins.handles.acquire(heap.allocator(), .{ .context = &sink, .link = 1, .transfer = noTransfer });
    const baseline = heap.live.load(.monotonic);
    const rounds: usize = if (quick) 500 else 5000;
    var expected: usize = 0;
    var results: [4]Result = undefined;
    const message: [65526]u8 = @splat('x');
    var buffer: [65536]u8 = undefined;
    for ([_]usize{ 32, 1024, 16384, 65536 }, &results) |size, *result| {
        const overhead: usize = if (size < 128) 8 else if (size <= 16384) 9 else 10;
        const packet = try sample.typedPacket(&buffer, .{ .text = .{
            .localize = false,
            .body = .{ .message_only = .{ .message_type = .raw, .message = message[0 .. size - overhead] } },
            .senders_xuid = "",
            .platform_id = "",
            .filtered_message = null,
        } });
        if (packet.len != size) return error.InvalidBenchmarkPacket;
        const before = heap.allocations.load(.monotonic);
        try enqueue(player, packet, &scheduler);
        const allocations = heap.allocations.load(.monotonic) - before;
        const queued = heap.live.load(.monotonic) - baseline;
        plugins.drain(0, io, &sink);
        var times: [7]u64 = undefined;
        for (&times) |*elapsed| {
            const started = harness.nowNs(io);
            for (0..rounds) |_| {
                try enqueue(player, packet, &scheduler);
                plugins.drain(0, io, &sink);
            }
            elapsed.* = harness.nowNs(io) - started;
        }
        std.mem.sort(u64, &times, {}, std.sort.asc(u64));
        expected += batch * (1 + rounds * times.len);
        var cpu_ns_per_packet: ?f64 = null;
        if (harness.has_usage) {
            const before_cpu = try harness.selfUsage(io);
            const started = harness.nowNs(io);
            var count: usize = 0;
            while (true) {
                for (0..64) |_| {
                    try enqueue(player, packet, &scheduler);
                    plugins.drain(0, io, &sink);
                }
                count += 64 * batch;
                if (harness.nowNs(io) - started >= (if (quick) @as(u64, 250) else 1000) * std.time.ns_per_ms) break;
            }
            const after_cpu = try harness.selfUsage(io);
            if (after_cpu.cpu_us < before_cpu.cpu_us) return error.InvalidCpuCounter;
            cpu_ns_per_packet = @as(f64, @floatFromInt(after_cpu.cpu_us - before_cpu.cpu_us)) * 1000 / @as(f64, @floatFromInt(count));
            expected += count;
        }
        const usage = try harness.selfUsage(io);
        if (harness.has_usage and (usage.rss_kb == 0 or usage.hwm_kb < usage.rss_kb)) return error.InvalidMemoryCounter;
        result.* = .{
            .bytes = size,
            .ns_per_packet = @as(f64, @floatFromInt(times[times.len / 2])) / @as(f64, @floatFromInt(rounds * batch)),
            .allocations_per_packet = @as(f64, @floatFromInt(allocations)) / batch,
            .queued_heap = queued,
            .retained_heap = heap.live.load(.monotonic) - baseline,
            .cpu_ns_per_packet = cpu_ns_per_packet,
            .resident_kb = if (harness.has_usage) usage.rss_kb else null,
            .peak_resident_kb = if (harness.has_usage) usage.hwm_kb else null,
        };
    }
    if (sink.delivered != expected) return error.MissingInjection;
    return results;
}
