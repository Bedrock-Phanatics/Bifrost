const std = @import("std");
const builtin = @import("builtin");
const zio = @import("zio");
const bifrost = @import("bifrost");
const bench_options = @import("bench_options");
const sample = @import("sample");
const harness = @import("harness.zig");
const managed = @import("managed.zig");
const bench_plugins = @import("plugins.zig");
const bench_ids = @import("runtime_ids.zig");
const bench_tasks = @import("tasks.zig");

const Backend = harness.Backend;
const Frames = harness.Frames;
const Player = harness.Player;
const Proxy = harness.Proxy;
const Recorder = harness.Recorder;
const Snapshot = harness.Snapshot;
const nowNs = harness.nowNs;
const sleepMs = harness.sleepMs;

pub const std_options_debug_io = zio.debug_io;
// Expected failures (dead backends) would otherwise log inside timed sections
pub const std_options: std.Options = .{ .log_level = .err };

const usage =
    \\usage: bench [relay|fairness|managed|deflate|plugins|ids|tasks|handshake|connections|workers|backends ...] [--quick] [--driver-threads N] [--proxy-exe PATH]
    \\
;

const all_scenarios = [_][]const u8{ "relay", "fairness", "managed", "deflate", "plugins", "ids", "tasks", "handshake", "connections", "workers", "backends" };
const login_token_bytes = 16 * 1024;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len >= 2 and std.mem.eql(u8, args[1], "proxy")) return serveProxy(init, args[2..]);

    var driver_threads: u8 = 4;
    var quick = false;
    var proxy_exe: ?[]const u8 = null;
    var selected: std.ArrayList([]const u8) = .empty;
    defer selected.deinit(gpa);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print(usage, .{});
            return;
        } else if (std.mem.eql(u8, arg, "--quick")) {
            quick = true;
        } else if (std.mem.eql(u8, arg, "--driver-threads") and i + 1 < args.len) {
            i += 1;
            driver_threads = try std.fmt.parseInt(u8, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--proxy-exe") and i + 1 < args.len) {
            i += 1;
            proxy_exe = args[i];
        } else if (for (all_scenarios) |name| {
            if (std.mem.eql(u8, arg, name)) break true;
        } else false) {
            try selected.append(gpa, arg);
        } else {
            std.debug.print(usage, .{});
            return error.InvalidArguments;
        }
    }
    if (selected.items.len == 0) try selected.appendSlice(gpa, &all_scenarios);

    const rt = try zio.Runtime.init(gpa, .{ .executors = .exact(driver_threads) });
    defer rt.deinit();
    const io = rt.io();

    var frames: Frames = try .init(gpa, login_token_bytes);
    defer frames.deinit();
    var out_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buffer);
    var env: Env = .{
        .gpa = gpa,
        .io = io,
        .process_io = init.io,
        .exe = if (proxy_exe) |path| try gpa.dupeSentinel(u8, path, 0) else try std.process.executablePathAlloc(init.io, gpa),
        .frames = &frames,
        .out = &stdout.interface,
        .quick = quick,
        .cpus = std.Thread.getCpuCount() catch 1,
    };
    defer gpa.free(env.exe);

    try env.out.print("# Bifrost benchmark\n\n{t}-{t}, {t} build, {d} CPUs, driver threads {d}, proxy scheduling {s}{s}\n", .{
        builtin.os.tag,
        builtin.cpu.arch,
        builtin.mode,
        env.cpus,
        driver_threads,
        if (proxy_exe == null) "work_stealing" else bench_options.scheduling,
        if (quick) ", quick" else "",
    });
    try env.out.print("Login frame {d} B, {d} iterations of {d} ms after {d} ms warmup\n", .{
        frames.login.len, env.iterations(), env.iterationMs(), env.warmupMs(),
    });
    try env.out.flush();

    for (selected.items) |name| {
        if (std.mem.eql(u8, name, "relay")) try relayScenario(&env);
        if (std.mem.eql(u8, name, "fairness")) try fairnessScenario(&env);
        if (std.mem.eql(u8, name, "managed")) try managedScenario(&env);
        if (std.mem.eql(u8, name, "deflate")) try deflateScenario(&env);
        if (std.mem.eql(u8, name, "plugins")) try pluginsScenario(&env);
        if (std.mem.eql(u8, name, "ids")) try idsScenario(&env);
        if (std.mem.eql(u8, name, "tasks")) try tasksScenario(&env);
        if (std.mem.eql(u8, name, "handshake")) try handshakeScenario(&env);
        if (std.mem.eql(u8, name, "connections")) try connectionsScenario(&env);
        if (std.mem.eql(u8, name, "workers")) try workersScenario(&env);
        if (std.mem.eql(u8, name, "backends")) try backendsScenario(&env);
        try env.out.flush();
    }
    try memorySummary(&env);
    try env.out.flush();
}

const Env = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    exe: [:0]const u8,
    // zio hangs spawning and reading pipes on Windows, so child control uses the plain process io
    process_io: std.Io,
    frames: *const Frames,
    out: *std.Io.Writer,
    quick: bool,
    cpus: usize,
    memory: Memory = .{},

    fn iterations(self: *const Env) usize {
        return if (self.quick) 3 else 5;
    }

    fn iterationMs(self: *const Env) u64 {
        return if (self.quick) 500 else 1_000;
    }

    fn warmupMs(self: *const Env) u64 {
        return if (self.quick) 300 else 1_000;
    }

    fn startProxy(self: *Env, proxy: *Proxy, options: Proxy.Options) !void {
        try proxy.start(self.gpa, self.process_io, self.exe, options);
    }
};

const Memory = struct {
    base_kb: u64 = 0,
    pool_bytes: u64 = 0,
    per_player: ?struct { players: u64, rss_kb: f64, heap_kb: f64, session_kb: f64 } = null,
    peak: ?struct { kb: u64, what: []const u8 } = null,
    retained: ?struct { players: u64, rss_kb: i64, heap_bytes: i64 } = null,
    churn_kb: [3]u64 = @splat(0),
    churn_heap: [3]u64 = @splat(0),
};

/// args: workers connect_timeout_ms health_interval_ms passthrough|managed+<plugin setup> backend_port...
fn serveProxy(init: std.process.Init, args: []const [:0]const u8) !void {
    if (args.len < 5) return error.InvalidArguments;
    var config: bifrost.Config = .{ .bind = harness.loopback(0), .max_players = 16_384 };
    config.workers = try std.fmt.parseInt(u8, args[0], 10);
    config.connect_timeout_ms = try std.fmt.parseInt(u32, args[1], 10);
    config.health_interval_ms = try std.fmt.parseInt(u32, args[2], 10);
    config.health_timeout_ms = @min(1_000, config.health_interval_ms / 2);
    for (args[4..]) |port| try config.addBackend(null, harness.loopback(try std.fmt.parseInt(u16, port, 10)));
    var keys = try sample.keySet(init.gpa);
    defer keys.deinit();
    var options: bifrost.Workers.Options = .{};
    var plugins: bifrost.Plugins = try .init(init.gpa, config.backends(), .{ .workers = config.workers });
    defer plugins.deinit();
    if (std.mem.startsWith(u8, args[3], "managed+")) {
        config.session_mode = .managed;
        options = .{ .auth = .{ .verify = &keys }, .proxy_key = managed.proxyKey(), .plugins = &plugins };
        const setup = bench_plugins.parse(args[3]["managed+".len..]) orelse return error.InvalidArguments;
        try bench_plugins.load(&plugins, setup, bench_plugins.relay_packet_id);
    }

    // Same runtime setup as the real binary
    const rt = try zio.Runtime.init(init.gpa, .{ .executors = .exact(config.workers) });
    defer rt.deinit();
    const io = rt.io();
    var heap: harness.CountingAllocator = .{ .backing = init.gpa };
    const workers = try bifrost.Workers.create(heap.allocator(), io, config, options);
    defer workers.destroy();
    var task = try io.concurrent(bifrost.Workers.run, .{workers});

    var out_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buffer);
    const out = &stdout.interface;
    try out.print("ready {d}\n", .{workers.localAddress().getPort()});
    try out.flush();

    var in_buffer: [64]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(io, &in_buffer);
    while (stdin.interface.takeDelimiter('\n') catch null) |line| {
        if (!std.mem.eql(u8, line, "stats")) continue;
        try snapshot(io, workers, &heap).write(out);
        try out.flush();
    }
    workers.stop();
    try task.await(io);
}

