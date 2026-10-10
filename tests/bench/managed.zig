const std = @import("std");
const raknet = @import("raknet");
const bedwire = @import("bedwire");
const bifrost = @import("bifrost");
const sample = @import("sample");
const harness = @import("harness.zig");

const Current = bedwire.protocol.Current;
const Ecdsa = bedwire.crypto.spki.Ecdsa;

pub const limits: bedwire.Limits = .{
    .max_frame_bytes = 1024 * 1024,
    .max_batch_bytes = 4 * 1024 * 1024,
    .max_packet_bytes = 1024 * 1024,
};
const game_packet_id: u10 = 1020;
// 1020 as a varint
pub const header_len = 2;

pub fn proxyKey() Ecdsa.KeyPair {
    return Ecdsa.KeyPair.generateDeterministic(@splat(1)) catch unreachable;
}

pub const Bedrock = struct {
    gpa: std.mem.Allocator,
    pool: bedwire.BufferPool,
    session: bedwire.Session,
    key: Ecdsa.KeyPair,
    scratch: []u8,

    fn create(gpa: std.mem.Allocator, seed: u8) !*Bedrock {
        const self = try gpa.create(Bedrock);
        errdefer gpa.destroy(self);
        self.pool = try .init(gpa, limits, .conservative());
        errdefer self.pool.deinit();
        self.session = try .init(.client, .{ .pool = &self.pool });
        errdefer self.session.deinit();
        self.gpa = gpa;
        self.key = try Ecdsa.KeyPair.generateDeterministic(@splat(seed));
        self.scratch = try gpa.alloc(u8, limits.max_packet_bytes);
        return self;
    }

    pub fn destroy(self: *Bedrock) void {
        self.gpa.free(self.scratch);
        self.session.deinit();
        self.pool.deinit();
        self.gpa.destroy(self);
    }

    pub fn wrap(self: *Bedrock, payload: []const u8) !bedwire.Session.Frame {
        return self.session.encodeOne(try sample.rawPacket(self.scratch, game_packet_id, payload));
    }

    fn send(self: *Bedrock, client: *raknet.Client, packet: []const u8) !void {
        const frame = try self.session.encodeOne(packet);
        defer frame.release();
        try client.send(frame.bytes, .reliable_ordered, 0);
    }
};

pub fn join(gpa: std.mem.Allocator, io: std.Io, player: *harness.Player, seed: u8) !void {
    const bedrock = try Bedrock.create(gpa, seed);
    errdefer bedrock.destroy();
    const client = player.client;
    var inbox: Inbox = .{ .gpa = gpa };
    defer inbox.buffer.deinit(gpa);
    var buffer: [64]u8 = undefined;
    const session = &bedrock.session;

    try bedrock.send(client, try sample.typedPacket(&buffer, .{ .request_network_settings = .{ .client_network_version = @intCast(Current.protocol_number) } }));
    {
        var packets = try session.ingest(try inbox.next(io, client));
        defer packets.deinit();
        try session.negotiateFromSettings(packets.next() orelse return error.NoPacket);
    }
    const request = try sample.request(gpa, bedrock.key, bedrock.key, "Bench", "2535400000000001", std.Io.Clock.real.now(io).toSeconds());
    defer gpa.free(request);
    try bedrock.send(client, try bedwire.auth.login.encodeLoginPacket(Current, bedrock.scratch, request, limits));
    {
        var packets = try session.ingest(try inbox.next(io, client));
        defer packets.deinit();
        try session.acceptServerHandshakePacket(gpa, packets.next() orelse return error.NoPacket, bedrock.key.secret_key);
    }
    try bedrock.send(client, try sample.typedPacket(&buffer, .{ .client_to_server_handshake = .{} }));
    try session.advance(.resource_packs);
    try expectKind(session, try inbox.next(io, client), .play_status);
    try bedrock.send(client, try sample.typedPacket(&buffer, .{ .resource_pack_client_response = .{ .response = .{ .resource_pack_stack_finished = "" } } }));
    try session.advance(.waiting_for_start_game);
    try expectKind(session, try inbox.next(io, client), .start_game);
    try session.advance(.spawn_ready);
    try bedrock.send(client, try sample.rawPacket(&buffer, Current.packetId(.set_local_player_as_initialised).?, &.{1}));
    try session.advance(.in_game);
    player.bedrock = bedrock;
}

