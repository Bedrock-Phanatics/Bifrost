const std = @import("std");
const builtin = @import("builtin");
const raknet = @import("raknet");
const bedwire = @import("bedwire");
const bifrost = @import("bifrost");
const managed = @import("managed.zig");

const IpAddress = std.Io.net.IpAddress;
const Current = bedwire.protocol.Current;

pub const max_workers = 64;

pub fn nowNs(io: std.Io) u64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

pub fn millis(ms: i64) std.Io.Timeout {
    return .{ .duration = .{ .raw = .fromMilliseconds(ms), .clock = .awake } };
}

pub fn sleepMs(io: std.Io, ms: i64) void {
    io.sleep(.fromMilliseconds(ms), .awake) catch {};
}

pub fn loopback(port: u16) IpAddress {
    return .{ .ip4 = .loopback(port) };
}

pub const Snapshot = struct {
    rss_kb: u64 = 0,
    hwm_kb: u64 = 0,
    cpu_us: u64 = 0,
    pool_bytes: u64 = 0,
    accepted: u64 = 0,
    closed: u64 = 0,
    backend_failures: u64 = 0,
    backends_connected: u64 = 0,
    handshakes: u64 = 0,
    gave_up: u64 = 0,
    heap_bytes: u64 = 0,
    session_bytes: u64 = 0,
    relayed: u64 = 0,
    decoded: u64 = 0,
    per_worker: [max_workers]u64 = @splat(0),
    workers: usize = 0,

    const scalar_fields = 14;

    pub fn write(self: Snapshot, w: *std.Io.Writer) !void {
        inline for (@typeInfo(Snapshot).@"struct".field_names[0..scalar_fields]) |name| try w.print("{d} ", .{@field(self, name)});
        for (self.per_worker[0..self.workers]) |count| try w.print("{d} ", .{count});
        try w.writeByte('\n');
    }

    pub fn parse(line: []const u8) !Snapshot {
        var result: Snapshot = .{};
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        inline for (@typeInfo(Snapshot).@"struct".field_names[0..scalar_fields]) |name| {
            @field(result, name) = try std.fmt.parseInt(u64, fields.next() orelse return error.BadStats, 10);
        }
        while (fields.next()) |count| {
            if (result.workers == max_workers) return error.BadStats;
            result.per_worker[result.workers] = try std.fmt.parseInt(u64, count, 10);
            result.workers += 1;
        }
        return result;
    }
};

pub const Usage = struct { rss_kb: u64 = 0, hwm_kb: u64 = 0, cpu_us: u64 = 0 };

/// Linux only, zeros elsewhere
pub fn selfUsage(io: std.Io) Usage {
    if (builtin.os.tag != .linux) return .{};
    var usage: Usage = .{};
    const ru = std.posix.getrusage(std.os.linux.rusage.SELF);
    usage.cpu_us = @intCast(ru.utime.sec * 1_000_000 + ru.utime.usec + ru.stime.sec * 1_000_000 + ru.stime.usec);

    var buffer: [4096]u8 = undefined;
    var lines = std.mem.tokenizeScalar(u8, readProc(io, "/proc/self/status", &buffer), '\n');
    while (lines.next()) |line| {
        if (statusKb(line, "VmRSS:")) |kb| usage.rss_kb = kb;
        if (statusKb(line, "VmHWM:")) |kb| usage.hwm_kb = kb;
    }
    return usage;
}

/// Host-wide UDP datagrams the kernel dropped because a socket's receive buffer was full
pub fn udpReceiveDrops(io: std.Io) u64 {
    if (builtin.os.tag != .linux) return 0;
    var buffer: [4096]u8 = undefined;
    var lines = std.mem.tokenizeScalar(u8, readProc(io, "/proc/net/snmp", &buffer), '\n');
    while (lines.next()) |header| {
        if (!std.mem.startsWith(u8, header, "Udp: ")) continue;
        const values = lines.next() orelse return 0;
        var names = std.mem.tokenizeScalar(u8, header, ' ');
        var numbers = std.mem.tokenizeScalar(u8, values, ' ');
        while (names.next()) |name| {
            const number = numbers.next() orelse return 0;
            if (std.mem.eql(u8, name, "RcvbufErrors")) return std.fmt.parseInt(u64, number, 10) catch 0;
        }
    }
    return 0;
}

fn readProc(io: std.Io, path: []const u8, buffer: []u8) []const u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return "";
    defer file.close(io);
    var len: usize = 0;
    while (len < buffer.len) {
        const n = file.readStreaming(io, &.{buffer[len..]}) catch break;
        if (n == 0) break;
        len += n;
    }
    return buffer[0..len];
}

