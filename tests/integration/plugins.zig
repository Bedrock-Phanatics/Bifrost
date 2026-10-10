const std = @import("std");
const bedwire = @import("bedwire");
const bifrost = @import("bifrost");
const fixtures = @import("../support/fixtures.zig");
const managed = @import("../support/managed.zig");
const Rig = @import("../support/rig.zig").Rig;
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
        posted.store(-1, .release);
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

    var posted: std.atomic.Value(i32) = .init(-1);

    fn transferThere(_: ?*anyopaque, result: *const abi.TaskResult) callconv(.c) void {
        const api = host.?;
        const status = if (result.status == .ok) api.transfer(api.context, result.player, 1) else result.status;
        posted.store(@backingInt(status), .release);
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
    var plugins: bifrost.Plugins = try .init(gpa, &.{}, .{});
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
    var plugins: bifrost.Plugins = try .init(gpa, &.{}, .{});
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

    try std.testing.expectEqual(abi.Status.wrong_thread, host.transfer(host.context, player, 1));
    try std.testing.expectEqual(abi.Status.ok, host.post(host.context, player, Recorder.transferThere, null));
    try rig.waitFor(.transfers_committed, 1);
    try std.testing.expectEqual(@as(i32, 0), Recorder.posted.load(.acquire));
    try rig.expectOn(&rig.b);
    try Recorder.waitFor(.transfer_completed, 1);
    try std.testing.expectEqual(@as(u32, 0), Recorder.from.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), Recorder.backend.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), Recorder.count(.transfer_requested));

    rig.player.destroy();
    rig.player = try managed.Player.connect(io, rig.running.address(), 3);
    try Recorder.waitFor(.player_disconnected, 1);
    try std.testing.expectEqual(abi.Status.stale_handle, host.post(host.context, player, Recorder.transferThere, null));
    try std.testing.expectEqual(abi.Status.stale_handle, host.player_name(host.context, player, &name, name.len, &len));
}

