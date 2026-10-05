const std = @import("std");
const abi = @import("abi.zig");
const Backend = @import("../backend/Backend.zig");
const Library = @import("Library.zig").Library;
pub const Handles = @import("Handles.zig");

const Plugins = @This();
const log = std.log.scoped(.plugin);

pub const max_name_len = 64;

const Subscriber = struct {
    callback: abi.EventFn,
    user: ?*anyopaque,
};

const Pending = struct {
    kind: abi.EventKind,
    subscriber: Subscriber,
};

const Loaded = struct {
    owner: *Plugins,
    host: abi.Host = undefined,
    plugin: abi.Plugin = .{},
    library: ?Library,
    name: [max_name_len]u8 = undefined,
    name_len: usize = 0,

    fn label(self: *const Loaded) []const u8 {
        return self.name[0..self.name_len];
    }
};

gpa: std.mem.Allocator,
backends: []const Backend,
loaded: std.ArrayList(*Loaded) = .empty,
subscribers: [abi.EventKind.count]std.ArrayList(Subscriber) = @splat(.empty),
pending: std.ArrayList(Pending) = .empty,
initializing: std.atomic.Value(?*Loaded) = .init(null),
handles: Handles = .{},

pub fn init(gpa: std.mem.Allocator, backends: []const Backend) Plugins {
    return .{ .gpa = gpa, .backends = backends };
}

pub fn deinit(self: *Plugins) void {
    self.unload();
    for (&self.subscribers) |*list| list.deinit(self.gpa);
    self.loaded.deinit(self.gpa);
    self.pending.deinit(self.gpa);
    self.handles.deinit(self.gpa);
}

pub fn open(self: *Plugins, path: []const u8) !void {
    var library = try Library.open(path);
    errdefer library.close();
    const entry = library.lookup(abi.InitFn, abi.entrypoint) orelse return error.MissingEntrypoint;
    try self.add(entry, library);
}

pub fn add(self: *Plugins, entry: abi.InitFn, library: ?Library) !void {
    try self.loaded.ensureUnusedCapacity(self.gpa, 1);
    const loaded = try self.gpa.create(Loaded);
    errdefer self.gpa.destroy(loaded);
    loaded.* = .{ .owner = self, .library = library };
    loaded.host = hostFor(loaded);

    self.pending.clearRetainingCapacity();
    self.initializing.store(loaded, .release);
    const status = entry(&loaded.host, &loaded.plugin);
    self.initializing.store(null, .release);
    if (status != .ok) {
        log.warn("plugin init failed: {t}", .{status});
        return error.PluginInitFailed;
    }
    errdefer shutdown(loaded);

    const plugin = &loaded.plugin;
    loaded.name_len = @min(plugin.name.len, max_name_len);
    @memcpy(loaded.name[0..loaded.name_len], plugin.name.slice()[0..loaded.name_len]);
    if (plugin.abi_version != abi.version or plugin.struct_size < @sizeOf(abi.Plugin)) {
        log.warn("plugin {s} targets ABI {d}, Bifrost has {d}", .{ loaded.label(), plugin.abi_version, abi.version });
        return error.IncompatiblePlugin;
    }
    const unsupported = @as(u64, @bitCast(plugin.capabilities)) & ~@as(u64, @bitCast(abi.Capabilities.supported));
    if (unsupported != 0) {
        log.warn("plugin {s} needs unsupported capabilities 0x{x}", .{ loaded.label(), unsupported });
        return error.UnsupportedCapability;
    }

    for (self.pending.items) |item| try self.subscribers[@backingInt(item.kind)].ensureUnusedCapacity(self.gpa, countKind(self.pending.items, item.kind));
    for (self.pending.items) |item| self.subscribers[@backingInt(item.kind)].appendAssumeCapacity(item.subscriber);
    self.loaded.appendAssumeCapacity(loaded);
    log.info("loaded plugin {s} {s}", .{ loaded.label(), plugin.plugin_version.slice() });
}

pub fn unload(self: *Plugins) void {
    for (&self.subscribers) |*list| list.clearRetainingCapacity();
    while (self.loaded.pop()) |loaded| {
        shutdown(loaded);
        if (loaded.library) |*library| library.close();
        self.gpa.destroy(loaded);
    }
}

