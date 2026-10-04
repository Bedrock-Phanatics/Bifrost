const std = @import("std");
const toml = @import("toml");
const Backend = @import("../backend/Backend.zig");
const Config = @import("Config.zig");
const IpAddress = std.Io.net.IpAddress;

pub const max_file_size = 64 * 1024;

pub const Error = error{ InvalidSyntax, InvalidConfig, OutOfMemory };

pub const Diagnostic = struct {
    line: usize = 0,
    column: usize = 0,
    buffer: [192]u8 = undefined,
    len: usize = 0,

    pub fn message(self: *const Diagnostic) []const u8 {
        return self.buffer[0..self.len];
    }

    pub fn format(self: Diagnostic, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.line != 0) try w.print("line {d}, column {d}: ", .{ self.line, self.column });
        try w.writeAll(self.message());
    }

    fn set(self: *Diagnostic, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(&self.buffer, fmt, args) catch {
            self.len = self.buffer.len;
            return;
        };
        self.len = written.len;
    }
};

const Key = struct {
    section: []const u8,
    index: ?usize = null,
    name: ?[]const u8 = null,

    pub fn format(self: Key, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(self.section);
        if (self.index) |i| try w.print("[{d}]", .{i});
        if (self.name) |name| try w.print(".{s}", .{name});
    }
};

pub fn loadFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8, diag: *Diagnostic) (Error || std.Io.Dir.ReadFileAllocError)!Config {
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_size)) catch |err| switch (err) {
        error.StreamTooLong => {
            diag.set("file is larger than {d} bytes", .{max_file_size});
            return error.InvalidConfig;
        },
        else => return err,
    };
    defer gpa.free(source);
    return parse(gpa, source, diag);
}

pub fn parse(gpa: std.mem.Allocator, source: []const u8, diag: *Diagnostic) Error!Config {
    diag.* = .{};
    var parser = toml.Parser(toml.Table).init(gpa);
    defer parser.deinit();
    var parsed = parser.parseString(source) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        if (parser.error_info) |info| switch (info) {
            .parse => |position| {
                diag.line = position.line;
                diag.column = position.pos;
            },
            .struct_mapping, .unknown_fields => {},
        };
        diag.set("invalid TOML ({t})", .{err});
        return error.InvalidSyntax;
    };
    defer parsed.deinit();

    var config: Config = .{};
    try readRoot(&config, &parsed.value, diag);
    if (config.backend_count == 0) return fail(diag, .{ .section = "backend" }, "at least one [[backend]] is required", .{});
    if (config.max_players_per_ip > config.max_players)
        return fail(diag, .{ .section = "server", .name = "max_players_per_ip" }, "can't be more than max_players", .{});
    if (config.health_timeout_ms >= config.health_interval_ms)
        return fail(diag, .{ .section = "health", .name = "timeout_ms" }, "must be shorter than interval_ms", .{});
    if (config.auth == .verify and config.keysFile() == null)
        return fail(diag, .{ .section = "auth", .name = "keys_file" }, "is required when mode = \"verify\"", .{});
    if (config.session_mode == .managed) {
        if (config.auth != .verify)
            return fail(diag, .{ .section = "session", .name = "mode" }, "\"managed\" needs [auth] mode = \"verify\"", .{});
        if (config.proxyKeyFile() == null)
            return fail(diag, .{ .section = "session", .name = "proxy_key_file" }, "is required when mode = \"managed\"", .{});
    }
    return config;
}

fn readRoot(config: *Config, root: *const toml.Table, diag: *Diagnostic) Error!void {
    var it = root.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        const key: Key = .{ .section = name };
        if (eql(name, "server")) {
            try readServer(config, try table(diag, key, value), diag);
        } else if (eql(name, "limits")) {
            try readLimits(config, try table(diag, key, value), diag);
        } else if (eql(name, "health")) {
            try readHealth(config, try table(diag, key, value), diag);
        } else if (eql(name, "auth")) {
            try readAuth(config, try table(diag, key, value), diag);
        } else if (eql(name, "session")) {
            try readSession(config, try table(diag, key, value), diag);
        } else if (eql(name, "backend")) {
            if (value != .array) return fail(diag, key, "expected [[backend]] tables", .{});
            for (value.array.items, 0..) |item, i| {
                try readBackend(config, try table(diag, .{ .section = name, .index = i }, item), i, diag);
            }
        } else return fail(diag, key, "unknown section", .{});
    }
}