fn snapshot(io: std.Io, workers: *bifrost.Workers, heap: *const harness.CountingAllocator) Snapshot {
    const self = harness.selfUsage(io);
    const totals = workers.totals();
    const pool = &workers.proxies[0].observer_pool;
    var result: Snapshot = .{
        .rss_kb = self.rss_kb,
        .hwm_kb = self.hwm_kb,
        .cpu_us = self.cpu_us,
        .pool_bytes = pool.rx_storage.len + pool.tx_storage.len,
        .accepted = totals.sessions_accepted,
        .closed = totals.links_closed,
        .backend_failures = totals.backend_failures,
        .backends_connected = totals.backends_connected,
        .handshakes = totals.handshakes_observed,
        .gave_up = totals.observer_gave_up,
        .heap_bytes = heap.live.load(.monotonic),
        .relayed = totals.managed_relayed_batches,
        .decoded = totals.managed_decoded_batches,
        .workers = workers.proxies.len,
    };
    for (workers.proxies, 0..) |proxy, i| {
        result.per_worker[i] = proxy.stats.snapshot().sessions_accepted;
        // Racy read of a worker-owned counter, fine for a stats sample
        result.session_bytes += @atomicLoad(usize, &proxy.listener.session_quota.used_bytes, .monotonic);
    }
    return result;
}

/// Runs work(context, i) for every i in 0..items on `tasks` concurrent tasks
fn parallel(io: std.Io, items: usize, tasks: usize, context: anytype, comptime work: fn (@TypeOf(context), usize) void) void {
    const Shared = struct {
        next: std.atomic.Value(usize) = .init(0),
        items: usize,
        context: @TypeOf(context),

        fn run(shared: *@This()) void {
            while (true) {
                const i = shared.next.fetchAdd(1, .monotonic);
                if (i >= shared.items) return;
                work(shared.context, i);
            }
        }
    };
    var shared: Shared = .{ .items = items, .context = context };
    var group: std.Io.Group = .init;
    for (0..@min(tasks, items)) |_| group.concurrent(io, Shared.run, .{&shared}) catch Shared.run(&shared);
    group.await(io) catch {};
}

const Summary = struct {
    median: f64,
    min: f64,
    max: f64,

    fn of(values: []f64) Summary {
        std.mem.sort(f64, values, {}, std.sort.asc(f64));
        return .{ .median = values[values.len / 2], .min = values[0], .max = values[values.len - 1] };
    }
};

const Percentiles = struct {
    p50: f64 = 0,
    p95: f64 = 0,
    p99: f64 = 0,
    max: f64 = 0,

    /// Sorts in place, reports microseconds
    fn of(samples_ns: []u64) Percentiles {
        if (samples_ns.len == 0) return .{};
        std.mem.sort(u64, samples_ns, {}, std.sort.asc(u64));
        return .{ .p50 = at(samples_ns, 0.50), .p95 = at(samples_ns, 0.95), .p99 = at(samples_ns, 0.99), .max = at(samples_ns, 1.0) };
    }

    fn at(sorted: []const u64, p: f64) f64 {
        const index: usize = @intFromFloat(@floor(p * @as(f64, @floatFromInt(sorted.len - 1))));
        return @as(f64, @floatFromInt(sorted[index])) / 1000;
    }
};

fn elapsedS(io: std.Io, since: u64) f64 {
    return @as(f64, @floatFromInt(nowNs(io) - since)) / std.time.ns_per_s;
}

fn mib(bytes: f64) f64 {
    return bytes / (1024 * 1024);
}

const Backends = struct {
    items: []Backend,
    ports: []u16,

    fn start(env: *Env, count: usize) !Backends {
        const items = try env.gpa.alloc(Backend, count);
        errdefer env.gpa.free(items);
        const ports = try env.gpa.alloc(u16, count);
        errdefer env.gpa.free(ports);
        var started: usize = 0;
        errdefer for (items[0..started]) |*backend| backend.deinit();
        for (items, ports) |*backend, *port| {
            try backend.start(env.gpa, env.io, env.frames);
            started += 1;
            port.* = backend.port();
        }
        return .{ .items = items, .ports = ports };
    }

    fn deinit(self: Backends, env: *Env) void {
        for (self.items) |*backend| backend.deinit();
        env.gpa.free(self.items);
        env.gpa.free(self.ports);
    }
};

/// Players past the clear handshake, so the proxy has switched its Tap off
fn joinedPlayers(env: *Env, address: std.Io.net.IpAddress, count: usize) ![]Player {
    const players = try env.gpa.alloc(Player, count);
    errdefer env.gpa.free(players);
    var joined: usize = 0;
    errdefer for (players[0..joined]) |*player| player.deinit();
    for (players) |*player| {
        try player.connect(env.gpa, env.io, address);
        joined += 1;
        try player.handshake(env.frames);
    }
    return players;
}

fn leave(env: *Env, players: []Player) void {
    for (players) |*player| player.deinit();
    env.gpa.free(players);
}

const RelayResult = struct {
    round_trips: Summary,
    mib_s: Summary,
    latency: Percentiles,
    lost: usize,
    cpu_pct: f64,
};

const RelayJob = struct {
    io: std.Io,
    player: *Player,
    payload: []u8,
    window: usize,
    until_ns: u64,
    recorder: Recorder = .{},
    lost: bool = false,

    fn run(job: *RelayJob) void {
        const player = job.player;
        player.recorder = &job.recorder;
        player.count_until_ns = job.until_ns;
        defer player.recorder = null;
        const first = player.received;
        var sent: u64 = 0;
        while (true) {
            const now = nowNs(job.io);
            if (now < job.until_ns) {
                while (sent -| (player.received - first) < job.window) : (sent += 1) {
                    harness.stamp(job.payload, job.io);
                    player.send(job.payload) catch {
                        job.lost = true;
                        return;
                    };
                }
            } else if (player.received - first >= sent) {
                return;
            } else if (now > job.until_ns + 3 * std.time.ns_per_s) {
                job.lost = true;
                return;
            }
            player.pollOnce(10) catch {
                job.lost = true;
                return;
            };
        }
    }
};

