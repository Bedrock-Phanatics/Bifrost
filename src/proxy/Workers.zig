const std = @import("std");
const bedwire = @import("bedwire");
const Config = @import("../config/Config.zig");
const Health = @import("../backend/Health.zig");
const NetherNet = @import("../net/NetherNet.zig");
const Listener = @import("../net/Listener.zig");
const Observer = @import("../protocol/Observer.zig");
const proxy_key = @import("../session/proxy_key.zig");
const Admission = @import("Admission.zig");
const Budget = @import("Budget.zig");
const Proxy = @import("Proxy.zig");
const Stats = @import("Stats.zig");
const Metrics = @import("Metrics.zig");
const Plugins = @import("../plugin/Plugins.zig");

const Workers = @This();
const log = std.log.scoped(.stats);

const report_interval_s = 60;
const metrics_timeout_ms = 2_000;
const max_metrics_request = 2048;

gpa: std.mem.Allocator,
io: std.Io,
config: Config,
admission: Admission,
budget: Budget,
health: Health,
transport: NetherNet,
listener: ?*Listener = null,
proxies: []*Proxy,
next_proxy: std.atomic.Value(usize) = .init(0),
plugins: ?*Plugins,
metrics: ?std.Io.net.Server = null,

pub const Options = struct {
    auth: Observer.Auth = .off,
    proxy_key: ?proxy_key.Ecdsa.KeyPair = null,
    plugins: ?*Plugins = null,
    identity: NetherNet.KeyPair,
    // The JWKS behind auth, so clients prove at the transport the key their Login uses
    issuer_keys: ?[]const u8 = null,
};

pub fn create(gpa: std.mem.Allocator, io: std.Io, config: Config, options: Options) !*Workers {
    try config.validate();
    const self = try gpa.create(Workers);
    errdefer gpa.destroy(self);
    self.* = .{
        .gpa = gpa,
        .io = io,
        .config = config,
        .admission = try .init(gpa, config.max_players, config.max_players_per_ip),
        .budget = .init(std.math.cast(usize, config.total_pending_bytes) orelse std.math.maxInt(usize)),
        .health = undefined,
        .transport = undefined,
        .proxies = &.{},
        .plugins = options.plugins,
    };
    errdefer self.admission.deinit();
    var ice_servers: [Config.max_ice_servers][]const u8 = undefined;
    for (ice_servers[0..config.ice_server_count], 0..) |*url, i| url.* = config.iceServer(i);
    try self.transport.init(gpa, io, .{
        .identity = options.identity,
        .issuer_keys = options.issuer_keys,
        .connect_timeout_ms = config.connect_timeout_ms,
        .port_min = config.port_min,
        .port_max = config.port_max,
        .ice_bind = config.iceBind(),
        .ice_servers = ice_servers[0..config.ice_server_count],
        .udp_mux = config.udp_mux,
    });
    errdefer self.transport.deinit();
    if (config.metrics_bind) |address| self.metrics = try address.listen(io, .{ .reuse_address = true });
    errdefer if (self.metrics) |*server| server.deinit(io);
    self.health = .init(self.config.backends(), config.health_interval_ms, config.health_timeout_ms);
    self.proxies = try gpa.alloc(*Proxy, config.workers);
    errdefer gpa.free(self.proxies);

    var created: usize = 0;
    errdefer for (self.proxies[0..created]) |proxy| proxy.destroy();
    for (self.proxies, 0..) |*proxy, worker| {
        proxy.* = try Proxy.create(gpa, io, config, .{
            .transport = &self.transport,
            .auth = options.auth,
            .admission = &self.admission,
            .budget = &self.budget,
            .health = &self.health,
            .proxy_key = options.proxy_key,
            .plugins = options.plugins,
            .worker = @intCast(worker),
        });
        created += 1;
    }
    self.listener = try Listener.start(gpa, io, &self.transport, config.bind, .{ .context = self, .accept = dispatch }, .{
        .max_negotiations = config.max_negotiations,
        .max_negotiations_per_ip = config.max_negotiations_per_ip,
        .status = .{ .context = self, .get = serverStatus },
    });
    return self;
}