fn readServer(config: *Config, section: *const toml.Table, diag: *Diagnostic) Error!void {
    var it = section.iterator();
    while (it.next()) |entry| {
        const key: Key = .{ .section = "server", .name = entry.key_ptr.* };
        const value = entry.value_ptr.*;
        if (eql(key.name.?, "bind")) {
            config.bind = try address(diag, key, value, true);
        } else if (eql(key.name.?, "motd")) {
            config.setMotd(try string(diag, key, value)) catch
                return fail(diag, key, "must be 1 to {d} bytes", .{Config.max_motd_len});
        } else if (eql(key.name.?, "workers")) {
            config.workers = try integer(u8, diag, key, value, 1, Config.max_workers);
            if (config.workers > 1 and !Config.multi_worker_supported)
                return fail(diag, key, "more than 1 needs Linux (SO_REUSEPORT)", .{});
        } else if (eql(key.name.?, "max_players")) {
            config.max_players = try integer(u32, diag, key, value, 1, 100_000);
        } else if (eql(key.name.?, "max_players_per_ip")) {
            config.max_players_per_ip = try integer(u32, diag, key, value, 0, 100_000);
        } else return fail(diag, key, "unknown key", .{});
    }
}

fn readLimits(config: *Config, section: *const toml.Table, diag: *Diagnostic) Error!void {
    var it = section.iterator();
    while (it.next()) |entry| {
        const key: Key = .{ .section = "limits", .name = entry.key_ptr.* };
        const value = entry.value_ptr.*;
        if (eql(key.name.?, "connect_timeout_ms")) {
            config.connect_timeout_ms = try integer(u32, diag, key, value, Config.min_connect_timeout_ms, 60_000);
        } else if (eql(key.name.?, "pending_packets")) {
            config.pending_packets = try integer(u32, diag, key, value, 1, 4096);
        } else if (eql(key.name.?, "pending_bytes")) {
            config.pending_bytes = try integer(u32, diag, key, value, 1, 64 * 1024 * 1024);
        } else return fail(diag, key, "unknown key", .{});
    }
}

fn readHealth(config: *Config, section: *const toml.Table, diag: *Diagnostic) Error!void {
    var it = section.iterator();
    while (it.next()) |entry| {
        const key: Key = .{ .section = "health", .name = entry.key_ptr.* };
        const value = entry.value_ptr.*;
        if (eql(key.name.?, "interval_ms")) {
            config.health_interval_ms = try integer(u32, diag, key, value, 1_000, 600_000);
        } else if (eql(key.name.?, "timeout_ms")) {
            config.health_timeout_ms = try integer(u32, diag, key, value, 100, 10_000);
        } else return fail(diag, key, "unknown key", .{});
    }
}

fn readAuth(config: *Config, section: *const toml.Table, diag: *Diagnostic) Error!void {
    var it = section.iterator();
    while (it.next()) |entry| {
        const key: Key = .{ .section = "auth", .name = entry.key_ptr.* };
        const value = entry.value_ptr.*;
        if (eql(key.name.?, "mode")) {
            const text = try string(diag, key, value);
            config.auth = std.meta.stringToEnum(Config.Auth, text) orelse
                return fail(diag, key, "expected \"off\" or \"verify\", got \"{s}\"", .{text});
        } else if (eql(key.name.?, "keys_file")) {
            config.setKeysFile(try string(diag, key, value)) catch
                return fail(diag, key, "must be 1 to {d} bytes", .{Config.max_path_len});
        } else return fail(diag, key, "unknown key", .{});
    }
}