/// Every player keeps `window` echoes in flight for each timed iteration
fn relay(env: *Env, proxy: *Proxy, players: []Player, size: usize, window: usize) !RelayResult {
    const gpa = env.gpa;
    const io = env.io;
    const jobs = try gpa.alloc(RelayJob, players.len);
    defer gpa.free(jobs);
    // Random, so compression can't flatter managed mode
    var prng: std.Random.DefaultPrng = .init(size);
    for (jobs, players) |*job, *player| {
        const payload = try gpa.alloc(u8, size);
        prng.random().bytes(payload);
        payload[0] = 0xfe;
        job.* = .{ .io = io, .player = player, .payload = payload, .window = window, .until_ns = 0 };
        job.recorder.latencies_ns = try .initCapacity(gpa, 1 << 18);
    }
    defer for (jobs) |*job| {
        gpa.free(job.payload);
        job.recorder.deinit(gpa);
    };

    var latencies: std.ArrayList(u64) = .empty;
    defer latencies.deinit(gpa);
    var round_trips: [8]f64 = undefined;
    var throughput: [8]f64 = undefined;
    var lost: usize = 0;
    var cpu_before: Snapshot = .{};
    var measuring_since: u64 = 0;
    const iterations = env.iterations();
    for (0..iterations + 1) |iteration| {
        const duration_ms = if (iteration == 0) env.warmupMs() else env.iterationMs();
        if (iteration == 1) {
            cpu_before = try proxy.stats();
            measuring_since = nowNs(io);
        }
        const started = nowNs(io);
        for (jobs) |*job| {
            job.until_ns = started + duration_ms * std.time.ns_per_ms;
            job.recorder.latencies_ns.clearRetainingCapacity();
            job.recorder.messages = 0;
            job.recorder.bytes = 0;
        }
        var group: std.Io.Group = .init;
        for (jobs) |*job| group.concurrent(io, RelayJob.run, .{job}) catch RelayJob.run(job);
        try group.await(io);
        if (iteration == 0) continue;

        var messages: u64 = 0;
        var bytes: u64 = 0;
        for (jobs) |*job| {
            messages += job.recorder.messages;
            bytes += job.recorder.bytes;
            lost += @intFromBool(job.lost);
            try latencies.appendSlice(gpa, job.recorder.latencies_ns.items);
        }
        const seconds = @as(f64, @floatFromInt(duration_ms)) / 1000;
        round_trips[iteration - 1] = @as(f64, @floatFromInt(messages)) / seconds;
        throughput[iteration - 1] = mib(@as(f64, @floatFromInt(bytes))) / seconds;
    }
    const cpu_after = try proxy.stats();
    const wall_us = (nowNs(io) - measuring_since) / 1000;
    return .{
        .cpu_pct = @as(f64, @floatFromInt(cpu_after.cpu_us - cpu_before.cpu_us)) * 100 / @as(f64, @floatFromInt(wall_us)),
        .round_trips = .of(round_trips[0..iterations]),
        .mib_s = .of(throughput[0..iterations]),
        .latency = .of(latencies.items),
        .lost = lost,
    };
}

const Mixed = struct { light: Percentiles, hot: ?Percentiles };

fn mixedRelay(env: *Env, players: []Player, light_count: usize) !Mixed {
    const gpa = env.gpa;
    const io = env.io;
    const jobs = try gpa.alloc(RelayJob, players.len);
    defer gpa.free(jobs);
    for (jobs, players, 0..) |*job, *player, i| {
        const light = i < light_count;
        const payload = try gpa.alloc(u8, if (light) 64 else 512);
        @memset(payload, 0x5a);
        payload[0] = 0xfe;
        job.* = .{ .io = io, .player = player, .payload = payload, .window = if (light) 1 else 32, .until_ns = 0 };
        job.recorder.latencies_ns = try .initCapacity(gpa, 1 << 18);
    }
    defer for (jobs) |*job| {
        gpa.free(job.payload);
        job.recorder.deinit(gpa);
    };
    var light: std.ArrayList(u64) = .empty;
    defer light.deinit(gpa);
    var hot: std.ArrayList(u64) = .empty;
    defer hot.deinit(gpa);
    for (0..env.iterations() + 1) |iteration| {
        const started = nowNs(io);
        const duration_ms = if (iteration == 0) env.warmupMs() else env.iterationMs();
        for (jobs) |*job| {
            job.until_ns = started + duration_ms * std.time.ns_per_ms;
            job.recorder.latencies_ns.clearRetainingCapacity();
        }
        var group: std.Io.Group = .init;
        for (jobs) |*job| group.concurrent(io, RelayJob.run, .{job}) catch RelayJob.run(job);
        try group.await(io);
        if (iteration == 0) continue;
        for (jobs, 0..) |*job, i| try (if (i < light_count) &light else &hot).appendSlice(gpa, job.recorder.latencies_ns.items);
    }
    return .{ .light = .of(light.items), .hot = if (hot.items.len == 0) null else .of(hot.items) };
}

fn fairnessScenario(env: *Env) !void {
    var backends: Backends = try .start(env, 1);
    defer backends.deinit(env);
    var proxy: Proxy = undefined;
    try env.startProxy(&proxy, .{ .backends = backends.ports[0..1] });
    defer proxy.stop();
    const players = try joinedPlayers(env, proxy.address(), 8);
    defer leave(env, players);

    const alone = try mixedRelay(env, players[0..4], 4);
    const loaded = try mixedRelay(env, players, 4);
    try env.out.print(
        \\
        \\## Fairness
        \\
        \\4 light players (64 B, 1 in flight) alone, then next to 4 hot players (512 B, 32 in flight), 1 worker, passthrough.
        \\
        \\| run | light p50 us | light p99 us | hot p50 us | hot p99 us |
        \\|---|---|---|---|---|
        \\| alone | {d:.0} | {d:.0} | - | - |
        \\| with hot players | {d:.0} | {d:.0} | {d:.0} | {d:.0} |
        \\
    , .{ alone.light.p50, alone.light.p99, loaded.light.p50, loaded.light.p99, loaded.hot.?.p50, loaded.hot.?.p99 });
}

fn windowFor(size: usize) usize {
    return std.math.clamp(256 * 1024 / size, 1, 32);
}

fn relayScenario(env: *Env) !void {
    const backends: Backends = try .start(env, 1);
    defer backends.deinit(env);
    var proxy: Proxy = undefined;
    try env.startProxy(&proxy, .{ .backends = backends.ports });
    defer proxy.stop();
    const base = try proxy.stats();
    env.memory.base_kb = base.rss_kb;
    env.memory.pool_bytes = base.pool_bytes;

    const loaded_players = 8;
    const players = try joinedPlayers(env, proxy.address(), loaded_players);
    defer leave(env, players);
    const joined = try proxy.stats();
    const idle_cpu = try idleCpu(env, &proxy, players);

    try env.out.print(
        \\
        \\## Raw relay
        \\
        \\Player -> Bifrost -> backend echo -> Bifrost -> player, after the Tap has seen the handshake and switched off.
        \\1 worker, 1 backend. "1x1" is one player with one message in flight; "8xN" is 8 players with N in flight each.
        \\Round trips/s and MiB/s (one way) are median [min-max] over iterations; latency is round-trip in us.
        \\
        \\| payload | load | round trips/s | MiB/s | p50 | p95 | p99 | proxy CPU | lost |
        \\|---|---|---|---|---|---|---|---|---|
        \\
    , .{});
    for ([_]usize{ 64, 512, 8 * 1024, 20 * 1024 }) |size| {
        for ([_]bool{ false, true }) |loaded| {
            const window = if (loaded) windowFor(size) else 1;
            const result = try relay(env, &proxy, if (loaded) players else players[0..1], size, window);
            try env.out.print("| {Bi} | {s}{d} | {d:.0} [{d:.0}-{d:.0}] | {d:.1} [{d:.1}-{d:.1}] | {d:.0} | {d:.0} | {d:.0} | {d:.0}% | {d} |\n", .{
                size,                      if (loaded) "8x" else "1x", window,
                result.round_trips.median, result.round_trips.min,     result.round_trips.max,
                result.mib_s.median,       result.mib_s.min,           result.mib_s.max,
                result.latency.p50,        result.latency.p95,         result.latency.p99,
                result.cpu_pct,            result.lost,
            });
            try env.out.flush();
        }
    }
    const after = try proxy.stats();
    env.memory.peak = .{ .kb = after.hwm_kb, .what = "8 players relaying up to 20 KiB" };
    try env.out.print("\nTap: {d} handshakes observed, {d} gave up. Proxy RSS {d} KiB fresh, {d} KiB with 8 players, peak {d} KiB. Proxy CPU with 8 silent players: {d:.1}%.\n", .{
        after.handshakes, after.gave_up, base.rss_kb, joined.rss_kb, after.hwm_kb, idle_cpu,
    });
}

