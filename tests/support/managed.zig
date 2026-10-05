const std = @import("std");
const raknet = @import("raknet");
const bedwire = @import("bedwire");
const bifrost = @import("bifrost");
const fixtures = @import("fixtures.zig");
const sample = @import("sample.zig");

const protocol = bedwire.protocol;
const Current = protocol.Current;
pub const Ecdsa = bedwire.crypto.spki.Ecdsa;
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
    return sample.keySet(gpa);
}

pub const rawPacket = sample.rawPacket;
pub const typedPacket = sample.typedPacket;

pub fn config(backends: []const IpAddress) !bifrost.Config {
    var result = try fixtures.config(backends);
    result.session_mode = .managed;
    return result;
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
    frames: std.ArrayList([]u8) = .empty,
    current: ?[]u8 = null,
    timeout_ms: i64 = 5_000,
    game_packets: std.ArrayList([]u8) = .empty,
    dimension_changes: usize = 0,
    dimensions: [8]i32 = undefined,

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
        if (self.current) |frame| gpa.free(frame);
        for (self.frames.items) |frame| gpa.free(frame);
        self.frames.deinit(gpa);
        for (self.game_packets.items) |packet| gpa.free(packet);
        self.game_packets.deinit(gpa);
        gpa.destroy(self);
    }

    pub fn login(self: *Player, name: []const u8, xuid: []const u8) !void {
        try self.settings(@intCast(Current.protocol_number));
        try self.sendLogin(name, xuid, self.key);
        try self.finishHandshake();
        try self.awaitLoginStatus();
    }

    pub fn settings(self: *Player, version: i32) !void {
        var buffer: [64]u8 = undefined;
        try self.send(&.{try typedPacket(&buffer, .{ .request_network_settings = .{ .client_network_version = version } })});
        var packets = try self.receive();
        defer packets.deinit();
        try self.session.negotiateFromSettings(packets.next() orelse return error.NoPacket);
    }

    // Signing ClientData with another key forges it
    pub fn sendLogin(self: *Player, name: []const u8, xuid: []const u8, client_data_signer: Ecdsa.KeyPair) !void {
        const request = try sample.request(gpa, self.key, client_data_signer, name, xuid, std.Io.Clock.real.now(self.io).toSeconds());
        defer gpa.free(request);
        const storage = try gpa.alloc(u8, request.len + 32);
        defer gpa.free(storage);
        try self.send(&.{try bedwire.auth.login.encodeLoginPacket(Current, storage, request, limits)});
    }

    pub fn finishHandshake(self: *Player) !void {
        {
            var packets = try self.receive();
            defer packets.deinit();
            try self.session.acceptServerHandshakePacket(gpa, packets.next() orelse return error.NoPacket, self.key.secret_key);
        }
        var buffer: [8]u8 = undefined;
        try self.send(&.{try typedPacket(&buffer, .{ .client_to_server_handshake = .{} })});
        try self.session.advance(.resource_packs);
    }

    // Only the backend sends this, so both handshakes are done
    pub fn awaitLoginStatus(self: *Player) !void {
        var packets = try self.receive();
        defer packets.deinit();
        const packet = packets.next() orelse return error.NoPacket;
        if (packet.kind != .play_status) return error.UnexpectedPacket;
        const status = (try self.session.decodePacket(packet)).value.typed.play_status.status;
        if (status != .loginsuccess) return error.LoginRefused;
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
        const echoed = try gpa.alloc(u8, payload.len + 8);
        defer gpa.free(echoed);
        try std.testing.expectEqualSlices(u8, payload, try self.nextGamePacket(echoed));
    }

    pub fn nextGamePacket(self: *Player, out: []u8) ![]const u8 {
        while (self.game_packets.items.len == 0) try self.pump();
        const payload = self.game_packets.orderedRemove(0);
        defer gpa.free(payload);
        @memcpy(out[0..payload.len], payload);
        return out[0..payload.len];
    }

    // Acks dimension changes like a client
    pub fn pump(self: *Player) !void {
        var acks: usize = 0;
        {
            var packets = try self.receive();
            defer packets.deinit();
            while (packets.next()) |packet| switch (packet.kind orelse {
                try self.game_packets.ensureUnusedCapacity(gpa, 1);
                self.game_packets.appendAssumeCapacity(try gpa.dupe(u8, packet.bytes[2..]));
                continue;
            }) {
                .change_dimension => {
                    const change = (try self.session.decodePacket(packet)).value.typed.change_dimension;
                    if (self.dimension_changes < self.dimensions.len) self.dimensions[self.dimension_changes] = change.dimension_id;
                    self.dimension_changes += 1;
                    acks += 1;
                },
                else => {},
            };
        }
        var buffer: [64]u8 = undefined;
        for (0..acks) |_| try self.send(&.{try typedPacket(&buffer, .{ .player_action = .{
            .player_runtime_id = 0,
            .action = .changedimensionack,
            .block_position = .{ .x = 0, .y = 0, .z = 0 },
            .result_pos = .{ .x = 0, .y = 0, .z = 0 },
            .face = 0,
        } })});
    }

    pub fn countGamePackets(self: *Player, suffix: []const u8, ms: i64) !usize {
        const saved = self.timeout_ms;
        defer self.timeout_ms = saved;
        self.timeout_ms = 20;
        var count: usize = 0;
        var buffer: [64]u8 = undefined;
        const started = std.Io.Clock.awake.now(self.io);
        while (started.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds() < ms) {
            const payload = self.nextGamePacket(&buffer) catch |err| switch (err) {
                error.NoMessage => continue,
                else => return err,
            };
            if (std.mem.endsWith(u8, payload, suffix)) count += 1;
        }
        return count;
    }

    fn awaitFrame(self: *Player) ![]const u8 {
        if (self.current) |frame| gpa.free(frame);
        self.current = null;
        const started = std.Io.Clock.awake.now(self.io);
        while (self.frames.items.len == 0) {
            if (started.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds() >= self.timeout_ms) return error.NoMessage;
            _ = self.client.poll(fixtures.millis(10), self, collect) catch |err| switch (err) {
                error.Timeout => {},
                else => return err,
            };
            if (self.frames.items.len == 0 and self.client.isClosed()) return error.ConnectionClosed;
        }
        self.current = self.frames.orderedRemove(0);
        return self.current.?;
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
        self.frames.ensureUnusedCapacity(gpa, 1) catch return error.ApplicationFailure;
        self.frames.appendAssumeCapacity(gpa.dupe(u8, payload.bytes) catch return error.ApplicationFailure);
    }
};