pub fn destroy(self: *Workers) void {
    if (self.listener) |listener| listener.destroy(self.gpa);
    for (self.proxies) |proxy| proxy.destroy();
    self.transport.deinit();
    if (self.metrics) |*server| server.deinit(self.io);
    self.admission.deinit();
    self.gpa.free(self.proxies);
    self.gpa.destroy(self);
}

pub fn localAddress(self: *const Workers) std.Io.net.IpAddress {
    return self.listener.?.localAddress();
}

// Round robin; a full worker passes the player on to the next one
fn dispatch(context: *anyopaque, connection: *NetherNet.Connection) void {
    const self: *Workers = @ptrCast(@alignCast(context));
    const first = self.next_proxy.fetchAdd(1, .monotonic);
    for (0..self.proxies.len) |offset| {
        self.proxies[(first + offset) % self.proxies.len].adopt(connection) catch continue;
        return;
    }
    connection.destroy();
}

// The server list asks for this on every refresh, from the HTTP tasks
fn serverStatus(context: ?*anyopaque) anyerror!Listener.ServerStatus {
    const self: *Workers = @ptrCast(@alignCast(context.?));
    return .{
        .name = self.config.motd(),
        .protocol = bedwire.protocol.protocol_version,
        .version = bedwire.protocol.minecraft_version,
        .level = "Bifrost",
        .players = @min(self.health.onlinePlayers(), self.config.max_players),
        .max_players = self.config.max_players,
        .game_type = 0,
    };
}

pub fn metricsAddress(self: *const Workers) ?std.Io.net.IpAddress {
    return if (self.metrics) |server| server.socket.address else null;
}

pub fn stop(self: *Workers) void {
    for (self.proxies) |proxy| proxy.stop();
}

pub fn run(self: *Workers) !void {
    var health_task = try self.io.concurrent(Health.run, .{ &self.health, self.io });
    defer health_task.cancel(self.io);
    var report_task = try self.io.concurrent(report, .{self});
    defer report_task.cancel(self.io);
    var metrics_task: ?std.Io.Future(void) = if (self.metrics != null) try self.io.concurrent(serveMetrics, .{self}) else null;
    defer if (metrics_task) |*task| task.cancel(self.io);

    const tasks = try self.gpa.alloc(std.Io.Future(void), self.proxies.len);
    defer self.gpa.free(tasks);
    var started: usize = 0;
    defer for (tasks[0..started]) |*task| task.await(self.io);
    errdefer self.stop();

    for (self.proxies, tasks) |proxy, *task| {
        task.* = try self.io.concurrent(runWorker, .{ self, proxy });
        started += 1;
    }
}

pub fn totals(self: *const Workers) Stats {
    var sum: Stats = .{};
    for (self.proxies) |proxy| sum.add(proxy.stats.snapshot());
    return sum;
}

