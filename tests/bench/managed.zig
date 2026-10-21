const std = @import("std");
const bedwire = @import("bedwire");
const bifrost = @import("bifrost");
const sample = @import("sample");
const net = @import("net");
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
        self.session = try .init(.client, .{ .pool = &self.pool, .policy = bifrost.Managed.session_policy });
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

    fn send(self: *Bedrock, connection: *net.Connection, packet: []const u8) !void {
        const frame = try self.session.encodeOne(packet);
        defer frame.release();
        try connection.send(frame.bytes, .reliable);
    }
};

/// Connects with a proven key and logs in all the way to in-game.
pub fn join(gpa: std.mem.Allocator, io: std.Io, player: *harness.Player, address: std.Io.net.IpAddress, seed: u8) !void {
    const bedrock = try Bedrock.create(gpa, seed);
    errdefer bedrock.destroy();
    const token = try sample.transportToken(gpa, bedrock.key, std.Io.Clock.real.now(io).toSeconds());
    defer gpa.free(token);
    try player.connectAs(gpa, io, address, .{ .key = bedrock.key, .token = token });
    errdefer player.connection.destroy();
    const connection = player.connection;
    var buffer: [64]u8 = undefined;
    const session = &bedrock.session;

    try bedrock.send(connection, try sample.typedPacket(&buffer, .{ .request_network_settings = .{ .client_network_version = @intCast(Current.protocol_number) } }));
    {
        var packets = try session.ingest(try next(connection));
        defer packets.deinit();
        try session.negotiateFromSettings(packets.next() orelse return error.NoPacket);
    }
    const request = try sample.request(gpa, bedrock.key, bedrock.key, "Bench", "2535400000000001", std.Io.Clock.real.now(io).toSeconds());
    defer gpa.free(request);
    try bedrock.send(connection, try bedwire.auth.login.encodeLoginPacket(Current, bedrock.scratch, request, limits));
    try expectKind(session, try next(connection), .play_status);
    try bedrock.send(connection, try sample.typedPacket(&buffer, .{ .resource_pack_client_response = .{ .response = .{ .resource_pack_stack_finished = "" } } }));
    try session.advance(.waiting_for_start_game);
    try expectKind(session, try next(connection), .start_game);
    try session.advance(.spawn_ready);
    try bedrock.send(connection, try sample.rawPacket(&buffer, Current.packetId(.set_local_player_as_initialised).?, &.{1}));
    try session.advance(.in_game);
    player.bedrock = bedrock;
}

fn next(connection: *net.Connection) ![]const u8 {
    const message = (try net.receive(connection, 5_000)) orelse return error.ReplyTimedOut;
    return message.data;
}

fn expectKind(session: *bedwire.Session, frame: []const u8, kind: bedwire.PacketKind) !void {
    var packets = try session.ingest(frame);
    defer packets.deinit();
    const packet = packets.next() orelse return error.NoPacket;
    if (packet.kind != kind) return error.UnexpectedPacket;
}

pub const Backend = struct {
    const Session = bifrost.Managed.BackendSession;

    gpa: std.mem.Allocator,
    io: std.Io,
    server: net.Server = undefined,
    pool: bedwire.BufferPool,
    trusted: Ecdsa.PublicKey,
    task: ?std.Io.Future(void) = null,
    stopping: std.atomic.Value(bool) = .init(false),
    packets: std.ArrayList([]const u8) = .empty,

    pub fn start(self: *Backend, gpa: std.mem.Allocator, io: std.Io) !void {
        self.* = .{
            .gpa = gpa,
            .io = io,
            .pool = undefined,
            .trusted = proxyKey().public_key,
        };
        self.pool = try .init(gpa, limits, .{ .rx_slots = 1, .tx_slots = 1 });
        errdefer self.pool.deinit();
        try self.packets.ensureTotalCapacity(gpa, limits.max_packets_per_batch);
        errdefer self.packets.deinit(gpa);
        try self.server.start(gpa, io, harness.loopback(0), null);
        errdefer self.server.deinit();
        self.task = try io.concurrent(run, .{self});
    }

    pub fn deinit(self: *Backend) void {
        if (self.task) |*task| {
            self.stopping.store(true, .release);
            self.server.wakeup.signal(self.io);
            task.await(self.io);
        }
        for (self.server.clients.items) |client| self.free(client);
        self.server.deinit();
        self.packets.deinit(self.gpa);
        self.pool.deinit();
    }

    pub fn port(self: *const Backend) u16 {
        return self.server.address().getPort();
    }

    fn run(self: *Backend) void {
        while (!self.stopping.load(.acquire)) self.server.poll(5, self);
    }

    fn free(self: *Backend, client: *net.Server.Client) void {
        const session: *Session = @ptrCast(@alignCast(client.user orelse return));
        client.user = null;
        session.deinit();
        self.gpa.destroy(session);
    }

    pub fn connected(self: *Backend, client: *net.Server.Client) !void {
        const session = try self.gpa.create(Session);
        errdefer self.gpa.destroy(session);
        session.* = try Session.init(.server, .{ .pool = &self.pool, .policy = bifrost.Managed.session_policy });
        client.user = session;
    }

    pub fn disconnected(self: *Backend, client: *net.Server.Client) void {
        self.free(client);
    }

    fn send(session: *Session, client: *net.Server.Client, packets: []const []const u8) !void {
        const frame = try session.encode(packets);
        defer frame.release();
        try client.send(frame.bytes);
    }

    pub fn message(self: *Backend, client: *net.Server.Client, frame: []const u8) !void {
        const session: *Session = @ptrCast(@alignCast(client.user orelse return error.UnknownClient));
        var packets = try session.ingest(frame);
        defer packets.deinit();
        var buffer: [512]u8 = undefined;
        self.packets.clearRetainingCapacity();
        while (packets.next()) |packet| switch (packet.kind orelse {
            self.packets.appendAssumeCapacity(packet.bytes);
            continue;
        }) {
            .request_network_settings => {
                try send(session, client, &.{try sample.typedPacket(&buffer, .{ .network_settings = .{
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
                try session.advance(.resource_packs);
                try send(session, client, &.{try sample.typedPacket(&buffer, .{ .play_status = .{ .status = .loginsuccess } })});
            },
            .resource_pack_client_response => {
                try session.advance(.waiting_for_start_game);
                var start_buffer: [1024]u8 = undefined;
                var items_buffer: [256]u8 = undefined;
                try send(session, client, &.{
                    try sample.startGame(&start_buffer, .{}),
                    try sample.itemRegistry(&items_buffer, .{}),
                    &sample.biome_definitions,
                });
                try session.advance(.spawn_ready);
            },
            .set_local_player_as_initialised => try session.advance(.in_game),
            .text => self.packets.appendAssumeCapacity(packet.bytes),
            else => {},
        };
        if (self.packets.items.len != 0) send(session, client, self.packets.items) catch |err| if (err != error.Backpressure) return err;
    }
};
