const std = @import("std");
const builtin = @import("builtin");
const Backend = @import("../backend/Backend.zig");
const content = @import("../content/policy.zig");
const IpAddress = std.Io.net.IpAddress;

const Config = @This();

pub const max_backends = 64;
pub const max_workers = 64;
pub const multi_worker_supported = builtin.os.tag == .linux;
pub const max_motd_len = 256;
pub const max_path_len = 1024;
pub const max_plugins = 16;
// raknet retries every 500 ms and rejects anything shorter
pub const min_connect_timeout_ms = 500;
pub const default_motd = "MCPE;Bifrost;2193;1.26.51;0;100;0;Bifrost;Survival;1;19132;19133;";

bind: IpAddress = .{ .ip4 = .unspecified(19132) },
workers: u8 = 1,
max_players: u32 = 4096,
max_players_per_ip: u32 = 0,
connect_timeout_ms: u32 = 5_000,
pending_packets: u32 = 64,
pending_bytes: u32 = 1024 * 1024,
slow_plugin_callback_ms: u32 = 5,
plugin_task_threads: u8 = 4,
health_interval_ms: u32 = 5_000,
health_timeout_ms: u32 = 1_000,
transfer_phase_timeout_ms: u32 = 5_000,
transfer_timeout_ms: u32 = 15_000,
content_policy: content.Policy = .initial,
auth: Auth = .off,
keys_file_storage: [max_path_len]u8 = undefined,
keys_file_len: usize = 0,
session_mode: SessionMode = .passthrough,
proxy_key_file_storage: [max_path_len]u8 = undefined,
proxy_key_file_len: usize = 0,
motd_storage: [max_motd_len]u8 = undefined,
motd_len: usize = 0,
backend_storage: [max_backends]Backend = undefined,
backend_count: usize = 0,
plugin_storage: [max_plugins][max_path_len]u8 = undefined,
plugin_lens: [max_plugins]u16 = undefined,
plugin_count: usize = 0,

pub const Auth = enum {
    off,
    verify,
};

pub const SessionMode = enum {
    passthrough,
    managed,
};

pub fn keysFile(self: *const Config) ?[]const u8 {
    return if (self.keys_file_len == 0) null else self.keys_file_storage[0..self.keys_file_len];
}

pub fn setKeysFile(self: *Config, path: []const u8) error{InvalidPath}!void {
    if (path.len == 0 or path.len > max_path_len) return error.InvalidPath;
    @memcpy(self.keys_file_storage[0..path.len], path);
    self.keys_file_len = path.len;
}

pub fn proxyKeyFile(self: *const Config) ?[]const u8 {
    return if (self.proxy_key_file_len == 0) null else self.proxy_key_file_storage[0..self.proxy_key_file_len];
}

pub fn setProxyKeyFile(self: *Config, path: []const u8) error{InvalidPath}!void {
    if (path.len == 0 or path.len > max_path_len) return error.InvalidPath;
    @memcpy(self.proxy_key_file_storage[0..path.len], path);
    self.proxy_key_file_len = path.len;
}

pub fn motd(self: *const Config) []const u8 {
    return if (self.motd_len == 0) default_motd else self.motd_storage[0..self.motd_len];
}

pub fn setMotd(self: *Config, value: []const u8) error{InvalidMotd}!void {
    if (value.len == 0 or value.len > max_motd_len) return error.InvalidMotd;
    @memcpy(self.motd_storage[0..value.len], value);
    self.motd_len = value.len;
}

pub fn pluginPath(self: *const Config, index: usize) []const u8 {
    return self.plugin_storage[index][0..self.plugin_lens[index]];
}

pub fn addPlugin(self: *Config, path: []const u8) error{ InvalidPath, TooManyPlugins }!void {
    if (path.len == 0 or path.len > max_path_len) return error.InvalidPath;
    if (self.plugin_count == max_plugins) return error.TooManyPlugins;
    @memcpy(self.plugin_storage[self.plugin_count][0..path.len], path);
    self.plugin_lens[self.plugin_count] = @intCast(path.len);
    self.plugin_count += 1;
}

