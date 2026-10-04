const std = @import("std");
const raknet = @import("raknet");
const bedwire = @import("bedwire");
const PacketQueue = @import("../proxy/PacketQueue.zig");
const Stats = @import("../proxy/Stats.zig");

const protocol = bedwire.protocol;
const Current = protocol.Current;
const Ecdsa = bedwire.crypto.spki.Ecdsa;

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
const login_lifetime_s = 60;

// One per worker, used by one call at a time
pub const Shared = struct {
    pool: bedwire.BufferPool,
    key: Ecdsa.KeyPair,
    keys: *const bedwire.auth.KeySet,
    batch: [][]const u8,

    pub fn init(gpa: std.mem.Allocator, key: Ecdsa.KeyPair, keys: *const bedwire.auth.KeySet) !Shared {
        // Calls never overlap, so one slot each is enough
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
pub const BackendPhase = enum { dialing, settings, waiting_for_player, handshake, ready };

gpa: std.mem.Allocator,
shared: *Shared,
player: PlayerSession,
backend: BackendSession,
player_phase: PlayerPhase = .settings,
backend_phase: BackendPhase = .dialing,
identity: ?bedwire.Identity = null,
client_data: ?[]u8 = null,
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
        .backend = try .init(.client, .{ .pool = &shared.pool }),
        .early = .init(early_packets, early_bytes),
    };
    return self;
}

pub fn destroy(self: *Managed) void {
    self.player.deinit();
    self.backend.deinit();
    if (self.identity) |*identity| identity.deinit();
    if (self.client_data) |json| self.gpa.free(json);
    self.early.deinit(self.gpa);
    self.gpa.destroy(self);
}

pub fn backendConnected(self: *Managed, ends: Ends) !void {
    std.debug.assert(self.backend_phase == .dialing);
    var buffer: [16]u8 = undefined;
    const request = try encodeTyped(&buffer, .{ .request_network_settings = .{ .client_network_version = @intCast(Current.protocol_number) } });
    try self.sendToBackend(ends, &.{request});
    self.backend_phase = .settings;
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
            if (self.backend_phase == .waiting_for_player) try self.sendBackendLogin(ends);
        },
        .ready => unreachable,
    }
}

pub fn fromBackend(self: *Managed, ends: Ends, payload: []const u8) !void {
    var packets = try self.backend.ingest(payload);
    defer packets.deinit();
    if (self.backend_phase == .ready) return self.relayFromBackend(ends, &packets);

    const packet = packets.next() orelse return error.MalformedBatch;
    if (packet.kind == .disconnect or packet.kind == .play_status) {
        // Pass the reason on if we can
        if (self.player_phase == .ready) self.sendToPlayer(ends, &.{packet.bytes}) catch {};
        return error.BackendRefused;
    }
    switch (self.backend_phase) {
        .settings => {
            try self.backend.negotiateFromSettings(packet);
            self.backend_phase = .waiting_for_player;
            if (self.player_phase == .ready) try self.sendBackendLogin(ends);
        },
        .handshake => {
            try self.backend.acceptServerHandshakePacket(self.gpa, packet, self.shared.key.secret_key);
            var buffer: [8]u8 = undefined;
            try self.sendToBackend(ends, &.{try encodeTyped(&buffer, .{ .client_to_server_handshake = .{} })});
            try self.backend.advance(.resource_packs);
            self.backend_phase = .ready;
            defer self.early.clear(self.gpa);
            if (self.early.items().len != 0) try self.sendToBackend(ends, self.early.items());
        },
        .dialing, .waiting_for_player => return error.UnexpectedPacket,
        .ready => unreachable,
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

fn sendBackendLogin(self: *Managed, ends: Ends) !void {
    const client_data = self.client_data.?;
    defer {
        self.gpa.free(client_data);
        self.client_data = null;
    }
    const expires = std.Io.Clock.real.now(ends.io).toSeconds() + login_lifetime_s;
    const request = try bedwire.auth.login.buildProxyConnectionRequest(BackendProfile, self.gpa, self.shared.key, &self.identity.?, client_data, expires, .envelope, limits);
    defer self.gpa.free(request);
    const storage = try self.gpa.alloc(u8, request.len + 32);
    defer self.gpa.free(storage);
    try self.sendToBackend(ends, &.{try bedwire.auth.login.encodeLoginPacket(BackendProfile, storage, request, limits)});
    ends.stats.bump(.proxy_logins, 1);
    self.backend_phase = .handshake;
}

fn relayFromPlayer(self: *Managed, ends: Ends, packets: *PlayerSession.Packets) !void {
    var next_state: ?bedwire.State = null;
    var count: usize = 0;
    while (packets.next()) |packet| {
        if (try self.playerMilestone(packet)) |state| next_state = state;
        if (self.backend_phase != .ready) {
            try self.early.push(self.gpa, packet.bytes);
            continue;
        }
        self.shared.batch[count] = packet.bytes;
        count += 1;
    }
    if (count != 0) try self.sendToBackend(ends, self.shared.batch[0..count]);
    if (next_state) |state| try self.advance(state);
}

fn relayFromBackend(self: *Managed, ends: Ends, packets: *BackendSession.Packets) !void {
    var start_game = false;
    var count: usize = 0;
    while (packets.next()) |packet| {
        if (packet.kind == .start_game) start_game = true;
        self.shared.batch[count] = packet.bytes;
        count += 1;
    }
    try self.sendToPlayer(ends, self.shared.batch[0..count]);
    if (start_game) try self.advance(.spawn_ready);
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
    if (self.backend_phase != .ready) return error.UnexpectedPacket;
    try self.player.advance(state);
    try self.backend.advance(state);
}

fn sendToPlayer(self: *Managed, ends: Ends, packets: []const []const u8) !void {
    try send(&self.player, ends.player, ends.stats, .bytes_to_player, packets);
}

fn sendToBackend(self: *Managed, ends: Ends, packets: []const []const u8) !void {
    try send(&self.backend, ends.backend orelse return error.BackendClosed, ends.stats, .bytes_to_backend, packets);
}

// Halves the batch until it fits in a frame
fn send(session: anytype, sink: anytype, stats: *Stats, comptime counter: std.meta.FieldEnum(Stats), packets: []const []const u8) !void {
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

fn encodeTyped(buffer: []u8, packet: protocol.typed.Packet) ![]const u8 {
    var writer = protocol.Writer.init(buffer);
    try protocol.typed.encode(&writer, .{ .header = .{ .packet_id = Current.packetId(protocol.typed.packetKind(packet)).? }, .packet = packet });
    return writer.written();
}

fn typed(envelope: protocol.BorrowedEnvelope, comptime kind: bedwire.PacketKind) !@FieldType(protocol.typed.Packet, @tagName(kind)) {
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