fn expectKind(session: *bedwire.Session, frame: []const u8, kind: bedwire.PacketKind) !void {
    var packets = try session.ingest(frame);
    defer packets.deinit();
    const packet = packets.next() orelse return error.NoPacket;
    if (packet.kind != kind) return error.UnexpectedPacket;
}

const Inbox = struct {
    gpa: std.mem.Allocator,
    buffer: std.ArrayList(u8) = .empty,
    got: bool = false,

    fn next(self: *Inbox, io: std.Io, client: *raknet.Client) ![]const u8 {
        self.got = false;
        const deadline = harness.nowNs(io) + 5 * std.time.ns_per_s;
        while (!self.got) {
            if (harness.nowNs(io) > deadline) return error.ReplyTimedOut;
            _ = client.poll(harness.millis(20), self, collect) catch |err| switch (err) {
                error.Timeout => {},
                else => return err,
            };
        }
        return self.buffer.items;
    }

    fn collect(context: *anyopaque, payload: raknet.BorrowedPayload) error{ApplicationFailure}!void {
        const self: *Inbox = @ptrCast(@alignCast(context));
        if (self.got) return error.ApplicationFailure;
        self.buffer.clearRetainingCapacity();
        self.buffer.appendSlice(self.gpa, payload.bytes) catch return error.ApplicationFailure;
        self.got = true;
    }
};