pub const Backend = struct {
    const Session = bifrost.Managed.BackendSession;

    const Connection = struct {
        session: Session,
        key: Ecdsa.KeyPair,
        carrier: *raknet.Session,
    };

    pub const Mode = enum { normal, silent_login, kick_login, silent_stack, kick_packs, welcome, flood, chatter };

    io: std.Io,
    listener: *raknet.Server,
    pool: *bedwire.BufferPool,
    trusted: Ecdsa.PublicKey,
    task: ?std.Io.Future(void) = null,
    stopping: std.atomic.Value(bool) = .init(false),
    connections: std.ArrayList(*Connection) = .empty,
    logins: std.atomic.Value(u32) = .init(0),
    echoes: std.atomic.Value(u32) = .init(0),
    handshakes: std.atomic.Value(u32) = .init(0),
    disconnects: std.atomic.Value(u32) = .init(0),
    refuse: bool = false,
    mode: Mode = .normal,
    content: sample.Content = .{},
    chattered_ns: u64 = 0,
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
            if (self.mode == .chatter) self.chatter();
        }
    }

    fn chatter(self: *Backend) void {
        const now: u64 = @intCast(std.Io.Clock.awake.now(self.io).nanoseconds);
        if (now - self.chattered_ns < 5 * std.time.ns_per_ms) return;
        self.chattered_ns = now;
        var buffer: [16]u8 = undefined;
        const packet = rawPacket(&buffer, game_packet_id, "chatter") catch unreachable;
        for (self.connections.items) |connection| {
            if (connection.session.state != .in_game and connection.session.state != .spawn_ready) continue;
            sendFrame(&connection.session, connection.carrier, &.{packet}) catch {};
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
            .carrier = session,
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
            if (std.mem.endsWith(u8, packet.bytes, "kick")) return carrier.close();
            _ = self.echoes.fetchAdd(1, .release);
            try sendFrame(session, carrier, &.{packet.bytes});
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
                var identity = session.authenticateLoginPacket(gpa, packet, .{ .certificate_chain = .{
                    .now = std.Io.Clock.real.now(self.io).toSeconds(),
                    .trusted_issuer_key = self.trusted,
                } }) catch return carrier.close();
                defer identity.deinit();
                @memcpy(self.identity_name[0..identity.display_name.len], identity.display_name);
                self.identity_name_len = identity.display_name.len;
                self.identity_xuid_len = identity.xuid.len;
                self.identity_online = identity.online;
                _ = self.logins.fetchAdd(1, .release);
                if (self.mode == .silent_login) return;
                if (self.mode == .kick_login) return carrier.close();
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
                _ = self.handshakes.fetchAdd(1, .release);
                const status = try typedPacket(&buffer, .{ .play_status = .{ .status = .loginsuccess } });
                if (self.mode == .silent_stack) return sendFrame(session, carrier, &.{status});
                var stack: [128]u8 = undefined;
                try sendFrame(session, carrier, &.{ status, try sample.packStack(&stack, self.content) });
            },
            .resource_pack_client_response => {
                if (self.mode == .kick_packs) return carrier.close();
                try session.advance(.waiting_for_start_game);
                var start_buffer: [1024]u8 = undefined;
                var items_buffer: [256]u8 = undefined;
                var batch: [303][]const u8 = undefined;
                batch[0] = try sample.startGame(&start_buffer, self.content);
                batch[1] = try sample.itemRegistry(&items_buffer, self.content);
                batch[2] = &sample.biome_definitions;
                var extra: [16]u8 = undefined;
                const count: usize = switch (self.mode) {
                    .welcome => count: {
                        batch[3] = try rawPacket(&extra, game_packet_id, "welcome");
                        break :count 4;
                    },
                    .flood => count: {
                        @memset(batch[3..], try rawPacket(&extra, game_packet_id, "flood"));
                        break :count batch.len;
                    },
                    else => 3,
                };
                try sendFrame(session, carrier, batch[0..count]);
                try session.advance(.spawn_ready);
            },
            .set_local_player_as_initialised => try session.advance(.in_game),
            else => {},
        };
    }
};
