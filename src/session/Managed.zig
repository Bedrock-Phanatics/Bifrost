const std = @import("std");
const raknet = @import("raknet");
const bedwire = @import("bedwire");
const PacketQueue = @import("../proxy/PacketQueue.zig");
const Stats = @import("../proxy/Stats.zig");
const packs = @import("../content/packs.zig");
pub const registries = @import("../content/registries.zig");
pub const Upstream = @import("Upstream.zig");
const ClientState = @import("ClientState.zig");
pub const Outbox = @import("Outbox.zig");
pub const self_id = @import("self_id.zig");
const commands = @import("commands.zig");
const Queue = @import("../transfer/Queue.zig");
const Handoff = @import("../transfer/Handoff.zig");
const Plugins = @import("../plugin/Plugins.zig");
const Packets = Plugins.Packets;
const abi = @import("../plugin/abi.zig");

const protocol = bedwire.protocol;
const Current = protocol.Current;
pub const Ecdsa = bedwire.crypto.spki.Ecdsa;

const Managed = @This();
const log = std.log.scoped(.managed);

// Same protocol, but logs in with the proxy's certificate chain
pub const BackendProfile = struct {
    pub const protocol_number = Current.protocol_number;
    pub const features: protocol.SessionFeatures = .{ .login_flow = .certificate_chain };
    pub const packetKind = Current.packetKind;
    pub const packetId = Current.packetId;
    pub const packetDirection = Current.packetDirection;
    pub const decodeBorrowed = Current.decodeBorrowed;
    pub const encode = Current.encode;
};

comptime {
    protocol.validateProfile(BackendProfile);
}

pub const PlayerSession = bedwire.Session;
pub const BackendSession = bedwire.SessionWithProfile(BackendProfile);

pub const limits: bedwire.Limits = .{
    .max_frame_bytes = 2 * 1024 * 1024,
    .max_batch_bytes = 4 * 1024 * 1024,
    .max_packet_bytes = 2 * 1024 * 1024,
};

const player_compression: bedwire.compression.Algorithm = .deflate;
const player_compression_threshold = 256;
// Used once, right away
pub const login_lifetime_s = 60;

// One per worker, used by one call at a time
pub const Shared = struct {
    pool: bedwire.BufferPool,
    key: Ecdsa.KeyPair,
    keys: *const bedwire.auth.KeySet,
    batch: [][]const u8,
    scratch: []u8 = &.{},
    translated: std.heap.ArenaAllocator,
    hooks: ?Hooks = null,
    transfers: bool = true,

    pub fn init(gpa: std.mem.Allocator, key: Ecdsa.KeyPair, keys: *const bedwire.auth.KeySet) !Shared {
        var pool: bedwire.BufferPool = try .init(gpa, limits, .{ .rx_slots = 1, .tx_slots = 1 });
        errdefer pool.deinit();
        return .{ .pool = pool, .key = key, .keys = keys, .batch = try gpa.alloc([]const u8, limits.max_packets_per_batch), .translated = .init(gpa) };
    }

    pub fn deinit(self: *Shared, gpa: std.mem.Allocator) void {
        self.translated.deinit();
        gpa.free(self.scratch);
        gpa.free(self.batch);
        self.pool.deinit();
    }
};

pub const Hooks = struct {
    plugins: *const Plugins,
    worker: u32,
};

pub const Ends = struct {
    io: std.Io,
    stats: *Stats,
    player: *raknet.Session,
    backend: ?*raknet.Client,
};

pub const PlayerPhase = enum { settings, login, handshake, ready };

gpa: std.mem.Allocator,
shared: *Shared,
player: PlayerSession,
upstream: Upstream,
player_phase: PlayerPhase = .settings,
identity: ?bedwire.Identity = null,
client_data: ?[]u8 = null,
initial_packs: packs.Fingerprint = .{},
initial_registries: registries.Fingerprint = .{},
transferred: bool = false,
client_state: ClientState = .{},
client_dimension: i32 = Handoff.overworld,
// New backend packets wait here until the client is in their dimension
hold: ?*Queue = null,
syncing: bool = false,
dimension_acks: u32 = 0,
target_spawned: bool = false,
client_ids: self_id.Ids = .{},
backend_ids: self_id.Ids = .{},
chunk_radius: ?struct { radius: i32, max: u8 } = null,
cache_supported: ?bool = null,
plugin_player: abi.Player = .{},
commands_sent: bool = false,
// Player packets sent before the backend is ready
early: PacketQueue,