/// Tracks live heap bytes; atomic because every worker allocates through it
pub const CountingAllocator = struct {
    backing: std.mem.Allocator,
    live: std.atomic.Value(u64) = .init(0),

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        const result = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        _ = self.live.fetchAdd(len, .monotonic);
        return result;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.adjust(memory.len, new_len);
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        const result = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.adjust(memory.len, new_len);
        return result;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.backing.rawFree(memory, alignment, ret_addr);
        _ = self.live.fetchSub(memory.len, .monotonic);
    }

    fn adjust(self: *CountingAllocator, old_len: usize, new_len: usize) void {
        if (new_len > old_len) {
            _ = self.live.fetchAdd(new_len - old_len, .monotonic);
        } else {
            _ = self.live.fetchSub(old_len - new_len, .monotonic);
        }
    }
};

fn statusKb(line: []const u8, key: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, line, key)) return null;
    var words = std.mem.tokenizeAny(u8, line[key.len..], " \tkB");
    return std.fmt.parseInt(u64, words.next() orelse return null, 10) catch null;
}

/// The real proxy, running in a child copy of this binary
pub const Proxy = struct {
    io: std.Io,
    child: std.process.Child,
    reader: std.Io.File.Reader,
    read_buffer: [4096]u8,
    port: u16,

    pub const Options = struct {
        workers: u8 = 1,
        connect_timeout_ms: u32 = 1_000,
        health_interval_ms: u32 = 1_000,
        managed: bool = false,
        plugins: []const u8 = "none",
        backends: []const u16,
    };

    pub fn start(self: *Proxy, gpa: std.mem.Allocator, io: std.Io, exe: []const u8, options: Options) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer {
            for (argv.items[2..]) |arg| gpa.free(arg);
            argv.deinit(gpa);
        }
        try argv.appendSlice(gpa, &.{ exe, "proxy" });
        try argv.append(gpa, try std.fmt.allocPrint(gpa, "{d}", .{options.workers}));
        try argv.append(gpa, try std.fmt.allocPrint(gpa, "{d}", .{options.connect_timeout_ms}));
        try argv.append(gpa, try std.fmt.allocPrint(gpa, "{d}", .{options.health_interval_ms}));
        try argv.append(gpa, if (options.managed) try std.fmt.allocPrint(gpa, "managed+{s}", .{options.plugins}) else try gpa.dupe(u8, "passthrough"));
        for (options.backends) |port| try argv.append(gpa, try std.fmt.allocPrint(gpa, "{d}", .{port}));

        self.io = io;
        self.child = try std.process.spawn(io, .{ .argv = argv.items, .stdin = .pipe, .stdout = .pipe });
        errdefer self.child.kill(io);
        self.reader = self.child.stdout.?.readerStreaming(io, &self.read_buffer);
        const line = try self.readLine();
        if (!std.mem.startsWith(u8, line, "ready ")) return error.ProxyFailedToStart;
        self.port = try std.fmt.parseInt(u16, line["ready ".len..], 10);
    }

    pub fn address(self: *const Proxy) IpAddress {
        return loopback(self.port);
    }

    pub fn stats(self: *Proxy) !Snapshot {
        try self.child.stdin.?.writeStreamingAll(self.io, "stats\n");
        return Snapshot.parse(try self.readLine());
    }

    pub fn waitClosed(self: *Proxy, closed: u64, timeout_ms: u64) !Snapshot {
        const deadline = nowNs(self.io) + timeout_ms * std.time.ns_per_ms;
        while (true) {
            const snapshot = try self.stats();
            if (snapshot.closed >= closed) return snapshot;
            if (nowNs(self.io) > deadline) return error.LinksNotClosed;
            sleepMs(self.io, 5);
        }
    }

    pub fn stop(self: *Proxy) void {
        if (self.child.stdin) |stdin| stdin.close(self.io);
        self.child.stdin = null;
        _ = self.child.wait(self.io) catch {};
    }

    fn readLine(self: *Proxy) ![]const u8 {
        return (try self.reader.interface.takeDelimiter('\n')) orelse error.ProxyExited;
    }
};