pub fn backends(self: *const Config) []const Backend {
    return self.backend_storage[0..self.backend_count];
}

pub fn findBackend(self: *const Config, name: []const u8) ?Backend.Id {
    for (self.backends(), 0..) |*backend, i| {
        if (std.mem.eql(u8, backend.name(), name)) return .of(i);
    }
    return null;
}

pub const AddBackendError = Backend.InitError || error{ TooManyBackends, DuplicateBackend, DuplicateName };

pub fn addBackend(self: *Config, name: ?[]const u8, address: IpAddress) AddBackendError!void {
    const backend: Backend = try .init(name, address);
    for (self.backends()) |*existing| {
        if (existing.address.eql(&address)) return error.DuplicateBackend;
    }
    if (self.findBackend(backend.name()) != null) return error.DuplicateName;
    if (self.backend_count == max_backends) return error.TooManyBackends;
    self.backend_storage[self.backend_count] = backend;
    self.backend_count += 1;
}

pub fn validate(self: *const Config) error{ NoBackends, InvalidLimit, MissingKeysFile }!void {
    if (self.backend_count == 0) return error.NoBackends;
    if (self.auth == .verify and self.keys_file_len == 0) return error.MissingKeysFile;
    if (self.workers == 0 or self.workers > max_workers) return error.InvalidLimit;
    if (self.workers > 1 and !multi_worker_supported) return error.InvalidLimit;
    if (self.max_players == 0 or self.connect_timeout_ms < min_connect_timeout_ms) return error.InvalidLimit;
    if (self.max_players_per_ip > self.max_players) return error.InvalidLimit;
    if (self.pending_packets == 0 or self.pending_bytes == 0) return error.InvalidLimit;
    if (self.health_timeout_ms == 0 or self.health_timeout_ms >= self.health_interval_ms) return error.InvalidLimit;
    if (self.transfer_phase_timeout_ms == 0 or self.transfer_timeout_ms < self.transfer_phase_timeout_ms) return error.InvalidLimit;
}

test "setMotd copies and bounds the value" {
    var config: Config = .{};
    try std.testing.expectEqualStrings(default_motd, config.motd());
    var source = "MCPE;Test".*;
    try config.setMotd(&source);
    source[0] = 'X';
    try std.testing.expectEqualStrings("MCPE;Test", config.motd());
    try std.testing.expectError(error.InvalidMotd, config.setMotd(""));
    try std.testing.expectError(error.InvalidMotd, config.setMotd(&@as([max_motd_len + 1]u8, @splat('a'))));
}

test "addBackend rejects port 0, duplicates and overflow" {
    var config: Config = .{};
    try std.testing.expectError(error.InvalidPort, config.addBackend(null, .{ .ip4 = .loopback(0) }));
    try config.addBackend(null, .{ .ip4 = .loopback(1) });
    try std.testing.expectError(error.DuplicateBackend, config.addBackend("other", .{ .ip4 = .loopback(1) }));
    for (2..max_backends + 1) |port| try config.addBackend(null, .{ .ip4 = .loopback(@intCast(port)) });
    try std.testing.expectError(error.TooManyBackends, config.addBackend(null, .{ .ip4 = .loopback(9999) }));
}

test "backends are found by name" {
    var config: Config = .{};
    try config.addBackend("lobby", .{ .ip4 = .loopback(1) });
    try config.addBackend(null, .{ .ip4 = .loopback(2) });
    try std.testing.expectError(error.DuplicateName, config.addBackend("lobby", .{ .ip4 = .loopback(3) }));
    try std.testing.expectEqual(Backend.Id.of(0), config.findBackend("lobby").?);
    try std.testing.expectEqual(Backend.Id.of(1), config.findBackend("127.0.0.1:2").?);
    try std.testing.expectEqual(@as(?Backend.Id, null), config.findBackend("missing"));
}