pub fn create(gpa: std.mem.Allocator, shared: *Shared, early_packets: u32, early_bytes: u32) !*Managed {
    const self = try gpa.create(Managed);
    errdefer gpa.destroy(self);
    var player: PlayerSession = try .init(.server, .{ .pool = &shared.pool });
    errdefer player.deinit();
    self.* = .{
        .gpa = gpa,
        .shared = shared,
        .player = player,
        .upstream = try .init(shared),
        .early = .init(early_packets, early_bytes),
    };
    return self;
}

pub fn destroy(self: *Managed) void {
    self.player.deinit();
    self.upstream.deinit();
    if (self.identity) |*identity| identity.deinit();
    if (self.client_data) |json| self.gpa.free(json);
    self.client_state.deinit(self.gpa);
    self.early.deinit(self.gpa);
    self.gpa.destroy(self);
}

pub fn inGame(self: *const Managed) bool {
    return self.upstream.phase == .ready and self.player.state == .in_game;
}

pub fn upstreamContext(self: *Managed, ends: Ends, client: *raknet.Client) Upstream.Context {
    return .{ .gpa = self.gpa, .io = ends.io, .stats = ends.stats, .shared = self.shared, .client = client };
}

pub fn loginUpstream(self: *Managed, upstream: *Upstream, ctx: Upstream.Context) !void {
    try upstream.login(ctx, &self.identity.?, self.client_data.?);
}

pub fn swapUpstream(self: *Managed, next: Upstream) Upstream {
    const previous = self.upstream;
    self.upstream = next;
    self.transferred = true;
    return previous;
}

pub fn deliver(self: *Managed, ends: Ends, packets: []const []const u8) !usize {
    var batch = self.newBatch(ends, true);
    errdefer batch.discard();
    var skipped: usize = 0;
    for (packets) |packet| {
        const header = protocol.packet.decode(packet, .{ .max_packet_bytes = @max(packet.len, 1) }) catch {
            skipped += 1;
            continue;
        };
        const kind = Current.packetKind(header.header.packet_id);
        if (!self.player.state.permits(Current.features, .server, kind)) {
            skipped += 1;
            continue;
        }
        _ = try batch.add(kind, packet);
    }
    try batch.flush();
    return skipped;
}

pub fn spawnTarget(self: *Managed, ends: Ends) !void {
    var buffer: [16]u8 = undefined;
    try self.upstream.send(self.upstreamContext(ends, ends.backend orelse return error.BackendClosed), &.{try encodeTyped(&buffer, .{ .set_local_player_as_initialised = .{ .player_id = self.backend_ids.runtime } })});
    if (self.upstream.session.state == .spawn_ready) try self.upstream.session.advance(.in_game);
}

fn idSwap(self: *const Managed) ?self_id.Swap {
    const ids: self_id.Swap = .{ .client = self.client_ids, .backend = self.backend_ids };
    return if (self.transferred and ids.active()) ids else null;
}

fn newBatch(self: *Managed, ends: Ends, to_player: bool) Batch {
    var batch: Batch = .{ .managed = self, .ends = ends, .to_player = to_player };
    const hooks = self.shared.hooks orelse return batch;
    if (hooks.plugins.packetTable(if (to_player) .from_backend else .from_player)) |table| {
        if (self.player.state != .in_game or table.in_game) batch.table = table;
    }
    return batch;
}