test "a transfer request can be cancelled" {
    var plugins: bifrost.Plugins = try .init(gpa, &.{}, .{});
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
    var plugins: bifrost.Plugins = try .init(gpa, &.{}, .{});
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
    var plugins: bifrost.Plugins = try .init(gpa, &.{}, .{});
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
        .{ abi.Packet, header.bifrost_packet },
        .{ abi.Command, header.bifrost_command },
        .{ abi.TaskResult, header.bifrost_task_result },
        .{ abi.CommandInfo, header.bifrost_command_info },
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
    try expectConstants(abi.Direction, "BIFROST_DIRECTION_");
    try expectConstants(abi.PacketPhase, "BIFROST_PHASE_");
    try expectConstants(abi.PacketAction, "BIFROST_PACKET_");
    try expectConstants(abi.CommandPermission, "BIFROST_PERMISSION_");
    try std.testing.expectEqual(@as(u32, @bitCast(abi.PacketFlags{ .validated = true })), header.BIFROST_PACKET_VALIDATED);
    try std.testing.expectEqual(abi.version, header.BIFROST_ABI_VERSION);
    try std.testing.expectEqual(abi.no_backend, header.BIFROST_NO_BACKEND);
    try std.testing.expectEqual(abi.no_worker, header.BIFROST_NO_WORKER);
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
    var plugins: bifrost.Plugins = try .init(gpa, &.{}, .{});
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

const Hook = struct {
    const Mode = enum(u8) { pass, cancel, replace, corrupt };
    var mode: std.atomic.Value(Mode) = .init(.pass);
    var calls: std.atomic.Value(u32) = .init(0);

    fn init(host_api: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
        plugin.name = .of("hook");
        plugin.plugin_version = .of("1.0.0");
        plugin.capabilities = .{ .packets = true };
        return host_api.subscribe_packet(host_api.context, .from_player, managed.game_packet_id, .in_game, .{}, onPacket, null);
    }

    fn onPacket(_: ?*anyopaque, packet: *abi.Packet) callconv(.c) abi.PacketAction {
        _ = calls.fetchAdd(1, .acq_rel);
        const out = packet.replacement.?[0..packet.replacement_capacity];
        switch (mode.load(.acquire)) {
            .pass => return .pass,
            .cancel => return .cancel,
            .replace => {
                @memcpy(out[0..2], packet.bytes.slice()[0..2]);
                @memcpy(out[2..6], "pong");
                packet.replacement_len = 6;
            },
            .corrupt => {
                out[0] = 0xff;
                packet.replacement_len = 1;
            },
        }
        return .replace;
    }

    fn sendWith(rig: *Rig, next: Mode, payload: []const u8) !void {
        mode.store(next, .release);
        const before = calls.load(.acquire);
        var buffer: [16]u8 = undefined;
        try rig.player.send(&.{try managed.rawPacket(&buffer, managed.game_packet_id, payload)});
        for (0..500) |_| {
            if (calls.load(.acquire) > before) return;
            try io.sleep(.fromMilliseconds(10), .awake);
        }
        return error.WaitTimedOut;
    }
};

test "a packet hook can pass, cancel or replace player packets" {
    var plugins: bifrost.Plugins = try .init(gpa, &.{}, .{});
    defer plugins.deinit();
    Hook.mode.store(.pass, .release);
    Hook.calls.store(0, .release);
    try plugins.add(Hook.init, null);
    var rig: Rig = undefined;
    try rig.start(.{ .plugins = &plugins });
    defer rig.deinit();
    var buffer: [16]u8 = undefined;

    try Hook.sendWith(&rig, .cancel, "dropped");
    try Hook.sendWith(&rig, .replace, "ping");
    try std.testing.expectEqualStrings("pong", try rig.player.nextGamePacket(&buffer));

    Hook.mode.store(.corrupt, .release);
    try rig.expectOn(&rig.a);
    const totals = plugins.totals(0);
    try std.testing.expectEqual(@as(u64, 1), totals.errors);
    try std.testing.expectEqual(@as(u64, Hook.calls.load(.acquire)), totals.calls);
    try std.testing.expectEqual(@as(u32, 3), rig.a.echoes.load(.acquire));
}

test "passthrough refuses packet subscriptions" {
    var plugins: bifrost.Plugins = try .init(gpa, &.{}, .{ .packets = false });
    defer plugins.deinit();
    try std.testing.expectError(error.PluginInitFailed, plugins.add(Hook.init, null));
}

const Commander = struct {
    var host: ?*const abi.Host = null;
    var gate: std.atomic.Value(bool) = .init(true);
    var commands: std.atomic.Value(u32) = .init(0);
    var spawned: [4]abi.Status = undefined;
    var spawn_count: std.atomic.Value(u32) = .init(0);
    var done_count: std.atomic.Value(u32) = .init(0);
    var done_status: std.atomic.Value(i32) = .init(0);
    var done_worker: std.atomic.Value(u32) = .init(0);
    var args: [16]u8 = undefined;
    var args_len: usize = 0;

    fn reset() void {
        gate.store(true, .release);
        commands.store(0, .release);
        spawn_count.store(0, .release);
        done_count.store(0, .release);
        args_len = 0;
    }

    fn init(host_api: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
        plugin.name = .of("commander");
        plugin.plugin_version = .of("1.0.0");
        plugin.capabilities = .{ .commands = true, .tasks = true };
        host = host_api;
        const hub = host_api.register_command(host_api.context, .of("Hub"), onHub, null);
        if (hub != .ok) return hub;
        if (host_api.register_command(host_api.context, .of("hub"), onHub, null) != .invalid_argument) return .failed;
        return host_api.register_command(host_api.context, .of("slow"), onSlow, null);
    }

    fn onHub(_: ?*anyopaque, command: *const abi.Command) callconv(.c) void {
        const text = command.args.slice();
        @memcpy(args[0..text.len], text);
        args_len = text.len;
        const api = host.?;
        _ = api.send_message(api.context, command.player, .of("taking you there"));
        _ = api.transfer(api.context, command.player, 1);
        _ = commands.fetchAdd(1, .acq_rel);
    }

    fn onSlow(_: ?*anyopaque, command: *const abi.Command) callconv(.c) void {
        const api = host.?;
        const index = spawn_count.load(.acquire);
        spawned[index] = api.spawn_task(api.context, command.player, run, done, null);
        spawn_count.store(index + 1, .release);
    }

    fn run(_: ?*anyopaque) callconv(.c) void {
        while (!gate.load(.acquire)) std.atomic.spinLoopHint();
    }

    fn done(_: ?*anyopaque, result: *const abi.TaskResult) callconv(.c) void {
        done_status.store(@backingInt(result.status), .release);
        done_worker.store(result.worker, .release);
        if (result.status == .ok) {
            const api = host.?;
            _ = api.send_message(api.context, result.player, .of("done"));
        }
        _ = done_count.fetchAdd(1, .acq_rel);
    }

    fn send(rig: *Rig, line: []const u8) !void {
        var buffer: [128]u8 = undefined;
        try rig.player.send(&.{try managed.typedPacket(&buffer, .{ .command_request = .{
            .command = line,
            .origin = .{ .type = "player", .uuid = @splat(0), .request_id = "", .player_id = 0 },
            .is_internal = false,
            .version = "latest",
        } })});
    }

    fn waitFor(counter: *const std.atomic.Value(u32), value: u32) !void {
        for (0..500) |_| {
            if (counter.load(.acquire) >= value) return;
            try io.sleep(.fromMilliseconds(10), .awake);
        }
        return error.WaitTimedOut;
    }
};

const Texts = struct {
    fn arrived(player: *managed.Player) bool {
        return player.received(.text) >= 1;
    }
};

test "a plugin command runs on the player's worker and never reaches the backend" {
    var plugins: bifrost.Plugins = try .init(gpa, &.{}, .{});
    defer plugins.deinit();
    Commander.reset();
    try plugins.add(Commander.init, null);
    var rig: Rig = undefined;
    try rig.start(.{ .plugins = &plugins });
    defer rig.deinit();
    plugins.backends = rig.running.proxy.config.backends();

    try Commander.send(&rig, "/HUB  now ");
    try rig.waitFor(.transfers_committed, 1);
    try rig.pumpUntil(rig.player, Texts.arrived);
    try std.testing.expectEqualStrings("now", Commander.args[0..Commander.args_len]);
    try rig.expectOn(&rig.b);

    try Commander.send(&rig, "/gamemode creative");
    try fixtures.waitFor(io, &rig.b.commands, 1);
    try std.testing.expectEqual(@as(u32, 0), rig.a.commands.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), Commander.commands.load(.acquire));
}