const ManagedSetup = struct {
    name: []const u8,
    managed: bool = true,
    plugins: []const u8 = "none",
    backends: usize = 1,
};
const managed_setups = [_]ManagedSetup{
    .{ .name = "passthrough", .managed = false },
    .{ .name = "managed, transfers possible", .backends = 2 },
    .{ .name = "managed, relayed", .backends = 1 },
    .{ .name = "managed, relayed, 10 idle plugins", .plugins = "idle_10" },
    .{ .name = "managed, 1 decoded subscriber", .plugins = "one_decoded" },
};
const managed_sizes = [_]usize{ 256, 1024, 8 * 1024, 20 * 1024 };

const ManagedRow = struct { result: RelayResult, relayed_pct: f64 };

fn managedScenario(env: *Env) !void {
    var rows: [managed_setups.len][managed_sizes.len][2]ManagedRow = undefined;
    var join_ms: [managed_setups.len]f64 = undefined;
    for (managed_setups, &rows, &join_ms) |setup, *setup_rows, *join| {
        var echoes: [2]managed.Backend = undefined;
        var started_echoes: usize = 0;
        var passthrough: ?Backends = null;
        defer {
            for (echoes[0..started_echoes]) |*echo| echo.deinit();
            if (passthrough) |b| b.deinit(env);
        }
        var ports: [2]u16 = undefined;
        if (setup.managed) {
            for (echoes[0..setup.backends], ports[0..setup.backends]) |*echo, *port| {
                try echo.start(env.gpa, env.io);
                started_echoes += 1;
                port.* = echo.port();
            }
        } else {
            passthrough = try .start(env, 1);
            ports[0] = passthrough.?.ports[0];
        }
        var proxy: Proxy = undefined;
        try env.startProxy(&proxy, .{ .backends = ports[0..setup.backends], .managed = setup.managed, .plugins = setup.plugins });
        defer proxy.stop();

        const players = try env.gpa.alloc(Player, 8);
        var joined: usize = 0;
        defer {
            for (players[0..joined]) |*player| player.deinit();
            env.gpa.free(players);
        }
        const started = nowNs(env.io);
        for (players, 0..) |*player, i| {
            try player.connect(env.gpa, env.io, proxy.address());
            joined += 1;
            if (setup.managed) try managed.join(env.gpa, env.io, player, @intCast(i + 2)) else try player.handshake(env.frames);
        }
        join.* = elapsedS(env.io, started) * 1000 / @as(f64, @floatFromInt(players.len));
        for (managed_sizes, setup_rows) |size, *pair| for (pair, 0..) |*row, loaded| {
            const before = try proxy.stats();
            const result = try relay(env, &proxy, if (loaded == 1) players else players[0..1], size, if (loaded == 1) windowFor(size) else 1);
            const after = try proxy.stats();
            const relayed: f64 = @floatFromInt(after.relayed - before.relayed);
            const decoded: f64 = @floatFromInt(after.decoded - before.decoded);
            row.* = .{ .result = result, .relayed_pct = if (relayed + decoded == 0) 0 else relayed * 100 / (relayed + decoded) };
        };
    }

    try env.out.print(
        \\
        \\## Passthrough vs managed
        \\
        \\Same echo workload as the raw relay, 1 worker, random payloads, deflate over 256 B on both legs. Decoded batches
        \\are decrypted, decompressed, re-batched, compressed and encrypted again. Relayed batches are only re-encrypted.
        \\Two backends make transfers possible, so every batch is decoded for client state tracking; active transfers and
        \\runtime ID mapping always take that path. The decoded subscriber listens to player packets only.
        \\
        \\| payload | load | setup | round trips/s | MiB/s | p50 us | p95 us | p99 us | proxy CPU | relayed |
        \\|---|---|---|---|---|---|---|---|---|---|
        \\
    , .{});
    for (managed_sizes, 0..) |size, s| for (0..2) |loaded| for (managed_setups, rows) |setup, setup_rows| {
        const row = setup_rows[s][loaded];
        const result = row.result;
        try env.out.print("| {Bi} | {s}{d} | {s} | {d:.0} [{d:.0}-{d:.0}] | {d:.1} | {d:.0} | {d:.0} | {d:.0} | {d:.0}% | {d:.0}% |\n", .{
            size,                   if (loaded == 1) "8x" else "1x", if (loaded == 1) windowFor(size) else 1,
            setup.name,             result.round_trips.median,       result.round_trips.min,
            result.round_trips.max, result.mib_s.median,             result.latency.p50,
            result.latency.p95,     result.latency.p99,              result.cpu_pct,
            row.relayed_pct,
        });
    };
    try env.out.print("\nJoin time per player:", .{});
    for (managed_setups, join_ms) |setup, ms| try env.out.print(" {d:.1} ms {s};", .{ ms, setup.name });
    try env.out.print("\n", .{});
}

const deflate_levels = [_]struct { name: []const u8, options: std.compress.flate.Compress.Options }{
    .{ .name = "1", .options = .level_1 },
    .{ .name = "4", .options = .level_4 },
    .{ .name = "6 (used)", .options = .level_6 },
    .{ .name = "9", .options = .level_9 },
};

fn deflateScenario(env: *Env) !void {
    try env.out.print(
        \\
        \\## Deflate levels
        \\
        \\In-process raw deflate of one batch, for comparison only; Bedwire compresses at level 6. "Game" repeats a
        \\structured 64 B record with a few changing bytes, "noise" is random.
        \\
        \\| data | size | level | us per batch | MiB/s | output |
        \\|---|---|---|---|---|---|
        \\
    , .{});
    const input = try env.gpa.alloc(u8, 64 * 1024);
    defer env.gpa.free(input);
    const output = try env.gpa.alloc(u8, 128 * 1024);
    defer env.gpa.free(output);
    const history = try env.gpa.create([std.compress.flate.max_window_len]u8);
    defer env.gpa.destroy(history);
    var prng: std.Random.DefaultPrng = .init(0xdef1a7e);
    for ([_]bool{ true, false }) |game| {
        if (game) {
            for (input, 0..) |*byte, i| byte.* = @truncate(i % 64 *% 31 +% 7);
            var i: usize = 0;
            while (i < input.len) : (i += 64) prng.random().bytes(input[i..][0..4]);
        } else prng.random().bytes(input);
        for ([_]usize{ 1024, 8 * 1024, 64 * 1024 }) |size| for (deflate_levels) |level| {
            const mib_per_level: usize = if (env.quick) 4 else 16;
            const rounds = @max(4, mib_per_level * 1024 * 1024 / size);
            var len: usize = 0;
            const started = nowNs(env.io);
            for (0..rounds) |_| {
                var writer: std.Io.Writer = .fixed(output);
                var compressor: std.compress.flate.Compress = try .init(&writer, history, .raw, level.options);
                try compressor.writer.writeAll(input[0..size]);
                try compressor.finish();
                len = writer.end;
            }
            const ns = @as(f64, @floatFromInt(nowNs(env.io) - started)) / @as(f64, @floatFromInt(rounds));
            try env.out.print("| {s} | {Bi} | {s} | {d:.1} | {d:.0} | {d:.1}% |\n", .{
                if (game) "game" else "noise",                 size,                                                               level.name, ns / 1000,
                mib(@as(f64, @floatFromInt(size))) * 1e9 / ns, @as(f64, @floatFromInt(len)) * 100 / @as(f64, @floatFromInt(size)),
            });
        };
    }
}