pub fn emit(self: *const Plugins, event: *const abi.Event, decision: ?*abi.TransferDecision) void {
    for (self.subscribers[@backingInt(event.kind)].items) |subscriber| subscriber.callback(subscriber.user, event, decision);
}

pub fn subscribed(self: *const Plugins, kind: abi.EventKind) bool {
    return self.subscribers[@backingInt(kind)].items.len != 0;
}

fn countKind(items: []const Pending, kind: abi.EventKind) usize {
    var count: usize = 0;
    for (items) |item| count += @intFromBool(item.kind == kind);
    return count;
}

fn shutdown(loaded: *Loaded) void {
    if (loaded.plugin.shutdown) |stop| stop(loaded.plugin.state);
}

fn hostFor(loaded: *Loaded) abi.Host {
    return .{
        .context = loaded,
        .log = hostLog,
        .subscribe = hostSubscribe,
        .backend_count = hostBackendCount,
        .backend_name = hostBackendName,
        .player_name = hostPlayerName,
        .transfer = hostTransfer,
    };
}

fn from(context: *anyopaque) *Loaded {
    return @ptrCast(@alignCast(context));
}

fn hostLog(context: *anyopaque, level: abi.LogLevel, message: abi.Str) callconv(.c) void {
    const loaded = from(context);
    const text = message.slice();
    switch (level) {
        .err => log.err("{s}: {s}", .{ loaded.label(), text }),
        .warn => log.warn("{s}: {s}", .{ loaded.label(), text }),
        .info => log.info("{s}: {s}", .{ loaded.label(), text }),
        else => log.debug("{s}: {s}", .{ loaded.label(), text }),
    }
}

fn hostSubscribe(context: *anyopaque, kind: abi.EventKind, callback: ?abi.EventFn, user: ?*anyopaque) callconv(.c) abi.Status {
    const loaded = from(context);
    const owner = loaded.owner;
    if (owner.initializing.load(.acquire) != loaded) return .too_late;
    if (@backingInt(kind) >= abi.EventKind.count) return .invalid_argument;
    owner.pending.append(owner.gpa, .{ .kind = kind, .subscriber = .{ .callback = callback orelse return .invalid_argument, .user = user } }) catch return .failed;
    return .ok;
}

fn hostBackendCount(context: *anyopaque) callconv(.c) u32 {
    return @intCast(from(context).owner.backends.len);
}

fn hostBackendName(context: *anyopaque, backend: u32, name: ?*abi.Str) callconv(.c) abi.Status {
    const backends = from(context).owner.backends;
    if (backend >= backends.len) return .invalid_argument;
    (name orelse return .invalid_argument).* = .of(backends[backend].name());
    return .ok;
}

fn hostPlayerName(context: *anyopaque, player: abi.Player, out: ?[*]u8, capacity: usize, len: ?*usize) callconv(.c) abi.Status {
    const full_len = len orelse return .invalid_argument;
    const buffer: []u8 = if (capacity == 0) &.{} else (out orelse return .invalid_argument)[0..capacity];
    full_len.* = from(context).owner.handles.copyName(player, buffer) orelse return .stale_handle;
    return .ok;
}

fn hostTransfer(context: *anyopaque, player: abi.Player, backend: u32) callconv(.c) abi.Status {
    const owner = from(context).owner;
    if (backend >= owner.backends.len) return .invalid_argument;
    const route = owner.handles.route(player) orelse return .stale_handle;
    return route.transfer(route.context, route.link, backend);
}

const testing = std.testing;

