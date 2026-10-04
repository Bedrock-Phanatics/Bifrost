const std = @import("std");
const raknet = @import("raknet");
const bifrost = @import("bifrost");

const gpa = std.testing.allocator;
const IpAddress = std.Io.net.IpAddress;

pub const loopback: IpAddress = .{ .ip4 = .loopback(0) };
pub const nowhere: IpAddress = .{ .ip4 = .loopback(9) };
pub const kick = "\xfekick";

pub fn millis(ms: i64) std.Io.Timeout {
    return .{ .duration = .{ .raw = .fromMilliseconds(ms), .clock = .awake } };
}

pub fn config(backends: []const IpAddress) !bifrost.Config {
    var result: bifrost.Config = .{ .bind = loopback, .max_players = 8, .connect_timeout_ms = 500 };
    for (backends) |backend| try result.addBackend(null, backend);
    return result;
}

pub fn silent(io: std.Io) !std.Io.net.Socket {
    return loopback.bind(io, .{ .mode = .dgram, .protocol = .udp });
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
    listener: *raknet.Server,
    task: ?std.Io.Future(void) = null,
    stopping: std.atomic.Value(bool) = .init(false),
    greeting: ?[]const u8,
    replies: []const []const u8,
    replied: usize = 0,
    received: std.atomic.Value(u32) = .init(0),
    connects: std.atomic.Value(u32) = .init(0),
    disconnects: std.atomic.Value(u32) = .init(0),

    pub const Options = struct {
        advertisement: []const u8 = "MCPE;backend",
        greeting: ?[]const u8 = null,
        replies: []const []const u8 = &.{},
        serving: bool = true,
    };

    pub fn start(self: *Backend, io: std.Io, options: Options) !void {
        self.* = .{
            .io = io,
            .listener = try raknet.Server.listen(gpa, io, loopback, .{ .advertisement = options.advertisement }),
            .greeting = options.greeting,
            .replies = options.replies,
        };
        errdefer self.listener.destroy();
        if (options.serving) try self.serve();
    }

    pub fn deinit(self: *Backend) void {
        self.pause();
        self.listener.destroy();
    }

    pub fn address(self: *const Backend) IpAddress {
        return self.listener.localAddress();
    }

    pub fn serve(self: *Backend) !void {
        self.stopping.store(false, .release);
        self.task = try self.io.concurrent(run, .{self});
    }

    pub fn pause(self: *Backend) void {
        var task = self.task orelse return;
        self.stopping.store(true, .release);
        task.await(self.io);
        self.task = null;
    }

    fn run(self: *Backend) void {
        while (!self.stopping.load(.acquire)) {
            _ = self.listener.poll(millis(5), .{
                .context = self,
                .connected = onConnected,
                .message = onMessage,
                .disconnected = onDisconnected,
            }) catch {};
        }
    }

    fn onConnected(context: *anyopaque, session: *raknet.Session) error{ApplicationFailure}!void {
        const self: *Backend = @ptrCast(@alignCast(context));
        _ = self.connects.fetchAdd(1, .release);
        if (self.greeting) |greeting| session.send(greeting, .reliable_ordered, 0) catch return error.ApplicationFailure;
    }

    fn onMessage(context: *anyopaque, session: *raknet.Session, payload: raknet.BorrowedPayload) error{ApplicationFailure}!void {
        const self: *Backend = @ptrCast(@alignCast(context));
        _ = self.received.fetchAdd(1, .release);
        if (std.mem.eql(u8, payload.bytes, kick)) return session.close();
        var reply = payload.bytes;
        if (self.replied < self.replies.len) {
            reply = self.replies[self.replied];
            self.replied += 1;
        }
        session.send(reply, .reliable_ordered, 0) catch return error.ApplicationFailure;
    }

    fn onDisconnected(context: *anyopaque, _: *raknet.Session) void {
        const self: *Backend = @ptrCast(@alignCast(context));
        _ = self.disconnects.fetchAdd(1, .release);
    }
};

pub const Running = struct {
    io: std.Io,
    proxy: *bifrost.Proxy,
    task: std.Io.Future(void),
    stopped: bool = false,

    pub fn start(self: *Running, io: std.Io, proxy_config: bifrost.Config, options: bifrost.Proxy.Options) !void {
        const proxy = try bifrost.Proxy.create(gpa, io, proxy_config, options);
        errdefer proxy.destroy();
        self.* = .{ .io = io, .proxy = proxy, .task = try io.concurrent(bifrost.Proxy.run, .{proxy}) };
    }

    pub fn stop(self: *Running) void {
        if (self.stopped) return;
        self.stopped = true;
        self.proxy.stop();
        self.task.await(self.io);
    }

    pub fn deinit(self: *Running) void {
        self.stop();
        self.proxy.destroy();
    }

    pub fn address(self: *const Running) IpAddress {
        return self.proxy.localAddress();
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
        const workers = try bifrost.Workers.create(gpa, io, workers_config, .off);
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

pub const Player = struct {
    io: std.Io,
    client: *raknet.Client,
    received: std.ArrayList(u8) = .empty,
    got_message: bool = false,

    pub fn connect(io: std.Io, address: IpAddress) !Player {
        return .{ .io = io, .client = try raknet.Client.connect(gpa, io, address, .{ .handshake_retry_ms = 10 }) };
    }

    pub fn deinit(self: *Player) void {
        self.client.destroy();
        self.received.deinit(gpa);
    }

    pub fn send(self: *Player, payload: []const u8) !void {
        try self.client.send(payload, .reliable_ordered, 0);
    }

    pub fn roundTrip(self: *Player, payload: []const u8) !void {
        try self.send(payload);
        try self.expect(payload);
    }

    pub fn expect(self: *Player, payload: []const u8) !void {
        self.got_message = false;
        const started = std.Io.Clock.awake.now(self.io);
        while (started.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds() < 4_000) {
            _ = self.client.poll(millis(10), self, collect) catch |err| switch (err) {
                error.Timeout => {},
                else => return err,
            };
            if (self.got_message) return std.testing.expectEqualSlices(u8, payload, self.received.items);
        }
        return error.NoMessage;
    }

    pub fn awaitClosed(self: *Player) !void {
        const started = std.Io.Clock.awake.now(self.io);
        while (started.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds() < 10_000) {
            _ = self.client.poll(millis(10), self, collect) catch |err| switch (err) {
                error.Timeout => {},
                else => return,
            };
            if (self.client.isClosed()) return;
        }
        return error.NotClosed;
    }

    fn collect(context: *anyopaque, payload: raknet.BorrowedPayload) error{ApplicationFailure}!void {
        const self: *Player = @ptrCast(@alignCast(context));
        self.received.clearRetainingCapacity();
        self.received.appendSlice(gpa, payload.bytes) catch return error.ApplicationFailure;
        self.got_message = true;
    }
};