/// Login gets a filler token so it is realistically sized and fragmented
pub const Frames = struct {
    gpa: std.mem.Allocator,
    request: []u8,
    settings: []u8,
    login: []u8,
    handshake: []u8,

    const limits: bedwire.Limits = .{};

    pub fn init(gpa: std.mem.Allocator, login_token_bytes: usize) !Frames {
        const token = try gpa.alloc(u8, login_token_bytes);
        defer gpa.free(token);
        var prng: std.Random.DefaultPrng = .init(0x5eed);
        const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
        for (token) |*byte| byte.* = alphabet[prng.random().int(u6)];

        const buffer = try gpa.alloc(u8, login_token_bytes + 1024);
        defer gpa.free(buffer);
        const version: i32 = @intCast(Current.protocol_number);
        const request = try plain(gpa, try encode(buffer, .{
            .header = .{ .packet_id = Current.packetId(.request_network_settings).? },
            .packet = .{ .request_network_settings = .{ .client_network_version = version } },
        }));
        errdefer gpa.free(request);
        const settings = try plain(gpa, try encode(buffer, .{
            .header = .{ .packet_id = Current.packetId(.network_settings).? },
            .packet = .{ .network_settings = .{
                .compression_threshold = 0,
                .compression_algorithm = .snappy,
                .client_throttle_enabled = false,
                .client_throttle_threshold = 0,
                .client_throttle_scalar = 0,
            } },
        }));
        errdefer gpa.free(settings);
        const login = try compressed(gpa, try encode(buffer, .{
            .header = .{ .packet_id = Current.packetId(.login).? },
            .packet = .{ .login = .{ .client_network_version = version, .connection_request = token } },
        }));
        errdefer gpa.free(login);
        const handshake = try compressed(gpa, try encode(buffer, .{
            .header = .{ .packet_id = Current.packetId(.server_to_client_handshake).? },
            .packet = .{ .server_to_client_handshake = .{ .handshake_web_token = "header.payload.signature" } },
        }));
        return .{ .gpa = gpa, .request = request, .settings = settings, .login = login, .handshake = handshake };
    }

    pub fn deinit(self: *Frames) void {
        for ([_][]u8{ self.request, self.settings, self.login, self.handshake }) |frame| self.gpa.free(frame);
    }

    fn encode(buffer: []u8, envelope: bedwire.protocol.typed.Envelope) ![]const u8 {
        var writer = bedwire.protocol.Writer.init(buffer);
        try bedwire.protocol.typed.encode(&writer, envelope);
        return writer.written();
    }

    fn plain(gpa: std.mem.Allocator, packet: []const u8) ![]u8 {
        const frame = try gpa.alloc(u8, packet.len + 16);
        errdefer gpa.free(frame);
        frame[0] = bedwire.framing.batch.header;
        var writer = bedwire.framing.batch.Writer.init(frame[1..], limits);
        try writer.append(packet);
        return gpa.realloc(frame, 1 + writer.written().len);
    }

    fn compressed(gpa: std.mem.Allocator, packet: []const u8) ![]u8 {
        const raw = try gpa.alloc(u8, packet.len + 16);
        defer gpa.free(raw);
        var writer = bedwire.framing.batch.Writer.init(raw, limits);
        try writer.append(packet);
        var codec = bedwire.compression.Compression.init(Current.features);
        try codec.negotiate(.snappy, 0);
        const scratch = try gpa.create(bedwire.compression.Scratch);
        defer gpa.destroy(scratch);
        const frame = try gpa.alloc(u8, packet.len * 2 + 64);
        errdefer gpa.free(frame);
        const framed = try codec.encode(writer.written(), frame[2..], scratch);
        frame[0] = bedwire.framing.batch.header;
        frame[1] = @backingInt(framed.algorithm);
        return gpa.realloc(frame, 2 + framed.bytes.len);
    }
};

/// Answers the fake handshake, then echoes everything
pub const Backend = struct {
    io: std.Io,
    listener: *raknet.Server,
    frames: *const Frames,
    task: ?std.Io.Future(void) = null,
    stopping: std.atomic.Value(bool) = .init(false),
    connects: std.atomic.Value(u32) = .init(0),

    pub fn start(self: *Backend, gpa: std.mem.Allocator, io: std.Io, frames: *const Frames) !void {
        var config: raknet.Config = .{};
        config.listener.maximum_connections = 16_384;
        config.listener.maximum_pending_handshakes = 16_384;
        self.* = .{
            .io = io,
            .listener = try raknet.Server.listen(gpa, io, loopback(0), .{ .advertisement = "MCPE;bench", .config = config, .offline_rate_per_second = 1_000_000, .offline_burst = 1_000_000 }),
            .frames = frames,
        };
        errdefer self.listener.destroy();
        try self.serve();
    }

    pub fn deinit(self: *Backend) void {
        self.pause();
        self.listener.destroy();
    }

    pub fn port(self: *const Backend) u16 {
        return self.listener.localAddress().getPort();
    }

    pub fn serve(self: *Backend) !void {
        if (self.task != null) return;
        self.stopping.store(false, .release);
        self.task = try self.io.concurrent(run, .{self});
    }

    /// Stops answering, so dials and pings time out like a hung server
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
            }) catch {};
        }
    }

    fn onConnected(context: *anyopaque, _: *raknet.Session) error{ApplicationFailure}!void {
        const self: *Backend = @ptrCast(@alignCast(context));
        _ = self.connects.fetchAdd(1, .monotonic);
    }

    fn onMessage(context: *anyopaque, session: *raknet.Session, payload: raknet.BorrowedPayload) error{ApplicationFailure}!void {
        const self: *Backend = @ptrCast(@alignCast(context));
        const bytes = payload.bytes;
        const reply = if (std.mem.eql(u8, bytes, self.frames.request))
            self.frames.settings
        else if (std.mem.eql(u8, bytes, self.frames.login))
            self.frames.handshake
        else
            bytes;
        session.send(reply, .reliable_ordered, 0) catch return error.ApplicationFailure;
    }
};

