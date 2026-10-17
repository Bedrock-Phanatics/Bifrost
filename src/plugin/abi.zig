// Plugins run in-process, so a crash takes the proxy down. Callbacks run on several workers at once; never block.
// From your own threads use log, counts, names, player_info and queued actions. Query network_stats, gameplay and entities on the player's worker.
// Stop your threads before shutdown returns. Anything passed in is only valid until the callback returns.

const std = @import("std");

pub const version: u32 = 1;
pub const entrypoint = "bifrost_plugin_init";
pub const manifest_entrypoint = "bifrost_plugin_get_manifest";
pub const max_manifest_bytes = 4096;
pub const ManifestFn = *const fn (out: ?*Str) callconv(.c) Status;
pub const no_backend: u32 = std.math.maxInt(u32);
pub const no_worker: u32 = std.math.maxInt(u32);
pub const api_revision: u32 = 3;

pub const ConnectionState = enum(u32) { connected, closing, disconnected, _ };
pub const AuthenticationState = enum(u32) { pending, authenticated, disabled, unavailable, rejected, _ };
pub const SessionMode = enum(u32) { passthrough, managed, _ };
pub const ConnectionPhase = enum(u32) { unknown, settings, login, handshake, resource_packs, joining, in_game, closing, disconnected, _ };
pub const TransferState = enum(u32) { none, requested, dialing, logging_in, joining, preparing_client, syncing_client, closing_source, _ };

pub const PlayerState = extern struct {
    backend: u32 = no_backend,
    connection: ConnectionState = .connected,
    authentication: AuthenticationState = .pending,
    mode: SessionMode = .passthrough,
    phase: ConnectionPhase = .unknown,
    transfer: TransferState = .none,
};

pub const PlayerInfo = extern struct {
    struct_size: u32 = @sizeOf(PlayerInfo),
    worker: u32 = no_worker,
    state: PlayerState = .{},
    connection_duration_ms: u64 = 0,
    name_len: u32 = 0,
    xuid_len: u32 = 0,
    uuid_len: u32 = 0,
    online: u32 = 0,
    name: [64]u8 = @splat(0),
    xuid: [32]u8 = @splat(0),
    uuid: [36]u8 = @splat(0),
};

pub const NetworkMetric = struct {
    pub const rtt: u64 = 1 << 0;
    pub const reliability: u64 = 1 << 1;
    pub const queues: u64 = 1 << 2;
    pub const loss_estimate: u64 = 1 << 3;
    pub const rates: u64 = 1 << 4;
    pub const jitter: u64 = 1 << 5;
    pub const duplicates: u64 = 1 << 6;
    pub const out_of_order: u64 = 1 << 7;
    pub const anomalies: u64 = 1 << 8;
};

pub const NetworkStats = extern struct {
    struct_size: u32 = @sizeOf(NetworkStats),
    mtu: u32 = 0,
    available: u64 = 0,
    sampled_at_ms: u64 = 0,
    rtt_ms: u64 = 0,
    jitter_ms: u64 = 0,
    loss_estimate_ppm: u32 = 0,
    retransmission_timeout_ms: u32 = 0,
    acknowledged_datagrams: u64 = 0,
    lost_datagrams: u64 = 0,
    retransmitted_datagrams: u64 = 0,
    ack_records_received: u64 = 0,
    nack_records_received: u64 = 0,
    ack_records_sent: u64 = 0,
    nack_records_sent: u64 = 0,
    queued_packets: u64 = 0,
    queued_bytes: u64 = 0,
    queued_packets_high_water: u64 = 0,
    recovery_packets: u64 = 0,
    recovery_bytes: u64 = 0,
    ordered_packets: u64 = 0,
    ordered_bytes: u64 = 0,
    in_flight_bytes: u64 = 0,
    congestion_window_bytes: u64 = 0,
    incoming_packets_per_second: u64 = 0,
    outgoing_packets_per_second: u64 = 0,
    incoming_bytes_per_second: u64 = 0,
    outgoing_bytes_per_second: u64 = 0,
    duplicate_packets: u64 = 0,
    out_of_order_packets: u64 = 0,
    reliability_anomalies: u64 = 0,
    rate_interval_ms: u64 = 0,
};

pub const Vec3 = extern struct { x: f32 = 0, y: f32 = 0, z: f32 = 0 };

pub const GameplayField = struct {
    pub const position: u64 = 1 << 0;
    pub const velocity: u64 = 1 << 1;
    pub const dimension: u64 = 1 << 2;
    pub const game_mode: u64 = 1 << 3;
    pub const movement: u64 = 1 << 4;
    pub const attributes: u64 = 1 << 5;
    pub const effects: u64 = 1 << 6;
};

pub const PositionSource = enum(u32) { none, backend, client, _ };

pub const Movement = struct {
    pub const sneaking: u32 = 1 << 0;
    pub const sprinting: u32 = 1 << 1;
    pub const jumping: u32 = 1 << 2;
    pub const swimming: u32 = 1 << 3;
    pub const gliding: u32 = 1 << 4;
    pub const crawling: u32 = 1 << 5;
    pub const flying: u32 = 1 << 6;
    pub const in_vehicle: u32 = 1 << 7;
};

pub const AttributeKind = enum(u32) {
    health,
    absorption,
    hunger,
    saturation,
    exhaustion,
    movement,
    level,
    experience,
    _,

    pub const count = 8;
};

pub const Attribute = extern struct { min: f32 = 0, max: f32 = 0, current: f32 = 0 };

