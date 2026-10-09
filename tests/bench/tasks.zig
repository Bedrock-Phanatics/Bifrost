const std = @import("std");
const bifrost = @import("bifrost");
const harness = @import("harness.zig");

const abi = bifrost.plugin_abi;

pub const Result = struct {
    tasks_per_s: f64,
    p50_us: f64,
    p99_us: f64,
};

var host: ?*const abi.Host = null;
var player: abi.Player = .{};
var wanted: usize = 0;
var accepted: usize = 0;
var done_count: usize = 0;

fn init(api: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
    plugin.name = .of("tasks");
    plugin.plugin_version = .of("1");
    plugin.capabilities = .{ .commands = true, .tasks = true };
    host = api;
    return api.register_command(api.context, .of("go"), spawn, null);
}

fn spawn(_: ?*anyopaque, _: *const abi.Command) callconv(.c) void {
    const api = host.?;
    while (accepted < wanted) : (accepted += 1) {
        if (api.spawn_task(api.context, player, run, done, null) != .ok) return;
    }
}

fn run(_: ?*anyopaque) callconv(.c) void {}

fn done(_: ?*anyopaque, _: *const abi.TaskResult) callconv(.c) void {
    done_count += 1;
}

fn noTransfer(_: *anyopaque, _: u64, _: u32) abi.Status {
    return .ok;
}

fn complete(plugins: *bifrost.Plugins, io: std.Io, count: usize) void {
    wanted += count;
    while (done_count < wanted) {
        _ = plugins.runCommand(0, io, player, "go");
        plugins.drain(0, io, null);
    }
}

pub fn measure(gpa: std.mem.Allocator, io: std.Io, quick: bool) !Result {
    var plugins: bifrost.Plugins = try .init(gpa, &.{}, .{ .packets = true, .slow_callback_ns = std.math.maxInt(u64) });
    defer plugins.deinit();
    try plugins.add(init, null);
    var context: u8 = 0;
    player = try plugins.handles.acquire(gpa, .{ .context = &context, .link = 1, .transfer = noTransfer });
    wanted = 0;
    accepted = 0;
    done_count = 0;

    const total: usize = if (quick) 20_000 else 100_000;
    complete(&plugins, io, 1000);
    const started = harness.nowNs(io);
    complete(&plugins, io, total);
    const elapsed = harness.nowNs(io) - started;

    var samples: [2000]u64 = undefined;
    for (&samples) |*sample| {
        const at = harness.nowNs(io);
        complete(&plugins, io, 1);
        sample.* = harness.nowNs(io) - at;
    }
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    return .{
        .tasks_per_s = @as(f64, @floatFromInt(total)) * std.time.ns_per_s / @as(f64, @floatFromInt(elapsed)),
        .p50_us = @as(f64, @floatFromInt(samples[samples.len / 2])) / std.time.ns_per_us,
        .p99_us = @as(f64, @floatFromInt(samples[samples.len * 99 / 100])) / std.time.ns_per_us,
    };
}