pub const Backend = struct {
    const Session = bifrost.Managed.BackendSession;

    const Connection = struct {
        session: Session,
        key: Ecdsa.KeyPair,
    };

    gpa: std.mem.Allocator,
    io: std.Io,
    listener: *raknet.Server,
    pool: bedwire.BufferPool,
    trusted: Ecdsa.PublicKey,
    connections: std.ArrayList(*Connection) = .empty,
    task: ?std.Io.Future(void) = null,
    stopping: std.atomic.Value(bool) = .init(false),
    packets: std.ArrayList([]const u8) = .empty,

    pub fn start(self: *Backend, gpa: std.mem.Allocator, io: std.Io) !void {
        var config: raknet.Config = .{};
        config.listener.maximum_connections = 16_384;
        self.* = .{
            .gpa = gpa,
            .io = io,
            .listener = try raknet.Server.listen(gpa, io, harness.loopback(0), .{ .advertisement = "MCPE;bench", .config = config, .offline_rate_per_second = 1_000_000, .offline_burst = 1_000_000 }),
            .pool = undefined,
            .trusted = proxyKey().public_key,
        };
        errdefer self.listener.destroy();
        self.pool = try .init(gpa, limits, .{ .rx_slots = 1, .tx_slots = 1 });
        errdefer self.pool.deinit();
        try self.packets.ensureTotalCapacity(gpa, limits.max_packets_per_batch);
        errdefer self.packets.deinit(gpa);
        self.task = try io.concurrent(run, .{self});
    }

    pub fn deinit(self: *Backend) void {
        if (self.task) |*task| {
            self.stopping.store(true, .release);
            task.await(self.io);
        }
        self.listener.destroy();
        for (self.connections.items) |connection| self.free(connection);
        self.connections.deinit(self.gpa);
        self.packets.deinit(self.gpa);
        self.pool.deinit();
    }

    pub fn port(self: *const Backend) u16 {
        return self.listener.localAddress().getPort();
    }

    fn run(self: *Backend) void {
        while (!self.stopping.load(.acquire)) {
            _ = self.listener.poll(harness.millis(5), .{
                .context = self,
                .connected = onConnected,
                .message = onMessage,
                .disconnected = onDisconnected,
            }) catch {};
        }
    }

    fn free(self: *Backend, connection: *Connection) void {
        connection.session.deinit();
        self.gpa.destroy(connection);
    }

    fn onConnected(context: *anyopaque, carrier: *raknet.Session) error{ApplicationFailure}!void {
        const self: *Backend = @ptrCast(@alignCast(context));
        self.connections.ensureUnusedCapacity(self.gpa, 1) catch return error.ApplicationFailure;
        const connection = self.gpa.create(Connection) catch return error.ApplicationFailure;
        connection.* = .{
            .session = Session.init(.server, .{ .pool = &self.pool }) catch {
                self.gpa.destroy(connection);
                return error.ApplicationFailure;
            },
            .key = Ecdsa.KeyPair.generateDeterministic(@splat(99)) catch unreachable,
        };
        self.connections.appendAssumeCapacity(connection);
        carrier.setUserData(connection);
    }

    fn onDisconnected(context: *anyopaque, carrier: *raknet.Session) void {
        const self: *Backend = @ptrCast(@alignCast(context));
        const connection: *Connection = @ptrCast(@alignCast(carrier.userData() orelse return));
        carrier.setUserData(null);
        for (self.connections.items, 0..) |item, i| if (item == connection) {
            _ = self.connections.swapRemove(i);
            break;
        };
        self.free(connection);
    }

    fn onMessage(context: *anyopaque, carrier: *raknet.Session, payload: raknet.BorrowedPayload) error{ApplicationFailure}!void {
        const self: *Backend = @ptrCast(@alignCast(context));
        const connection: *Connection = @ptrCast(@alignCast(carrier.userData() orelse return error.ApplicationFailure));
        self.handle(connection, carrier, payload.bytes) catch return error.ApplicationFailure;
    }

    fn send(session: *Session, carrier: *raknet.Session, packets: []const []const u8) !void {
        const frame = try session.encode(packets);
        defer frame.release();
        try carrier.send(frame.bytes, .reliable_ordered, 0);
    }

    fn handle(self: *Backend, connection: *Connection, carrier: *raknet.Session, frame: []const u8) !void {
        const session = &connection.session;
        var packets = try session.ingest(frame);
        defer packets.deinit();
        var buffer: [512]u8 = undefined;
        self.packets.clearRetainingCapacity();
        while (packets.next()) |packet| switch (packet.kind orelse {
            self.packets.appendAssumeCapacity(packet.bytes);
            continue;
        }) {
            .request_network_settings => {
                try send(session, carrier, &.{try sample.typedPacket(&buffer, .{ .network_settings = .{
                    .compression_threshold = 256,
                    .compression_algorithm = .zlib,
                    .client_throttle_enabled = false,
                    .client_throttle_threshold = 0,
                    .client_throttle_scalar = 0,
                } })});
                try session.negotiateCompression(.deflate, 256);
            },
            .login => {
                var identity = try session.authenticateLoginPacket(self.gpa, packet, .{ .certificate_chain = .{
                    .now = std.Io.Clock.real.now(self.io).toSeconds(),
                    .trusted_issuer_key = self.trusted,
                } });
                identity.deinit();
                const salt: [16]u8 = @splat(7);
                const token = try bedwire.auth.login.serverHandshake(self.gpa, connection.key, salt, limits);
                defer self.gpa.free(token);
                const storage = try self.gpa.alloc(u8, token.len + 16);
                defer self.gpa.free(storage);
                try send(session, carrier, &.{try sample.typedPacket(storage, .{ .server_to_client_handshake = .{ .handshake_web_token = token } })});
                try session.installServerCrypto(connection.key.secret_key, salt);
            },
            .client_to_server_handshake => {
                try session.advance(.resource_packs);
                try send(session, carrier, &.{try sample.typedPacket(&buffer, .{ .play_status = .{ .status = .loginsuccess } })});
            },
            .resource_pack_client_response => {
                try session.advance(.waiting_for_start_game);
                var start_buffer: [1024]u8 = undefined;
                var items_buffer: [256]u8 = undefined;
                try send(session, carrier, &.{
                    try sample.startGame(&start_buffer, .{}),
                    try sample.itemRegistry(&items_buffer, .{}),
                    &sample.biome_definitions,
                });
                try session.advance(.spawn_ready);
            },
            .set_local_player_as_initialised => try session.advance(.in_game),
            else => {},
        };
        if (self.packets.items.len != 0) try send(session, carrier, self.packets.items);
    }
};