const Probe = struct {
    var shutdowns: [4]u8 = undefined;
    var shutdown_count: usize = 0;
    var events: usize = 0;
    var seen_host: ?abi.Host = null;

    fn reset() void {
        shutdown_count = 0;
        events = 0;
        seen_host = null;
    }

    fn onEvent(_: ?*anyopaque, _: *const abi.Event, _: ?*abi.TransferDecision) callconv(.c) void {
        events += 1;
    }

    fn onShutdown(state: ?*anyopaque) callconv(.c) void {
        shutdowns[shutdown_count] = @intCast(@intFromPtr(state));
        shutdown_count += 1;
    }

    fn describe(plugin: *abi.Plugin, id: usize) void {
        plugin.name = .of("probe");
        plugin.plugin_version = .of("1.0.0");
        plugin.capabilities = .{ .events = true };
        plugin.state = @ptrFromInt(id);
        plugin.shutdown = onShutdown;
    }

    fn first(host: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
        describe(plugin, 1);
        seen_host = host.*;
        return host.subscribe(host.context, .player_connected, onEvent, null);
    }

    fn second(host: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
        describe(plugin, 2);
        return host.subscribe(host.context, .player_connected, onEvent, null);
    }

    fn failing(host: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
        describe(plugin, 3);
        _ = host.subscribe(host.context, .player_connected, onEvent, null);
        return .failed;
    }

    fn future(host: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
        describe(plugin, 4);
        plugin.abi_version = abi.version + 1;
        return host.subscribe(host.context, .player_connected, onEvent, null);
    }

    fn greedy(host: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
        describe(plugin, 5);
        plugin.capabilities.packets = true;
        return host.subscribe(host.context, .player_connected, onEvent, null);
    }
};

fn routedTransfer(context: *anyopaque, link: u64, backend: u32) abi.Status {
    const seen: *[2]u64 = @ptrCast(@alignCast(context));
    seen.* = .{ link, backend };
    return .ok;
}

test "plugins that fail or don't fit are turned away without leaving hooks behind" {
    Probe.reset();
    var plugins: Plugins = .init(testing.allocator, &.{});
    defer plugins.deinit();

    try testing.expectError(error.PluginInitFailed, plugins.add(Probe.failing, null));
    try testing.expectError(error.IncompatiblePlugin, plugins.add(Probe.future, null));
    try testing.expectError(error.UnsupportedCapability, plugins.add(Probe.greedy, null));
    try testing.expectEqualSlices(u8, &.{ 4, 5 }, Probe.shutdowns[0..Probe.shutdown_count]);
    try testing.expect(!plugins.subscribed(.player_connected));
    plugins.emit(&.{ .kind = .player_connected }, null);
    try testing.expectEqual(@as(usize, 0), Probe.events);
}

test "plugins get events, can't subscribe late and shut down newest first" {
    Probe.reset();
    var plugins: Plugins = .init(testing.allocator, &.{});
    try plugins.add(Probe.first, null);
    try plugins.add(Probe.second, null);
    plugins.emit(&.{ .kind = .player_connected }, null);
    plugins.emit(&.{ .kind = .proxy_started }, null);
    try testing.expectEqual(@as(usize, 2), Probe.events);

    const host = Probe.seen_host.?;
    try testing.expectEqual(abi.Status.too_late, host.subscribe(host.context, .proxy_started, Probe.onEvent, null));
    plugins.deinit();
    try testing.expectEqualSlices(u8, &.{ 2, 1 }, Probe.shutdowns[0..Probe.shutdown_count]);
}

test "host calls check handles and backends" {
    Probe.reset();
    const backends = [_]Backend{try .init("lobby", .{ .ip4 = .loopback(19133) })};
    var plugins: Plugins = .init(testing.allocator, &backends);
    defer plugins.deinit();
    try plugins.add(Probe.first, null);
    const host = Probe.seen_host.?;

    var seen: [2]u64 = .{ 0, 0 };
    const player = try plugins.handles.acquire(testing.allocator, .{ .context = &seen, .link = 7, .transfer = routedTransfer });
    plugins.handles.setName(player, "Steve");
    try testing.expectEqual(abi.Status.ok, host.transfer(host.context, player, 0));
    try testing.expectEqual([2]u64{ 7, 0 }, seen);
    try testing.expectEqual(abi.Status.invalid_argument, host.transfer(host.context, player, 1));

    var name: [16]u8 = undefined;
    var len: usize = 0;
    try testing.expectEqual(abi.Status.ok, host.player_name(host.context, player, &name, name.len, &len));
    try testing.expectEqualStrings("Steve", name[0..len]);
    var backend_name: abi.Str = .{};
    try testing.expectEqual(abi.Status.ok, host.backend_name(host.context, 0, &backend_name));
    try testing.expectEqualStrings("lobby", backend_name.slice());

    plugins.handles.release(player);
    try testing.expectEqual(abi.Status.stale_handle, host.transfer(host.context, player, 0));
    try testing.expectEqual(abi.Status.stale_handle, host.player_name(host.context, player, &name, name.len, &len));
}