fn readSession(config: *Config, section: *const toml.Table, diag: *Diagnostic) Error!void {
    var it = section.iterator();
    while (it.next()) |entry| {
        const key: Key = .{ .section = "session", .name = entry.key_ptr.* };
        const value = entry.value_ptr.*;
        if (eql(key.name.?, "mode")) {
            const text = try string(diag, key, value);
            config.session_mode = std.meta.stringToEnum(Config.SessionMode, text) orelse
                return fail(diag, key, "expected \"passthrough\" or \"managed\", got \"{s}\"", .{text});
        } else if (eql(key.name.?, "proxy_key_file")) {
            config.setProxyKeyFile(try string(diag, key, value)) catch
                return fail(diag, key, "must be 1 to {d} bytes", .{Config.max_path_len});
        } else return fail(diag, key, "unknown key", .{});
    }
}

fn readBackend(config: *Config, section: *const toml.Table, index: usize, diag: *Diagnostic) Error!void {
    var backend: ?IpAddress = null;
    var name: ?[]const u8 = null;
    var it = section.iterator();
    while (it.next()) |entry| {
        const key: Key = .{ .section = "backend", .index = index, .name = entry.key_ptr.* };
        if (eql(key.name.?, "address")) {
            backend = try address(diag, key, entry.value_ptr.*, false);
        } else if (eql(key.name.?, "name")) {
            name = try string(diag, key, entry.value_ptr.*);
        } else return fail(diag, key, "unknown key", .{});
    }
    const key: Key = .{ .section = "backend", .index = index, .name = "address" };
    const name_key: Key = .{ .section = "backend", .index = index, .name = "name" };
    config.addBackend(name, backend orelse return fail(diag, key, "is required", .{})) catch |err| return switch (err) {
        error.InvalidPort => fail(diag, key, "needs a non-zero port", .{}),
        error.DuplicateBackend => fail(diag, key, "duplicates an earlier backend", .{}),
        error.TooManyBackends => fail(diag, key, "more than {d} backends", .{Config.max_backends}),
        error.InvalidName => fail(diag, name_key, "must be 1 to {d} of a-z A-Z 0-9 - _ . : [ ]", .{Backend.max_name_len}),
        error.DuplicateName => fail(diag, name_key, "duplicates an earlier backend", .{}),
    };
}

fn table(diag: *Diagnostic, key: Key, value: toml.Value) Error!*const toml.Table {
    if (value != .table) return fail(diag, key, "expected a table", .{});
    return value.table;
}

fn string(diag: *Diagnostic, key: Key, value: toml.Value) Error![]const u8 {
    if (value != .string) return fail(diag, key, "expected a string", .{});
    return value.string;
}

fn integer(comptime T: type, diag: *Diagnostic, key: Key, value: toml.Value, min: T, max: T) Error!T {
    if (value != .integer) return fail(diag, key, "expected an integer", .{});
    if (value.integer < min or value.integer > max) return fail(diag, key, "must be between {d} and {d}", .{ min, max });
    return @intCast(value.integer);
}

fn address(diag: *Diagnostic, key: Key, value: toml.Value, allow_any_port: bool) Error!IpAddress {
    const text = try string(diag, key, value);
    const parsed = IpAddress.parseLiteral(text) catch
        return fail(diag, key, "expected \"ip:port\", got \"{s}\"", .{text});
    if (!allow_any_port and parsed.getPort() == 0) return fail(diag, key, "needs a non-zero port, got \"{s}\"", .{text});
    return parsed;
}

fn fail(diag: *Diagnostic, key: Key, comptime fmt: []const u8, args: anytype) error{InvalidConfig} {
    diag.set("{f}: " ++ fmt, .{key} ++ args);
    return error.InvalidConfig;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn expectInvalid(source: []const u8, expected: []const u8) !void {
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.InvalidConfig, parse(std.testing.allocator, source, &diag));
    try std.testing.expectEqualStrings(expected, diag.message());
}

test "minimal config uses defaults" {
    var diag: Diagnostic = .{};
    const config = try parse(std.testing.allocator, "[[backend]]\naddress = \"127.0.0.1:19133\"\n", &diag);
    const defaults: Config = .{};
    try std.testing.expectEqual(defaults.bind.getPort(), config.bind.getPort());
    try std.testing.expectEqual(defaults.max_players, config.max_players);
    try std.testing.expectEqual(defaults.connect_timeout_ms, config.connect_timeout_ms);
    try std.testing.expectEqualStrings(Config.default_motd, config.motd());
    try std.testing.expectEqual(@as(usize, 1), config.backends().len);
}