pub fn writeMetrics(self: *const Workers, w: *std.Io.Writer) std.Io.Writer.Error!void {
    const totals_now = self.totals();
    var timings: Metrics.Timings = .{};
    for (self.proxies) |proxy| timings.add(&proxy.timings);
    try Metrics.value(w, "players_online", "gauge", "Players admitted and not yet gone.", self.admission.active.load(.monotonic));
    try Metrics.value(w, "links_active", "gauge", "Player links the workers hold.", totals_now.links_active);
    try Metrics.value(w, "sessions_accepted_total", "counter", "Players accepted.", totals_now.sessions_accepted);
    try Metrics.value(w, "sessions_rejected_total", "counter", "Players turned away.", totals_now.sessions_rejected);
    try Metrics.header(w, "messages_total", "counter", "NetherNet messages forwarded.");
    try w.print("bifrost_messages_total{{direction=\"to_backend\"}} {d}\nbifrost_messages_total{{direction=\"to_player\"}} {d}\n", .{ totals_now.messages_to_backend, totals_now.messages_to_player });
    try Metrics.header(w, "bytes_total", "counter", "Bytes forwarded.");
    try w.print("bifrost_bytes_total{{direction=\"to_backend\"}} {d}\nbifrost_bytes_total{{direction=\"to_player\"}} {d}\n", .{ totals_now.bytes_to_backend, totals_now.bytes_to_player });
    try Metrics.value(w, "managed_relayed_batches_total", "counter", "Managed batches relayed without decoding.", totals_now.managed_relayed_batches);
    try Metrics.value(w, "managed_decoded_batches_total", "counter", "Managed batches decoded.", totals_now.managed_decoded_batches);
    try Metrics.value(w, "player_buffered_bytes", "gauge", "Bytes waiting in the data channels to players.", totals_now.player_buffered_bytes);
    try Metrics.value(w, "unreliable_dropped_total", "counter", "Unreliable messages managed sessions dropped.", totals_now.unreliable_dropped);
    try Metrics.value(w, "queued_bytes", "gauge", "Bytes held in the shared pending budget.", self.budget.used.load(.monotonic));
    try Metrics.value(w, "queued_bytes_limit", "gauge", "Size of the shared pending budget.", self.budget.limit);
    try Metrics.value(w, "queue_refusals_total", "counter", "Packets refused because the budget was full.", self.budget.refusals.load(.monotonic));
    try Metrics.value(w, "backlog_pauses_total", "counter", "Times a backend was paused for a slow player.", totals_now.backlog_pauses);
    try Metrics.value(w, "slow_players_total", "counter", "Players closed for not keeping up.", totals_now.slow_players);
    try Metrics.value(w, "player_floods_total", "counter", "Players closed for sending too much.", totals_now.player_floods);
    try Metrics.value(w, "backends_connected_total", "counter", "Backend connections made.", totals_now.backends_connected);
    try Metrics.value(w, "backend_failures_total", "counter", "Backend connections that failed.", totals_now.backend_failures);
    try Metrics.header(w, "backend_up", "gauge", "1 if the last health check passed.");
    for (self.health.backends, 0..) |*backend, i| {
        try w.writeAll("bifrost_backend_up{backend=\"");
        try Metrics.label(w, backend.name());
        try w.print("\"}} {d}\n", .{@intFromBool(self.health.status(.of(i)) == .healthy)});
    }
    try Metrics.value(w, "transfers_started_total", "counter", "Transfers started.", totals_now.transfers_started);
    try Metrics.value(w, "transfers_committed_total", "counter", "Transfers that finished.", totals_now.transfers_committed);
    try Metrics.value(w, "transfers_failed_total", "counter", "Transfers that failed or timed out.", totals_now.transfers_failed_before_commit + totals_now.transfers_failed_after_commit + totals_now.transfers_timed_out);
    try Metrics.histogram(w, "turn_seconds", "Time each worker turn spends working.", &timings.turn);
    try Metrics.histogram(w, "backend_dial_seconds", "Time to connect a player to a backend.", &timings.dial);
    try Metrics.histogram(w, "transfer_seconds", "Time from transfer start to commit.", &timings.transfer);
    const plugins = self.plugins orelse return;
    try Metrics.header(w, "plugin_calls_total", "counter", "Plugin callbacks run.");
    for (plugins.loaded.items, 0..) |loaded, i| try pluginLine(w, "plugin_calls_total", loaded.label(), plugins.totals(i).calls);
    try Metrics.header(w, "plugin_errors_total", "counter", "Plugin callbacks that failed.");
    for (plugins.loaded.items, 0..) |loaded, i| try pluginLine(w, "plugin_errors_total", loaded.label(), plugins.totals(i).errors);
    try Metrics.header(w, "plugin_seconds_total", "counter", "Time spent in plugin callbacks.");
    for (plugins.loaded.items, 0..) |loaded, i| try pluginLine(w, "plugin_seconds_total", loaded.label(), @as(f64, @floatFromInt(plugins.totals(i).total_ns)) / std.time.ns_per_s);
    try Metrics.header(w, "plugin_max_seconds", "gauge", "Slowest plugin callback so far.");
    for (plugins.loaded.items, 0..) |loaded, i| try pluginLine(w, "plugin_max_seconds", loaded.label(), @as(f64, @floatFromInt(plugins.totals(i).max_ns)) / std.time.ns_per_s);
}

fn pluginLine(w: *std.Io.Writer, name: []const u8, plugin: []const u8, amount: anytype) !void {
    try w.print("bifrost_{s}{{plugin=\"", .{name});
    try Metrics.label(w, plugin);
    try w.print("\"}} {d}\n", .{amount});
}