const Batch = struct {
    managed: *Managed,
    ends: Ends,
    to_player: bool,
    table: ?*const Packets.Table = null,
    count: usize = 0,

    // Returns what was queued, or null if a plugin cancelled the packet
    fn add(self: *Batch, kind: ?bedwire.PacketKind, bytes: []const u8) !?[]const u8 {
        const shared = self.managed.shared;
        var packet = bytes;
        if (self.count == shared.batch.len) try self.flush();
        // Plugins and ClientState see the client's ids in both directions
        const ids = self.managed.idSwap();
        if (self.to_player) if (ids) |swap| {
            packet = try swap.apply(shared.translated.allocator(), kind, packet, protocolLimits()) orelse packet;
        };
        if (self.table) |table| if (Packets.packetId(packet)) |id| {
            const in_game = self.managed.player.state == .in_game;
            if (table.wants(id, in_game)) {
                if (shared.scratch.len == 0) shared.scratch = try self.managed.gpa.alloc(u8, Packets.scratch_bytes);
                const hooks = shared.hooks.?;
                const call: Packets.Call = .{
                    .io = self.ends.io,
                    .worker = hooks.worker,
                    .player = self.managed.plugin_player,
                    .direction = if (self.to_player) .from_backend else .from_player,
                    .in_game = in_game,
                    .slow_ns = hooks.plugins.options.slow_callback_ns,
                };
                switch (Packets.run(table, call, id, packet, shared.scratch, Checker{ .managed = self.managed, .to_player = self.to_player })) {
                    .pass => {},
                    .cancel => return null,
                    .replace => |replacement| packet = try shared.translated.allocator().dupe(u8, replacement),
                }
            }
        };
        if (self.to_player) {
            try self.managed.sentToPlayer(kind, packet);
        } else if (ids) |swap| {
            packet = try swap.apply(shared.translated.allocator(), kind, packet, protocolLimits()) orelse packet;
        }
        shared.batch[self.count] = packet;
        self.count += 1;
        return packet;
    }

    fn flush(self: *Batch) !void {
        defer if (!self.managed.shared.translated.reset(.{ .retain_with_limit = 256 * 1024 })) self.discard();
        if (self.count == 0) return;
        const packets = self.managed.shared.batch[0..self.count];
        self.count = 0;
        if (self.to_player) return self.managed.sendToPlayer(self.ends, packets);
        try self.managed.upstream.send(self.managed.upstreamContext(self.ends, self.ends.backend orelse return error.BackendClosed), packets);
    }

    fn discard(self: *Batch) void {
        _ = self.managed.shared.translated.reset(.free_all);
    }
};

const Checker = struct {
    managed: *Managed,
    to_player: bool,

    pub fn permits(self: Checker, packet_type: abi.PacketType) bool {
        const kind = Packets.Decoded.kind(packet_type) orelse return false;
        return self.managed.player.state.permits(Current.features, if (self.to_player) .server else .client, kind);
    }

    pub fn decode(self: Checker, bytes: []const u8, packet_type: abi.PacketType) Packets.Decoded.Error!Packets.Decoded.Value {
        if (!self.permits(packet_type)) return error.InvalidArgument;
        return Packets.Decoded.decode(bytes, packet_type, protocolLimits());
    }

    pub fn valid(self: Checker, bytes: []const u8) bool {
        const header = protocol.packet.decode(bytes, .{ .max_packet_bytes = limits.max_packet_bytes }) catch return false;
        const kind = Current.packetKind(header.header.packet_id);
        if (!self.managed.player.state.permits(Current.features, if (self.to_player) .server else .client, kind)) return false;
        if (kind == null) return true;
        _ = Current.decodeBorrowed(bytes, protocolLimits()) catch return false;
        return true;
    }
};

pub fn sendText(self: *Managed, ends: Ends, text: []const u8) !void {
    var buffer: [Plugins.max_message_bytes + 64]u8 = undefined;
    try self.sendToPlayer(ends, &.{try encodeTyped(&buffer, .{ .text = .{
        .localize = false,
        .body = .{ .message_only = .{ .message_type = .raw, .message = text } },
        .senders_xuid = "",
        .platform_id = "",
        .filtered_message = null,
    } })});
}

pub fn sendDisconnect(self: *Managed, ends: Ends, reason: []const u8) !void {
    var buffer: [Plugins.max_message_bytes + 32]u8 = undefined;
    try self.sendToPlayer(ends, &.{try encodeTyped(&buffer, .{ .disconnect = .{
        .reason = .disconnected,
        .messages = .{ .messages = .{ .message = reason, .filtered_message = "" } },
    } })});
}

pub fn inject(self: *Managed, ends: Ends, target: abi.PacketTarget, packet: []const u8) !void {
    if (!self.inGame() or self.hold != null or self.syncing) return error.NotInGame;
    // Only Text and RequestChunkRadius reach here; neither contains entity IDs.
    switch (target) {
        .player => try self.sendToPlayer(ends, &.{packet}),
        .backend => {
            try self.upstream.send(self.upstreamContext(ends, ends.backend orelse return error.BackendClosed), &.{packet});
            const kind = Current.packetKind((try protocol.packet.decode(packet, protocolLimits())).header.packet_id);
            _ = try self.sentToBackend(kind, packet);
        },
        else => return error.InvalidTarget,
    }
}