const wire = bedwire.protocol.packets.available_commands;

fn commandList(buffer: []u8, names: []const []const u8) ![]const u8 {
    var list: [4]wire.Command = undefined;
    for (names, list[0..names.len]) |name, *command| command.* = .{
        .name = name,
        .description = "from the backend",
        .flags = 0,
        .permission_level = "any",
        .alias_enum = -1,
        .command_data_chained_subcommand_indexes = .empty,
        .overloads = .empty,
    };
    return managed.typedPacket(buffer, .{ .available_commands = .{
        .enum_values = .empty,
        .chained_subcommand_values = .empty,
        .post_fixes = .empty,
        .enum_data = .empty,
        .chained_subcommand_data = .empty,
        .commands = .init(list[0..names.len]),
        .soft_enums = .empty,
        .constraints = .empty,
    } });
}

fn expectCommands(player: *managed.Player, expected: []const []const u8) !void {
    const decoded = try bedwire.protocol.typed.decode(player.commands orelse return error.NotReceived, .{});
    var it = decoded.packet.available_commands.commands.iterator();
    var count: usize = 0;
    while (try it.next()) |command| : (count += 1) {
        for (expected) |name| {
            if (std.mem.eql(u8, name, command.name)) break;
        } else return error.UnexpectedCommand;
    }
    try std.testing.expectEqual(expected.len, count);
}

const Advertised = struct {
    fn arrived(player: *managed.Player) bool {
        return player.received(.available_commands) >= 1;
    }
};

test "plugin commands are advertised even when the backend lists none" {
    var plugins: bifrost.Plugins = try .init(gpa, &.{}, .{});
    defer plugins.deinit();
    Commander.reset();
    try plugins.add(Commander.init, null);
    var rig: Rig = undefined;
    try rig.start(.{ .plugins = &plugins });
    defer rig.deinit();

    try rig.pumpUntil(rig.player, Advertised.arrived);
    try expectCommands(rig.player, &.{ "hub", "slow" });
}

test "a backend's command list gets plugin commands added, and again after a transfer" {
    var plugins: bifrost.Plugins = try .init(gpa, &.{}, .{});
    defer plugins.deinit();
    Commander.reset();
    try plugins.add(Commander.init, null);
    var rig: Rig = undefined;
    try rig.start(.{ .plugins = &plugins });
    defer rig.deinit();
    plugins.backends = rig.running.proxy.config.backends();

    var buffer: [512]u8 = undefined;
    try rig.player.relay(&.{try commandList(&buffer, &.{ "gamemode", "hub" })});
    try expectCommands(rig.player, &.{ "gamemode", "hub", "slow" });

    try rig.transfer(1);
    try rig.waitFor(.transfers_committed, 1);
    try rig.expectOn(&rig.b);
    try rig.player.relay(&.{try commandList(&buffer, &.{ "warp", "say" })});
    try expectCommands(rig.player, &.{ "warp", "say", "hub", "slow" });

    try Commander.send(&rig, "/hub");
    try Commander.waitFor(&Commander.commands, 1);
    try Commander.send(&rig, "/warp home");
    try fixtures.waitFor(io, &rig.b.commands, 1);
}

