const std = @import("std");
const bifrost = @import("bifrost");
const fixtures = @import("support/fixtures.zig");
const managed = @import("support/managed.zig");
const Rig = @import("support/rig.zig").Rig;
const test_options = @import("test_options");
const header = @import("bifrost_plugin_h");

const abi = bifrost.plugin_abi;
const io = std.testing.io;
const gpa = std.testing.allocator;

const Recorder = struct {
    var counts: [abi.EventKind.count]std.atomic.Value(u32) = @splat(.init(0));
    var player: std.atomic.Value(u64) = .init(0);
    var from: std.atomic.Value(u32) = .init(0);
    var backend: std.atomic.Value(u32) = .init(0);
    var failure: std.atomic.Value(u32) = .init(0);
    var name: [16]u8 = undefined;
    var name_len: std.atomic.Value(usize) = .init(0);
    var action: abi.TransferAction = .proceed;
    var redirect_to: u32 = abi.no_backend;
    var host: ?*const abi.Host = null;

    fn reset() void {
        for (&counts) |*counter| counter.store(0, .release);
        player.store(0, .release);
        name_len.store(0, .release);
        action = .proceed;
        redirect_to = abi.no_backend;
        host = null;
    }

    fn init(host_api: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
        plugin.name = .of("recorder");
        plugin.plugin_version = .of("1.0.0");
        plugin.capabilities = .{ .events = true };
        host = host_api;
        for (0..abi.EventKind.count) |kind| {
            const status = host_api.subscribe(host_api.context, @fromBackingInt(@intCast(kind)), onEvent, null);
            if (status != .ok) return status;
        }
        return .ok;
    }

    fn onEvent(_: ?*anyopaque, event: *const abi.Event, decision: ?*abi.TransferDecision) callconv(.c) void {
        switch (event.kind) {
            .player_connected => player.store(event.player.id, .release),
            .player_authenticated => {
                const text = event.name.slice();
                @memcpy(name[0..text.len], text);
                name_len.store(text.len, .release);
            },
            .transfer_requested => if (decision) |out| {
                out.action = action;
                out.backend = redirect_to;
            },
            .transfer_failed, .transfer_completed => {
                from.store(event.from_backend, .release);
                backend.store(event.backend, .release);
                failure.store(@backingInt(event.failure), .release);
            },
            else => {},
        }
        _ = counts[@backingInt(event.kind)].fetchAdd(1, .acq_rel);
    }

    fn count(kind: abi.EventKind) u32 {
        return counts[@backingInt(kind)].load(.acquire);
    }

    fn handle() abi.Player {
        return .{ .id = player.load(.acquire) };
    }

    fn waitFor(kind: abi.EventKind, value: u32) !void {
        for (0..500) |_| {
            if (count(kind) >= value) return;
            try io.sleep(.fromMilliseconds(10), .awake);
        }
        return error.WaitTimedOut;
    }
};

fn loadRecorder(plugins: *bifrost.Plugins) !void {
    Recorder.reset();
    try plugins.add(Recorder.init, null);
}

test "a passthrough player's life is visible without decrypting anything" {
    var plugins: bifrost.Plugins = .init(gpa, &.{});
    defer plugins.deinit();
    try loadRecorder(&plugins);
    var backend: fixtures.Backend = undefined;
    try backend.start(io, .{});
    defer backend.deinit();
    var running: fixtures.Running = undefined;
    try running.start(io, try fixtures.config(&.{backend.address()}), .{ .plugins = &plugins });
    defer running.deinit();

    var player: fixtures.Player = try .connect(io, running.address());
    try player.roundTrip("\xfehello");
    try Recorder.waitFor(.backend_selected, 1);
    try std.testing.expect(Recorder.handle().id != 0);
    player.deinit();
    try Recorder.waitFor(.player_disconnected, 1);
    running.stop();

    try std.testing.expectEqual(@as(u32, 1), Recorder.count(.proxy_started));
    try std.testing.expectEqual(@as(u32, 1), Recorder.count(.proxy_stopping));
    try std.testing.expectEqual(@as(u32, 1), Recorder.count(.player_connected));
    try std.testing.expectEqual(@as(u32, 0), Recorder.count(.player_authenticated));
}

test "a managed player is named, followed across a transfer and goes stale on leaving" {
    var plugins: bifrost.Plugins = .init(gpa, &.{});
    defer plugins.deinit();
    try loadRecorder(&plugins);
    var rig: Rig = undefined;
    try rig.start(.{ .plugins = &plugins });
    defer rig.deinit();
    plugins.backends = rig.running.proxy.config.backends();

    try Recorder.waitFor(.player_authenticated, 1);
    try std.testing.expectEqualStrings("Steve", Recorder.name[0..Recorder.name_len.load(.acquire)]);
    const host = Recorder.host.?;
    const player = Recorder.handle();
    var name: [16]u8 = undefined;
    var len: usize = 0;
    try std.testing.expectEqual(abi.Status.ok, host.player_name(host.context, player, &name, name.len, &len));
    try std.testing.expectEqualStrings("Steve", name[0..len]);

    try std.testing.expectEqual(abi.Status.ok, host.transfer(host.context, player, 1));
    try rig.waitFor(.transfers_committed, 1);
    try rig.expectOn(&rig.b);
    try Recorder.waitFor(.transfer_completed, 1);
    try std.testing.expectEqual(@as(u32, 0), Recorder.from.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), Recorder.backend.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), Recorder.count(.transfer_requested));

    rig.player.destroy();
    rig.player = try managed.Player.connect(io, rig.running.address(), 3);
    try Recorder.waitFor(.player_disconnected, 1);
    try std.testing.expectEqual(abi.Status.stale_handle, host.transfer(host.context, player, 0));
    try std.testing.expectEqual(abi.Status.stale_handle, host.player_name(host.context, player, &name, name.len, &len));
    try std.testing.expectEqual(abi.Status.invalid_argument, host.transfer(host.context, player, 7));
}