fn idsScenario(env: *Env) !void {
    const results = try bench_ids.run(env.gpa, env.io, env.quick);
    try env.out.print(
        \\
        \\## Player id translation
        \\
        \\Per-packet work a managed relay adds after a transfer to keep the client's own actor ids, in-process. Half the
        \\stream is MovePlayer and SetActorMotion, the rest text and raw packets that are never decoded. Packets naming
        \\the player are decoded, rewritten and re-encoded.
        \\
        \\| case | ns per packet | added ns |
        \\|---|---|---|
        \\
    , .{});
    for (results) |result| try env.out.print("| {s} | {d:.1} | {d:.1} |\n", .{ result.case.describe(), result.ns_per_packet, result.extra_ns });
}

fn tasksScenario(env: *Env) !void {
    const result = try bench_tasks.measure(env.gpa, env.io, env.quick);
    try env.out.print(
        \\
        \\## Plugin tasks
        \\
        \\Empty tasks from one plugin and player, in-process, with `done` drained on the submitting thread.
        \\
        \\| tasks/s, up to the limit in flight | submit to done p50 | p99 |
        \\|---|---|---|
        \\| {d:.0} | {d:.1} us | {d:.1} us |
        \\
    , .{ result.tasks_per_s, result.p50_us, result.p99_us });
}

const plugin_relays = [_]bench_plugins.Setup{ .none, .idle_10, .one_raw, .one_decoded, .ten_ids, .ten_hot };

fn pluginsScenario(env: *Env) !void {
    const dispatch = try bench_plugins.dispatch(env.gpa, env.io, env.quick);
    try env.out.print(
        \\
        \\## Plugin packet dispatch
        \\
        \\Per-packet work a managed relay adds for plugins, in-process: the table check, and the callbacks when someone
        \\subscribed. The stream alternates a text packet (the hot packet here) and a 64 B raw packet. Callbacks do
        \\nothing, so the cost is dispatch, timing and metrics. Decoded subscribers get the packet only after a full decode.
        \\
        \\| setup | ns per packet | added ns | ns per callback | budget |
        \\|---|---|---|---|---|
        \\
    , .{});
    for (dispatch) |result| {
        const callbacks = result.setup.callbacksPerPacket();
        const cost = if (callbacks == 0) result.extra_ns else result.extra_ns / callbacks;
        const budget = result.setup.budgetNs();
        try env.out.print("| {s} | {d:.1} | {d:.1} | {d:.1} | {s} {d:.0} ns |\n", .{
            result.setup.describe(),              result.ns_per_packet,
            result.extra_ns,                      cost,
            if (cost <= budget) "ok" else "OVER", budget,
        });
    }

    var results: [plugin_relays.len][2]RelayResult = undefined;
    var heaps: [plugin_relays.len][2]u64 = undefined;
    for (plugin_relays, &results, &heaps) |setup, *result, *heap| {
        var echo: managed.Backend = undefined;
        try echo.start(env.gpa, env.io);
        defer echo.deinit();
        var proxy: Proxy = undefined;
        try env.startProxy(&proxy, .{ .backends = &.{echo.port()}, .managed = true, .plugins = @tagName(setup) });
        defer proxy.stop();
        heap[0] = (try proxy.stats()).heap_bytes;
        const players = try env.gpa.alloc(Player, 8);
        var joined: usize = 0;
        defer {
            for (players[0..joined]) |*player| player.deinit();
            env.gpa.free(players);
        }
        for (players, 0..) |*player, i| {
            try player.connect(env.gpa, env.io, proxy.address());
            joined += 1;
            try managed.join(env.gpa, env.io, player, @intCast(i + 2));
        }
        heap[1] = ((try proxy.stats()).heap_bytes - heap[0]) / players.len;
        result[0] = try relay(env, &proxy, players[0..1], 512, 1);
        result[1] = try relay(env, &proxy, players, 512, windowFor(512));
    }
    try env.out.print(
        \\
        \\Managed echo relay, 512 B, 1 worker, with the same setups. Here the hot packet is the relayed payload itself.
        \\
        \\| setup | load | round trips/s | p50 us | p95 us | p99 us | proxy CPU |
        \\|---|---|---|---|---|---|---|
        \\
    , .{});
    for (plugin_relays, results) |setup, pair| for (pair, 0..) |result, loaded| {
        try env.out.print("| {s} | {s} | {d:.0} [{d:.0}-{d:.0}] | {d:.0} | {d:.0} | {d:.0} | {d:.0}% |\n", .{
            setup.describe(),          if (loaded == 1) "8x32" else "1x1",
            result.round_trips.median, result.round_trips.min,
            result.round_trips.max,    result.latency.p50,
            result.latency.p95,        result.latency.p99,
            result.cpu_pct,
        });
    };
    try env.out.print(
        \\
        \\| setup | heap of a fresh managed proxy | heap per managed player |
        \\|---|---|---|
        \\
    , .{});
    for (plugin_relays, heaps) |setup, heap| try env.out.print("| {s} | {Bi:.1} | {Bi:.1} |\n", .{ setup.describe(), heap[0], heap[1] });
}

/// Proxy CPU while connected players send nothing; should be close to zero
fn idleCpu(env: *Env, proxy: *Proxy, players: []Player) !f64 {
    const before = try proxy.stats();
    const started = nowNs(env.io);
    const Idle = struct {
        fn run(list: []Player, _: usize) void {
            for (0..20) |_| for (list) |*player| player.idle(5) catch {};
        }
    };
    parallel(env.io, 1, 1, players, Idle.run);
    const after = try proxy.stats();
    return @as(f64, @floatFromInt(after.cpu_us - before.cpu_us)) * 100_000 / @as(f64, @floatFromInt(nowNs(env.io) - started));
}

const HandshakeRun = struct {
    env: *Env,
    address: std.Io.net.IpAddress,
    raw_request: []u8,
    raw_login: []u8,
    observed_ns: []u64,
    raw_ns: []u64,
    failed: std.atomic.Value(u32) = .init(0),

    fn one(run: *HandshakeRun, i: usize) void {
        const io = run.env.io;
        var player: Player = undefined;
        player.connect(run.env.gpa, io, run.address) catch {
            _ = run.failed.fetchAdd(1, .monotonic);
            return;
        };
        defer player.deinit();
        const started = nowNs(io);
        player.handshake(run.env.frames) catch {
            _ = run.failed.fetchAdd(1, .monotonic);
            return;
        };
        const observed = nowNs(io);
        player.exchange(run.raw_request, run.raw_request, 5_000) catch {};
        player.exchange(run.raw_login, run.raw_login, 5_000) catch {
            _ = run.failed.fetchAdd(1, .monotonic);
            return;
        };
        run.observed_ns[i] = observed - started;
        run.raw_ns[i] = nowNs(io) - observed;
    }
};