pub fn sendOutbox(self: *Managed, ends: Ends, outbox: *const Outbox) !void {
    var start: usize = 0;
    while (start < outbox.count()) {
        const packets = outbox.slices(start, self.shared.batch);
        try self.sendToPlayer(ends, packets);
        start += packets.len;
    }
}

// Proxy state follows what was delivered, after plugins had their say
fn sentToPlayer(self: *Managed, kind: ?bedwire.PacketKind, packet: []const u8) !void {
    if (kind == .change_dimension) self.client_dimension = (try typed(try decode(packet), .change_dimension)).dimension_id;
    if (!ClientState.tracks(kind)) return;
    const decoded = decode(packet) catch {
        self.client_state.untracked = true;
        return;
    };
    self.client_state.observe(self.gpa, decoded) catch {
        self.client_state.untracked = true;
    };
}

fn sentToBackend(self: *Managed, kind: ?bedwire.PacketKind, packet: []const u8) !?bedwire.State {
    switch (kind orelse return null) {
        .request_chunk_radius => {
            const request = try typed(try decode(packet), .request_chunk_radius);
            self.chunk_radius = .{ .radius = request.chunk_radius, .max = request.max_chunk_radius };
        },
        .client_cache_status => self.cache_supported = (try typed(try decode(packet), .client_cache_status)).is_cache_supported,
        .container_close => self.client_state.containerClosed(),
        .resource_pack_client_response => {
            const response = try typed(try decode(packet), .resource_pack_client_response);
            return if (response.response == .resource_pack_stack_finished) .waiting_for_start_game else null;
        },
        .set_local_player_as_initialised => return if (self.player.state == .spawn_ready) .in_game else null,
        else => {},
    }
    return null;
}

fn decode(packet: []const u8) !protocol.BorrowedEnvelope {
    return Current.decodeBorrowed(packet, protocolLimits());
}

fn protocolLimits() protocol.DecodeLimits {
    return .{ .max_packet_bytes = limits.max_packet_bytes, .max_string_bytes = limits.max_packet_bytes, .max_byte_array_bytes = limits.max_packet_bytes, .max_nbt_bytes = limits.max_packet_bytes };
}

pub fn backendConnected(self: *Managed, ends: Ends) !void {
    try self.upstream.connected(self.upstreamContext(ends, ends.backend.?));
}

// ClientState, the chunk radius and plugin commands have to see every batch
fn relayable(self: *const Managed, direction: abi.Direction) bool {
    if (self.shared.transfers or !self.inGame()) return false;
    const hooks = self.shared.hooks orelse return true;
    if (hooks.plugins.packetTable(direction)) |table| if (table.in_game) return false;
    return !hooks.plugins.hasCommands();
}

fn pluginCommands(self: *const Managed) ?*const Plugins {
    const hooks = self.shared.hooks orelse return null;
    return if (hooks.plugins.hasCommands()) hooks.plugins else null;
}

fn advertise(self: *Managed, arena: std.mem.Allocator, plugins: *const Plugins, backend: ?[]const u8) ?[]const u8 {
    self.commands_sent = true;
    return commands.merge(arena, plugins, backend, limits.max_packet_bytes, protocolLimits()) catch |err| {
        log.info("plugin commands not advertised: {t}", .{err});
        return null;
    };
}

fn relay(source: anytype, dest: anytype, sink: anytype, stats: *Stats, comptime counter: std.meta.FieldEnum(Stats), payload: []const u8) !bool {
    const frame = source.relayTo(dest, payload) catch |err| switch (err) {
        error.IncompatibleRelay => {
            stats.bump(.managed_relay_incompatible, 1);
            return false;
        },
        else => return err,
    };
    defer frame.release();
    sink.send(frame.bytes, .reliable_ordered, 0) catch |err| {
        dest.close();
        return err;
    };
    stats.bump(counter, frame.bytes.len);
    stats.bump(.managed_relayed_batches, 1);
    stats.bump(.managed_relayed_bytes, payload.len);
    return true;
}