pub const Recorder = struct {
    latencies_ns: std.ArrayList(u64) = .empty,
    messages: u64 = 0,
    bytes: u64 = 0,

    pub fn deinit(self: *Recorder, gpa: std.mem.Allocator) void {
        self.latencies_ns.deinit(gpa);
    }
};

pub fn stamp(payload: []u8, io: std.Io) void {
    std.mem.writeInt(u64, payload[1..9], nowNs(io), .little);
}

pub const Player = struct {
    io: std.Io,
    client: *raknet.Client,
    received: u64 = 0,
    matched: bool = false,
    expect: ?[]const u8 = null,
    recorder: ?*Recorder = null,
    count_until_ns: u64 = 0,
    bedrock: ?*managed.Bedrock = null,

    pub fn connect(self: *Player, gpa: std.mem.Allocator, io: std.Io, address: IpAddress) !void {
        self.* = .{ .io = io, .client = try raknet.Client.connect(gpa, io, address, .{}) };
    }

    pub fn deinit(self: *Player) void {
        self.client.destroy();
        if (self.bedrock) |bedrock| bedrock.destroy();
    }

    pub fn send(self: *Player, payload: []const u8) !void {
        const bedrock = self.bedrock orelse return self.client.send(payload, .reliable_ordered, 0);
        const frame = try bedrock.wrap(payload);
        defer frame.release();
        try self.client.send(frame.bytes, .reliable_ordered, 0);
    }

    /// Sends and waits for exactly this reply
    pub fn exchange(self: *Player, payload: []const u8, reply: []const u8, timeout_ms: u64) !void {
        self.expect = reply;
        defer self.expect = null;
        const target = self.received + 1;
        try self.send(payload);
        try self.waitFor(target, timeout_ms);
        if (!self.matched) return error.UnexpectedReply;
    }

    pub fn handshake(self: *Player, frames: *const Frames) !void {
        try self.exchange(frames.request, frames.settings, 5_000);
        try self.exchange(frames.login, frames.handshake, 5_000);
    }

    pub fn waitFor(self: *Player, target: u64, timeout_ms: u64) !void {
        const deadline = nowNs(self.io) + timeout_ms * std.time.ns_per_ms;
        while (self.received < target) {
            if (nowNs(self.io) > deadline) return error.ReplyTimedOut;
            try self.pollOnce(20);
        }
    }

    /// Keeps the session alive while idle
    pub fn idle(self: *Player, ms: i64) !void {
        try self.pollOnce(ms);
        if (self.client.isClosed()) return error.ConnectionClosed;
    }

    pub fn pollOnce(self: *Player, ms: i64) !void {
        _ = self.client.poll(millis(ms), self, onMessage) catch |err| switch (err) {
            error.Timeout => {},
            else => return err,
        };
    }

    fn onMessage(context: *anyopaque, payload: raknet.BorrowedPayload) error{ApplicationFailure}!void {
        const self: *Player = @ptrCast(@alignCast(context));
        const bedrock = self.bedrock orelse return self.record(payload.bytes);
        var packets = bedrock.session.ingest(payload.bytes) catch return error.ApplicationFailure;
        defer packets.deinit();
        while (packets.next()) |packet| try self.record(packet.bytes[managed.header_len..]);
    }

    fn record(self: *Player, bytes: []const u8) error{ApplicationFailure}!void {
        self.received += 1;
        if (self.expect) |expected| self.matched = std.mem.eql(u8, expected, bytes);
        const recorder = self.recorder orelse return;
        if (bytes.len < 9) return error.ApplicationFailure;
        const now = nowNs(self.io);
        recorder.latencies_ns.appendBounded(now -| std.mem.readInt(u64, bytes[1..9], .little)) catch {};
        if (now <= self.count_until_ns) {
            recorder.messages += 1;
            recorder.bytes += bytes.len;
        }
    }
};
