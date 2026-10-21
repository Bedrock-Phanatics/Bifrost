const std = @import("std");
const Config = @import("../config/Config.zig");
const Backend = @import("Backend.zig");

const Health = @This();
const log = std.log.scoped(.health);

pub const Status = enum(u8) { unknown, healthy, unhealthy };

const Entry = struct {
    status: std.atomic.Value(Status) = .init(.unknown),
    players: std.atomic.Value(u32) = .init(0),
};

backends: []const Backend,
interval_ms: u32,
timeout_ms: u32,
entries: [Config.max_backends]Entry = @splat(.{}),

pub fn init(backends: []const Backend, interval_ms: u32, timeout_ms: u32) Health {
    return .{ .backends = backends, .interval_ms = interval_ms, .timeout_ms = timeout_ms };
}

pub fn status(self: *const Health, id: Backend.Id) Status {
    return self.entries[id.index()].status.load(.acquire);
}

pub fn markFailed(self: *Health, id: Backend.Id) void {
    self.entries[id.index()].status.store(.unhealthy, .release);
}

pub fn healthyCount(self: *const Health) usize {
    var count: usize = 0;
    for (self.entries[0..self.backends.len]) |*entry| count += @intFromBool(entry.status.load(.acquire) == .healthy);
    return count;
}

pub fn onlinePlayers(self: *const Health) u32 {
    var total: u32 = 0;
    for (self.entries[0..self.backends.len]) |*entry| {
        if (entry.status.load(.acquire) == .healthy) total +|= entry.players.load(.monotonic);
    }
    return total;
}

pub fn run(self: *Health, io: std.Io) void {
    while (true) {
        self.checkAll(io) catch return;
        io.sleep(.fromMilliseconds(self.interval_ms), .awake) catch return;
    }
}

pub fn checkAll(self: *Health, io: std.Io) error{Canceled}!void {
    var group: std.Io.Group = .init;
    for (0..self.backends.len) |index| {
        group.concurrent(io, check, .{ self, io, index }) catch check(self, io, index);
    }
    try group.await(io);
}

fn check(self: *Health, io: std.Io, index: usize) void {
    const backend = &self.backends[index];
    const players_now = probe(io, backend.address, self.timeout_ms) catch |err| {
        if (err == error.Canceled) return;
        if (self.entries[index].status.swap(.unhealthy, .acq_rel) != .unhealthy) log.warn("backend {f} is down: {t}", .{ backend.*, err });
        return;
    };
    const entry = &self.entries[index];
    entry.players.store(players_now, .monotonic);
    if (entry.status.swap(.healthy, .acq_rel) == .unhealthy) log.info("backend {f} is back", .{backend.*});
}

/// Asks the backend's signaling endpoint for its status, the same query the game's server list makes.
pub fn probe(io: std.Io, address: std.Io.net.IpAddress, timeout_ms: u32) !u32 {
    const Result = union(enum) { players: anyerror!u32, timeout: std.Io.Cancelable!void };
    var results: [2]Result = undefined;
    var select = std.Io.Select(Result).init(io, &results);
    defer select.cancelDiscard();
    try select.concurrent(.timeout, std.Io.sleep, .{ io, std.Io.Duration.fromMilliseconds(timeout_ms), .awake });
    try select.concurrent(.players, query, .{ io, address });
    return switch (try select.await()) {
        .players => |players| players,
        .timeout => |result| {
            try result;
            return error.Timeout;
        },
    };
}

fn query(io: std.Io, address: std.Io.net.IpAddress) anyerror!u32 {
    const stream = try address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var send_buffer: [128]u8 = undefined;
    var sender = stream.writer(io, &send_buffer);
    sender.interface.print("GET /v1/join HTTP/1.1\r\nHost: {f}\r\nConnection: close\r\n\r\n", .{address}) catch return sender.err orelse error.WriteFailed;
    sender.interface.flush() catch return sender.err orelse error.WriteFailed;

    var receive_buffer: [8 * 1024]u8 = undefined;
    var receiver = stream.reader(io, &receive_buffer);
    var http: std.http.Reader = .{ .in = &receiver.interface, .interface = undefined, .state = .ready, .max_head_len = receive_buffer.len };
    const head = try std.http.Client.Response.Head.parse(http.receiveHead() catch |err| return if (err == error.ReadFailed) receiver.err orelse err else err);
    if (head.status != .ok) return error.BackendUnavailable;
    var transfer: [1024]u8 = undefined;
    var body_buffer: [16 * 1024]u8 = undefined;
    var body = std.Io.Writer.fixed(&body_buffer);
    _ = http.bodyReader(&transfer, head.transfer_encoding, head.content_length).streamRemaining(&body) catch return error.InvalidStatus;
    return playerCount(body.buffered());
}

// An empty 200 is a valid answer too, it just has no count
fn playerCount(json: []const u8) u32 {
    var buffer: [4096]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&buffer);
    const Body = struct { players: u32 = 0 };
    const parsed = std.json.parseFromSliceLeaky(Body, fixed.allocator(), json, .{ .ignore_unknown_fields = true }) catch return 0;
    return parsed.players;
}

test "status bodies give a player count or nothing" {
    try std.testing.expectEqual(@as(u32, 7), playerCount("{\"name\":\"x\",\"players\":7,\"maxPlayers\":10}"));
    try std.testing.expectEqual(@as(u32, 0), playerCount(""));
    try std.testing.expectEqual(@as(u32, 0), playerCount("{\"players\":-1}"));
}

test "online players sum healthy backends and saturate" {
    var backends: [3]Backend = undefined;
    for (&backends, 1..) |*backend, port| backend.* = try .init(null, .{ .ip4 = .loopback(@intCast(port)) });
    var health: Health = .init(&backends, 1000, 100);
    try std.testing.expectEqual(@as(u32, 0), health.onlinePlayers());

    health.entries[0].status.store(.healthy, .release);
    health.entries[0].players.store(std.math.maxInt(u32) - 1, .monotonic);
    health.entries[1].status.store(.healthy, .release);
    health.entries[1].players.store(5, .monotonic);
    health.entries[2].status.store(.unhealthy, .release);
    health.entries[2].players.store(1000, .monotonic);
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), health.onlinePlayers());
    try std.testing.expectEqual(@as(usize, 2), health.healthyCount());

    health.markFailed(.of(0));
    try std.testing.expectEqual(Status.unhealthy, health.status(.of(0)));
    try std.testing.expectEqual(@as(u32, 5), health.onlinePlayers());
}
