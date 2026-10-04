const std = @import("std");
const raknet = @import("raknet");
const bedwire = @import("bedwire");
const bifrost = @import("bifrost");
const fixtures = @import("fixtures.zig");
const oidc_key = @import("oidc_key.zig");

const protocol = bedwire.protocol;
const Current = protocol.Current;
const Ecdsa = bedwire.crypto.spki.Ecdsa;
const IpAddress = std.Io.net.IpAddress;
const gpa = std.testing.allocator;

pub const limits: bedwire.Limits = .{
    .max_frame_bytes = 256 * 1024,
    .max_batch_bytes = 1024 * 1024,
    .max_packet_bytes = 256 * 1024,
};
// Unknown id, so Bedwire relays it without decoding
pub const game_packet_id: u10 = 1020;

pub fn proxyKey(seed: u8) !Ecdsa.KeyPair {
    return Ecdsa.KeyPair.generateDeterministic(@splat(seed));
}

pub fn keySet() !bedwire.auth.KeySet {
    return bedwire.auth.KeySet.parse(gpa, oidc_key.jwks_json, .{});
}

pub fn config(backends: []const IpAddress) !bifrost.Config {
    var result = try fixtures.config(backends);
    result.session_mode = .managed;
    return result;
}

pub fn rawPacket(buffer: []u8, id: u10, payload: []const u8) ![]const u8 {
    var writer = protocol.Writer.init(buffer);
    try writer.writeVarU32(id);
    try writer.writeRaw(payload);
    return writer.written();
}

pub fn typedPacket(buffer: []u8, packet: protocol.typed.Packet) ![]const u8 {
    var writer = protocol.Writer.init(buffer);
    try protocol.typed.encode(&writer, .{ .header = .{ .packet_id = Current.packetId(protocol.typed.packetKind(packet)).? }, .packet = packet });
    return writer.written();
}

fn signRsa(allocator: std.mem.Allocator, header: []const u8, payload: []const u8) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const header_len = encoder.calcSize(header.len);
    const payload_len = encoder.calcSize(payload.len);
    const bytes = try allocator.alloc(u8, header_len + 1 + payload_len + 1 + encoder.calcSize(256));
    errdefer allocator.free(bytes);
    _ = encoder.encode(bytes[0..header_len], header);
    bytes[header_len] = '.';
    _ = encoder.encode(bytes[header_len + 1 ..][0..payload_len], payload);
    const signed_len = header_len + 1 + payload_len;

    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[0..signed_len], &hash, .{});
    const digest_info = "\x30\x31\x30\x0d\x06\x09\x60\x86\x48\x01\x65\x03\x04\x02\x01\x05\x00\x04\x20";
    var em: [256]u8 = @splat(0xff);
    em[0] = 0;
    em[1] = 1;
    em[256 - 52] = 0;
    @memcpy(em[256 - 51 ..][0..19], digest_info);
    @memcpy(em[256 - 32 ..], &hash);

    const Modulus = std.crypto.ff.Modulus(4096);
    const n = try Modulus.fromBytes(&oidc_key.n, .big);
    const d = try Modulus.Fe.fromBytes(n, &oidc_key.d, .big);
    const signature = try n.powPublic(try Modulus.Fe.fromBytes(n, &em, .big), d);
    var signature_bytes: [256]u8 = undefined;
    try signature.toBytes(&signature_bytes, .big);
    bytes[signed_len] = '.';
    _ = encoder.encode(bytes[signed_len + 1 ..], &signature_bytes);
    return bytes;
}

pub fn loginRequest(allocator: std.mem.Allocator, key: Ecdsa.KeyPair, name: []const u8, xuid: []const u8, now: i64) ![]u8 {
    const claims = try std.fmt.allocPrint(
        allocator,
        "{{\"iss\":\"https://authorization.franchise.minecraft-services.net/\",\"aud\":\"api://auth-minecraft-services/multiplayer\",\"exp\":{d},\"cpk\":\"{s}\",\"xname\":\"{s}\",\"xid\":\"{s}\"}}",
        .{ now + 3600, bedwire.auth.login.encodedPublicKey(key.public_key), name, xuid },
    );
    defer allocator.free(claims);
    const token = try signRsa(allocator, "{\"alg\":\"RS256\",\"kid\":\"" ++ oidc_key.kid ++ "\"}", claims);
    defer allocator.free(token);
    const client_data = try bedwire.auth.login.sign(allocator, key, "{\"alg\":\"ES384\"}", "{\"SkinId\":\"bifrost-test\",\"ServerAddress\":\"proxy\"}", .{});
    defer allocator.free(client_data);
    const envelope = try std.fmt.allocPrint(allocator, "{{\"AuthenticationType\":0,\"Token\":\"{s}\"}}", .{token});
    defer allocator.free(envelope);
    return bedwire.auth.encodeConnectionRequest(allocator, .{ .chain_data = envelope, .client_data = client_data }, .{});
}

