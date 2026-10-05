// Callbacks run on worker threads, possibly at the same time, and must not block

const std = @import("std");

pub const version: u32 = 1;
pub const entrypoint = "bifrost_plugin_init";
pub const no_backend: u32 = std.math.maxInt(u32);

pub const Status = enum(i32) {
    ok = 0,
    failed = -1,
    incompatible = -2,
    stale_handle = -3,
    invalid_argument = -4,
    unsupported = -5,
    too_late = -6,
    busy = -7,
    _,
};

// Borrowed, only valid during the call
pub const Str = extern struct {
    ptr: ?[*]const u8 = null,
    len: usize = 0,

    pub fn of(bytes: []const u8) Str {
        return .{ .ptr = bytes.ptr, .len = bytes.len };
    }

    pub fn slice(self: Str) []const u8 {
        return if (self.ptr) |ptr| ptr[0..self.len] else &.{};
    }
};

pub const Player = extern struct {
    id: u64 = 0,
};

pub const Capabilities = packed struct(u64) {
    events: bool = false,
    commands: bool = false,
    packets: bool = false,
    tasks: bool = false,
    _: u60 = 0,

    pub const supported: Capabilities = .{ .events = true };
};

pub const LogLevel = enum(u32) { err, warn, info, debug, _ };

pub const EventKind = enum(u32) {
    proxy_started,
    proxy_stopping,
    player_connected,
    player_authenticated,
    player_disconnected,
    backend_selected,
    transfer_requested,
    transfer_failed,
    transfer_completed,
    _,

    pub const count = 9;
};

pub const TransferFailure = enum(u32) {
    none,
    rejected,
    failed_before_commit,
    failed_after_commit,
    timed_out,
    incompatible_content,
    _,
};

pub const Event = extern struct {
    struct_size: u32 = @sizeOf(Event),
    kind: EventKind,
    player: Player = .{},
    backend: u32 = no_backend,
    from_backend: u32 = no_backend,
    failure: TransferFailure = .none,
    name: Str = .{},
    xuid: Str = .{},
    address: Str = .{},
};

pub const TransferAction = enum(u32) { proceed, cancel, redirect, _ };

pub const TransferDecision = extern struct {
    struct_size: u32 = @sizeOf(TransferDecision),
    action: TransferAction = .proceed,
    backend: u32 = no_backend,
};

pub const EventFn = *const fn (user: ?*anyopaque, event: *const Event, decision: ?*TransferDecision) callconv(.c) void;

pub const Host = extern struct {
    struct_size: u32 = @sizeOf(Host),
    abi_version: u32 = version,
    context: *anyopaque,
    log: *const fn (context: *anyopaque, level: LogLevel, message: Str) callconv(.c) void,
    // Only works inside bifrost_plugin_init
    subscribe: *const fn (context: *anyopaque, kind: EventKind, callback: ?EventFn, user: ?*anyopaque) callconv(.c) Status,
    backend_count: *const fn (context: *anyopaque) callconv(.c) u32,
    backend_name: *const fn (context: *anyopaque, backend: u32, name: ?*Str) callconv(.c) Status,
    player_name: *const fn (context: *anyopaque, player: Player, out: ?[*]u8, capacity: usize, len: ?*usize) callconv(.c) Status,
    transfer: *const fn (context: *anyopaque, player: Player, backend: u32) callconv(.c) Status,
};

pub const Plugin = extern struct {
    struct_size: u32 = @sizeOf(Plugin),
    abi_version: u32 = version,
    name: Str = .{},
    plugin_version: Str = .{},
    capabilities: Capabilities = .{},
    state: ?*anyopaque = null,
    shutdown: ?*const fn (state: ?*anyopaque) callconv(.c) void = null,
};

pub const InitFn = *const fn (host: *const Host, plugin: *Plugin) callconv(.c) Status;
