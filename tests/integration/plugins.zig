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
    var last_phase: abi.ConnectionPhase = .unknown;
    var bad_snapshot: bool = false;
    var network_status: std.atomic.Value(i32) = .init(-100);
    var player_network: abi.NetworkStats = .{};
    var backend_network: abi.NetworkStats = .{};

    fn reset() void {
        for (&counts) |*counter| counter.store(0, .release);
        player.store(0, .release);
        posted.store(-1, .release);
        name_len.store(0, .release);
        action = .proceed;
        redirect_to = abi.no_backend;
        host = null;
        last_phase = .unknown;
        bad_snapshot = false;
        network_status.store(-100, .release);
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
            .player_connected => {
                var info: abi.PlayerInfo = undefined;
                const api = host.?;
                if (api.player_info(api.context, event.player, &info, @sizeOf(abi.PlayerInfo)) != .ok) bad_snapshot = true else last_phase = info.state.phase;
                player.store(event.player.id, .release);
            },
            .connection_phase_changed => {
                var info: abi.PlayerInfo = undefined;
                const api = host.?;
                if (event.previous_phase != last_phase or api.player_info(api.context, event.player, &info, @sizeOf(abi.PlayerInfo)) != .ok or info.state.phase != event.phase) bad_snapshot = true;
                last_phase = event.phase;
            },
            .player_disconnected => {
                var info: abi.PlayerInfo = undefined;
                const api = host.?;
                if (api.player_info(api.context, event.player, &info, @sizeOf(abi.PlayerInfo)) != .ok or info.state.connection != .disconnected) bad_snapshot = true;
            },
            .player_authenticated => {
                var network: abi.NetworkStats = undefined;
                const api = host.?;
                if (api.network_stats(api.context, event.player, .player, &network, @sizeOf(abi.NetworkStats)) != .ok) bad_snapshot = true;
                const text = event.name.slice();
                @memcpy(name[0..text.len], text);
                name_len.store(text.len, .release);
            },
            .transfer_requested => if (decision) |out| {
                out.action = action;
                out.backend = redirect_to;
            },
            .transfer_failed, .transfer_completed => {
                var info: abi.PlayerInfo = undefined;
                const api = host.?;
                if (api.player_info(api.context, event.player, &info, @sizeOf(abi.PlayerInfo)) != .ok or ((event.kind == .transfer_completed or event.failure == .failed_after_commit) and info.state.backend != event.backend)) bad_snapshot = true;
                from.store(event.from_backend, .release);
                backend.store(event.backend, .release);
                failure.store(@backingInt(event.failure), .release);
            },
            else => {},
        }
        _ = counts[@backingInt(event.kind)].fetchAdd(1, .acq_rel);
    }

    var posted: std.atomic.Value(i32) = .init(-1);

    fn queryNetwork(_: ?*anyopaque, result: *const abi.TaskResult) callconv(.c) void {
        const api = host.?;
        var status = result.status;
        if (status == .ok) status = api.network_stats(api.context, result.player, .player, &player_network, @sizeOf(abi.NetworkStats));
        if (status == .ok) status = api.network_stats(api.context, result.player, .backend, &backend_network, @sizeOf(abi.NetworkStats));
        network_status.store(@backingInt(status), .release);
    }

    fn query(player_handle: abi.Player) !void {
        const api = host.?;
        network_status.store(-100, .release);
        try std.testing.expectEqual(abi.Status.ok, api.post(api.context, player_handle, queryNetwork, null));
        for (0..500) |_| {
            if (network_status.load(.acquire) != -100) break;
            try io.sleep(.fromMilliseconds(10), .awake);
        }
        try std.testing.expectEqual(@as(i32, 0), network_status.load(.acquire));
    }

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

const NativePlugins = struct {
    tmp: std.testing.TmpDir,
    root: [:0]u8,

    fn init() !NativePlugins {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        return .{ .tmp = tmp, .root = try tmp.dir.realPathFileAlloc(io, ".", gpa) };
    }

    fn deinit(self: *NativePlugins) void {
        gpa.free(self.root);
        self.tmp.cleanup();
    }

    fn add(self: *NativePlugins, stem: []const u8, built: []const u8) ![:0]u8 {
        const library = try std.fmt.allocPrint(gpa, "{s}{s}", .{ stem, bifrost.Plugins.Package.library_extension });
        defer gpa.free(library);
        try std.Io.Dir.copyFile(.cwd(), built, self.tmp.dir, library, io, .{});
        return self.tmp.dir.realPathFileAlloc(io, library, gpa);
    }

    fn load(self: *NativePlugins, plugins: *bifrost.Plugins, stem: []const u8) !void {
        const library = try std.fmt.allocPrint(gpa, "{s}{s}", .{ stem, bifrost.Plugins.Package.library_extension });
        defer gpa.free(library);
        try bifrost.Plugins.Package.load(plugins, io, self.tmp.dir, library);
    }
};

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
    var info: abi.PlayerInfo = undefined;
    try std.testing.expectEqual(abi.Status.ok, host.player_info(host.context, player, &info, @sizeOf(abi.PlayerInfo)));
    try std.testing.expectEqual(abi.ConnectionState.connected, info.state.connection);
    try std.testing.expectEqual(abi.AuthenticationState.authenticated, info.state.authentication);
    try std.testing.expectEqual(abi.SessionMode.managed, info.state.mode);
    try std.testing.expectEqual(abi.ConnectionPhase.in_game, info.state.phase);
    try std.testing.expectEqualStrings("Steve", info.name[0..info.name_len]);
    try std.testing.expectEqualStrings("2535400000000001", info.xuid[0..info.xuid_len]);
    try std.testing.expectEqual(@as(u32, 36), info.uuid_len);
    try std.testing.expect(info.connection_duration_ms > 0);
    var network: abi.NetworkStats = undefined;
    try std.testing.expectEqual(abi.Status.wrong_thread, host.network_stats(host.context, player, .player, &network, @sizeOf(abi.NetworkStats)));
    try Recorder.query(player);
    try std.testing.expect(Recorder.player_network.available & abi.NetworkMetric.reliability != 0);
    try std.testing.expectEqual(@as(u64, 0), Recorder.player_network.available & abi.NetworkMetric.rates);
    try std.testing.expectEqual(@as(u64, 0), Recorder.backend_network.available & abi.NetworkMetric.rates);
    try io.sleep(.fromMilliseconds(260), .awake);
    try rig.expectOn(&rig.a);
    try Recorder.query(player);
    try std.testing.expect(Recorder.backend_network.available & abi.NetworkMetric.rates != 0);
    try std.testing.expect(Recorder.backend_network.incoming_bytes_per_second > 0);

    try std.testing.expectEqual(abi.Status.wrong_thread, host.transfer(host.context, player, 1));
    try std.testing.expectEqual(abi.Status.ok, host.post(host.context, player, Recorder.transferThere, null));
    try rig.waitFor(.transfers_committed, 1);
    try std.testing.expectEqual(@as(i32, 0), Recorder.posted.load(.acquire));
    try rig.expectOn(&rig.b);
    try Recorder.waitFor(.transfer_completed, 1);
    try std.testing.expectEqual(@as(u32, 0), Recorder.from.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), Recorder.backend.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), Recorder.count(.transfer_requested));
    try std.testing.expectEqual(abi.Status.ok, host.player_info(host.context, player, &info, @sizeOf(abi.PlayerInfo)));
    try std.testing.expectEqual(@as(u32, 1), info.state.backend);
    try std.testing.expectEqual(abi.TransferState.none, info.state.transfer);
    try Recorder.query(player);
    try std.testing.expectEqual(@as(u64, 0), Recorder.backend_network.available & abi.NetworkMetric.rates);

    rig.player.destroy();
    rig.player = try managed.Player.connect(io, rig.running.address(), 3);
    try Recorder.waitFor(.player_disconnected, 1);
    try std.testing.expectEqual(abi.Status.stale_handle, host.post(host.context, player, Recorder.transferThere, null));
    try std.testing.expectEqual(abi.Status.stale_handle, host.player_name(host.context, player, &name, name.len, &len));
    try std.testing.expectEqual(abi.Status.stale_handle, host.player_info(host.context, player, &info, @sizeOf(abi.PlayerInfo)));
    rig.running.stop();
    try std.testing.expect(!Recorder.bad_snapshot);
}

