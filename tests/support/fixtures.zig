const std = @import("std");
const nethernet = @import("nethernet");
const bifrost = @import("bifrost");
const net = @import("net.zig");
const oidc_key = @import("oidc_key.zig");
const sample = @import("sample.zig");

const gpa = std.testing.allocator;
const IpAddress = std.Io.net.IpAddress;

pub const loopback = net.loopback;
pub const nowhere: IpAddress = .{ .ip4 = .loopback(9) };
pub const kick = "\xfekick";
pub const burst = "\xfeburst";

pub fn millis(ms: i64) std.Io.Timeout {
    return .{ .duration = .{ .raw = .fromMilliseconds(ms), .clock = .awake } };
}

pub fn config(backends: []const IpAddress) !bifrost.Config {
    var result: bifrost.Config = .{ .bind = loopback, .max_players = 8, .connect_timeout_ms = 500 };
    for (backends) |backend| try result.addBackend(null, backend);
    return result;
}

/// Takes TCP connections and never answers them, so signaling to it hangs until the dial gives up.
pub const Silent = struct {
    server: std.Io.net.Server,
    address: IpAddress,

    pub fn close(self: Silent, io: std.Io) void {
        var server = self.server;
        server.deinit(io);
    }
};

pub fn silent(io: std.Io) !Silent {
    return silentAt(io, loopback);
}

fn silentAt(io: std.Io, address: IpAddress) !Silent {
    const server = try address.listen(io, .{ .reuse_address = true });
    return .{ .server = server, .address = server.socket.address };
}

