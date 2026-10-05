const std = @import("std");
const abi = @import("abi.zig");
const Plugins = @import("Plugins.zig");
const Handles = @import("Handles.zig");

const Events = @This();
const log = std.log.scoped(.plugin);

plugins: ?*Plugins = null,

pub fn proxyStarted(self: Events) void {
    const plugins = self.plugins orelse return;
    if (!plugins.started.swap(true, .acq_rel)) plugins.emit(&.{ .kind = .proxy_started }, null);
}

pub fn proxyStopping(self: Events) void {
    const plugins = self.plugins orelse return;
    if (!plugins.stopping.swap(true, .acq_rel)) plugins.emit(&.{ .kind = .proxy_stopping }, null);
}

pub fn connected(self: Events, route: Handles.Route, address: std.Io.net.IpAddress) abi.Player {
    const plugins = self.plugins orelse return .{};
    const player = plugins.handles.acquire(plugins.gpa, route) catch |err| {
        log.warn("player hidden from plugins: {t}", .{err});
        return .{};
    };
    var buffer: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{f}", .{address}) catch "";
    plugins.emit(&.{ .kind = .player_connected, .player = player, .address = .of(text) }, null);
    return player;
}

pub fn authenticated(self: Events, player: abi.Player, name: []const u8, xuid: []const u8) void {
    const plugins = self.live(player) orelse return;
    plugins.handles.setName(player, name);
    plugins.emit(&.{ .kind = .player_authenticated, .player = player, .name = .of(name), .xuid = .of(xuid) }, null);
}

pub fn disconnected(self: Events, player: *abi.Player) void {
    const plugins = self.live(player.*) orelse return;
    plugins.emit(&.{ .kind = .player_disconnected, .player = player.* }, null);
    plugins.handles.release(player.*);
    player.* = .{};
}

pub fn backendSelected(self: Events, player: abi.Player, backend: usize) void {
    const plugins = self.live(player) orelse return;
    plugins.emit(&.{ .kind = .backend_selected, .player = player, .backend = @intCast(backend) }, null);
}

pub fn transferRequested(self: Events, player: abi.Player, from: usize, to: usize) abi.TransferDecision {
    var decision: abi.TransferDecision = .{};
    const plugins = self.live(player) orelse return decision;
    plugins.emit(&.{ .kind = .transfer_requested, .player = player, .from_backend = @intCast(from), .backend = @intCast(to) }, &decision);
    return decision;
}

pub fn transferEnded(self: Events, player: abi.Player, from: usize, to: usize, failure: abi.TransferFailure) void {
    const plugins = self.live(player) orelse return;
    plugins.emit(&.{
        .kind = if (failure == .none) .transfer_completed else .transfer_failed,
        .player = player,
        .from_backend = @intCast(from),
        .backend = @intCast(to),
        .failure = failure,
    }, null);
}

fn live(self: Events, player: abi.Player) ?*Plugins {
    if (player.id == 0) return null;
    return self.plugins;
}