test "player API disconnect delivers a managed reason and transfers from non-worker threads" {
    var plugins: bifrost.Plugins = try .init(gpa, &.{}, .{});
    defer plugins.deinit();
    try loadRecorder(&plugins);
    var rig: Rig = undefined;
    try rig.start(.{ .plugins = &plugins });
    defer rig.deinit();
    plugins.backends = rig.running.proxy.config.backends();
    const api = Recorder.host.?;
    const player = Recorder.handle();
    try std.testing.expectEqual(abi.Status.ok, api.request_transfer(api.context, player, 1, null, null));
    try rig.waitFor(.transfers_committed, 1);
    try rig.expectOn(&rig.b);
    try Recorder.waitFor(.transfer_completed, 1);
    try std.testing.expectEqual(abi.Status.ok, api.disconnect(api.context, player, .of("Maintenance"), null, null));
    var found = false;
    for (0..8) |_| {
        var packets = try rig.player.receive();
        defer packets.deinit();
        while (packets.next()) |packet| if (packet.kind == .disconnect) {
            const message = (try rig.player.session.decodePacket(packet)).value.typed.disconnect.messages.messages.message;
            try std.testing.expectEqualStrings("Maintenance", message);
            found = true;
        };
        if (found) break;
    }
    try std.testing.expect(found);
}

test "player snapshots follow transfer commit and retain the target on shutdown failure" {
    var plugins: bifrost.Plugins = try .init(gpa, &.{}, .{});
    defer plugins.deinit();
    try loadRecorder(&plugins);
    var rig: Rig = undefined;
    try rig.start(.{ .plugins = &plugins });
    defer rig.deinit();
    rig.player.hold_acks = true;
    try rig.transfer(1);
    try rig.pumpUntil(rig.player, struct {
        fn waiting(player: *managed.Player) bool {
            return player.held_acks != 0;
        }
    }.waiting);
    var info: abi.PlayerInfo = undefined;
    const api = Recorder.host.?;
    try std.testing.expectEqual(abi.Status.ok, api.player_info(api.context, Recorder.handle(), &info, @sizeOf(abi.PlayerInfo)));
    try std.testing.expectEqual(@as(u32, 1), info.state.backend);
    try std.testing.expectEqual(abi.TransferState.syncing_client, info.state.transfer);
    rig.running.stop();
    try std.testing.expectEqual(@as(u32, 1), Recorder.count(.transfer_failed));
    try std.testing.expectEqual(@backingInt(abi.TransferFailure.failed_after_commit), Recorder.failure.load(.acquire));
    try std.testing.expect(!Recorder.bad_snapshot);
}