fn serveMetrics(self: *Workers) void {
    const server = &self.metrics.?;
    log.info("metrics on http://{f}/metrics", .{server.socket.address});
    while (true) {
        const stream = server.accept(self.io) catch |err| switch (err) {
            error.Canceled => return,
            else => {
                log.warn("metrics accept failed: {t}", .{err});
                self.io.sleep(.fromMilliseconds(100), .awake) catch return;
                continue;
            },
        };
        defer stream.close(self.io);
        self.answerMetrics(stream) catch |err| switch (err) {
            error.Canceled => return,
            else => log.debug("metrics request failed: {t}", .{err}),
        };
    }
}

// One client at a time and a deadline on every read and write, so a stuck scraper can't pile up work
fn answerMetrics(self: *Workers, stream: std.Io.net.Stream) !void {
    const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(metrics_timeout_ms), .clock = .awake } };
    var request: [max_metrics_request]u8 = undefined;
    var len: usize = 0;
    while (std.mem.indexOf(u8, request[0..len], "\r\n\r\n") == null) {
        if (len == request.len) return error.RequestTooLarge;
        var data = [_][]u8{request[len..]};
        const read = try (try operate(self.io, .{ .net_read = .{ .socket_handle = stream.socket.handle, .data = &data } }, timeout)).net_read;
        if (read.data_len == 0) return error.EndOfStream;
        len += read.data_len;
    }
    var body: std.Io.Writer.Allocating = .init(self.gpa);
    defer body.deinit();
    const found = std.mem.startsWith(u8, request[0..len], "GET /metrics ") or std.mem.startsWith(u8, request[0..len], "GET /metrics?");
    if (found) try self.writeMetrics(&body.writer) else try body.writer.writeAll("not found\n");
    var head: [160]u8 = undefined;
    const status = if (found) "200 OK" else "404 Not Found";
    const header = try std.fmt.bufPrint(&head, "HTTP/1.1 {s}\r\nContent-Type: text/plain; version=0.0.4; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, body.written().len });
    for ([_][]const u8{ header, body.written() }) |part| {
        var rest = part;
        while (rest.len != 0) {
            const wrote = try (try operate(self.io, .{ .net_write = .{ .socket_handle = stream.socket.handle, .data = &.{rest} } }, timeout)).net_write;
            rest = rest[wrote..];
        }
    }
    stream.shutdown(self.io, .send) catch {};
}

// ZIO has timeouts, the threaded test Io doesn't and refuses before starting the operation
fn operate(io: std.Io, operation: std.Io.Operation, timeout: std.Io.Timeout) !std.Io.Operation.Result {
    return io.operateTimeout(operation, timeout) catch |err| switch (err) {
        error.ConcurrencyUnavailable => io.operate(operation),
        else => err,
    };
}

fn report(self: *Workers) void {
    while (true) {
        self.io.sleep(.fromSeconds(report_interval_s), .awake) catch return;
        const totals_now = self.totals();
        log.info("{d} online, {d} joined, {d}/{d} backends up, {d} backend failures, {Bi:.1} to backends, {Bi:.1} to players", .{
            self.admission.active.load(.monotonic),
            totals_now.sessions_accepted,
            self.health.healthyCount(),
            self.health.backends.len,
            totals_now.backend_failures,
            totals_now.bytes_to_backend,
            totals_now.bytes_to_player,
        });
        const timeouts = totals_now.login_timeouts + totals_now.resource_pack_timeouts + totals_now.join_timeouts;
        const refusals = self.budget.refusals.load(.monotonic);
        if (timeouts + totals_now.logins_throttled + totals_now.player_floods + totals_now.slow_players + refusals + totals_now.sessions_rejected == 0) continue;
        log.info("{d} rejected, {d} timed out, {d} logins throttled, {d} floods, {d} too slow, {d} queue refusals, {Bi:.1} queued", .{
            totals_now.sessions_rejected,
            timeouts,
            totals_now.logins_throttled,
            totals_now.player_floods,
            totals_now.slow_players,
            refusals,
            self.budget.used.load(.monotonic),
        });
    }
}

fn runWorker(self: *Workers, proxy: *Proxy) void {
    proxy.run();
    self.stop();
}