fn sendFrame(session: anytype, sink: anytype, packets: []const []const u8) !void {
    const frame = try session.encode(packets);
    defer frame.release();
    try sink.send(frame.bytes, .reliable_ordered, 0);
}

pub const Player = struct {
    io: std.Io,
    client: *raknet.Client,
    pool: *bedwire.BufferPool,
    session: bedwire.Session,
    key: Ecdsa.KeyPair,
    inbox: std.ArrayList(u8) = .empty,
    got: bool = false,

    pub fn connect(io: std.Io, address: IpAddress, seed: u8) !*Player {
        const self = try gpa.create(Player);
        errdefer gpa.destroy(self);
        const pool = try gpa.create(bedwire.BufferPool);
        errdefer gpa.destroy(pool);
        pool.* = try .init(gpa, limits, .conservative());
        errdefer pool.deinit();
        self.* = .{
            .io = io,
            .client = try raknet.Client.connect(gpa, io, address, .{ .handshake_retry_ms = 10 }),
            .pool = pool,
            .session = try .init(.client, .{ .pool = pool }),
            .key = try proxyKey(seed),
        };
        return self;
    }

    pub fn destroy(self: *Player) void {
        self.session.deinit();
        self.client.destroy();
        self.pool.deinit();
        gpa.destroy(self.pool);
        self.inbox.deinit(gpa);
        gpa.destroy(self);
    }

    pub fn login(self: *Player, name: []const u8, xuid: []const u8) !void {
        var buffer: [64]u8 = undefined;
        try self.send(&.{try typedPacket(&buffer, .{ .request_network_settings = .{ .client_network_version = @intCast(Current.protocol_number) } })});
        {
            var packets = try self.receive();
            defer packets.deinit();
            try self.session.negotiateFromSettings(packets.next() orelse return error.NoPacket);
        }
        const request = try loginRequest(gpa, self.key, name, xuid, std.Io.Clock.real.now(self.io).toSeconds());
        defer gpa.free(request);
        const storage = try gpa.alloc(u8, request.len + 32);
        defer gpa.free(storage);
        try self.send(&.{try bedwire.auth.login.encodeLoginPacket(Current, storage, request, limits)});
        {
            var packets = try self.receive();
            defer packets.deinit();
            try self.session.acceptServerHandshakePacket(gpa, packets.next() orelse return error.NoPacket, self.key.secret_key);
        }
        try self.send(&.{try typedPacket(&buffer, .{ .client_to_server_handshake = .{} })});
        try self.session.advance(.resource_packs);
        // Only the backend sends this, so both handshakes are done
        var packets = try self.receive();
        defer packets.deinit();
        const status = packets.next() orelse return error.NoPacket;
        if (status.kind != .play_status) return error.UnexpectedPacket;
    }

    pub fn spawn(self: *Player) !void {
        var buffer: [64]u8 = undefined;
        try self.send(&.{try typedPacket(&buffer, .{ .resource_pack_client_response = .{ .response = .{ .resource_pack_stack_finished = "" } } })});
        try self.session.advance(.waiting_for_start_game);
        {
            var packets = try self.receive();
            defer packets.deinit();
            const start = packets.next() orelse return error.NoPacket;
            if (start.kind != .start_game) return error.UnexpectedPacket;
        }
        try self.session.advance(.spawn_ready);
        try self.send(&.{try rawPacket(&buffer, Current.packetId(.set_local_player_as_initialised).?, &.{1})});
        try self.session.advance(.in_game);
    }

    pub fn send(self: *Player, packets: []const []const u8) !void {
        try sendFrame(&self.session, self.client, packets);
    }

    pub fn receive(self: *Player) !bedwire.Session.Packets {
        const frame = try self.awaitFrame();
        return self.session.ingest(frame);
    }

    pub fn echo(self: *Player, payload: []const u8) !void {
        const buffer = try gpa.alloc(u8, payload.len + 8);
        defer gpa.free(buffer);
        try self.send(&.{try rawPacket(buffer, game_packet_id, payload)});
        var packets = try self.receive();
        defer packets.deinit();
        const packet = packets.next() orelse return error.NoPacket;
        try std.testing.expectEqual(@as(u10, game_packet_id), packet.id);
        try std.testing.expectEqualSlices(u8, payload, packet.bytes[packet.bytes.len - payload.len ..]);
    }

    fn awaitFrame(self: *Player) ![]const u8 {
        self.got = false;
        const started = std.Io.Clock.awake.now(self.io);
        while (started.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds() < 5_000) {
            _ = self.client.poll(fixtures.millis(10), self, collect) catch |err| switch (err) {
                error.Timeout => {},
                else => return err,
            };
            if (self.got) return self.inbox.items;
            if (self.client.isClosed()) return error.ConnectionClosed;
        }
        return error.NoMessage;
    }

    pub fn awaitClosed(self: *Player) !void {
        const started = std.Io.Clock.awake.now(self.io);
        while (started.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds() < 10_000) {
            _ = self.client.poll(fixtures.millis(10), self, collect) catch |err| switch (err) {
                error.Timeout => {},
                else => return,
            };
            if (self.client.isClosed()) return;
        }
        return error.NotClosed;
    }

    fn collect(context: *anyopaque, payload: raknet.BorrowedPayload) error{ApplicationFailure}!void {
        const self: *Player = @ptrCast(@alignCast(context));
        // Tests read one frame at a time
        if (self.got) return;
        self.inbox.clearRetainingCapacity();
        self.inbox.appendSlice(gpa, payload.bytes) catch return error.ApplicationFailure;
        self.got = true;
    }
};