test "slow plugin work finishes on the player's worker, or reports the player gone" {
    var plugins: bifrost.Plugins = try .init(gpa, &.{}, .{ .max_tasks_per_plugin = 2 });
    defer plugins.deinit();
    Commander.reset();
    try plugins.add(Commander.init, null);
    var rig: Rig = undefined;
    try rig.start(.{ .plugins = &plugins });
    defer rig.deinit();

    Commander.gate.store(false, .release);
    try Commander.send(&rig, "/slow");
    try Commander.send(&rig, "/slow");
    try Commander.send(&rig, "/slow");
    try Commander.waitFor(&Commander.spawn_count, 3);
    try std.testing.expectEqualSlices(abi.Status, &.{ .ok, .ok, .busy }, Commander.spawned[0..3]);
    try std.testing.expectEqual(@as(u32, 2), plugins.totals(0).outstanding);

    Commander.gate.store(true, .release);
    try Commander.waitFor(&Commander.done_count, 2);
    try std.testing.expectEqual(@as(i32, @backingInt(abi.Status.ok)), Commander.done_status.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), Commander.done_worker.load(.acquire));
    try rig.pumpUntil(rig.player, Texts.arrived);
    try std.testing.expectEqual(@as(u32, 0), plugins.totals(0).outstanding);

    Commander.gate.store(false, .release);
    try Commander.send(&rig, "/slow");
    try Commander.waitFor(&Commander.spawn_count, 4);
    rig.player.destroy();
    rig.player = try managed.Player.connect(io, rig.running.address(), 3);
    try rig.running.waitForStat(.links_closed, 1);
    Commander.gate.store(true, .release);
    try Commander.waitFor(&Commander.done_count, 3);
    try std.testing.expectEqual(@as(i32, @backingInt(abi.Status.stale_handle)), Commander.done_status.load(.acquire));
}

test "a task still running at shutdown is finished before the plugin unloads" {
    var plugins: bifrost.Plugins = try .init(gpa, &.{}, .{});
    defer plugins.deinit();
    Commander.reset();
    try plugins.add(Commander.init, null);
    var rig: Rig = undefined;
    try rig.start(.{ .plugins = &plugins });

    Commander.gate.store(false, .release);
    try Commander.send(&rig, "/slow");
    try Commander.waitFor(&Commander.spawn_count, 1);
    rig.deinit();
    Commander.gate.store(true, .release);
    plugins.unload();
    try std.testing.expectEqual(@as(u32, 1), Commander.done_count.load(.acquire));
    try std.testing.expectEqual(@as(i32, @backingInt(abi.Status.stale_handle)), Commander.done_status.load(.acquire));
}

const Slow = struct {
    fn init(host_api: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
        plugin.name = .of("slow");
        plugin.plugin_version = .of("1.0.0");
        plugin.capabilities = .{ .packets = true };
        return host_api.subscribe_packet(host_api.context, .from_player, managed.game_packet_id, .any, .{}, onPacket, null);
    }

    fn onPacket(_: ?*anyopaque, _: *abi.Packet) callconv(.c) abi.PacketAction {
        const started = std.Io.Clock.awake.now(io);
        while (started.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 3) std.atomic.spinLoopHint();
        return .pass;
    }
};

test "a slow packet callback is measured and the packet still goes through" {
    var plugins: bifrost.Plugins = try .init(gpa, &.{}, .{ .slow_callback_ns = std.time.ns_per_ms });
    defer plugins.deinit();
    try plugins.add(Slow.init, null);
    var rig: Rig = undefined;
    try rig.start(.{ .plugins = &plugins });
    defer rig.deinit();
    try rig.expectOn(&rig.a);
    const totals = plugins.totals(0);
    try std.testing.expect(totals.max_ns >= 3 * std.time.ns_per_ms);
    try std.testing.expect(totals.calls >= 2);
}
