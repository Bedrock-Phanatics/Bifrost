const std = @import("std");
const Backend = @import("../backend/Backend.zig");
const content = @import("../content/policy.zig");
const IpAddress = std.Io.net.IpAddress;

const Config = @This();

pub const max_backends = 64;
pub const max_workers = 64;
pub const max_motd_len = 256;
pub const max_ice_servers = 4;
pub const max_ice_url_len = 255;
pub const max_path_len = 1024;
pub const max_disabled_plugins = 16;
pub const max_plugin_dir_name = 255;
pub const default_plugins_dir = "plugins";
pub const min_connect_timeout_ms = 500;
pub const default_motd = "Bifrost";
pub const default_identity_file = "bifrost-identity.der";

bind: IpAddress = .{ .ip4 = .unspecified(19132) },
metrics_bind: ?IpAddress = null,
workers: u8 = 1,
max_players: u32 = 4096,
max_players_per_ip: u32 = 0,
connect_timeout_ms: u32 = 5_000,
pending_packets: u32 = 64,
pending_bytes: u32 = 1024 * 1024,
total_pending_bytes: u64 = 256 * 1024 * 1024,
login_timeout_ms: u32 = 30_000,
resource_pack_timeout_ms: u32 = 600_000,
join_timeout_ms: u32 = 120_000,
slow_player_timeout_ms: u32 = 5_000,
logins_per_second: u32 = 100,
player_bytes_per_second: u32 = 8 * 1024 * 1024,
slow_plugin_callback_ms: u32 = 5,
plugin_task_threads: u8 = 4,
health_interval_ms: u32 = 5_000,
health_timeout_ms: u32 = 1_000,
transfer_phase_timeout_ms: u32 = 5_000,
transfer_timeout_ms: u32 = 15_000,
max_transfers: u32 = 64,
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
plugins_dir_storage: [max_path_len]u8 = undefined,
plugins_dir_len: usize = 0,
disabled_storage: [max_disabled_plugins][max_plugin_dir_name]u8 = undefined,
disabled_lens: [max_disabled_plugins]u8 = undefined,
disabled_count: usize = 0,
identity_file_storage: [max_path_len]u8 = undefined,
identity_file_len: usize = 0,
// 0 lets libdatachannel use one thread per core, up to four
native_threads: u8 = 0,
port_min: u16 = 0,
port_max: u16 = 0,
ice_bind_storage: [64]u8 = undefined,
ice_bind_len: usize = 0,
ice_server_storage: [max_ice_servers][max_ice_url_len]u8 = undefined,
ice_server_lens: [max_ice_servers]u8 = undefined,
ice_server_count: usize = 0,
udp_mux: bool = false,
max_negotiations: u32 = 32,
max_negotiations_per_ip: u32 = 4,

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

pub fn identityFile(self: *const Config) []const u8 {
    return if (self.identity_file_len == 0) default_identity_file else self.identity_file_storage[0..self.identity_file_len];
}

pub fn setIdentityFile(self: *Config, path: []const u8) error{InvalidPath}!void {
    if (path.len == 0 or path.len > max_path_len) return error.InvalidPath;
    @memcpy(self.identity_file_storage[0..path.len], path);
    self.identity_file_len = path.len;
}

pub fn iceBind(self: *const Config) ?[]const u8 {
    return if (self.ice_bind_len == 0) null else self.ice_bind_storage[0..self.ice_bind_len];
}

pub fn setIceBind(self: *Config, address: []const u8) error{InvalidAddress}!void {
    _ = std.Io.net.IpAddress.parse(address, 0) catch return error.InvalidAddress;
    if (address.len > self.ice_bind_storage.len) return error.InvalidAddress;
    @memcpy(self.ice_bind_storage[0..address.len], address);
    self.ice_bind_len = address.len;
}

pub fn iceServer(self: *const Config, index: usize) []const u8 {
    return self.ice_server_storage[index][0..self.ice_server_lens[index]];
}

pub fn addIceServer(self: *Config, url: []const u8) error{ InvalidUrl, TooManyServers }!void {
    const known = std.mem.startsWith(u8, url, "stun:") or std.mem.startsWith(u8, url, "turn:") or std.mem.startsWith(u8, url, "turns:");
    if (!known or url.len > max_ice_url_len or std.mem.indexOfScalar(u8, url, 0) != null) return error.InvalidUrl;
    if (self.ice_server_count == max_ice_servers) return error.TooManyServers;
    @memcpy(self.ice_server_storage[self.ice_server_count][0..url.len], url);
    self.ice_server_lens[self.ice_server_count] = @intCast(url.len);
    self.ice_server_count += 1;
}