test "player API actions and snapshots stay on their owning proxy workers" {
    const Multi = struct {
        var api: *const abi.Host = undefined;
        var players: [2]std.atomic.Value(u64) = @splat(.init(0));
        var finished: [2]std.atomic.Value(i32) = @splat(.init(-100));
        var left: std.atomic.Value(u32) = .init(0);
        fn init(host_api: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
            api = host_api;
            plugin.name = .of("multi-player");
            plugin.plugin_version = .of("1");
            plugin.capabilities.events = true;
            const status = api.subscribe(api.context, .player_connected, event, null);
            if (status != .ok) return status;
            return api.subscribe(api.context, .player_disconnected, event, null);
        }
        fn event(_: ?*anyopaque, incoming: *const abi.Event, _: ?*abi.TransferDecision) callconv(.c) void {
            if (incoming.kind == .player_connected) players[incoming.worker].store(incoming.player.id, .release);
            if (incoming.kind == .player_disconnected) _ = left.fetchAdd(1, .release);
        }
        fn query(_: ?*anyopaque, result: *const abi.TaskResult) callconv(.c) void {
            var stats: abi.NetworkStats = undefined;
            var status = api.network_stats(api.context, result.player, .player, &stats, @sizeOf(abi.NetworkStats));
            if (result.player.id != players[result.worker].load(.acquire)) status = .failed;
            if (status == .ok) status = api.disconnect(api.context, result.player, .of("opaque reason"), done, null);
            if (status != .ok) finished[result.worker].store(@backingInt(status), .release);
        }
        fn done(_: ?*anyopaque, result: *const abi.TaskResult) callconv(.c) void {
            finished[result.worker].store(@backingInt(result.status), .release);
        }
    };
    for (&Multi.players) |*player| player.store(0, .release);
    for (&Multi.finished) |*status| status.store(-100, .release);
    Multi.left.store(0, .release);
    var plugins: bifrost.Plugins = try .init(gpa, &.{}, .{ .workers = 2, .packets = false });
    defer plugins.deinit();
    try plugins.add(Multi.init, null);
    var backend: fixtures.Backend = undefined;
    try backend.start(io, .{});
    defer backend.deinit();
    var first: fixtures.Running = undefined;
    try first.start(io, try fixtures.config(&.{backend.address()}), .{ .plugins = &plugins, .worker = 0 });
    defer first.deinit();
    var second: fixtures.Running = undefined;
    try second.start(io, try fixtures.config(&.{backend.address()}), .{ .plugins = &plugins, .worker = 1 });
    defer second.deinit();
    var a = try fixtures.Player.connect(io, first.address());
    defer a.deinit();
    var b = try fixtures.Player.connect(io, second.address());
    defer b.deinit();
    try a.roundTrip("\xfehello");
    try b.roundTrip("\xfehello");
    for (&Multi.players) |*player| try std.testing.expectEqual(abi.Status.ok, Multi.api.post(Multi.api.context, .{ .id = player.load(.acquire) }, Multi.query, null));
    try a.awaitClosed();
    try b.awaitClosed();
    try fixtures.waitFor(io, &Multi.left, 2);
    for (&Multi.finished) |*status| try std.testing.expectEqual(@as(i32, 0), status.load(.acquire));
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
        .{ abi.Text, header.bifrost_text },
        .{ abi.ChunkRadius, header.bifrost_chunk_radius },
        .{ abi.Command, header.bifrost_command },
        .{ abi.TaskResult, header.bifrost_task_result },
        .{ abi.CommandInfo, header.bifrost_command_info },
        .{ abi.PlayerState, header.bifrost_player_state },
        .{ abi.PlayerInfo, header.bifrost_player_info },
        .{ abi.NetworkStats, header.bifrost_network_stats },
        .{ abi.Vec3, header.bifrost_vec3 },
        .{ abi.Attribute, header.bifrost_attribute },
        .{ abi.Gameplay, header.bifrost_gameplay },
        .{ abi.Entity, header.bifrost_entity },
    }) |pair| {
        try std.testing.expectEqual(@sizeOf(pair[0]), @sizeOf(pair[1]));
        try std.testing.expectEqual(@alignOf(pair[0]), @alignOf(pair[1]));
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
    try expectConstants(abi.PacketType, "BIFROST_PACKET_TYPE_");
    try expectConstants(abi.PacketTarget, "BIFROST_PACKET_TO_");
    try expectConstants(abi.TextType, "BIFROST_TEXT_");
    try expectConstants(abi.CommandPermission, "BIFROST_PERMISSION_");
    try expectConstants(abi.ConnectionState, "BIFROST_CONNECTION_");
    try expectConstants(abi.AuthenticationState, "BIFROST_AUTHENTICATION_");
    try expectConstants(abi.SessionMode, "BIFROST_MODE_");
    try expectConstants(abi.ConnectionPhase, "BIFROST_CONNECTION_PHASE_");
    try expectConstants(abi.TransferState, "BIFROST_TRANSFER_STATE_");
    try expectConstants(abi.PositionSource, "BIFROST_POSITION_");
    try expectConstants(abi.AttributeKind, "BIFROST_ATTRIBUTE_");
    try std.testing.expectEqual(abi.AttributeKind.count, header.BIFROST_ATTRIBUTE_COUNT);
    try expectFlags(abi.NetworkMetric, "BIFROST_NETWORK_");
    try expectFlags(abi.GameplayField, "BIFROST_GAMEPLAY_");
    try expectFlags(abi.Movement, "BIFROST_MOVEMENT_");
    try std.testing.expectEqual(abi.api_revision, header.BIFROST_API_REVISION);
    try std.testing.expectEqual(@as(u32, @bitCast(abi.PacketFlags{ .validated = true })), header.BIFROST_PACKET_VALIDATED);
    try std.testing.expectEqual(@as(u32, @bitCast(abi.PacketFlags{ .fields = true })), header.BIFROST_PACKET_FIELDS);
    try std.testing.expectEqual(abi.version, header.BIFROST_ABI_VERSION);
    try std.testing.expectEqual(abi.no_backend, header.BIFROST_NO_BACKEND);
    try std.testing.expectEqual(abi.no_worker, header.BIFROST_NO_WORKER);
    inline for (comptime std.meta.fieldNames(abi.Capabilities)[0 .. std.meta.fieldNames(abi.Capabilities).len - 1]) |field| {
        var capability: abi.Capabilities = .{};
        @field(capability, field) = true;
        const name = comptime upper: {
            var buffer: [field.len]u8 = undefined;
            break :upper "BIFROST_CAPABILITY_" ++ std.ascii.upperString(&buffer, field);
        };
        try std.testing.expectEqual(@as(u64, @bitCast(capability)), @field(header, name));
    }
    try std.testing.expectEqual(@as(u64, @bitCast(abi.Capabilities.supported)), header.BIFROST_CAPABILITY_EVENTS | header.BIFROST_CAPABILITY_COMMANDS |
        header.BIFROST_CAPABILITY_PACKETS | header.BIFROST_CAPABILITY_TASKS | header.BIFROST_CAPABILITY_GAMEPLAY | header.BIFROST_CAPABILITY_ENTITIES);
}