pub fn fromPlayer(self: *Managed, ends: Ends, payload: []const u8) !void {
    if (self.relayable(.from_player)) if (ends.backend) |client| {
        if (try relay(&self.player, &self.upstream.session, client, ends.stats, .bytes_to_backend, payload)) return;
    };
    ends.stats.bump(.managed_decoded_batches, 1);
    ends.stats.bump(.managed_decoded_bytes, payload.len);
    var packets = try self.player.ingest(payload);
    defer packets.deinit();
    if (self.player_phase == .ready) return self.relayFromPlayer(ends, &packets);

    // Bedwire allows one packet per batch until encryption is up
    const packet = packets.next() orelse return error.MalformedBatch;
    switch (self.player_phase) {
        .settings => try self.answerSettings(ends, packet),
        .login => try self.authenticate(ends, packet),
        .handshake => {
            try self.player.advance(.resource_packs);
            self.player_phase = .ready;
            if (self.upstream.phase == .waiting_for_login) try self.loginUpstream(&self.upstream, self.upstreamContext(ends, ends.backend.?));
        },
        .ready => unreachable,
    }
}

pub fn fromBackend(self: *Managed, ends: Ends, payload: []const u8) !void {
    if (self.relayable(.from_backend)) {
        if (try relay(&self.upstream.session, &self.player, ends.player, ends.stats, .bytes_to_player, payload)) return;
    }
    ends.stats.bump(.managed_decoded_batches, 1);
    ends.stats.bump(.managed_decoded_bytes, payload.len);
    var packets = try self.upstream.session.ingest(payload);
    defer packets.deinit();
    if (self.upstream.phase == .ready) return self.relayFromBackend(ends, &packets);

    const packet = packets.next() orelse return error.MalformedBatch;
    const ctx = self.upstreamContext(ends, ends.backend orelse return error.BackendClosed);
    const progress = self.upstream.receive(ctx, packet) catch |err| {
        if (err == error.BackendRefused and self.player_phase == .ready) self.sendToPlayer(ends, &.{packet.bytes}) catch {};
        return err;
    };
    switch (progress) {
        .wants_login => if (self.player_phase == .ready) try self.loginUpstream(&self.upstream, ctx),
        .logged_in => {
            defer self.early.clear(self.gpa);
            var batch = self.newBatch(ends, false);
            errdefer batch.discard();
            var next_state: ?bedwire.State = null;
            for (self.early.items()) |bytes| {
                const kind = Current.packetKind(Packets.packetId(bytes) orelse return error.MalformedBatch);
                const sent = try batch.add(kind, bytes) orelse continue;
                if (try self.sentToBackend(kind, sent)) |state| next_state = state;
            }
            try batch.flush();
            if (next_state) |state| try self.advance(state);
        },
    }
}

fn answerSettings(self: *Managed, ends: Ends, packet: PlayerSession.Packet) !void {
    const request = try typed(try self.player.decodePacket(packet), .request_network_settings);
    if (request.client_network_version != Current.protocol_number) return error.UnsupportedVersion;
    var buffer: [32]u8 = undefined;
    try self.sendToPlayer(ends, &.{try encodeTyped(&buffer, .{ .network_settings = .{
        .compression_threshold = player_compression_threshold,
        .compression_algorithm = .zlib,
        .client_throttle_enabled = false,
        .client_throttle_threshold = 0,
        .client_throttle_scalar = 0,
    } })});
    try self.player.negotiateCompression(player_compression, player_compression_threshold);
    self.player_phase = .login;
}

fn authenticate(self: *Managed, ends: Ends, packet: PlayerSession.Packet) !void {
    const policy: bedwire.TrustPolicy = .{ .oidc = .{ .now = std.Io.Clock.real.now(ends.io).toSeconds(), .keys = self.shared.keys } };
    var identity = self.player.authenticateLoginPacket(self.gpa, packet, policy) catch |err| {
        if (err == error.OutOfMemory) ends.stats.bump(.auth_unavailable, 1) else ends.stats.bump(.logins_rejected, 1);
        log.info("login rejected: {t}", .{err});
        return err;
    };
    errdefer identity.deinit();
    const client_data = try clientData(self.gpa, try typed(try self.player.decodePacket(packet), .login));
    errdefer self.gpa.free(client_data);

    var salt: [16]u8 = undefined;
    ends.io.random(&salt);
    const token = try bedwire.auth.login.serverHandshake(self.gpa, self.shared.key, salt, limits);
    defer self.gpa.free(token);
    const storage = try self.gpa.alloc(u8, token.len + 16);
    defer self.gpa.free(storage);
    try self.sendToPlayer(ends, &.{try encodeTyped(storage, .{ .server_to_client_handshake = .{ .handshake_web_token = token } })});
    try self.player.installServerCrypto(self.shared.key.secret_key, salt);

    ends.stats.bump(.logins_verified, 1);
    log.info("verified {s} (xuid {s})", .{ identity.display_name, identity.xuid });
    self.identity = identity;
    self.client_data = client_data;
    self.player_phase = .handshake;
}