test "full config reads every key" {
    var diag: Diagnostic = .{};
    const config = try parse(std.testing.allocator,
        \\[server]
        \\bind = "127.0.0.1:1000"
        \\motd = "MCPE;Test"
        \\max_players = 10
        \\workers = 1
        \\
        \\[limits]
        \\connect_timeout_ms = 2000
        \\pending_packets = 8
        \\pending_bytes = 4096
        \\
        \\[[backend]]
        \\name = "lobby"
        \\address = "127.0.0.1:2000"
        \\
        \\[[backend]]
        \\address = "[::1]:3000"
        \\
    , &diag);
    try std.testing.expectEqual(@as(u16, 1000), config.bind.getPort());
    try std.testing.expectEqualStrings("MCPE;Test", config.motd());
    try std.testing.expectEqual(@as(u32, 10), config.max_players);
    try std.testing.expectEqual(@as(u32, 2000), config.connect_timeout_ms);
    try std.testing.expectEqual(@as(u32, 8), config.pending_packets);
    try std.testing.expectEqual(@as(u32, 4096), config.pending_bytes);
    try std.testing.expectEqual(@as(u16, 2000), config.backends()[0].address.getPort());
    try std.testing.expectEqualStrings("lobby", config.backends()[0].name());
    try std.testing.expectEqual(@as(u16, 3000), config.backends()[1].address.getPort());
    try std.testing.expectEqualStrings("[::1]:3000", config.backends()[1].name());
}

test "syntax errors report a position" {
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.InvalidSyntax, parse(std.testing.allocator, "[server]\nbind = \n", &diag));
    try std.testing.expectEqual(@as(usize, 2), diag.line);
    try std.testing.expect(diag.column != 0);
}

test "invalid values name the offending key" {
    const backend = "[[backend]]\naddress = \"127.0.0.1:1\"\n";
    try expectInvalid("", "backend: at least one [[backend]] is required");
    try expectInvalid("[nope]\n" ++ backend, "nope: unknown section");
    try expectInvalid("[server]\nport = 1\n" ++ backend, "server.port: unknown key");
    try expectInvalid("[server]\nbind = \"localhost:1\"\n" ++ backend, "server.bind: expected \"ip:port\", got \"localhost:1\"");
    try expectInvalid("[server]\nbind = 19132\n" ++ backend, "server.bind: expected a string");
    try expectInvalid("[server]\nworkers = 0\n" ++ backend, "server.workers: must be between 1 and 64");
    if (!Config.multi_worker_supported) try expectInvalid("[server]\nworkers = 2\n" ++ backend, "server.workers: more than 1 needs Linux (SO_REUSEPORT)");
    try expectInvalid("[server]\nmax_players = 2\nmax_players_per_ip = 3\n" ++ backend, "server.max_players_per_ip: can't be more than max_players");
    try expectInvalid("[server]\nmax_players = 0\n" ++ backend, "server.max_players: must be between 1 and 100000");
    try expectInvalid("[server]\nmotd = \"\"\n" ++ backend, "server.motd: must be 1 to 256 bytes");
    try expectInvalid("[limits]\nconnect_timeout_ms = \"5s\"\n" ++ backend, "limits.connect_timeout_ms: expected an integer");
    try expectInvalid("[limits]\nconnect_timeout_ms = 100\n" ++ backend, "limits.connect_timeout_ms: must be between 500 and 60000");
    try expectInvalid("server = 1\n" ++ backend, "server: expected a table");
    try expectInvalid("[[backend]]\n", "backend[0].address: is required");
    try expectInvalid("[[backend]]\naddress = \"127.0.0.1:0\"\n", "backend[0].address: needs a non-zero port, got \"127.0.0.1:0\"");
    try expectInvalid("[[backend]]\naddress = \"127.0.0.1:1\"\nweight = 1\n", "backend[0].weight: unknown key");
    try expectInvalid(backend ++ backend, "backend[1].address: duplicates an earlier backend");
    try expectInvalid("[[backend]]\nname = \"a b\"\naddress = \"127.0.0.1:1\"\n", "backend[0].name: must be 1 to 48 of a-z A-Z 0-9 - _ . : [ ]");
    try expectInvalid("[[backend]]\nname = 1\naddress = \"127.0.0.1:1\"\n", "backend[0].name: expected a string");
    try expectInvalid("[[backend]]\nname = \"x\"\naddress = \"127.0.0.1:1\"\n[[backend]]\nname = \"x\"\naddress = \"127.0.0.1:2\"\n", "backend[1].name: duplicates an earlier backend");
    try expectInvalid("backend = \"127.0.0.1:1\"\n", "backend: expected [[backend]] tables");
    try expectInvalid("[auth]\nmode = \"strict\"\n" ++ backend, "auth.mode: expected \"off\" or \"verify\", got \"strict\"");
    try expectInvalid("[health]\ntimeout_ms = 50\n" ++ backend, "health.timeout_ms: must be between 100 and 10000");
    try expectInvalid("[health]\ninterval_ms = 1000\ntimeout_ms = 1000\n" ++ backend, "health.timeout_ms: must be shorter than interval_ms");
    try expectInvalid("[auth]\nmode = \"verify\"\n" ++ backend, "auth.keys_file: is required when mode = \"verify\"");
}