fn expectFlags(comptime Flags: type, comptime prefix: []const u8) !void {
    inline for (comptime std.meta.declarations(Flags)) |decl| {
        const name = comptime upper: {
            var buffer: [decl.len]u8 = undefined;
            break :upper prefix ++ std.ascii.upperString(&buffer, decl);
        };
        try std.testing.expectEqual(@field(Flags, decl), @field(header, name));
    }
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

test "a native C plugin built from the header loads, gets its event, shuts down and agrees on the layout" {
    var files: NativePlugins = try .init();
    defer files.deinit();
    const path = try files.add("CFixture", test_options.c_plugin);
    defer gpa.free(path);
    var library: bifrost.Plugins.Library = try .open(path);
    defer library.close();
    const events = library.lookup(*const fn () callconv(.c) u32, "bifrost_fixture_events").?;
    const shutdowns = library.lookup(*const fn () callconv(.c) u32, "bifrost_fixture_shutdowns").?;
    const layout = library.lookup(*const fn (out: [*]u64, capacity: usize) callconv(.c) usize, "bifrost_fixture_layout").?;
    const events_before = events();
    const shutdowns_before = shutdowns();

    var plugins: bifrost.Plugins = try .init(gpa, &.{}, .{});
    try files.load(&plugins, "CFixture");
    try std.testing.expectEqualStrings("c-fixture", plugins.metadata(0).name());
    try std.testing.expectEqualStrings("1.0.0", plugins.metadata(0).version());
    try std.testing.expectEqualStrings("Counts players, says plugin.toml", plugins.metadata(0).description());
    try std.testing.expectEqualStrings(path, plugins.metadata(0).package);
    plugins.emit(&.{ .kind = .player_connected }, null);
    plugins.emit(&.{ .kind = .proxy_started }, null);
    try std.testing.expectEqual(events_before + 1, events());
    plugins.deinit();
    try std.testing.expectEqual(shutdowns_before + 1, shutdowns());

    var expected: [128]u64 = undefined;
    var len: usize = 0;
    inline for (.{ abi.Str, abi.Player, abi.Event, abi.TransferDecision, abi.Packet, abi.Text, abi.ChunkRadius, abi.Command, abi.CommandInfo, abi.TaskResult, abi.Host, abi.Plugin }) |T| {
        expected[len] = @sizeOf(T);
        len += 1;
        inline for (comptime std.meta.fieldNames(T)) |field| {
            expected[len] = @offsetOf(T, field);
            len += 1;
        }
    }
    expected[len] = abi.version;
    len += 1;
    var actual: [128]u64 = undefined;
    try std.testing.expectEqualSlices(u64, expected[0..len], actual[0..layout(&actual, actual.len)]);
}

test "the example plugin loads from disk and keeps players off maintenance" {
    var files: NativePlugins = try .init();
    defer files.deinit();
    gpa.free(try files.add("Maintenance", test_options.example_plugin));
    var plugins: bifrost.Plugins = try .init(gpa, &.{}, .{});
    defer plugins.deinit();
    try files.load(&plugins, "Maintenance");
    try std.testing.expectEqualStrings("Keeps players off the maintenance backend", plugins.metadata(0).description());
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
    const Mode = enum(u8) { pass, cancel, replace, corrupt, retag };
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
            .retag => packet.replacement_len = (managed.rawPacket(out, managed.game_packet_id - 1, "pong") catch unreachable).len,
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
    try Hook.sendWith(&rig, .retag, "ping");
    try std.testing.expectEqualStrings("ping", try rig.player.nextGamePacket(&buffer));

    Hook.mode.store(.corrupt, .release);
    try rig.expectOn(&rig.a);
    const totals = plugins.totals(0);
    try std.testing.expectEqual(@as(u64, 2), totals.errors);
    try std.testing.expectEqual(@as(u64, Hook.calls.load(.acquire)), totals.calls);
    try std.testing.expectEqual(@as(u32, 4), rig.a.echoes.load(.acquire));
}

const Filter = struct {
    const Current = bedwire.protocol.Current;

    fn init(host_api: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
        plugin.name = .of("filter");
        plugin.plugin_version = .of("1.0.0");
        plugin.capabilities = .{ .packets = true };
        for ([_]bedwire.PacketKind{ .add_painting, .container_open }) |kind| {
            const status = host_api.subscribe_packet(host_api.context, .from_backend, Current.packetId(kind).?, .any, .{}, cancel, null);
            if (status != .ok) return status;
        }
        return host_api.subscribe_packet(host_api.context, .from_player, Current.packetId(.client_cache_status).?, .any, .{}, noCache, null);
    }

    fn cancel(_: ?*anyopaque, _: *abi.Packet) callconv(.c) abi.PacketAction {
        return .cancel;
    }

    fn noCache(_: ?*anyopaque, packet: *abi.Packet) callconv(.c) abi.PacketAction {
        const out = packet.replacement.?[0..packet.replacement_capacity];
        packet.replacement_len = (managed.typedPacket(out, .{ .client_cache_status = .{ .is_cache_supported = false } }) catch return .pass).len;
        return .replace;
    }

    fn shown(player: *managed.Player) bool {
        return player.received(.mob_effect) == 1;
    }
};

test "proxy state and transfers follow what plugins let through, not what the other side sent" {
    var plugins: bifrost.Plugins = try .init(gpa, &.{}, .{});
    defer plugins.deinit();
    try plugins.add(Filter.init, null);
    var rig: Rig = undefined;
    try rig.start(.{ .plugins = &plugins, .cache = true });
    defer rig.deinit();
    var buffer: [16]u8 = undefined;
    try rig.player.send(&.{try managed.rawPacket(&buffer, managed.game_packet_id, "scene")});
    try rig.pumpUntil(rig.player, Filter.shown);
    try std.testing.expectEqual(@as(usize, 0), rig.player.received(.add_painting));

    try rig.transfer(1);
    try rig.waitFor(.transfers_committed, 1);
    try rig.expectOn(&rig.b);
    try std.testing.expectEqual(@as(usize, 0), rig.player.received(.remove_actor));
    try std.testing.expectEqual(@as(usize, 0), rig.player.received(.container_close));
    try std.testing.expectEqual(@as(usize, 1), rig.player.received(.remove_objective));
    try std.testing.expectEqual(@as(u32, 1), rig.b.cache_reports.load(.acquire));
    try std.testing.expect(!rig.a.cache_supported.load(.acquire) and !rig.b.cache_supported.load(.acquire));
}

const StateHook = struct {
    var block_spawn: std.atomic.Value(bool) = .init(false);
    var before_game: std.atomic.Value(u32) = .init(0);
    var in_game: std.atomic.Value(u32) = .init(0);

    fn init(host: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
        plugin.name = .of("state-hook");
        plugin.plugin_version = .of("1");
        plugin.capabilities = .{ .packets = true };
        const Current = bedwire.protocol.Current;
        const subscriptions = .{
            .{ Current.packetId(.set_local_player_as_initialised).?, abi.PacketPhase.before_game, spawn },
            .{ Current.packetId(.container_close).?, abi.PacketPhase.any, cancel },
            .{ managed.game_packet_id, abi.PacketPhase.before_game, before },
            .{ managed.game_packet_id, abi.PacketPhase.in_game, after },
        };
        inline for (subscriptions) |subscription| {
            const status = host.subscribe_packet(host.context, .from_player, subscription[0], subscription[1], .{}, subscription[2], null);
            if (status != .ok) return status;
        }
        return .ok;
    }

    fn spawn(_: ?*anyopaque, _: *abi.Packet) callconv(.c) abi.PacketAction {
        return if (block_spawn.load(.acquire)) .cancel else .pass;
    }

    fn cancel(_: ?*anyopaque, _: *abi.Packet) callconv(.c) abi.PacketAction {
        return .cancel;
    }

    fn before(_: ?*anyopaque, _: *abi.Packet) callconv(.c) abi.PacketAction {
        _ = before_game.fetchAdd(1, .release);
        return .pass;
    }

    fn after(_: ?*anyopaque, _: *abi.Packet) callconv(.c) abi.PacketAction {
        _ = in_game.fetchAdd(1, .release);
        return .pass;
    }
};

test "canceling a spawn milestone preserves the packet listener phase until it is delivered" {
    var plugins: bifrost.Plugins = try .init(gpa, &.{}, .{});
    defer plugins.deinit();
    StateHook.block_spawn.store(false, .release);
    StateHook.before_game.store(0, .release);
    StateHook.in_game.store(0, .release);
    try plugins.add(StateHook.init, null);
    var rig: Rig = undefined;
    try rig.start(.{ .plugins = &plugins });
    defer rig.deinit();

    const next_player = try managed.Player.connect(io, rig.running.address(), 3);
    rig.player.destroy();
    rig.player = next_player;
    try rig.player.login("Steve", "2535400000000001");
    StateHook.block_spawn.store(true, .release);
    defer StateHook.block_spawn.store(false, .release);
    try rig.player.spawn();
    const before = StateHook.before_game.load(.acquire);
    const after = StateHook.in_game.load(.acquire);
    try rig.player.echo("before spawn");
    try std.testing.expectEqual(before + 1, StateHook.before_game.load(.acquire));
    try std.testing.expectEqual(after, StateHook.in_game.load(.acquire));

    StateHook.block_spawn.store(false, .release);
    var buffer: [16]u8 = undefined;
    try rig.player.send(&.{try managed.typedPacket(&buffer, .{ .set_local_player_as_initialised = .{ .player_id = 1 } })});
    try rig.player.echo("after spawn");
    try std.testing.expectEqual(before + 1, StateHook.before_game.load(.acquire));
    try std.testing.expectEqual(after + 1, StateHook.in_game.load(.acquire));
}

test "a canceled container close is still cleaned up during transfer" {
    var plugins: bifrost.Plugins = try .init(gpa, &.{}, .{});
    defer plugins.deinit();
    StateHook.block_spawn.store(false, .release);
    try plugins.add(StateHook.init, null);
    var rig: Rig = undefined;
    try rig.start(.{ .plugins = &plugins });
    defer rig.deinit();
    var buffer: [16]u8 = undefined;
    try rig.player.send(&.{try managed.rawPacket(&buffer, managed.game_packet_id, "scene")});
    try rig.pumpUntil(rig.player, Filter.shown);
    try std.testing.expectEqual(@as(usize, 1), rig.player.received(.container_open));
    try rig.player.send(&.{try managed.typedPacket(&buffer, .{ .container_close = .{ .container_id = 3, .container_type = 0, .server_initiated_close = false } })});
    try rig.expectOn(&rig.a);
    try rig.transfer(1);
    try rig.waitFor(.transfers_committed, 1);
    try rig.expectOn(&rig.b);
    try std.testing.expectEqual(@as(usize, 1), rig.player.received(.container_close));
}

const Fields = struct {
    var failures: std.atomic.Value(u32) = .init(0);
    var observed: std.atomic.Value(u32) = .init(0);
    var radius: std.atomic.Value(i32) = .init(0);

    fn init(api: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
        plugin.name = .of("fields");
        plugin.plugin_version = .of("1");
        plugin.capabilities = .{ .packets = true };
        const status = api.subscribe_packet(api.context, .from_player, 9, .in_game, .{ .fields = true }, editText, @constCast(api));
        if (status != .ok) return status;
        return api.subscribe_packet(api.context, .from_player, 69, .any, .{ .fields = true, .validated = true }, editRadius, @constCast(api));
    }

    fn observer(api: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
        plugin.name = .of("fields-observer");
        plugin.plugin_version = .of("1");
        plugin.capabilities = .{ .packets = true };
        return api.subscribe_packet(api.context, .from_player, 9, .in_game, .{ .fields = true, .validated = true }, readText, @constCast(api));
    }

    fn apiFrom(user: ?*anyopaque) *const abi.Host {
        return @ptrCast(@alignCast(user.?));
    }

    fn editText(user: ?*anyopaque, packet: *abi.Packet) callconv(.c) abi.PacketAction {
        const api = apiFrom(user);
        var text: abi.Text = undefined;
        if (api.decode_packet(api.context, packet, .text, &text, @sizeOf(abi.Text)) != .ok) {
            _ = failures.fetchAdd(1, .release);
            return .pass;
        }
        if (std.mem.eql(u8, text.message.slice(), "blocked")) return .cancel;
        text.message = .of("changed");
        if (api.encode_packet(api.context, packet, .text, &text, @sizeOf(abi.Text)) != .ok) {
            _ = failures.fetchAdd(1, .release);
            return .pass;
        }
        return .replace;
    }

    fn readText(user: ?*anyopaque, packet: *abi.Packet) callconv(.c) abi.PacketAction {
        const api = apiFrom(user);
        var text: abi.Text = undefined;
        if (api.decode_packet(api.context, packet, .text, &text, @sizeOf(abi.Text)) != .ok or !std.mem.eql(u8, text.message.slice(), "changed")) _ = failures.fetchAdd(1, .release);
        _ = observed.fetchAdd(1, .release);
        return .pass;
    }

    fn editRadius(user: ?*anyopaque, packet: *abi.Packet) callconv(.c) abi.PacketAction {
        const api = apiFrom(user);
        var value: abi.ChunkRadius = undefined;
        if (api.decode_packet(api.context, packet, .chunk_radius, &value, @sizeOf(abi.ChunkRadius)) != .ok) {
            _ = failures.fetchAdd(1, .release);
            return .pass;
        }
        value.radius = 6;
        if (api.encode_packet(api.context, packet, .chunk_radius, &value, @sizeOf(abi.ChunkRadius)) != .ok) {
            _ = failures.fetchAdd(1, .release);
            return .pass;
        }
        radius.store(value.radius, .release);
        return .replace;
    }
};

fn sendTextPair(player: *managed.Player, original: []const u8, expected: []const u8) !void {
    var buffers: [2][128]u8 = undefined;
    const blocked = try managed.typedPacket(&buffers[0], .{ .text = .{ .localize = false, .body = .{ .message_only = .{ .message_type = .raw, .message = "blocked" } }, .senders_xuid = "", .platform_id = "", .filtered_message = null } });
    const text = try managed.typedPacket(&buffers[1], .{ .text = .{ .localize = false, .body = .{ .author_and_message = .{ .message_type = .chat, .player_name = "Steve", .message = original } }, .senders_xuid = "123", .platform_id = "platform", .filtered_message = "filtered" } });
    try player.send(&.{ blocked, text });
    var packets = try player.receive();
    defer packets.deinit();
    const packet = packets.next() orelse return error.NoPacket;
    const decoded = (try player.session.decodePacket(packet)).value.typed.text;
    try std.testing.expectEqualStrings(expected, decoded.body.author_and_message.message);
    try std.testing.expectEqualStrings("Steve", decoded.body.author_and_message.player_name);
    try std.testing.expectEqualStrings("123", decoded.senders_xuid);
    try std.testing.expectEqualStrings("platform", decoded.platform_id);
    try std.testing.expectEqualStrings("filtered", decoded.filtered_message.?);
    try std.testing.expect(packets.next() == null);
}

test "typed plugin modifications cross the managed transport and survive transfers" {
    var plugins: bifrost.Plugins = try .init(gpa, &.{}, .{});
    defer plugins.deinit();
    Fields.failures.store(0, .release);
    Fields.observed.store(0, .release);
    Fields.radius.store(0, .release);
    try plugins.add(Fields.init, null);
    try plugins.add(Fields.observer, null);
    var rig: Rig = undefined;
    try rig.start(.{ .plugins = &plugins });
    defer rig.deinit();
    try std.testing.expectEqual(@as(i32, 6), Fields.radius.load(.acquire));
    try sendTextPair(rig.player, "original", "changed");
    try std.testing.expectEqual(@as(u32, 1), Fields.observed.load(.acquire));
    try rig.transfer(1);
    try rig.waitFor(.transfers_committed, 1);
    try rig.expectOn(&rig.b);
    try sendTextPair(rig.player, "original", "changed");
    try std.testing.expectEqual(@as(u32, 2), Fields.observed.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), Fields.failures.load(.acquire));
}