fn handshakeScenario(env: *Env) !void {
    const gpa = env.gpa;
    const backends: Backends = try .start(env, 1);
    defer backends.deinit(env);
    var proxy: Proxy = undefined;
    try env.startProxy(&proxy, .{ .backends = backends.ports });
    defer proxy.stop();

    const count: usize = if (env.quick) 100 else 400;
    const raw_request = try gpa.alloc(u8, env.frames.request.len);
    defer gpa.free(raw_request);
    const raw_login = try gpa.alloc(u8, env.frames.login.len);
    defer gpa.free(raw_login);
    for ([_][]u8{ raw_request, raw_login }) |raw| {
        @memset(raw, 0x5a);
        raw[0] = 0xfe;
    }
    var run: HandshakeRun = .{
        .env = env,
        .address = proxy.address(),
        .raw_request = raw_request,
        .raw_login = raw_login,
        .observed_ns = try gpa.alloc(u64, count),
        .raw_ns = try gpa.alloc(u64, count),
    };
    defer gpa.free(run.observed_ns);
    defer gpa.free(run.raw_ns);
    @memset(run.observed_ns, 0);
    @memset(run.raw_ns, 0);

    parallel(env.io, count / 4, 8, &run, HandshakeRun.one); // warmup, overwritten below
    parallel(env.io, count, 8, &run, HandshakeRun.one);
    const stats = try proxy.stats();
    const observed: Percentiles = .of(run.observed_ns);
    const raw: Percentiles = .of(run.raw_ns);

    try env.out.print(
        \\
        \\## Handshake observer
        \\
        \\Per player: RequestNetworkSettings -> NetworkSettings, then compressed Login ({d} B, fragmented) -> ServerToClientHandshake,
        \\which ends the Tap. "Raw" is the same two exchanges with identical sizes after the Tap is off.
        \\{d} players, 8 at a time, after {d} warmup players. Times are for both exchanges, in us.
        \\
        \\| path | p50 | p95 | p99 |
        \\|---|---|---|---|
        \\| observed handshake | {d:.0} | {d:.0} | {d:.0} |
        \\| raw relay, same bytes | {d:.0} | {d:.0} | {d:.0} |
        \\
        \\Observer cost at p50: {d:.0} us per player ({d:.2}x raw). Tap: {d} handshakes observed, {d} gave up, {d} failed players.
        \\
    , .{
        env.frames.login.len,
        count,
        count / 4,
        observed.p50,
        observed.p95,
        observed.p99,
        raw.p50,
        raw.p95,
        raw.p99,
        observed.p50 - raw.p50,
        observed.p50 / raw.p50,
        stats.handshakes,
        stats.gave_up,
        run.failed.load(.monotonic),
    });
}

const HoldRun = struct {
    env: *Env,
    address: std.Io.net.IpAddress,
    players: []Player,
    connected: []bool,
    latency_ns: []u64,
    concurrency: usize,
    done: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(usize) = .init(0),
    release: std.atomic.Value(bool) = .init(false),

    fn one(run: *HoldRun, i: usize) void {
        const io = run.env.io;
        while (run.done.load(.acquire) + run.concurrency <= i) sleepMs(io, 1);
        const started = nowNs(io);
        const player = &run.players[i];
        joinOne(run.env, player, run.address) catch {
            _ = run.failed.fetchAdd(1, .monotonic);
            _ = run.done.fetchAdd(1, .release);
            return;
        };
        run.latency_ns[i] = nowNs(io) - started;
        run.connected[i] = true;
        _ = run.done.fetchAdd(1, .release);
        while (!run.release.load(.acquire)) player.idle(50) catch {
            _ = run.failed.fetchAdd(1, .monotonic);
            return;
        };
    }
};

fn joinOne(env: *Env, player: *Player, address: std.Io.net.IpAddress) !void {
    try player.connect(env.gpa, env.io, address);
    errdefer player.deinit();
    try player.handshake(env.frames);
    var ping: [64]u8 = @splat(0x33);
    ping[0] = 0xfe;
    try player.exchange(&ping, &ping, 5_000);
}

const Wave = struct {
    joined: usize,
    join_rate: f64,
    join_latency: Percentiles,
    leave_rate: f64,
    drops: u64,
    held: Snapshot,
    after: Snapshot,
};

/// Joins `count` players, holds them, then has them all leave at once
fn wave(env: *Env, proxy: *Proxy, count: usize) !Wave {
    const gpa = env.gpa;
    const io = env.io;
    var run: HoldRun = .{
        .env = env,
        .address = proxy.address(),
        .players = try gpa.alloc(Player, count),
        .connected = try gpa.alloc(bool, count),
        .latency_ns = try gpa.alloc(u64, count),
        .concurrency = 64,
    };
    defer gpa.free(run.players);
    defer gpa.free(run.connected);
    defer gpa.free(run.latency_ns);
    @memset(run.connected, false);

    const drops_before = harness.udpReceiveDrops(io);
    const closed_before = (try proxy.stats()).closed;
    const started = nowNs(io);
    var group: std.Io.Group = .init;
    for (0..count) |i| group.concurrent(io, holdOne, .{ &run, i }) catch {
        _ = run.failed.fetchAdd(1, .monotonic);
        _ = run.done.fetchAdd(1, .release);
    };
    while (run.done.load(.acquire) < count) sleepMs(io, 2);
    const join_s = elapsedS(io, started);
    const held = try proxy.stats();
    run.release.store(true, .release);
    try group.await(io);

    var latencies: std.ArrayList(u64) = .empty;
    defer latencies.deinit(gpa);
    for (run.connected, run.latency_ns) |ok, latency| if (ok) try latencies.append(gpa, latency);
    const joined = latencies.items.len;

    const leaving = nowNs(io);
    for (run.players, run.connected) |*player, ok| if (ok) player.deinit();
    const left = try proxy.waitClosed(held.accepted, 30_000);
    const leave_s = elapsedS(io, leaving);
    const drops = harness.udpReceiveDrops(io) - drops_before;
    sleepMs(io, 1_000);
    return .{
        .joined = joined,
        .join_rate = @as(f64, @floatFromInt(joined)) / join_s,
        .join_latency = .of(latencies.items),
        .leave_rate = @as(f64, @floatFromInt(left.closed - closed_before)) / leave_s,
        .drops = drops,
        .held = held,
        .after = try proxy.stats(),
    };
}

fn perPlayerKib(held: u64, base: u64, players: usize, scale: f64) f64 {
    return @as(f64, @floatFromInt(held -| base)) / scale / @as(f64, @floatFromInt(@max(players, 1)));
}

fn connectionsScenario(env: *Env) !void {
    const backends: Backends = try .start(env, 1);
    defer backends.deinit(env);
    const counts: []const usize = if (env.quick) &.{ 100, 500 } else &.{ 100, 500, 1000, 2000 };
    var waves: [4][2]Wave = undefined;
    var bases: [4]Snapshot = undefined;
    for (counts, 0..) |count, i| {
        var proxy: Proxy = undefined;
        try env.startProxy(&proxy, .{ .backends = backends.ports });
        defer proxy.stop();
        bases[i] = try proxy.stats();
        for (&waves[i]) |*result| result.* = try wave(env, &proxy, count);
    }

    try env.out.print(
        \\
        \\## Connections
        \\
        \\Each player connects, completes the observed handshake and one echo, with at most 64 joins in flight.
        \\Everyone then leaves at once; leave time runs until the proxy has freed every link.
        \\Each size runs two waves on one fresh proxy. "Drops" is the host's UDP RcvbufErrors delta: leave notifications
        \\the kernel dropped are only cleaned up by RakNet's 10 s idle timeout, which then dominates leaves/s.
        \\
        \\| players | wave | joined | joins/s | join p50 ms | join p99 ms | leaves/s | drops |
        \\|---|---|---|---|---|---|---|---|
        \\
    , .{});
    for (counts, 0..) |count, i| for (waves[i], 1..) |result, number| {
        try env.out.print("| {d} | {d} | {d} | {d:.0} | {d:.1} | {d:.1} | {d:.0} | {d} |\n", .{
            count,                          number,                         result.joined,     result.join_rate,
            result.join_latency.p50 / 1000, result.join_latency.p99 / 1000, result.leave_rate, result.drops,
        });
    };

    try env.out.print(
        \\
        \\Memory per held player, first wave vs the fresh proxy. Heap is live bytes through Bifrost's allocator; RakNet session
        \\is the listener's session quota; the rest of the heap is the backend RakNet client, Link, Tap and pending queue.
        \\RSS stays near its peak after players leave because the allocator keeps freed pages; heap after leave shows what is
        \\really still allocated.
        \\
        \\| players | RSS/player | heap/player | RakNet session | rest of heap | RSS held, wave 1 / 2 | RSS after leave | heap after leave |
        \\|---|---|---|---|---|---|---|---|
        \\
    , .{});
    for (counts, 0..) |count, i| {
        const base = bases[i];
        const first = waves[i][0];
        const second = waves[i][1];
        const rss = perPlayerKib(first.held.rss_kb, base.rss_kb, first.joined, 1);
        const heap = perPlayerKib(first.held.heap_bytes, base.heap_bytes, first.joined, 1024);
        const session = perPlayerKib(first.held.session_bytes, base.session_bytes, first.joined, 1024);
        const heap_left = @as(i64, @intCast(second.after.heap_bytes)) - @as(i64, @intCast(base.heap_bytes));
        try env.out.print("| {d} | {d:.1} KiB | {d:.1} KiB | {d:.1} KiB | {d:.1} KiB | {d} / {d} KiB | {d} KiB | {d} B |\n", .{
            count,             rss,                heap,                session,   heap - session,
            first.held.rss_kb, second.held.rss_kb, second.after.rss_kb, heap_left,
        });
        env.memory.per_player = .{ .players = first.joined, .rss_kb = rss, .heap_kb = heap, .session_kb = session };
        env.memory.retained = .{ .players = first.joined, .rss_kb = @as(i64, @intCast(second.after.rss_kb)) - @as(i64, @intCast(base.rss_kb)), .heap_bytes = heap_left };
    }
    try env.out.flush();
    try churn(env, backends.ports);
}