pub fn motd(self: *const Config) []const u8 {
    return if (self.motd_len == 0) default_motd else self.motd_storage[0..self.motd_len];
}

pub fn setMotd(self: *Config, value: []const u8) error{InvalidMotd}!void {
    if (value.len == 0 or value.len > max_motd_len or !std.unicode.utf8ValidateSlice(value)) return error.InvalidMotd;
    @memcpy(self.motd_storage[0..value.len], value);
    self.motd_len = value.len;
}

pub fn pluginsDir(self: *const Config) []const u8 {
    return if (self.plugins_dir_len == 0) default_plugins_dir else self.plugins_dir_storage[0..self.plugins_dir_len];
}

pub fn setPluginsDir(self: *Config, path: []const u8) error{InvalidPath}!void {
    if (path.len == 0 or path.len > max_path_len) return error.InvalidPath;
    @memcpy(self.plugins_dir_storage[0..path.len], path);
    self.plugins_dir_len = path.len;
}

pub fn disabledPlugin(self: *const Config, index: usize) []const u8 {
    return self.disabled_storage[index][0..self.disabled_lens[index]];
}

pub fn disablePlugin(self: *Config, name: []const u8) error{ InvalidName, TooManyPlugins }!void {
    if (name.len == 0 or name.len > max_plugin_dir_name) return error.InvalidName;
    if (self.disabled_count == max_disabled_plugins) return error.TooManyPlugins;
    @memcpy(self.disabled_storage[self.disabled_count][0..name.len], name);
    self.disabled_lens[self.disabled_count] = @intCast(name.len);
    self.disabled_count += 1;
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
    if ((self.port_min == 0) != (self.port_max == 0) or self.port_min > self.port_max) return error.InvalidLimit;
    if (self.max_negotiations == 0 or self.max_negotiations > 1024 or self.max_negotiations_per_ip == 0) return error.InvalidLimit;
    if (self.max_players == 0 or self.connect_timeout_ms < min_connect_timeout_ms) return error.InvalidLimit;
    if (self.max_players_per_ip > self.max_players) return error.InvalidLimit;
    if (self.pending_packets == 0 or self.pending_bytes == 0 or self.total_pending_bytes < self.pending_bytes) return error.InvalidLimit;
    if (self.login_timeout_ms == 0 or self.resource_pack_timeout_ms == 0 or self.join_timeout_ms == 0 or self.slow_player_timeout_ms == 0) return error.InvalidLimit;
    if (self.logins_per_second == 0 or self.player_bytes_per_second == 0 or self.max_transfers == 0) return error.InvalidLimit;
    if (self.health_timeout_ms == 0 or self.health_timeout_ms >= self.health_interval_ms) return error.InvalidLimit;
    if (self.transfer_phase_timeout_ms == 0 or self.transfer_timeout_ms < self.transfer_phase_timeout_ms) return error.InvalidLimit;
}

test "setMotd copies and bounds the value" {
    var config: Config = .{};
    try std.testing.expectEqualStrings(default_motd, config.motd());
    var source = "Lobby".*;
    try config.setMotd(&source);
    source[0] = 'X';
    try std.testing.expectEqualStrings("Lobby", config.motd());
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

test "ICE settings are checked as they are set" {
    var config: Config = .{};
    try config.addIceServer("stun:stun.example.com:3478");
    try std.testing.expectEqualStrings("stun:stun.example.com:3478", config.iceServer(0));
    try std.testing.expectError(error.InvalidUrl, config.addIceServer("http://example.com"));
    for (1..max_ice_servers) |_| try config.addIceServer("turn:relay.example.com");
    try std.testing.expectError(error.TooManyServers, config.addIceServer("stun:one.more"));
    try config.setIceBind("10.0.0.2");
    try std.testing.expectError(error.InvalidAddress, config.setIceBind("not an address"));
    config.port_min = 50000;
    try std.testing.expectError(error.NoBackends, config.validate());
    try config.addBackend(null, .{ .ip4 = .loopback(1) });
    try std.testing.expectError(error.InvalidLimit, config.validate());
    config.port_max = 50100;
    try config.validate();
}