fn sendFilteredPackets(player: *managed.Player, backend: *managed.Backend) !void {
    var buffers: [4][2048]u8 = undefined;
    const negative = try managed.typedPacket(&buffers[0], .{ .request_chunk_radius = .{ .chunk_radius = -1, .max_chunk_radius = 64 } });
    const radius = try managed.typedPacket(&buffers[1], .{ .request_chunk_radius = .{ .chunk_radius = 32, .max_chunk_radius = 64 } });
    const long_message: [513]u8 = @splat('x');
    const oversized = try managed.typedPacket(&buffers[2], .{ .text = .{ .localize = false, .body = .{ .author_and_message = .{ .message_type = .chat, .player_name = "Steve", .message = &long_message } }, .senders_xuid = "", .platform_id = "", .filtered_message = null } });
    const chat = try managed.typedPacket(&buffers[3], .{ .text = .{ .localize = false, .body = .{ .author_and_message = .{ .message_type = .chat, .player_name = "spoofed", .message = "hello Bedrock" } }, .senders_xuid = "123", .platform_id = "platform", .filtered_message = "filtered" } });
    try player.send(&.{ negative, radius, oversized, chat });
    var received: usize = 0;
    var saw_radius = false;
    var saw_chat = false;
    var saw_warning = false;
    while (received < 3) {
        var packets = try player.receive();
        defer packets.deinit();
        while (packets.next()) |packet| {
            const decoded = (try player.session.decodePacket(packet)).value.typed;
            switch (decoded) {
                .chunk_radius_updated => |updated| {
                    try std.testing.expect(!saw_radius);
                    saw_radius = true;
                    try std.testing.expectEqual(@as(i32, 12), updated.chunk_radius);
                    try std.testing.expectEqual(@as(u32, 12), backend.requested_max_radius.load(.acquire));
                },
                .text => |text| if (text.body == .message_only) {
                    try std.testing.expect(!saw_warning);
                    saw_warning = true;
                    try std.testing.expectEqualStrings("Chat messages are limited to 512 bytes.", text.body.message_only.message);
                } else {
                    try std.testing.expect(!saw_chat);
                    saw_chat = true;
                    try std.testing.expectEqualStrings("hello Bedrock", text.body.author_and_message.message);
                    try std.testing.expectEqualStrings("Steve", text.body.author_and_message.player_name);
                    try std.testing.expectEqualStrings("123", text.senders_xuid);
                    try std.testing.expectEqualStrings("platform", text.platform_id);
                    try std.testing.expectEqualStrings("filtered", text.filtered_message.?);
                },
                else => return error.UnexpectedPacket,
            }
            received += 1;
        }
    }
    try std.testing.expect(saw_radius and saw_chat and saw_warning);
}