fn relayFromPlayer(self: *Managed, ends: Ends, packets: *PlayerSession.Packets) !void {
    var next_state: ?bedwire.State = null;
    var batch = self.newBatch(ends, false);
    errdefer batch.discard();
    while (packets.next()) |packet| {
        if (packet.kind == .command_request) if (self.shared.hooks) |hooks| if (hooks.plugins.hasCommands()) {
            const request = try typed(try self.player.decodePacket(packet), .command_request);
            if (hooks.plugins.runCommand(hooks.worker, ends.io, self.plugin_player, request.command)) continue;
        };
        if (self.syncing) if (packet.kind) |kind| switch (kind) {
            .player_action => if (Handoff.isAck(try self.player.decodePacket(packet))) {
                self.dimension_acks += 1;
                continue;
            },
            .player_auth_input, .move_player => continue,
            else => {},
        };
        if (self.upstream.phase != .ready) {
            try self.early.push(self.gpa, packet.bytes);
            continue;
        }
        const sent = try batch.add(packet.kind, packet.bytes) orelse continue;
        if (try self.sentToBackend(packet.kind, sent)) |state| next_state = state;
    }
    try batch.flush();
    if (next_state) |state| try self.advance(state);
    if (next_state == .in_game and !self.commands_sent) if (self.pluginCommands()) |plugins| {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        if (self.advertise(arena.allocator(), plugins, null)) |packet| try self.sendToPlayer(ends, &.{packet});
    };
}

fn relayFromBackend(self: *Managed, ends: Ends, packets: *BackendSession.Packets) !void {
    var start_game = false;
    var batch = self.newBatch(ends, true);
    errdefer batch.discard();
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    while (packets.next()) |packet| {
        var bytes = packet.bytes;
        if (packet.kind == .available_commands) if (self.pluginCommands()) |plugins| {
            bytes = self.advertise(arena.allocator(), plugins, bytes) orelse bytes;
        };
        if (self.syncing and packet.kind == .play_status) {
            if ((try typed(try self.upstream.session.decodePacket(packet), .play_status)).status == .playerspawn) {
                self.target_spawned = true;
                continue;
            }
        }
        if (registries.isRegistry(packet.kind)) {
            if (self.transferred) {
                try self.checkRegistry(packet);
                continue;
            }
            if (self.player.state != .in_game) {
                const decoded = try self.upstream.session.decodePacket(packet);
                try self.initial_registries.record(decoded);
                if (decoded.value == .typed and decoded.value.typed == .start_game) {
                    const start = decoded.value.typed.start_game;
                    self.client_ids = .{ .runtime = start.runtime_id, .unique = start.entity_id };
                    self.backend_ids = self.client_ids;
                    self.client_state.own_runtime_id = start.runtime_id;
                    self.client_dimension = start.settings.spawn_settings.dimension;
                }
            }
        }
        if (self.hold) |hold| {
            try hold.push(self.gpa, bytes);
            continue;
        }
        if (self.player.state == .resource_packs) try self.capturePacks(packet);
        _ = try batch.add(packet.kind, bytes) orelse continue;
        if (packet.kind == .start_game) start_game = true;
    }
    try batch.flush();
    if (start_game) try self.advance(.spawn_ready);
}

fn checkRegistry(self: *Managed, packet: BackendSession.Packet) !void {
    var late: registries.Fingerprint = .{};
    try late.record(try self.upstream.session.decodePacket(packet));
    for (std.enums.values(registries.Kind)) |kind| {
        const value = late.get(kind) orelse continue;
        if (value != self.initial_registries.get(kind)) return error.IncompatibleRegistry;
    }
}

