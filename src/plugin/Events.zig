const std = @import("std");
const abi = @import("abi.zig");
const Plugins = @import("Plugins.zig");
const Handles = @import("Handles.zig");

const Events = @This();
const log = std.log.scoped(.plugin);

plugins: ?*Plugins = null,
worker: u32 = 0,

pub fn drain(self: Events, io: std.Io, sink: anytype) void {
    const plugins = self.plugins orelse return;
    plugins.drain(self.worker, io, sink);
}

pub fn proxyStarted(self: Events) void {
    const plugins = self.plugins orelse return;
    if (!plugins.started.swap(true, .acq_rel)) plugins.emit(&.{ .kind = .proxy_started }, null);
}

pub fn proxyStopping(self: Events) void {
    const plugins = self.plugins orelse return;
    if (!plugins.stopping.swap(true, .acq_rel)) plugins.emit(&.{ .kind = .proxy_stopping }, null);
}

pub fn connected(self: Events, route: Handles.Route, address: std.Io.net.IpAddress, state: abi.PlayerState) abi.Player {
    const plugins = self.plugins orelse return .{};
    const player = plugins.handles.acquire(plugins.gpa, route) catch |err| {
        log.warn("player hidden from plugins: {t}", .{err});
        return .{};
    };
    _ = plugins.handles.setState(player, state);
    var buffer: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{f}", .{address}) catch "";
    plugins.emit(&.{ .kind = .player_connected, .player = player, .address = .of(text), .worker = self.worker }, null);
    return player;
}

pub fn authenticated(self: Events, player: abi.Player, name: []const u8, xuid: []const u8, uuid: []const u8, online: bool, state: abi.PlayerState) void {
    const plugins = self.live(player) orelse return;
    plugins.handles.setIdentity(player, name, xuid, uuid, online);
    self.stateChanged(player, state);
    plugins.emit(&.{ .kind = .player_authenticated, .player = player, .name = .of(name), .xuid = .of(xuid), .worker = self.worker }, null);
}

pub fn disconnected(self: Events, player: *abi.Player) void {
    const plugins = self.live(player.*) orelse return;
    var info: abi.PlayerInfo = undefined;
    if (plugins.handles.copyInfo(player.*, &info)) {
        info.state.connection = .disconnected;
        info.state.phase = .disconnected;
        self.stateChanged(player.*, info.state);
    }
    plugins.emit(&.{ .kind = .player_disconnected, .player = player.*, .worker = self.worker }, null);
    plugins.handles.release(player.*);
    player.* = .{};
}

pub fn backendSelected(self: Events, player: abi.Player, backend: usize) void {
    const plugins = self.live(player) orelse return;
    plugins.handles.invalidatePackets(player);
    var info: abi.PlayerInfo = undefined;
    if (plugins.handles.copyInfo(player, &info)) {
        info.state.backend = @intCast(backend);
        _ = plugins.handles.setState(player, info.state);
    }
    plugins.emit(&.{ .kind = .backend_selected, .player = player, .backend = @intCast(backend), .worker = self.worker }, null);
}

pub fn transferRequested(self: Events, player: abi.Player, from: usize, to: usize) abi.TransferDecision {
    var decision: abi.TransferDecision = .{};
    const plugins = self.live(player) orelse return decision;
    plugins.handles.invalidatePackets(player);
    var info: abi.PlayerInfo = undefined;
    if (plugins.handles.copyInfo(player, &info)) {
        info.state.transfer = .requested;
        _ = plugins.handles.setState(player, info.state);
    }
    plugins.emit(&.{ .kind = .transfer_requested, .player = player, .from_backend = @intCast(from), .backend = @intCast(to), .worker = self.worker }, &decision);
    return decision;
}

pub fn transferEnded(self: Events, player: abi.Player, from: usize, to: usize, failure: abi.TransferFailure) void {
    const plugins = self.live(player) orelse return;
    plugins.handles.invalidatePackets(player);
    plugins.emit(&.{
        .kind = if (failure == .none) .transfer_completed else .transfer_failed,
        .player = player,
        .from_backend = @intCast(from),
        .backend = @intCast(to),
        .failure = failure,
        .worker = self.worker,
    }, null);
}

pub fn stateChanged(self: Events, player: abi.Player, state: abi.PlayerState) void {
    const plugins = self.live(player) orelse return;
    const previous = plugins.handles.setState(player, state) orelse return;
    if (previous != state.phase) plugins.emit(&.{
        .kind = .connection_phase_changed,
        .player = player,
        .backend = state.backend,
        .worker = self.worker,
        .phase = state.phase,
        .previous_phase = previous,
    }, null);
}

fn live(self: Events, player: abi.Player) ?*Plugins {
    if (player.id == 0) return null;
    return self.plugins;
}