test "the C++ packet example enforces Bedrock limits and player context across transfers" {
    var files: NativePlugins = try .init();
    defer files.deinit();
    const path = try files.add("PacketFilter", test_options.packet_filter);
    defer gpa.free(path);
    var plugins: bifrost.Plugins = try .init(gpa, &.{}, .{});
    defer plugins.deinit();
    try files.load(&plugins, "PacketFilter");
    var rig: Rig = undefined;
    try rig.start(.{ .plugins = &plugins });
    defer rig.deinit();
    try sendFilteredPackets(rig.player, &rig.a);
    try rig.transfer(1);
    try rig.waitFor(.transfers_committed, 1);
    try rig.expectOn(&rig.b);
    try sendFilteredPackets(rig.player, &rig.b);
}

fn chatPacket(buffer: []u8, message: []const u8) ![]const u8 {
    return managed.typedPacket(buffer, .{ .text = .{ .localize = false, .body = .{ .author_and_message = .{ .message_type = .chat, .player_name = "Steve", .message = message } }, .senders_xuid = "", .platform_id = "", .filtered_message = null } });
}

test "the C++ chat guard example warns, cancels and finally removes a player" {
    var files: NativePlugins = try .init();
    defer files.deinit();
    const path = try files.add("ChatGuard", test_options.chat_guard);
    defer gpa.free(path);
    var plugins: bifrost.Plugins = try .init(gpa, &.{}, .{});
    defer plugins.deinit();
    try files.load(&plugins, "ChatGuard");
    try std.testing.expectEqualStrings("ChatGuard", plugins.metadata(0).name());
    var rig: Rig = undefined;
    try rig.start(.{ .plugins = &plugins });
    defer rig.deinit();
    var buffers: [2][128]u8 = undefined;
    for ([_]u32{ 2, 1 }) |left| {
        try rig.player.send(&.{ try chatPacket(&buffers[0], "Free Robux here"), try chatPacket(&buffers[1], "hello") });
        var expected: [96]u8 = undefined;
        const warning = try std.fmt.bufPrint(&expected, "That message was blocked. {d} more and you will be removed.", .{left});
        var warned = false;
        var echoed = false;
        while (!warned or !echoed) {
            var packets = try rig.player.receive();
            defer packets.deinit();
            while (packets.next()) |packet| switch ((try rig.player.session.decodePacket(packet)).value.typed.text.body) {
                .message_only => |body| {
                    try std.testing.expect(!warned);
                    try std.testing.expectEqualStrings(warning, body.message);
                    warned = true;
                },
                .author_and_message => |body| {
                    try std.testing.expect(!echoed);
                    try std.testing.expectEqualStrings("hello", body.message);
                    echoed = true;
                },
                else => return error.UnexpectedPacket,
            };
        }
    }
    try rig.player.send(&.{try chatPacket(&buffers[0], "griefing time")});
    var removed = false;
    for (0..8) |_| {
        var packets = try rig.player.receive();
        defer packets.deinit();
        while (packets.next()) |packet| {
            if (packet.kind != .disconnect) return error.UnexpectedPacket;
            const message = (try rig.player.session.decodePacket(packet)).value.typed.disconnect.messages.messages.message;
            try std.testing.expectEqualStrings("Removed for repeated blocked messages", message);
            removed = true;
        }
        if (removed) break;
    }
    try std.testing.expect(removed);
    try std.testing.expectEqual(@as(u64, 0), plugins.totals(0).errors);
}

const Injector = struct {
    var completed: std.atomic.Value(u32) = .init(0);
    var failed: std.atomic.Value(u32) = .init(0);
    var pregame: std.atomic.Value(i32) = .init(-1);
    var from_player: std.atomic.Value(u32) = .init(0);
    var from_backend: std.atomic.Value(u32) = .init(0);
    var transfer_status: std.atomic.Value(i32) = .init(-1);

    fn init(host: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
        completed.store(0, .release);
        failed.store(0, .release);
        pregame.store(-1, .release);
        from_player.store(0, .release);
        from_backend.store(0, .release);
        transfer_status.store(-1, .release);
        const status = Recorder.init(host, plugin);
        if (status != .ok) return status;
        plugin.capabilities.packets = true;
        const event = host.subscribe(host.context, .player_authenticated, onAuthenticated, null);
        if (event != .ok) return event;
        const transfer = host.subscribe(host.context, .transfer_requested, onTransfer, null);
        if (transfer != .ok) return transfer;
        for ([_]abi.Direction{ .from_player, .from_backend }) |direction| {
            const subscribed = host.subscribe_packet(host.context, direction, 9, .any, .{}, onPacket, null);
            if (subscribed != .ok) return subscribed;
        }
        return .ok;
    }

    fn onAuthenticated(_: ?*anyopaque, event: *const abi.Event, _: ?*abi.TransferDecision) callconv(.c) void {
        const host = Recorder.host.?;
        const bytes = [_]u8{ 9, 0, 0, 0, 2, 'h', 'i', 0, 0, 0 };
        const status = host.send_packet(host.context, event.player, .player, .of(&bytes), beforeGame, null);
        if (status != .ok) pregame.store(@backingInt(status), .release);
    }

    fn beforeGame(_: ?*anyopaque, result: *const abi.TaskResult) callconv(.c) void {
        pregame.store(@backingInt(result.status), .release);
    }

    fn onTransfer(_: ?*anyopaque, event: *const abi.Event, _: ?*abi.TransferDecision) callconv(.c) void {
        const host = Recorder.host.?;
        const bytes = [_]u8{ 9, 0, 0, 0, 2, 'h', 'i', 0, 0, 0 };
        const status = host.send_packet(host.context, event.player, .backend, .of(&bytes), duringTransfer, null);
        if (status != .ok) transfer_status.store(@backingInt(status), .release);
    }

    fn duringTransfer(_: ?*anyopaque, result: *const abi.TaskResult) callconv(.c) void {
        transfer_status.store(@backingInt(result.status), .release);
    }

    fn onPacket(_: ?*anyopaque, packet: *abi.Packet) callconv(.c) abi.PacketAction {
        const counter = if (packet.direction == .from_player) &from_player else &from_backend;
        _ = counter.fetchAdd(1, .monotonic);
        return .pass;
    }

    fn done(_: ?*anyopaque, result: *const abi.TaskResult) callconv(.c) void {
        if (result.status != .ok or result.worker != 0) _ = failed.fetchAdd(1, .monotonic);
        _ = completed.fetchAdd(1, .release);
    }

    fn wait() !void {
        for (0..500) |_| {
            if (completed.load(.acquire) == 3) return;
            try io.sleep(.fromMilliseconds(10), .awake);
        }
        return error.WaitTimedOut;
    }
};

