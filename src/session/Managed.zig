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
const Queue = @import("../transfer/Queue.zig");
const Handoff = @import("../transfer/Handoff.zig");

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

    pub fn init(gpa: std.mem.Allocator, key: Ecdsa.KeyPair, keys: *const bedwire.auth.KeySet) !Shared {
        var pool: bedwire.BufferPool = try .init(gpa, limits, .{ .rx_slots = 1, .tx_slots = 1 });
        errdefer pool.deinit();
        return .{ .pool = pool, .key = key, .keys = keys, .batch = try gpa.alloc([]const u8, limits.max_packets_per_batch) };
    }

    pub fn deinit(self: *Shared, gpa: std.mem.Allocator) void {
        gpa.free(self.batch);
        self.pool.deinit();
    }
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
    var count: usize = 0;
    for (packets) |packet| {
        const header = protocol.packet.decode(packet, .{ .max_packet_bytes = @max(packet.len, 1) }) catch continue;
        const kind = Current.packetKind(header.header.packet_id);
        if (!self.player.state.permits(Current.features, .server, kind)) continue;
        if (ClientState.tracks(kind)) self.observeClient(packet);
        self.shared.batch[count] = packet;
        count += 1;
    }
    if (count != 0) try self.sendToPlayer(ends, self.shared.batch[0..count]);
    return packets.len - count;
}

pub fn sendOutbox(self: *Managed, ends: Ends, outbox: *const Outbox) !void {
    var start: usize = 0;
    while (start < outbox.count()) {
        const packets = outbox.slices(start, self.shared.batch);
        try self.sendToPlayer(ends, packets);
        start += packets.len;
    }
}

fn observeClient(self: *Managed, packet: []const u8) void {
    const decoded = Current.decodeBorrowed(packet, protocolLimits()) catch {
        self.client_state.untracked = true;
        return;
    };
    self.client_state.observe(self.gpa, decoded) catch {
        self.client_state.untracked = true;
    };
}

fn protocolLimits() protocol.DecodeLimits {
    return .{ .max_packet_bytes = limits.max_packet_bytes, .max_string_bytes = limits.max_packet_bytes, .max_byte_array_bytes = limits.max_packet_bytes, .max_nbt_bytes = limits.max_packet_bytes };
}

pub fn backendConnected(self: *Managed, ends: Ends) !void {
    try self.upstream.connected(self.upstreamContext(ends, ends.backend.?));
}

pub fn fromPlayer(self: *Managed, ends: Ends, payload: []const u8) !void {
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
            if (self.early.items().len != 0) try self.upstream.send(ctx, self.early.items());
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
    var count: usize = 0;
    while (packets.next()) |packet| {
        if (self.syncing) if (packet.kind) |kind| switch (kind) {
            .player_action => if (Handoff.isAck(try self.player.decodePacket(packet))) {
                self.dimension_acks += 1;
                continue;
            },
            .player_auth_input, .move_player => continue,
            else => {},
        };
        if (packet.kind == .container_close) self.client_state.containerClosed();
        if (try self.playerMilestone(packet)) |state| next_state = state;
        if (self.upstream.phase != .ready) {
            try self.early.push(self.gpa, packet.bytes);
            continue;
        }
        self.shared.batch[count] = packet.bytes;
        count += 1;
    }
    if (count != 0) try self.upstream.send(self.upstreamContext(ends, ends.backend orelse return error.BackendClosed), self.shared.batch[0..count]);
    if (next_state) |state| try self.advance(state);
}

fn relayFromBackend(self: *Managed, ends: Ends, packets: *BackendSession.Packets) !void {
    var start_game = false;
    var count: usize = 0;
    while (packets.next()) |packet| {
        if (registries.isRegistry(packet.kind)) {
            if (self.transferred) {
                try self.checkRegistry(packet);
                continue;
            }
            if (self.player.state != .in_game) {
                const decoded = try self.upstream.session.decodePacket(packet);
                try self.initial_registries.record(decoded);
                if (decoded.value == .typed and decoded.value.typed == .start_game) {
                    self.client_state.own_runtime_id = decoded.value.typed.start_game.runtime_id;
                    self.client_dimension = decoded.value.typed.start_game.settings.spawn_settings.dimension;
                }
            }
        }
        if (ClientState.tracks(packet.kind)) self.observeClient(packet.bytes);
        if (packet.kind == .change_dimension) {
            const decoded = try typed(try self.upstream.session.decodePacket(packet), .change_dimension);
            self.client_dimension = decoded.dimension_id;
        }
        if (self.hold) |hold| {
            try hold.push(self.gpa, packet.bytes);
            continue;
        }
        if (packet.kind == .start_game) start_game = true;
        if (self.player.state == .resource_packs) try self.capturePacks(packet);
        self.shared.batch[count] = packet.bytes;
        count += 1;
    }
    try self.sendToPlayer(ends, self.shared.batch[0..count]);
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

fn playerMilestone(self: *Managed, packet: PlayerSession.Packet) !?bedwire.State {
    switch (packet.kind orelse return null) {
        .resource_pack_client_response => {
            const response = try typed(try self.player.decodePacket(packet), .resource_pack_client_response);
            return if (response.response == .resource_pack_stack_finished) .waiting_for_start_game else null;
        },
        .set_local_player_as_initialised => return if (self.player.state == .spawn_ready) .in_game else null,
        else => return null,
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