fn capturePacks(self: *Managed, packet: BackendSession.Packet) !void {
    switch (packet.kind orelse return) {
        .resource_packs_info => self.initial_packs.info = try packs.infoHash(try typed(try self.upstream.session.decodePacket(packet), .resource_packs_info)),
        .resource_pack_stack => self.initial_packs.stack = try packs.stackHash(try typed(try self.upstream.session.decodePacket(packet), .resource_pack_stack)),
        else => {},
    }
}

fn advance(self: *Managed, state: bedwire.State) !void {
    if (self.upstream.phase != .ready) return error.UnexpectedPacket;
    try self.player.advance(state);
    try self.upstream.session.advance(state);
}

fn sendToPlayer(self: *Managed, ends: Ends, packets: []const []const u8) !void {
    try send(&self.player, ends.player, ends.stats, .bytes_to_player, packets);
}

pub fn send(session: anytype, sink: anytype, stats: *Stats, comptime counter: std.meta.FieldEnum(Stats), packets: []const []const u8) !void {
    var rest = packets;
    var chunk = packets.len;
    while (rest.len != 0) {
        const count = @min(chunk, rest.len);
        const frame = session.encode(rest[0..count]) catch |err| {
            if (err == error.NoSpaceLeft and count > 1) {
                chunk = count / 2;
                continue;
            }
            return err;
        };
        defer frame.release();
        sink.send(frame.bytes, .reliable_ordered, 0) catch |err| {
            session.close();
            return err;
        };
        stats.bump(counter, frame.bytes.len);
        rest = rest[count..];
    }
}

pub fn encodeTyped(buffer: []u8, packet: protocol.typed.Packet) ![]const u8 {
    var writer = protocol.Writer.init(buffer);
    try protocol.typed.encode(&writer, .{ .header = .{ .packet_id = Current.packetId(protocol.typed.packetKind(packet)).? }, .packet = packet });
    return writer.written();
}

pub fn typed(envelope: protocol.BorrowedEnvelope, comptime kind: bedwire.PacketKind) !@FieldType(protocol.typed.Packet, @tagName(kind)) {
    if (envelope.value != .typed or envelope.value.typed != kind) return error.InvalidProfile;
    return @field(envelope.value.typed, @tagName(kind));
}

// Bedwire has already verified this against the player's key
fn clientData(gpa: std.mem.Allocator, login: @FieldType(protocol.typed.Packet, "login")) ![]u8 {
    const request = try bedwire.auth.decodeConnectionRequest(login.connection_request, limits);
    var parts = std.mem.splitScalar(u8, request.client_data, '.');
    _ = parts.first();
    const encoded = parts.next() orelse return error.InvalidClaims;
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const size = decoder.calcSizeForSlice(encoded) catch return error.InvalidClaims;
    if (size > limits.max_jwt_payload_bytes) return error.LimitExceeded;
    const json = try gpa.alloc(u8, size);
    errdefer gpa.free(json);
    decoder.decode(json, encoded) catch return error.InvalidClaims;
    return json;
}

test "failed managed batches release replacement storage before the next player" {
    const Replace = struct {
        var calls: usize = 0;

        fn init(host: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
            plugin.name = .of("batch-cleanup");
            plugin.plugin_version = .of("1");
            plugin.capabilities.packets = true;
            return host.subscribe_packet(host.context, .from_backend, 1020, .in_game, .{}, replace, null);
        }

        fn replace(_: ?*anyopaque, packet: *abi.Packet) callconv(.c) abi.PacketAction {
            calls += 1;
            const out = packet.replacement.?[0..packet.replacement_capacity];
            @memset(out, 'x');
            const header = packet.bytes.slice();
            @memcpy(out[0..header.len], header);
            packet.replacement_len = out.len;
            return .replace;
        }
    };
    const gpa = std.testing.allocator;
    var plugins: Plugins = try .init(gpa, &.{}, .{});
    defer plugins.deinit();
    try plugins.add(Replace.init, null);
    var storage: [16][]const u8 = undefined;
    var shared: Shared = .{ .pool = undefined, .key = undefined, .keys = undefined, .batch = &storage, .translated = .init(gpa), .hooks = .{ .plugins = &plugins, .worker = 0 } };
    defer shared.translated.deinit();
    defer gpa.free(shared.scratch);
    var managed: Managed = .{ .gpa = gpa, .shared = &shared, .player = undefined, .upstream = undefined, .early = .init(0, 0) };
    managed.player.state = .in_game;
    var header_buffer: [4]u8 = undefined;
    var writer = protocol.Writer.init(&header_buffer);
    try writer.writeVarU32(1020);
    try std.testing.expect(Current.packetKind(1020) == null);
    var packets: [9][]const u8 = @splat(writer.written());
    var malformed: [4]u8 = undefined;
    writer = protocol.Writer.init(&malformed);
    try writer.writeVarU32(Current.packetId(.change_dimension).?);
    packets[8] = writer.written();
    var stats: Stats = .{};
    var session: raknet.Session = undefined;
    const ends: Ends = .{ .io = std.testing.io, .stats = &stats, .player = &session, .backend = null };
    Replace.calls = 0;
    for (0..3) |_| {
        try std.testing.expectError(error.EndOfStream, managed.deliver(ends, &packets));
        try std.testing.expectEqual(@as(usize, 0), shared.translated.queryCapacity());
    }
    try std.testing.expectEqual(@as(usize, 24), Replace.calls);
}