pub fn waitFor(io: std.Io, counter: *const std.atomic.Value(u32), value: u32) !void {
    for (0..500) |_| {
        if (counter.load(.acquire) == value) return;
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    return error.WaitTimedOut;
}

pub fn eventually(io: std.Io, context: anytype, comptime check: fn (@TypeOf(context)) bool) !void {
    for (0..400) |_| {
        if (check(context)) return;
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    return error.WaitTimedOut;
}

pub const Backend = struct {
    io: std.Io,
    server: net.Server = undefined,
    serving: bool = false,
    parked: ?Silent = null,
    bound: IpAddress = loopback,
    task: ?std.Io.Future(void) = null,
    stopping: std.atomic.Value(bool) = .init(false),
    greeting: ?[]const u8,
    replies: []const []const u8,
    replied: usize = 0,
    players: std.atomic.Value(u32),
    received: std.atomic.Value(u32) = .init(0),
    connects: std.atomic.Value(u32) = .init(0),
    disconnects: std.atomic.Value(u32) = .init(0),
    burst_count: u32,
    burst_bytes: u32,

    pub const Options = struct {
        // What its server list status reports
        players: u32 = 0,
        greeting: ?[]const u8 = null,
        replies: []const []const u8 = &.{},
        serving: bool = true,
        // Sent back in one go when a player sends `burst`, each with its little-endian u32 index after the 0xfe
        burst_count: u32 = 0,
        burst_bytes: u32 = 1024,
    };

    pub fn start(self: *Backend, io: std.Io, options: Options) !void {
        self.* = .{
            .io = io,
            .greeting = options.greeting,
            .replies = options.replies,
            .players = .init(options.players),
            .burst_count = options.burst_count,
            .burst_bytes = options.burst_bytes,
        };
        if (options.serving) return self.serve();
        // Holds the port so serve() can come back on the same address
        self.parked = try silent(io);
        self.bound = self.parked.?.address;
    }

    pub fn deinit(self: *Backend) void {
        self.pause();
        if (self.parked) |parked| parked.close(self.io);
    }

    pub fn address(self: *const Backend) IpAddress {
        return self.bound;
    }

    pub fn serve(self: *Backend) !void {
        if (self.serving) return;
        if (self.parked) |parked| parked.close(self.io);
        self.parked = null;
        try self.server.start(gpa, self.io, self.bound, .{ .context = self, .get = status });
        self.bound = self.server.address();
        self.serving = true;
        self.stopping.store(false, .release);
        self.task = try self.io.concurrent(run, .{self});
    }

    /// Stops answering and drops everyone, like a crashed server.
    pub fn pause(self: *Backend) void {
        if (!self.serving) return;
        self.stopping.store(true, .release);
        self.server.wakeup.signal(self.io);
        if (self.task) |*task| task.await(self.io);
        self.task = null;
        self.server.deinit();
        self.serving = false;
    }

    fn status(context: ?*anyopaque) anyerror!nethernet.EndpointServerStatus {
        const self: *Backend = @ptrCast(@alignCast(context.?));
        return .{ .name = "backend", .protocol = 1, .version = "1", .level = "test", .players = self.players.load(.monotonic), .max_players = 100, .game_type = 0 };
    }

    fn run(self: *Backend) void {
        while (!self.stopping.load(.acquire)) self.server.poll(50, self);
    }

    pub fn connected(self: *Backend, client: *net.Server.Client) !void {
        _ = self.connects.fetchAdd(1, .release);
        if (self.greeting) |greeting| try client.send(greeting);
    }

    pub fn message(self: *Backend, client: *net.Server.Client, payload: []const u8) !void {
        _ = self.received.fetchAdd(1, .release);
        if (std.mem.eql(u8, payload, kick)) return client.close();
        if (std.mem.eql(u8, payload, burst)) {
            var buffer: [64 * 1024]u8 = @splat(0xfe);
            for (0..self.burst_count) |i| {
                std.mem.writeInt(u32, buffer[1..5], @intCast(i), .little);
                try client.send(buffer[0..self.burst_bytes]);
            }
            return;
        }
        var reply = payload;
        if (self.replied < self.replies.len) {
            reply = self.replies[self.replied];
            self.replied += 1;
        }
        // Echoes are best effort, so a closing proxy can still hand over everything it sent
        client.send(reply) catch {};
    }

    pub fn disconnected(self: *Backend, _: *net.Server.Client) void {
        _ = self.disconnects.fetchAdd(1, .release);
    }
};

/// Dials with a token from the test issuer vouching for `key`.
pub fn dialAs(io: std.Io, address: IpAddress, key: net.KeyPair) !*net.Connection {
    const token = try sample.transportToken(gpa, key, std.Io.Clock.real.now(io).toSeconds());
    defer gpa.free(token);
    return net.dial(gpa, io, address, .{ .key = key, .token = token });
}

pub fn identity(io: std.Io) bifrost.NetherNet.KeyPair {
    return .generate(io);
}

/// One worker with its own listener, the shape most tests need.
pub const Running = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    transport: bifrost.NetherNet,
    proxy: *bifrost.Proxy,
    listener: *bifrost.Listener,
    task: std.Io.Future(void),
    stopped: bool = false,

    pub const Options = struct {
        auth: bifrost.Auth = .off,
        admission: ?*bifrost.Admission = null,
        health: ?*bifrost.Health = null,
        proxy_key: ?bifrost.Managed.Ecdsa.KeyPair = null,
        plugins: ?*bifrost.Plugins = null,
        worker: u32 = 0,
    };

    pub fn start(self: *Running, io: std.Io, proxy_config: bifrost.Config, options: Options) !void {
        return self.startWith(io, gpa, proxy_config, options);
    }

    pub fn startWith(self: *Running, io: std.Io, allocator: std.mem.Allocator, proxy_config: bifrost.Config, options: Options) !void {
        self.io = io;
        self.allocator = allocator;
        self.stopped = false;
        try self.transport.init(allocator, io, .{
            .identity = identity(io),
            .dial_identity = bifrost.Workers.dialIdentity(io, options.auth, options.proxy_key),
            .issuer_keys = if (options.auth == .verify) oidc_key.jwks_json else null,
            .connect_timeout_ms = proxy_config.connect_timeout_ms,
        });
        errdefer self.transport.deinit();
        self.proxy = try bifrost.Proxy.create(allocator, io, proxy_config, .{
            .transport = &self.transport,
            .auth = options.auth,
            .admission = options.admission,
            .health = options.health,
            .proxy_key = options.proxy_key,
            .plugins = options.plugins,
            .worker = options.worker,
        });
        errdefer self.proxy.destroy();
        self.listener = try bifrost.Listener.start(allocator, io, &self.transport, proxy_config.bind, .{ .context = self, .accept = adopt }, .{ .max_negotiations = 64, .max_negotiations_per_ip = 64 });
        errdefer self.listener.destroy(allocator);
        self.task = try io.concurrent(bifrost.Proxy.run, .{self.proxy});
    }

    fn adopt(context: *anyopaque, connection: *bifrost.NetherNet.Connection) void {
        const self: *Running = @ptrCast(@alignCast(context));
        self.proxy.adopt(connection) catch connection.destroy();
    }

    pub fn stop(self: *Running) void {
        if (self.stopped) return;
        self.stopped = true;
        self.proxy.stop();
        self.task.await(self.io);
    }

    pub fn deinit(self: *Running) void {
        self.stop();
        self.listener.destroy(self.allocator);
        self.proxy.destroy();
        self.transport.deinit();
    }

    pub fn address(self: *const Running) IpAddress {
        return self.listener.localAddress();
    }

    pub fn stats(self: *const Running) bifrost.Stats {
        std.debug.assert(self.stopped);
        return self.proxy.stats;
    }

    pub fn waitForStat(self: *const Running, comptime field: std.meta.FieldEnum(bifrost.Stats), value: u64) !void {
        for (0..500) |_| {
            if (@field(self.proxy.stats.snapshot(), @tagName(field)) == value) return;
            try self.io.sleep(.fromMilliseconds(10), .awake);
        }
        return error.WaitTimedOut;
    }
};

pub const RunningWorkers = struct {
    const RunResult = @typeInfo(@TypeOf(bifrost.Workers.run)).@"fn".return_type.?;

    io: std.Io,
    workers: *bifrost.Workers,
    task: std.Io.Future(RunResult),
    stopped: bool = false,

    pub fn start(self: *RunningWorkers, io: std.Io, workers_config: bifrost.Config) !void {
        const workers = try bifrost.Workers.create(gpa, io, workers_config, .{ .identity = identity(io) });
        errdefer workers.destroy();
        self.* = .{ .io = io, .workers = workers, .task = try io.concurrent(bifrost.Workers.run, .{workers}) };
    }

    pub fn stop(self: *RunningWorkers) !void {
        if (self.stopped) return;
        self.stopped = true;
        self.workers.stop();
        try self.task.await(self.io);
    }

    pub fn deinit(self: *RunningWorkers) void {
        self.stop() catch {};
        self.workers.destroy();
    }

    pub fn address(self: *const RunningWorkers) IpAddress {
        return self.workers.localAddress();
    }

    pub fn totals(self: *const RunningWorkers) bifrost.Stats {
        std.debug.assert(self.stopped);
        return self.workers.totals();
    }
};

/// A passthrough player, sending raw messages.
pub const Player = struct {
    io: std.Io,
    connection: *net.Connection,
    received: std.ArrayList(u8) = .empty,

    pub fn connect(io: std.Io, address: IpAddress) !Player {
        return .{ .io = io, .connection = try net.dial(gpa, io, address, null) };
    }

    /// Proves `key` at the transport, as a signed-in client does.
    pub fn connectAs(io: std.Io, address: IpAddress, key: net.KeyPair) !Player {
        return .{ .io = io, .connection = try dialAs(io, address, key) };
    }

    pub fn deinit(self: *Player) void {
        self.connection.destroy();
        self.received.deinit(gpa);
    }

    pub fn send(self: *Player, payload: []const u8) !void {
        try self.connection.send(payload, .reliable);
    }

    pub fn roundTrip(self: *Player, payload: []const u8) !void {
        try self.send(payload);
        try self.expect(payload);
    }

    pub fn expect(self: *Player, payload: []const u8) !void {
        try std.testing.expectEqualSlices(u8, payload, try self.next(4_000));
    }

    /// The next message, copied so it outlives later reads.
    pub fn next(self: *Player, timeout_ms: i64) ![]const u8 {
        const message = (try net.receive(self.connection, timeout_ms)) orelse return error.NoMessage;
        self.received.clearRetainingCapacity();
        try self.received.appendSlice(gpa, message.data);
        return self.received.items;
    }

    pub fn awaitClosed(self: *Player) !void {
        return net.awaitClosed(self.connection);
    }

    /// Lets everything already sent arrive first, like a client quitting.
    pub fn leave(self: *Player) !void {
        try self.connection.closeGracefully();
    }

    pub fn isClosed(self: *Player) bool {
        return net.closed(self.connection);
    }
};