fn injectPackets(rig: *Rig) !void {
    const host = Recorder.host.?;
    var buffers: [3][128]u8 = undefined;
    const messages = [_][]const u8{ "to player", "to backend" };
    for (messages, buffers[0..2], [_]abi.PacketTarget{ .player, .backend }) |message, *buffer, target| {
        const packet = try managed.typedPacket(buffer, .{ .text = .{
            .localize = false,
            .body = .{ .message_only = .{ .message_type = .raw, .message = message } },
            .senders_xuid = "",
            .platform_id = "",
            .filtered_message = null,
        } });
        try std.testing.expectEqual(abi.Status.ok, host.send_packet(host.context, Recorder.handle(), target, .of(packet), Injector.done, null));
        @memset(buffer, 0);
    }
    const radius = try managed.typedPacket(&buffers[2], .{ .request_chunk_radius = .{ .chunk_radius = 10, .max_chunk_radius = 11 } });
    try std.testing.expectEqual(abi.Status.ok, host.send_packet(host.context, Recorder.handle(), .backend, .of(radius), Injector.done, null));
    var received: usize = 0;
    while (received < 3) {
        var packets = try rig.player.receive();
        defer packets.deinit();
        while (packets.next()) |packet| {
            const decoded = (try rig.player.session.decodePacket(packet)).value.typed;
            switch (received) {
                0, 1 => try std.testing.expectEqualStrings(messages[received], decoded.text.body.message_only.message),
                2 => try std.testing.expectEqual(@as(i32, 10), decoded.chunk_radius_updated.chunk_radius),
                else => return error.UnexpectedPacket,
            }
            received += 1;
        }
    }
    try Injector.wait();
    try std.testing.expectEqual(@as(u32, 0), Injector.failed.load(.acquire));

    const message: [65526]u8 = @splat('x');
    var buffer: [65536]u8 = undefined;
    const large = try managed.typedPacket(&buffer, .{ .text = .{
        .localize = false,
        .body = .{ .message_only = .{ .message_type = .raw, .message = &message } },
        .senders_xuid = "",
        .platform_id = "",
        .filtered_message = null,
    } });
    try std.testing.expectEqual(buffer.len, large.len);
    try std.testing.expectEqual(abi.Status.ok, host.send_packet(host.context, Recorder.handle(), .player, .of(large), null, null));
    @memset(&buffer, 0);
    var packets = try rig.player.receive();
    defer packets.deinit();
    const packet = packets.next() orelse return error.MissingPacket;
    const text = (try rig.player.session.decodePacket(packet)).value.typed.text;
    try std.testing.expectEqualStrings(&message, text.body.message_only.message);
    try std.testing.expect(packets.next() == null);
}

test "packet injection uses managed transport, skips listeners and preserves radius across transfers" {
    var plugins: bifrost.Plugins = try .init(gpa, &.{}, .{});
    defer plugins.deinit();
    Recorder.reset();
    try plugins.add(Injector.init, null);
    var rig: Rig = undefined;
    try rig.start(.{ .plugins = &plugins });
    defer rig.deinit();
    try std.testing.expectEqual(@as(i32, @backingInt(abi.Status.too_late)), Injector.pregame.load(.acquire));
    try injectPackets(&rig);
    try std.testing.expectEqual(@as(u32, 0), Injector.from_player.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), Injector.from_backend.load(.acquire));
    try rig.transfer(1);
    try rig.waitFor(.transfers_committed, 1);
    try rig.expectOn(&rig.b);
    const status = Injector.transfer_status.load(.acquire);
    try std.testing.expect(status == @backingInt(abi.Status.busy) or status == @backingInt(abi.Status.canceled));
    try std.testing.expectEqual(@as(i32, 10), rig.b.requested_radius.load(.acquire));
    try std.testing.expectEqual(@as(u32, 11), rig.b.requested_max_radius.load(.acquire));
    Injector.completed.store(0, .release);
    try injectPackets(&rig);
    try std.testing.expectEqual(@as(u32, 0), Injector.from_player.load(.acquire));
    try std.testing.expectEqual(@as(u32, 2), Injector.from_backend.load(.acquire));
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

test "a native C plugin can be loaded and unloaded repeatedly" {
    var files: NativePlugins = try .init();
    defer files.deinit();
    const path = try files.add("CFixture", test_options.c_plugin);
    defer gpa.free(path);
    var library: bifrost.Plugins.Library = try .open(path);
    defer library.close();
    const shutdowns = library.lookup(*const fn () callconv(.c) u32, "bifrost_fixture_shutdowns").?;
    const before = shutdowns();
    for (0..20) |_| {
        var plugins: bifrost.Plugins = try .init(gpa, &.{}, .{});
        defer plugins.deinit();
        try files.load(&plugins, "CFixture");
        try std.testing.expect(plugins.subscribed(.player_connected));
    }
    try std.testing.expectEqual(before + 20, shutdowns());
}

test "a native C++23 plugin loads, keeps its exceptions to itself and shuts down" {
    var files: NativePlugins = try .init();
    defer files.deinit();
    const path = try files.add("CppFixture", test_options.cpp_plugin);
    defer gpa.free(path);
    var library: bifrost.Plugins.Library = try .open(path);
    defer library.close();
    const counter = *const fn () callconv(.c) u32;
    const events = library.lookup(counter, "bifrost_fixture_events").?;
    const caught = library.lookup(counter, "bifrost_fixture_caught").?;
    const shutdowns = library.lookup(counter, "bifrost_fixture_shutdowns").?;
    const args = library.lookup(*const fn (out: [*]u8, capacity: usize) callconv(.c) usize, "bifrost_fixture_args").?;
    const host_size = library.lookup(*const fn () callconv(.c) usize, "bifrost_fixture_host_size").?;
    try std.testing.expectEqual(@as(usize, @sizeOf(abi.Host)), host_size());
    const events_before = events();
    const caught_before = caught();
    const shutdowns_before = shutdowns();

    var plugins: bifrost.Plugins = try .init(gpa, &.{}, .{});
    try files.load(&plugins, "CppFixture");
    try std.testing.expectEqualStrings("cpp-fixture", plugins.metadata(0).name());
    try std.testing.expectEqualStrings("Built as C++23", plugins.metadata(0).description());
    plugins.emit(&.{ .kind = .player_connected }, null);
    try std.testing.expectEqual(events_before + 1, events());
    try std.testing.expect(plugins.runCommand(0, io, .{}, "/echo"));
    try std.testing.expectEqual(caught_before + 1, caught());
    try std.testing.expect(plugins.runCommand(0, io, .{}, "/ECHO hello there"));
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("hello there", buffer[0..args(&buffer, buffer.len)]);
    plugins.deinit();
    try std.testing.expectEqual(shutdowns_before + 1, shutdowns());
}