pub const Backend = struct {
    const Session = bifrost.Managed.BackendSession;

    const Connection = struct {
        session: Session,
        key: Ecdsa.KeyPair,
    };

    io: std.Io,
    listener: *raknet.Server,
    pool: *bedwire.BufferPool,
    trusted: Ecdsa.PublicKey,
    task: ?std.Io.Future(void) = null,
    stopping: std.atomic.Value(bool) = .init(false),
    connections: std.ArrayList(*Connection) = .empty,
    logins: std.atomic.Value(u32) = .init(0),
    echoes: std.atomic.Value(u32) = .init(0),
    disconnects: std.atomic.Value(u32) = .init(0),
    refuse: bool = false,
    identity_name: [64]u8 = undefined,
    identity_name_len: usize = 0,
    identity_xuid_len: usize = 0,
    identity_online: bool = true,

    pub fn start(self: *Backend, io: std.Io, trusted: Ecdsa.PublicKey) !void {
        const pool = try gpa.create(bedwire.BufferPool);
        errdefer gpa.destroy(pool);
        pool.* = try .init(gpa, limits, .{ .rx_slots = 4, .tx_slots = 4 });
        errdefer pool.deinit();
        self.* = .{
            .io = io,
            .listener = try raknet.Server.listen(gpa, io, fixtures.loopback, .{ .advertisement = "MCPE;backend" }),
            .pool = pool,
            .trusted = trusted,
        };
        errdefer self.listener.destroy();
        self.task = try io.concurrent(run, .{self});
    }

    pub fn deinit(self: *Backend) void {
        if (self.task) |*task| {
            self.stopping.store(true, .release);
            task.await(self.io);
        }
        self.listener.destroy();
        for (self.connections.items) |connection| freeConnection(connection);
        self.connections.deinit(gpa);
        self.pool.deinit();
        gpa.destroy(self.pool);
    }

    pub fn address(self: *const Backend) IpAddress {
        return self.listener.localAddress();
    }

    pub fn name(self: *const Backend) []const u8 {
        return self.identity_name[0..self.identity_name_len];
    }

    fn run(self: *Backend) void {
        while (!self.stopping.load(.acquire)) {
            _ = self.listener.poll(fixtures.millis(5), .{
                .context = self,
                .connected = onConnected,
                .message = onMessage,
                .disconnected = onDisconnected,
            }) catch {};
        }
    }

    fn onConnected(context: *anyopaque, session: *raknet.Session) error{ApplicationFailure}!void {
        const self: *Backend = @ptrCast(@alignCast(context));
        self.connections.ensureUnusedCapacity(gpa, 1) catch return error.ApplicationFailure;
        const connection = gpa.create(Connection) catch return error.ApplicationFailure;
        connection.* = .{
            .session = Session.init(.server, .{ .pool = self.pool }) catch {
                gpa.destroy(connection);
                return error.ApplicationFailure;
            },
            .key = proxyKey(99) catch unreachable,
        };
        self.connections.appendAssumeCapacity(connection);
        session.setUserData(connection);
    }

    fn onDisconnected(context: *anyopaque, session: *raknet.Session) void {
        const self: *Backend = @ptrCast(@alignCast(context));
        _ = self.disconnects.fetchAdd(1, .release);
        const connection: *Connection = @ptrCast(@alignCast(session.userData() orelse return));
        session.setUserData(null);
        for (self.connections.items, 0..) |item, i| if (item == connection) {
            _ = self.connections.swapRemove(i);
            break;
        };
        freeConnection(connection);
    }

    fn freeConnection(connection: *Connection) void {
        connection.session.deinit();
        gpa.destroy(connection);
    }

    fn onMessage(context: *anyopaque, session: *raknet.Session, payload: raknet.BorrowedPayload) error{ApplicationFailure}!void {
        const self: *Backend = @ptrCast(@alignCast(context));
        const connection: *Connection = @ptrCast(@alignCast(session.userData() orelse return error.ApplicationFailure));
        self.handle(connection, session, payload.bytes) catch return error.ApplicationFailure;
    }

    fn handle(self: *Backend, connection: *Connection, carrier: *raknet.Session, frame: []const u8) !void {
        const session = &connection.session;
        var packets = try session.ingest(frame);
        defer packets.deinit();
        var buffer: [512]u8 = undefined;
        while (packets.next()) |packet| switch (packet.kind orelse {
            try sendFrame(session, carrier, &.{packet.bytes});
            _ = self.echoes.fetchAdd(1, .release);
            continue;
        }) {
            .request_network_settings => {
                try sendFrame(session, carrier, &.{try typedPacket(&buffer, .{ .network_settings = .{
                    .compression_threshold = 0,
                    .compression_algorithm = .snappy,
                    .client_throttle_enabled = false,
                    .client_throttle_threshold = 0,
                    .client_throttle_scalar = 0,
                } })});
                try session.negotiateCompression(.snappy, 0);
            },
            .login => {
                var identity = try session.authenticateLoginPacket(gpa, packet, .{ .certificate_chain = .{
                    .now = std.Io.Clock.real.now(self.io).toSeconds(),
                    .trusted_issuer_key = self.trusted,
                } });
                defer identity.deinit();
                @memcpy(self.identity_name[0..identity.display_name.len], identity.display_name);
                self.identity_name_len = identity.display_name.len;
                self.identity_xuid_len = identity.xuid.len;
                self.identity_online = identity.online;
                _ = self.logins.fetchAdd(1, .release);
                if (self.refuse) {
                    try sendFrame(session, carrier, &.{try typedPacket(&buffer, .{ .play_status = .{ .status = .loginfailed_serverold } })});
                    return;
                }
                const salt: [16]u8 = @splat(7);
                const token = try bedwire.auth.login.serverHandshake(gpa, connection.key, salt, limits);
                defer gpa.free(token);
                const storage = try gpa.alloc(u8, token.len + 16);
                defer gpa.free(storage);
                try sendFrame(session, carrier, &.{try typedPacket(storage, .{ .server_to_client_handshake = .{ .handshake_web_token = token } })});
                try session.installServerCrypto(connection.key.secret_key, salt);
            },
            .client_to_server_handshake => {
                try session.advance(.resource_packs);
                try sendFrame(session, carrier, &.{try typedPacket(&buffer, .{ .play_status = .{ .status = .loginsuccess } })});
            },
            .resource_pack_client_response => {
                try session.advance(.waiting_for_start_game);
                try sendFrame(session, carrier, &.{try rawPacket(&buffer, Current.packetId(.start_game).?, "not a real StartGame")});
                try session.advance(.spawn_ready);
            },
            .set_local_player_as_initialised => try session.advance(.in_game),
            else => {},
        };
    }
};