test "auth section reads mode and keys file" {
    var diag: Diagnostic = .{};
    const config = try parse(std.testing.allocator, "[auth]\nmode = \"verify\"\nkeys_file = \"keys.json\"\n[[backend]]\naddress = \"127.0.0.1:1\"\n", &diag);
    try std.testing.expectEqual(Config.Auth.verify, config.auth);
    try std.testing.expectEqualStrings("keys.json", config.keysFile().?);
    const defaults = try parse(std.testing.allocator, "[[backend]]\naddress = \"127.0.0.1:1\"\n", &diag);
    try std.testing.expectEqual(Config.Auth.off, defaults.auth);
}

test "session section selects managed mode" {
    var diag: Diagnostic = .{};
    const backend = "[[backend]]\naddress = \"127.0.0.1:1\"\n";
    const verify = "[auth]\nmode = \"verify\"\nkeys_file = \"keys.json\"\n";
    const config = try parse(std.testing.allocator, verify ++ "[session]\nmode = \"managed\"\nproxy_key_file = \"proxy.key\"\n" ++ backend, &diag);
    try std.testing.expectEqual(Config.SessionMode.managed, config.session_mode);
    try std.testing.expectEqualStrings("proxy.key", config.proxyKeyFile().?);
    try std.testing.expectEqual(Config.SessionMode.passthrough, (try parse(std.testing.allocator, backend, &diag)).session_mode);

    try expectInvalid("[session]\nmode = \"mixed\"\n" ++ backend, "session.mode: expected \"passthrough\" or \"managed\", got \"mixed\"");
    try expectInvalid("[session]\nmode = \"managed\"\nproxy_key_file = \"k\"\n" ++ backend, "session.mode: \"managed\" needs [auth] mode = \"verify\"");
    try expectInvalid(verify ++ "[session]\nmode = \"managed\"\n" ++ backend, "session.proxy_key_file: is required when mode = \"managed\"");
}

test "loadFile reports missing and oversized files" {
    const io = std.testing.io;
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.FileNotFound, loadFile(std.testing.allocator, io, "does-not-exist.toml", &diag));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const big = try std.testing.allocator.alloc(u8, max_file_size + 1);
    defer std.testing.allocator.free(big);
    @memset(big, '#');
    try tmp.dir.writeFile(io, .{ .sub_path = "big.toml", .data = big });
    const path = try tmp.dir.realPathFileAlloc(io, "big.toml", std.testing.allocator);
    defer std.testing.allocator.free(path);
    try std.testing.expectError(error.InvalidConfig, loadFile(std.testing.allocator, io, path, &diag));
}

test "parse frees everything when allocation fails" {
    const source =
        \\[server]
        \\motd = "MCPE;Test"
        \\[[backend]]
        \\address = "127.0.0.1:2000"
        \\
    ;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(gpa: std.mem.Allocator) !void {
            var diag: Diagnostic = .{};
            _ = try parse(gpa, source, &diag);
        }
    }.run, .{});
}