fn holdOne(run: *HoldRun, i: usize) void {
    HoldRun.one(run, i);
}

const ChurnRun = struct {
    env: *Env,
    address: std.Io.net.IpAddress,
    until_ns: u64,
    cycles: std.atomic.Value(u64) = .init(0),
    failed: std.atomic.Value(u64) = .init(0),
    latency_ns: []u64,
    samples: std.atomic.Value(usize) = .init(0),

    fn loop(run: *ChurnRun, _: usize) void {
        const io = run.env.io;
        while (nowNs(io) < run.until_ns) {
            const started = nowNs(io);
            var player: Player = undefined;
            joinOne(run.env, &player, run.address) catch {
                _ = run.failed.fetchAdd(1, .monotonic);
                continue;
            };
            player.deinit();
            const slot = run.samples.fetchAdd(1, .monotonic);
            if (slot < run.latency_ns.len) run.latency_ns[slot] = nowNs(io) - started;
            _ = run.cycles.fetchAdd(1, .monotonic);
        }
    }

    fn latencies(run: *ChurnRun) Percentiles {
        return .of(run.latency_ns[0..@min(run.samples.load(.monotonic), run.latency_ns.len)]);
    }
};

fn churn(env: *Env, backend_ports: []const u16) !void {
    var proxy: Proxy = undefined;
    try env.startProxy(&proxy, .{ .backends = backend_ports });
    defer proxy.stop();
    const base = try proxy.stats();
    const latency_ns = try env.gpa.alloc(u64, 1 << 16);
    defer env.gpa.free(latency_ns);

    try env.out.print(
        \\
        \\Rapid reconnect churn: 32 tasks each looping connect -> handshake -> echo -> disconnect.
        \\Memory is read once every link from the round is freed. Fresh proxy: {d} KiB RSS, {d} B heap.
        \\
        \\| round | cycles/s | cycle p50 ms | cycle p99 ms | failed | RSS after | heap after |
        \\|---|---|---|---|---|---|---|
        \\
    , .{ base.rss_kb, base.heap_bytes });
    const round_ms: u64 = if (env.quick) 1_000 else 3_000;
    for (0..env.memory.churn_kb.len) |round| {
        var run: ChurnRun = .{
            .env = env,
            .address = proxy.address(),
            .until_ns = nowNs(env.io) + round_ms * std.time.ns_per_ms,
            .latency_ns = latency_ns,
        };
        const started = nowNs(env.io);
        parallel(env.io, 32, 32, &run, ChurnRun.loop);
        const seconds = elapsedS(env.io, started);
        const accepted = (try proxy.stats()).accepted;
        const settled = try proxy.waitClosed(accepted, 30_000);
        env.memory.churn_kb[round] = settled.rss_kb;
        env.memory.churn_heap[round] = settled.heap_bytes;
        const latency = run.latencies();
        try env.out.print("| {d} | {d:.0} | {d:.1} | {d:.1} | {d} | {d} KiB | {d} B |\n", .{
            round + 1,
            @as(f64, @floatFromInt(run.cycles.load(.monotonic))) / seconds,
            latency.p50 / 1000,
            latency.p99 / 1000,
            run.failed.load(.monotonic),
            settled.rss_kb,
            settled.heap_bytes,
        });
        try env.out.flush();
    }
}

fn workersScenario(env: *Env) !void {
    const backends: Backends = try .start(env, 4);
    defer backends.deinit(env);
    const player_count: usize = if (env.quick) 32 else 64;
    const size = 512;
    const window = 8;

    try env.out.print(
        \\
        \\## Workers
        \\
        \\{d} players, {d} B echoes, {d} in flight each, 4 backends. CPU is proxy CPU time over wall time while measuring (100% = one core).
        \\Players spread across workers by the kernel's SO_REUSEPORT hash.
        \\
        \\| workers | round trips/s | MiB/s | p50 us | p99 us | proxy CPU | RSS | players per worker |
        \\|---|---|---|---|---|---|---|---|
        \\
    , .{ player_count, size, window });
    for ([_]u8{ 1, 2, 4, 8 }) |workers| {
        if (workers > 1 and !bifrost.Config.multi_worker_supported) {
            try env.out.print("| {d} | Linux only |\n", .{workers});
            continue;
        }
        if (workers > env.cpus) continue;
        var proxy: Proxy = undefined;
        try env.startProxy(&proxy, .{ .workers = workers, .backends = backends.ports });
        defer proxy.stop();
        const players = try joinedPlayers(env, proxy.address(), player_count);
        defer leave(env, players);

        const result = try relay(env, &proxy, players, size, window);
        const after = try proxy.stats();

        try env.out.print("| {d} | {d:.0} [{d:.0}-{d:.0}] | {d:.1} | {d:.0} | {d:.0} | {d:.0}% | {d} KiB | ", .{
            workers,
            result.round_trips.median,
            result.round_trips.min,
            result.round_trips.max,
            result.mib_s.median,
            result.latency.p50,
            result.latency.p99,
            result.cpu_pct,
            after.rss_kb,
        });
        for (after.per_worker[0..after.workers], 0..) |count, i| try env.out.print("{s}{d}", .{ if (i == 0) "" else " / ", count });
        try env.out.print(" |\n", .{});
        try env.out.flush();
    }
}