test "native plugins are discovered in filename order, skipping disabled ones" {
    var files: NativePlugins = try .init();
    defer files.deinit();
    const c_path = try files.add("B-C", test_options.c_plugin);
    defer gpa.free(c_path);
    gpa.free(try files.add("A-Cpp", test_options.cpp_plugin));
    gpa.free(try files.add("C-Zig", test_options.example_plugin));
    try files.tmp.dir.writeFile(io, .{ .sub_path = "D-Off" ++ bifrost.Plugins.Package.library_extension, .data = "not a library" });
    var library: bifrost.Plugins.Library = try .open(c_path);
    defer library.close();
    const shutdowns = library.lookup(*const fn () callconv(.c) u32, "bifrost_fixture_shutdowns").?;
    const before = shutdowns();

    var plugins: bifrost.Plugins = try .init(gpa, &.{}, .{});
    try bifrost.Plugins.Package.discover(&plugins, io, files.root, &.{"d-off"});
    try std.testing.expectEqual(@as(usize, 3), plugins.loaded.items.len);
    for ([_][]const u8{ "cpp-fixture", "c-fixture", "maintenance" }, [_][]const u8{ "A-Cpp", "B-C", "C-Zig" }, 0..) |name, dir, i| {
        try std.testing.expectEqualStrings(name, plugins.metadata(i).name());
        try std.testing.expectEqualStrings(dir, std.fs.path.stem(plugins.metadata(i).package));
    }
    plugins.deinit();
    try std.testing.expectEqual(before + 1, shutdowns());
}

test "native plugins reject missing exports, malformed manifests, metadata mismatches and unsupported ABI versions" {
    var files: NativePlugins = try .init();
    defer files.deinit();
    const path = try files.add("Rejected", test_options.rejected_plugin);
    defer gpa.free(path);
    gpa.free(try files.add("NoEntry", test_options.no_entry_library));
    gpa.free(try files.add("NoManifest", test_options.no_manifest_library));
    gpa.free(try files.add("Good", test_options.c_plugin));
    gpa.free(try files.add("Twin", test_options.c_plugin));
    var library: bifrost.Plugins.Library = try .open(path);
    defer library.close();
    const mode = library.lookup(*const fn (u32) callconv(.c) void, "bifrost_fixture_mode").?;
    const counter = *const fn () callconv(.c) u32;
    const shutdowns = library.lookup(counter, "bifrost_fixture_shutdowns").?;
    const inits = library.lookup(counter, "bifrost_fixture_inits").?;

    var plugins: bifrost.Plugins = try .init(gpa, &.{}, .{});
    defer plugins.deinit();
    try std.testing.expectError(error.MissingManifest, files.load(&plugins, "NoManifest"));
    try std.testing.expectError(error.MissingEntrypoint, files.load(&plugins, "NoEntry"));
    const before = shutdowns();
    const init_before = inits();
    for (1..8) |value| {
        mode(@intCast(value));
        try std.testing.expectError(error.InvalidManifest, files.load(&plugins, "Rejected"));
    }
    try std.testing.expectEqual(init_before, inits());
    for (8..13) |value| {
        mode(@intCast(value));
        const expected = switch (value) {
            8, 9 => error.MetadataMismatch,
            10, 11 => error.IncompatiblePlugin,
            else => error.PluginInitFailed,
        };
        try std.testing.expectError(expected, files.load(&plugins, "Rejected"));
        try std.testing.expectEqual(@as(usize, 0), plugins.loaded.items.len);
        try std.testing.expect(!plugins.subscribed(.player_connected));
        try std.testing.expect(!plugins.hasCommands());
        try std.testing.expect(plugins.packetTable(.from_player) == null);
        try std.testing.expectEqual(@as(usize, 0), plugins.pending.items.len);
        try std.testing.expectEqual(@as(usize, 0), plugins.pending_packets.items.len);
        try std.testing.expectEqual(@as(usize, 0), plugins.pending_commands.items.len);
    }
    try std.testing.expectEqual(before + 4, shutdowns());
    try files.load(&plugins, "Good");
    try std.testing.expectError(error.DuplicatePlugin, files.load(&plugins, "Twin"));
    try std.testing.expectEqual(@as(usize, 1), plugins.loaded.items.len);
}

test "native manifest retrieval returns the exact embedded bytes without allocating" {
    inline for (.{ test_options.c_plugin, test_options.cpp_plugin, test_options.example_plugin, test_options.packet_filter }, .{
        @embedFile("../plugin/fixture.toml"),
        @embedFile("../plugin/fixture_cpp.toml"),
        @embedFile("maintenance_manifest"),
        @embedFile("packet_manifest"),
    }) |built, expected| {
        const path = try std.Io.Dir.cwd().realPathFileAlloc(io, built, gpa);
        defer gpa.free(path);
        var library = try bifrost.Plugins.Library.open(path);
        defer library.close();
        const get = library.lookup(abi.ManifestFn, abi.manifest_entrypoint).?;
        try std.testing.expectEqual(abi.Status.invalid_argument, get(null));
        var source: abi.Str = .{};
        try std.testing.expectEqual(abi.Status.ok, get(&source));
        try std.testing.expectEqualStrings(expected, source.slice());
        var again: abi.Str = .{};
        try std.testing.expectEqual(abi.Status.ok, get(&again));
        try std.testing.expect(source.ptr == again.ptr and source.len == again.len);
        const manifest = try bifrost.Plugins.Package.retrieve(gpa, get, built);
        try std.testing.expect(manifest.metadata.description().len != 0);
        try std.testing.expect(std.mem.indexOf(u8, source.slice(), "library =") == null);
    }
}

test "disabled native filename stems are skipped before opening even when identity differs" {
    var files: NativePlugins = try .init();
    defer files.deinit();
    gpa.free(try files.add("Renamed", test_options.c_plugin));
    var plugins: bifrost.Plugins = try .init(gpa, &.{}, .{});
    defer plugins.deinit();
    try bifrost.Plugins.Package.discover(&plugins, io, files.root, &.{"renamed"});
    try std.testing.expectEqual(@as(usize, 0), plugins.loaded.items.len);
    try bifrost.Plugins.Package.discover(&plugins, io, files.root, &.{"c-fixture"});
    try std.testing.expectEqualStrings("c-fixture", plugins.metadata(0).name());
}

test "native libraries unload completely between startup and shutdown cycles" {
    var files: NativePlugins = try .init();
    defer files.deinit();
    const path = try files.add("CFixture", test_options.c_plugin);
    defer gpa.free(path);
    for (0..5) |_| {
        {
            var plugins: bifrost.Plugins = try .init(gpa, &.{}, .{});
            defer plugins.deinit();
            try files.load(&plugins, "CFixture");
            var library = try bifrost.Plugins.Library.open(path);
            defer library.close();
            const events = library.lookup(*const fn () callconv(.c) u32, "bifrost_fixture_events").?;
            try std.testing.expectEqual(@as(u32, 0), events());
            plugins.emit(&.{ .kind = .player_connected }, null);
            try std.testing.expectEqual(@as(u32, 1), events());
        }
    }
    const name = std.fs.path.basename(path);
    try files.tmp.dir.deleteFile(io, name);
}