test "a transfer request can be cancelled" {
    var plugins: bifrost.Plugins = .init(gpa, &.{});
    defer plugins.deinit();
    try loadRecorder(&plugins);
    Recorder.action = .cancel;
    var rig: Rig = undefined;
    try rig.start(.{ .plugins = &plugins });
    defer rig.deinit();

    try rig.transfer(1);
    try rig.waitFor(.transfers_rejected, 1);
    try rig.expectOn(&rig.a);
    try Recorder.waitFor(.transfer_failed, 1);
    try std.testing.expectEqual(@backingInt(abi.TransferFailure.rejected), Recorder.failure.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), rig.stats().transfers_started);
}

test "a transfer request can be redirected" {
    var plugins: bifrost.Plugins = .init(gpa, &.{});
    defer plugins.deinit();
    try loadRecorder(&plugins);
    Recorder.action = .redirect;
    Recorder.redirect_to = 1;
    var rig: Rig = undefined;
    try rig.start(.{ .plugins = &plugins });
    defer rig.deinit();

    try rig.transfer(0);
    try rig.waitFor(.transfers_committed, 1);
    try rig.expectOn(&rig.b);
    try Recorder.waitFor(.transfer_completed, 1);
    try std.testing.expectEqual(@as(u32, 1), Recorder.backend.load(.acquire));
}

test "a failed transfer says why" {
    var plugins: bifrost.Plugins = .init(gpa, &.{});
    defer plugins.deinit();
    try loadRecorder(&plugins);
    var rig: Rig = undefined;
    try rig.start(.{ .b = .kick_login, .plugins = &plugins });
    defer rig.deinit();

    try rig.transfer(1);
    try rig.waitFor(.transfers_failed_before_commit, 1);
    try Recorder.waitFor(.transfer_failed, 1);
    try std.testing.expectEqual(@backingInt(abi.TransferFailure.failed_before_commit), Recorder.failure.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), Recorder.count(.transfer_completed));
    try rig.expectOn(&rig.a);
}

test "the C header matches the Zig ABI" {
    inline for (.{
        .{ abi.Str, header.bifrost_str },
        .{ abi.Player, header.bifrost_player },
        .{ abi.Event, header.bifrost_event },
        .{ abi.TransferDecision, header.bifrost_transfer_decision },
        .{ abi.Host, header.bifrost_host },
        .{ abi.Plugin, header.bifrost_plugin },
    }) |pair| {
        try std.testing.expectEqual(@sizeOf(pair[0]), @sizeOf(pair[1]));
        inline for (comptime std.meta.fieldNames(pair[0])) |field| {
            try std.testing.expectEqual(@offsetOf(pair[0], field), @offsetOf(pair[1], field));
        }
    }
    try expectConstants(abi.Status, "BIFROST_STATUS_");
    try expectConstants(abi.LogLevel, "BIFROST_LOG_");
    try expectConstants(abi.EventKind, "BIFROST_EVENT_");
    try expectConstants(abi.TransferFailure, "BIFROST_FAILURE_");
    try expectConstants(abi.TransferAction, "BIFROST_TRANSFER_");
    try std.testing.expectEqual(abi.version, header.BIFROST_ABI_VERSION);
    try std.testing.expectEqual(abi.no_backend, header.BIFROST_NO_BACKEND);
    try std.testing.expectEqual(@as(u64, @bitCast(abi.Capabilities{ .packets = true })), header.BIFROST_CAPABILITY_PACKETS);
}

fn expectConstants(comptime Enum: type, comptime prefix: []const u8) !void {
    inline for (comptime std.meta.tags(Enum)) |tag| {
        const name = comptime upper: {
            var buffer: [@tagName(tag).len]u8 = undefined;
            break :upper prefix ++ std.ascii.upperString(&buffer, @tagName(tag));
        };
        try std.testing.expectEqual(@as(i64, @backingInt(tag)), @as(i64, @field(header, name)));
    }
}

test "the example plugin loads from disk and keeps players off maintenance" {
    var plugins: bifrost.Plugins = .init(gpa, &.{});
    defer plugins.deinit();
    try plugins.open(test_options.example_plugin);
    var rig: Rig = undefined;
    try rig.start(.{ .plugins = &plugins, .b_name = "maintenance" });
    defer rig.deinit();
    plugins.backends = rig.running.proxy.config.backends();

    try rig.transfer(1);
    try rig.waitFor(.transfers_rejected, 1);
    try rig.expectOn(&rig.a);
    try std.testing.expectEqual(@as(u64, 0), rig.stats().transfers_started);
}