fn backendsScenario(env: *Env) !void {
    try env.out.print(
        \\
        \\## Backends
        \\
        \\All with 1 worker. Join = connect + observed handshake + one echo.
        \\
        \\| case | joins/s | join p50 ms | join p99 ms | round trips/s (512 B, 32x8) | backend failures |
        \\|---|---|---|---|---|---|
        \\
    , .{});
    for ([_]usize{ 1, 4 }) |count| {
        const backends: Backends = try .start(env, count);
        defer backends.deinit(env);
        var proxy: Proxy = undefined;
        try env.startProxy(&proxy, .{ .backends = backends.ports });
        defer proxy.stop();
        const joins = try joinBurst(env, proxy.address(), 200);
        const players = try joinedPlayers(env, proxy.address(), 32);
        defer leave(env, players);
        const result = try relay(env, &proxy, players, 512, 8);
        try env.out.print("| {d} healthy | {d:.0} | {d:.1} | {d:.1} | {d:.0} | {d} |\n", .{
            count, joins.rate, joins.latency.p50 / 1000, joins.latency.p99 / 1000, result.round_trips.median, (try proxy.stats()).backend_failures,
        });
        try env.out.flush();
    }

    {
        const backends: Backends = try .start(env, 2);
        defer backends.deinit(env);
        backends.items[1].pause();
        var proxy: Proxy = undefined;
        try env.startProxy(&proxy, .{ .backends = backends.ports, .health_interval_ms = 500 });
        defer proxy.stop();
        sleepMs(env.io, 1_500);
        const joins = try joinBurst(env, proxy.address(), 200);
        try env.out.print("| 1 of 2 dead, health settled | {d:.0} | {d:.1} | {d:.1} | - | {d} |\n", .{
            joins.rate, joins.latency.p50 / 1000, joins.latency.p99 / 1000, (try proxy.stats()).backend_failures,
        });
        try env.out.flush();
    }

    try flapping(env);
    try failover(env);
}

const Joins = struct { rate: f64, latency: Percentiles, failed: u64 };

fn joinBurst(env: *Env, address: std.Io.net.IpAddress, count: usize) !Joins {
    const latency_ns = try env.gpa.alloc(u64, count);
    defer env.gpa.free(latency_ns);
    const Burst = struct {
        env: *Env,
        address: std.Io.net.IpAddress,
        latency_ns: []u64,
        ok: std.atomic.Value(usize) = .init(0),
        failed: std.atomic.Value(u64) = .init(0),

        fn one(burst: *@This(), _: usize) void {
            const started = nowNs(burst.env.io);
            var player: Player = undefined;
            joinOne(burst.env, &player, burst.address) catch {
                _ = burst.failed.fetchAdd(1, .monotonic);
                return;
            };
            player.deinit();
            burst.latency_ns[burst.ok.fetchAdd(1, .monotonic)] = nowNs(burst.env.io) - started;
        }
    };
    var burst: Burst = .{ .env = env, .address = address, .latency_ns = latency_ns };
    const started = nowNs(env.io);
    parallel(env.io, count, 16, &burst, Burst.one);
    const seconds = elapsedS(env.io, started);
    const ok = burst.ok.load(.monotonic);
    return .{ .rate = @as(f64, @floatFromInt(ok)) / seconds, .latency = .of(latency_ns[0..ok]), .failed = burst.failed.load(.monotonic) };
}

fn flapping(env: *Env) !void {
    const backends: Backends = try .start(env, 2);
    defer backends.deinit(env);
    var proxy: Proxy = undefined;
    try env.startProxy(&proxy, .{ .backends = backends.ports, .health_interval_ms = 500, .connect_timeout_ms = 500 });
    defer proxy.stop();
    sleepMs(env.io, 700);

    const run_ms: u64 = if (env.quick) 3_000 else 6_000;
    const latency_ns = try env.gpa.alloc(u64, 1 << 16);
    defer env.gpa.free(latency_ns);
    var run: ChurnRun = .{
        .env = env,
        .address = proxy.address(),
        .until_ns = nowNs(env.io) + run_ms * std.time.ns_per_ms,
        .latency_ns = latency_ns,
    };
    var toggler = try env.io.concurrent(toggle, .{ env, &backends.items[1], run.until_ns });
    const started = nowNs(env.io);
    parallel(env.io, 16, 16, &run, ChurnRun.loop);
    const seconds = elapsedS(env.io, started);
    toggler.await(env.io);
    const latency = run.latencies();
    try env.out.print("| 1 of 2 flapping every 1 s (16 churn tasks) | {d:.0} | {d:.1} | {d:.1} | - | {d} (players failed: {d}, max join {d:.0} ms) |\n", .{
        @as(f64, @floatFromInt(run.cycles.load(.monotonic))) / seconds,
        latency.p50 / 1000,
        latency.p99 / 1000,
        (try proxy.stats()).backend_failures,
        run.failed.load(.monotonic),
        latency.max / 1000,
    });
    try env.out.flush();
}

fn toggle(env: *Env, backend: *Backend, until_ns: u64) void {
    var down = false;
    while (nowNs(env.io) < until_ns) {
        sleepMs(env.io, 1_000);
        down = !down;
        if (down) backend.pause() else backend.serve() catch {};
    }
    backend.serve() catch {};
}

fn failover(env: *Env) !void {
    const backends: Backends = try .start(env, 2);
    defer backends.deinit(env);
    var proxy: Proxy = undefined;
    try env.startProxy(&proxy, .{ .backends = backends.ports, .health_interval_ms = 60_000, .connect_timeout_ms = 1_000 });
    defer proxy.stop();
    // Let the first health check mark both healthy, then kill the one the router picks first
    sleepMs(env.io, 300);
    backends.items[0].pause();

    var latency_ns: [10]u64 = undefined;
    for (&latency_ns) |*latency| {
        const started = nowNs(env.io);
        var player: Player = undefined;
        try joinOne(env, &player, proxy.address());
        player.deinit();
        latency.* = nowNs(env.io) - started;
    }
    const first = latency_ns[0];
    const rest: Percentiles = .of(latency_ns[1..]);
    try env.out.print(
        \\
        \\Initial-connect failover: 2 backends marked healthy, then the first one hangs (health interval 60 s, connect timeout 1000 ms).
        \\First player joins in {d:.0} ms (one timed-out dial, then the second backend); the next 9 take p50 {d:.1} ms since the dead one is now marked down.
        \\Backend failures: {d}.
        \\
    , .{
        @as(f64, @floatFromInt(first)) / std.time.ns_per_ms,
        rest.p50 / 1000,
        (try proxy.stats()).backend_failures,
    });
}

fn memorySummary(env: *Env) !void {
    const memory = env.memory;
    if (!harness_has_rss) {
        try env.out.print("\n## Memory\n\nRSS figures need Linux (/proc/self/status); this run reports zeros.\n", .{});
        return;
    }
    try env.out.print(
        \\
        \\## Memory
        \\
        \\| what | value |
        \\|---|---|
        \\
    , .{});
    if (memory.base_kb != 0) try env.out.print("| fresh proxy, 1 worker | {d} KiB RSS |\n", .{memory.base_kb});
    if (memory.pool_bytes != 0) try env.out.print("| Bedwire observer pool per worker (reserved, touched only by Login) | {Bi} |\n", .{memory.pool_bytes});
    if (memory.per_player) |per| {
        try env.out.print("| per held player at {d} players, RSS | {d:.1} KiB |\n", .{ per.players, per.rss_kb });
        try env.out.print("| per held player, heap: RakNet session + rest (backend client, Link, Tap) | {d:.1} + {d:.1} KiB |\n", .{ per.session_kb, per.heap_kb - per.session_kb });
    }
    if (memory.peak) |peak| try env.out.print("| peak RSS, {s} | {d} KiB |\n", .{ peak.what, peak.kb });
    if (memory.retained) |retained| try env.out.print("| after two waves of {d} players left: RSS above fresh / heap above fresh | {d} KiB / {d} B |\n", .{ retained.players, retained.rss_kb, retained.heap_bytes });
    if (memory.churn_kb[0] != 0) try env.out.print("| after each churn round: RSS / heap | {d} / {d} / {d} KiB, {d} / {d} / {d} B |\n", .{
        memory.churn_kb[0],   memory.churn_kb[1],   memory.churn_kb[2],
        memory.churn_heap[0], memory.churn_heap[1], memory.churn_heap[2],
    });
    try env.out.print("| pending queue cap per player (config) | {d} packets / {Bi} |\n", .{ (bifrost.Config{}).pending_packets, (bifrost.Config{}).pending_bytes });
}

const harness_has_rss = builtin.os.tag == .linux;