test "managed batches free storage when arena retention allocation fails" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .resize_fail_index = 0 });
    var shared: Shared = undefined;
    shared.translated = .init(failing.allocator());
    defer shared.translated.deinit();
    _ = try shared.translated.allocator().alloc(u8, 512 * 1024);
    failing.fail_index = failing.alloc_index;
    var managed: Managed = .{ .gpa = failing.allocator(), .shared = &shared, .player = undefined, .upstream = undefined, .early = .init(0, 0) };
    var batch: Batch = .{ .managed = &managed, .ends = undefined, .to_player = true };
    try batch.flush();
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), shared.translated.queryCapacity());
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "player milestones and container tracking use the delivered packet" {
    var managed: Managed = .{ .gpa = std.testing.allocator, .shared = undefined, .player = undefined, .upstream = undefined, .early = .init(0, 0) };
    managed.player.state = .resource_packs;
    var buffer: [32]u8 = undefined;
    const downloading = try encodeTyped(&buffer, .{ .resource_pack_client_response = .{ .response = .{ .downloading_finished = "" } } });
    try std.testing.expectEqual(@as(?bedwire.State, null), try managed.sentToBackend(.resource_pack_client_response, downloading));
    const finished = try encodeTyped(&buffer, .{ .resource_pack_client_response = .{ .response = .{ .resource_pack_stack_finished = "" } } });
    try std.testing.expectEqual(@as(?bedwire.State, .waiting_for_start_game), try managed.sentToBackend(.resource_pack_client_response, finished));
    try std.testing.expectError(error.EndOfStream, managed.sentToBackend(.resource_pack_client_response, finished[0..1]));

    const spawned = try encodeTyped(&buffer, .{ .set_local_player_as_initialised = .{ .player_id = 1 } });
    try std.testing.expectEqual(@as(?bedwire.State, null), try managed.sentToBackend(.set_local_player_as_initialised, spawned));
    managed.player.state = .spawn_ready;
    try std.testing.expectEqual(@as(?bedwire.State, .in_game), try managed.sentToBackend(.set_local_player_as_initialised, spawned));
    managed.client_state.container = .{ .id = 1, .kind = 0 };
    const closed = try encodeTyped(&buffer, .{ .container_close = .{ .container_id = 1, .container_type = 0, .server_initiated_close = false } });
    try std.testing.expectEqual(@as(?bedwire.State, null), try managed.sentToBackend(.container_close, closed));
    try std.testing.expectEqual(null, managed.client_state.container);
}

test "typed plugin fields respect session phase and packet direction" {
    var managed: Managed = .{ .gpa = std.testing.allocator, .shared = undefined, .player = undefined, .upstream = undefined, .early = .init(0, 0) };
    var checker: Checker = .{ .managed = &managed, .to_player = false };
    managed.player.state = .resource_packs;
    try std.testing.expect(!checker.permits(.text));
    managed.player.state = .spawn_ready;
    try std.testing.expect(checker.permits(.text) and checker.permits(.chunk_radius));
    checker.to_player = true;
    try std.testing.expect(checker.permits(.text) and !checker.permits(.chunk_radius));
    managed.player.state = .in_game;
    try std.testing.expect(checker.permits(.chunk_radius));
    managed.player.state = .disconnected;
    try std.testing.expect(!checker.permits(.text));
}