// What the proxy saw on the wire, never what the backend decided
pub const Gameplay = extern struct {
    struct_size: u32 = @sizeOf(Gameplay),
    position_source: PositionSource = .none,
    available: u64 = 0,
    sampled_at_ms: u64 = 0,
    position_at_ms: u64 = 0,
    runtime_id: u64 = 0,
    unique_id: i64 = 0,
    position: Vec3 = .{},
    velocity: Vec3 = .{},
    pitch: f32 = 0,
    yaw: f32 = 0,
    head_yaw: f32 = 0,
    dimension: i32 = 0,
    game_mode: i32 = 0,
    movement: u32 = 0,
    teleport_pending: u32 = 0,
    attributes_available: u32 = 0,
    attributes: [AttributeKind.count]Attribute = @splat(.{}),
    effects: [4]u64 = @splat(0),
};

pub const Entity = extern struct {
    runtime_id: u64 = 0,
    unique_id: i64 = 0,
    position: Vec3 = .{},
    pitch: f32 = 0,
    yaw: f32 = 0,
    head_yaw: f32 = 0,
    identifier_len: u32 = 0,
    identifier: [64]u8 = @splat(0),
};

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
    not_found = -10,
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
    gameplay: bool = false,
    entities: bool = false,
    _: u58 = 0,

    pub const supported: Capabilities = .{ .events = true, .commands = true, .packets = true, .tasks = true, .gameplay = true, .entities = true };
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
    connection_phase_changed,
    _,

    pub const count = 10;
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
    worker: u32 = no_worker,
    phase: ConnectionPhase = .unknown,
    previous_phase: ConnectionPhase = .unknown,
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
    fields: bool = false,
    _: u30 = 0,

    pub const supported: PacketFlags = .{ .validated = true, .fields = true };
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

pub const PacketType = enum(u32) { text = 1, chunk_radius = 2, _ };
pub const TextType = enum(u32) {
    raw,
    chat,
    translate,
    popup,
    jukebox_popup,
    tip,
    system_message,
    whisper,
    announcement,
    text_object_whisper,
    text_object,
    text_object_announcement,
    _,
};

pub const Text = extern struct {
    message_type: TextType = .raw,
    localize: u32 = 0,
    has_filtered_message: u32 = 0,
    parameter_count: u32 = 0,
    source: Str = .{},
    message: Str = .{},
    xuid: Str = .{},
    platform_id: Str = .{},
    filtered_message: Str = .{},
    parameters: [4]Str = @splat(.{}),
};

pub const ChunkRadius = extern struct {
    radius: i32,
    max_radius: u32,
};

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

pub const PacketTarget = enum(u32) { player, backend, _ };

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
    // Check has(.set_description) first
    set_description: *const fn (context: *anyopaque, description: Str) callconv(.c) Status,
    decode_packet: *const fn (context: *anyopaque, packet: ?*const Packet, packet_type: PacketType, out: ?*anyopaque, capacity: usize) callconv(.c) Status,
    encode_packet: *const fn (context: *anyopaque, packet: ?*Packet, packet_type: PacketType, data: ?*const anyopaque, size: usize) callconv(.c) Status,
    send_packet: *const fn (context: *anyopaque, player: Player, target: PacketTarget, bytes: Str, done: ?TaskDoneFn, user: ?*anyopaque) callconv(.c) Status,
    player_info: *const fn (context: *anyopaque, player: Player, out: ?*PlayerInfo, capacity: usize) callconv(.c) Status,
    network_stats: *const fn (context: *anyopaque, player: Player, target: PacketTarget, out: ?*NetworkStats, capacity: usize) callconv(.c) Status,
    disconnect: *const fn (context: *anyopaque, player: Player, reason: Str, done: ?TaskDoneFn, user: ?*anyopaque) callconv(.c) Status,
    request_transfer: *const fn (context: *anyopaque, player: Player, backend: u32, done: ?TaskDoneFn, user: ?*anyopaque) callconv(.c) Status,
    player_gameplay: *const fn (context: *anyopaque, player: Player, out: ?*Gameplay, capacity: usize) callconv(.c) Status,
    find_entity: *const fn (context: *anyopaque, player: Player, runtime_id: u64, out: ?*Entity, capacity: usize) callconv(.c) Status,
    list_entities: *const fn (context: *anyopaque, player: Player, out: ?[*]Entity, count: usize, total: ?*usize, complete: ?*u32) callconv(.c) Status,

    pub fn has(self: *const Host, comptime field: std.meta.FieldEnum(Host)) bool {
        const name = @tagName(field);
        return self.struct_size >= @offsetOf(Host, name) + @sizeOf(@FieldType(Host, name));
    }
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

// Older hosts allocate these, so a new field would overflow them
test "structs plugins write into are frozen" {
    const frozen = .{
        .{ Plugin, &[_][]const u8{ "struct_size", "abi_version", "name", "plugin_version", "capabilities", "state", "shutdown" } },
        .{ TransferDecision, &[_][]const u8{ "struct_size", "action", "backend" } },
        .{ Packet, &[_][]const u8{ "struct_size", "direction", "id", "worker", "player", "bytes", "replacement", "replacement_capacity", "replacement_len" } },
        .{ Text, &[_][]const u8{ "message_type", "localize", "has_filtered_message", "parameter_count", "source", "message", "xuid", "platform_id", "filtered_message", "parameters" } },
        .{ ChunkRadius, &[_][]const u8{ "radius", "max_radius" } },
        .{ Entity, &[_][]const u8{ "runtime_id", "unique_id", "position", "pitch", "yaw", "head_yaw", "identifier_len", "identifier" } },
    };
    inline for (frozen) |pair| {
        const names = comptime std.meta.fieldNames(pair[0]);
        try std.testing.expectEqual(pair[1].len, names.len);
        for (names, pair[1]) |actual, expected| try std.testing.expectEqualStrings(expected, actual);
    }
}
