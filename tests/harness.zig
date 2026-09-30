const std = @import("std");
const raknet = @import("raknet");
const bifrost = @import("bifrost");

const gpa = std.testing.allocator;
pub const loopback: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };

pub fn millis(ms: i64) std.Io.Timeout {
    return .{ .duration = .{ .raw = .fromMilliseconds(ms), .clock = .awake } };
}

pub const kick = "\xfekick";

/// Answers with `replies` in order, then echoes. Closes the session on `kick`.
pub const EchoBackend = struct {
    listener: *raknet.Server,
    greeting: ?[]const u8 = null,
    replies: []const []const u8 = &.{},
    replied: usize = 0,
    received: std.atomic.Value(u32) = .init(0),
    stop: std.atomic.Value(bool) = .init(false),
    connects: std.atomic.Value(u32) = .init(0),
    disconnects: std.atomic.Value(u32) = .init(0),

    pub fn start(io: std.Io) !EchoBackend {
        const listener = try raknet.Server.listen(gpa, io, loopback, .{ .advertisement = "MCPE;backend" });
        return .{ .listener = listener };
    }

    pub fn run(self: *EchoBackend) void {
        while (!self.stop.load(.acquire)) {
            _ = self.listener.poll(millis(5), .{
                .context = self,
                .connected = onConnected,
                .message = onMessage,
                .disconnected = onDisconnected,
            }) catch {};
        }
    }

    pub fn address(self: *const EchoBackend) std.Io.net.IpAddress {
        return self.listener.socket.value.address;
    }

    fn onConnected(context: *anyopaque, session: *raknet.Session) error{ApplicationFailure}!void {
        const self: *EchoBackend = @ptrCast(@alignCast(context));
        _ = self.connects.fetchAdd(1, .release);
        if (self.greeting) |greeting| session.send(greeting, .reliable_ordered, 0) catch return error.ApplicationFailure;
    }

    fn onMessage(context: *anyopaque, session: *raknet.Session, payload: raknet.BorrowedPayload) error{ApplicationFailure}!void {
        const self: *EchoBackend = @ptrCast(@alignCast(context));
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
        const self: *EchoBackend = @ptrCast(@alignCast(context));
        _ = self.disconnects.fetchAdd(1, .release);
    }
};

pub const Player = struct {
    client: *raknet.Client,
    received: std.ArrayList(u8) = .empty,
    got_message: bool = false,

    pub fn connect(io: std.Io, proxy: *const bifrost.Proxy) !Player {
        const client = try raknet.Client.connect(gpa, io, proxy.localAddress(), .{ .handshake_retry_ms = 10 });
        return .{ .client = client };
    }

    pub fn deinit(self: *Player) void {
        self.client.destroy();
        self.received.deinit(gpa);
    }

    fn collect(context: *anyopaque, payload: raknet.BorrowedPayload) error{ApplicationFailure}!void {
        const self: *Player = @ptrCast(@alignCast(context));
        self.received.clearRetainingCapacity();
        self.received.appendSlice(gpa, payload.bytes) catch return error.ApplicationFailure;
        self.got_message = true;
    }

    pub fn roundTrip(self: *Player, payload: []const u8) !void {
        try self.client.send(payload, .reliable_ordered, 0);
        try self.expect(payload);
    }

    pub fn expect(self: *Player, payload: []const u8) !void {
        self.got_message = false;
        for (0..400) |_| {
            _ = self.client.poll(millis(10), self, collect) catch |err| switch (err) {
                error.Timeout => {},
                else => return err,
            };
            if (self.got_message) return std.testing.expectEqualSlices(u8, payload, self.received.items);
        }
        return error.NoMessage;
    }

    pub fn awaitClosed(self: *Player) !void {
        for (0..1000) |_| {
            _ = self.client.poll(millis(10), self, collect) catch |err| switch (err) {
                error.Timeout => {},
                else => return,
            };
            if (self.client.isClosed()) return;
        }
        return error.NotClosed;
    }
};

pub fn testConfig(backend: std.Io.net.IpAddress) !bifrost.Config {
    var config: bifrost.Config = .{ .bind = loopback, .max_players = 8, .connect_timeout_ms = 500 };
    try config.addBackend(backend);
    return config;
}

pub fn waitFor(io: std.Io, flag: *const std.atomic.Value(u32), value: u32) !void {
    for (0..500) |_| {
        if (flag.load(.acquire) == value) return;
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    return error.WaitTimedOut;
}
