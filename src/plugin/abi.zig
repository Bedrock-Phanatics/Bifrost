// Plugins run in-process, so a crash takes the proxy down. Callbacks run on several workers at once; never block.
// From your own threads only log, counts, names, send_message and post work, the rest return wrong_thread.
// Stop your threads before shutdown returns. Anything passed in is only valid until the callback returns.

const std = @import("std");

pub const version: u32 = 1;
pub const entrypoint = "bifrost_plugin_init";
pub const no_backend: u32 = std.math.maxInt(u32);
pub const no_worker: u32 = std.math.maxInt(u32);

pub const Status = enum(i32) {
    ok = 0,
    failed = -1,
    incompatible = -2,
    stale_handle = -3,
    invalid_argument = -4,
    unsupported = -5,
    too_late = -6,
    busy = -7,
    wrong_thread = -8,
    canceled = -9,
    _,
};

// Only valid until the call returns
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

    pub const supported: Capabilities = .{ .events = true, .commands = true, .packets = true, .tasks = true };
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

pub const Direction = enum(u32) { from_player, from_backend, _ };

pub const PacketPhase = enum(u32) { any, before_game, in_game, _ };

pub const PacketFlags = packed struct(u32) {
    validated: bool = false,
    _: u31 = 0,
};

pub const PacketAction = enum(u32) { pass, cancel, replace, _ };

// Whole packets, header included, for both bytes and the replacement
pub const Packet = extern struct {
    struct_size: u32 = @sizeOf(Packet),
    direction: Direction,
    id: u32,
    worker: u32,
    player: Player,
    bytes: Str,
    replacement: ?[*]u8 = null,
    replacement_capacity: usize = 0,
    replacement_len: usize = 0,
};

pub const PacketFn = *const fn (user: ?*anyopaque, packet: *Packet) callconv(.c) PacketAction;

pub const Command = extern struct {
    struct_size: u32 = @sizeOf(Command),
    worker: u32,
    player: Player,
    name: Str,
    args: Str,
};

pub const CommandFn = *const fn (user: ?*anyopaque, command: *const Command) callconv(.c) void;

// Permission only affects autocomplete. Replaces any backend command with the same name
pub const CommandPermission = enum(u32) { any, game_directors, admin, host, owner, _ };

pub const CommandInfo = extern struct {
    struct_size: u32 = @sizeOf(CommandInfo),
    permission: CommandPermission = .any,
    name: Str,
    description: Str = .{},
    callback: ?CommandFn,
    user: ?*anyopaque = null,
};

pub const TaskFn = *const fn (user: ?*anyopaque) callconv(.c) void;

pub const TaskResult = extern struct {
    struct_size: u32 = @sizeOf(TaskResult),
    status: Status,
    worker: u32 = no_worker,
    player: Player = .{},
};

pub const TaskDoneFn = *const fn (user: ?*anyopaque, result: *const TaskResult) callconv(.c) void;

pub const EventFn = *const fn (user: ?*anyopaque, event: *const Event, decision: ?*TransferDecision) callconv(.c) void;

pub const Host = extern struct {
    struct_size: u32 = @sizeOf(Host),
    abi_version: u32 = version,
    context: *anyopaque,
    log: *const fn (context: *anyopaque, level: LogLevel, message: Str) callconv(.c) void,
    subscribe: *const fn (context: *anyopaque, kind: EventKind, callback: ?EventFn, user: ?*anyopaque) callconv(.c) Status,
    backend_count: *const fn (context: *anyopaque) callconv(.c) u32,
    backend_name: *const fn (context: *anyopaque, backend: u32, name: ?*Str) callconv(.c) Status,
    player_name: *const fn (context: *anyopaque, player: Player, out: ?[*]u8, capacity: usize, len: ?*usize) callconv(.c) Status,
    transfer: *const fn (context: *anyopaque, player: Player, backend: u32) callconv(.c) Status,
    worker_count: *const fn (context: *anyopaque) callconv(.c) u32,
    subscribe_packet: *const fn (context: *anyopaque, direction: Direction, id: u32, phase: PacketPhase, flags: PacketFlags, callback: ?PacketFn, user: ?*anyopaque) callconv(.c) Status,
    register_command: *const fn (context: *anyopaque, name: Str, callback: ?CommandFn, user: ?*anyopaque) callconv(.c) Status,
    // `run` shares a few threads with every plugin. `done` runs once on the player's worker,
    // with stale_handle if they left or canceled if `run` never started
    spawn_task: *const fn (context: *anyopaque, player: Player, run: ?TaskFn, done: ?TaskDoneFn, user: ?*anyopaque) callconv(.c) Status,
    send_message: *const fn (context: *anyopaque, player: Player, text: Str) callconv(.c) Status,
    // Runs `done` on the player's worker, same rules as spawn_task
    post: *const fn (context: *anyopaque, player: Player, done: ?TaskDoneFn, user: ?*anyopaque) callconv(.c) Status,
    register_command_info: *const fn (context: *anyopaque, info: ?*const CommandInfo) callconv(.c) Status,
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
