//! NetherNet ends for tests and benchmarks: a poll-style server standing in for backends, and dialing players.
const std = @import("std");
const nethernet = @import("nethernet");

const IpAddress = std.Io.net.IpAddress;
pub const Connection = nethernet.Connection;
pub const Message = nethernet.Message;
pub const KeyPair = nethernet.IdentityKeyPair;

pub const loopback: IpAddress = .{ .ip4 = .loopback(0) };
const max_message_bytes = 4 * 1024 * 1024;

/// A key the player proves and the token vouching for it.
pub const Identity = struct {
    key: KeyPair,
    token: []const u8,
};

/// Dials like a vanilla client, anonymously unless given an identity.
pub fn dial(gpa: std.mem.Allocator, io: std.Io, address: IpAddress, identity: ?Identity) !*Connection {
    var origin_buffer: [64]u8 = undefined;
    const origin = try std.fmt.bufPrint(&origin_buffer, "http://{f}", .{address});
    var id: [8]u8 = undefined;
    io.random(&id);
    return nethernet.dialEndpoint(gpa, io, origin, std.mem.readInt(u64, &id, .little), .{
        .maximum_message_size = max_message_bytes,
        .negotiation_timeout_ms = 10_000,
        .connection_timeout_ms = 10_000,
        .allow_anonymous = true,
        .native = .{ .maximum_message_size = max_message_bytes },
        .identity = if (identity) |proof| .{ .key = proof.key, .token = proof.token, .domain = "player" } else null,
    });
}

/// Null when nothing arrived in time.
pub fn receive(connection: *Connection, timeout_ms: i64) !?Message {
    const io = connection.io;
    const deadline = std.Io.Clock.awake.now(io).addDuration(.fromMilliseconds(timeout_ms));
    while (true) {
        const token = connection.prepareWait();
        while (try connection.poll()) |event| switch (event) {
            .message => |message| return message,
            .signal => {},
        };
        const left = std.Io.Clock.awake.now(io).durationTo(deadline);
        if (left.nanoseconds <= 0) return null;
        try connection.peer.wakeup.wait(io, token, .{ .duration = .{ .raw = left, .clock = .awake } });
    }
}

pub fn closed(connection: *Connection) bool {
    return switch (connection.state()) {
        .closed, .failed, .disconnected => true,
        else => false,
    };
}

/// Waits until the far end goes away, reading and dropping anything still in flight.
pub fn awaitClosed(connection: *Connection) !void {
    const started = std.Io.Clock.awake.now(connection.io);
    while (started.durationTo(std.Io.Clock.awake.now(connection.io)).toMilliseconds() < 10_000) {
        _ = receive(connection, 20) catch return;
        if (closed(connection)) return;
    }
    return error.NotClosed;
}

/// Accepts connections in the background; `poll` hands them and their messages to callbacks on the caller's task.
pub const Server = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    listener: *nethernet.EndpointListener,
    accept_task: ?std.Io.Future(void) = null,
    mutex: std.Io.Mutex = .init,
    arrived: std.ArrayList(*Connection) = .empty,
    wakeup: nethernet.Wakeup = .{},
    clients: std.ArrayList(*Client) = .empty,
    dialer: ?PublicKey = null,

    pub const PublicKey = nethernet.identity.Scheme.PublicKey;

    pub const Client = struct {
        connection: *Connection,
        user: ?*anyopaque = null,

        pub fn send(self: *Client, bytes: []const u8) !void {
            try self.connection.send(bytes, .reliable);
        }

        pub fn close(self: *Client) void {
            self.connection.close();
        }
    };

    pub fn start(self: *Server, gpa: std.mem.Allocator, io: std.Io, address_: IpAddress, status: ?nethernet.EndpointStatusProvider) !void {
        self.* = .{
            .gpa = gpa,
            .io = io,
            .listener = try nethernet.EndpointListener.listen(gpa, io, address_, .{
                .connection = .{
                    .allow_anonymous = true,
                    .verify_client = .{ .context = self, .verify = recordDialer },
                    .maximum_message_size = max_message_bytes,
                    .native = .{ .maximum_message_size = max_message_bytes },
                },
                .maximum_negotiations = 256,
                .maximum_http_workers = 256,
                .maximum_pending_accepts = 1024,
                .status_provider = status,
            }),
        };
        errdefer self.listener.destroy();
        self.accept_task = try io.concurrent(acceptAll, .{self});
    }

    pub fn deinit(self: *Server) void {
        if (self.accept_task) |*task| task.cancel(self.io);
        self.listener.destroy();
        for (self.arrived.items) |connection| connection.destroy();
        self.arrived.deinit(self.gpa);
        for (self.clients.items) |client| {
            client.connection.destroy();
            self.gpa.destroy(client);
        }
        self.clients.deinit(self.gpa);
    }

    pub fn address(self: *const Server) IpAddress {
        return self.listener.server.socket.address;
    }

    /// The key the most recent identified dialer proved.
    pub fn lastDialer(self: *Server) ?PublicKey {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.dialer;
    }

    fn recordDialer(context: ?*anyopaque, token: []const u8) anyerror!?PublicKey {
        const self: *Server = @ptrCast(@alignCast(context.?));
        const key = try nethernet.identity.claimPublicKey(self.gpa, token, std.Io.Clock.real.now(self.io).toSeconds(), .server);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.dialer = key;
        return key;
    }

    fn acceptAll(self: *Server) void {
        while (true) {
            const connection = self.listener.accept() catch return;
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.arrived.append(self.gpa, connection) catch {
                connection.destroy();
                continue;
            };
            self.wakeup.signal(self.io);
        }
    }

    /// `handler` has connected(*Client) !void, message(*Client, []const u8) !void and disconnected(*Client) void.
    pub fn poll(self: *Server, timeout_ms: i64, handler: anytype) void {
        const token = self.wakeup.prepare();
        var busy = false;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            for (self.arrived.items) |connection| {
                const client = self.gpa.create(Client) catch {
                    connection.destroy();
                    continue;
                };
                client.* = .{ .connection = connection };
                self.clients.append(self.gpa, client) catch {
                    connection.destroy();
                    self.gpa.destroy(client);
                    continue;
                };
                connection.peer.subscribe(&self.wakeup);
                handler.connected(client) catch client.close();
                busy = true;
            }
            self.arrived.clearRetainingCapacity();
        }
        var i: usize = 0;
        while (i < self.clients.items.len) {
            const client = self.clients.items[i];
            const gone = while (true) {
                const event = client.connection.poll() catch break true;
                const message = switch (event orelse break false) {
                    .message => |message| message,
                    .signal => continue,
                };
                busy = true;
                handler.message(client, message.data) catch client.close();
            };
            if (gone) {
                handler.disconnected(client);
                _ = self.clients.swapRemove(i);
                client.connection.destroy();
                self.gpa.destroy(client);
                busy = true;
                continue;
            }
            i += 1;
        }
        if (!busy) self.wakeup.wait(self.io, token, .{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } }) catch {};
    }
};
