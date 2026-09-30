const std = @import("std");
const IpAddress = std.Io.net.IpAddress;

const Config = @This();

pub const max_backends = 64;
pub const max_motd_len = 256;
pub const default_motd = "MCPE;Bifrost;944;1.26.0;0;100;0;Bifrost;Survival;1;19132;19133;";

bind: IpAddress = .{ .ip4 = .unspecified(19132) },
max_players: u32 = 4096,
connect_timeout_ms: u32 = 5_000,
pending_packets: u32 = 64,
pending_bytes: u32 = 1024 * 1024,
motd_storage: [max_motd_len]u8 = undefined,
motd_len: usize = 0,
backend_storage: [max_backends]IpAddress = undefined,
backend_count: usize = 0,

pub fn motd(self: *const Config) []const u8 {
    return if (self.motd_len == 0) default_motd else self.motd_storage[0..self.motd_len];
}

pub fn setMotd(self: *Config, value: []const u8) error{InvalidMotd}!void {
    if (value.len == 0 or value.len > max_motd_len) return error.InvalidMotd;
    @memcpy(self.motd_storage[0..value.len], value);
    self.motd_len = value.len;
}

pub fn backends(self: *const Config) []const IpAddress {
    return self.backend_storage[0..self.backend_count];
}

pub fn addBackend(self: *Config, address: IpAddress) error{ TooManyBackends, DuplicateBackend }!void {
    for (self.backends()) |existing| {
        if (existing.eql(&address)) return error.DuplicateBackend;
    }
    if (self.backend_count == max_backends) return error.TooManyBackends;
    self.backend_storage[self.backend_count] = address;
    self.backend_count += 1;
}

pub fn validate(self: *const Config) error{ NoBackends, InvalidLimit }!void {
    if (self.backend_count == 0) return error.NoBackends;
    if (self.max_players == 0 or self.connect_timeout_ms == 0) return error.InvalidLimit;
    if (self.pending_packets == 0 or self.pending_bytes == 0) return error.InvalidLimit;
}

test "setMotd copies and bounds the value" {
    var config: Config = .{};
    try std.testing.expectEqualStrings(default_motd, config.motd());
    var source = "MCPE;Test".*;
    try config.setMotd(&source);
    source[0] = 'X';
    try std.testing.expectEqualStrings("MCPE;Test", config.motd());
    try std.testing.expectError(error.InvalidMotd, config.setMotd(""));
    try std.testing.expectError(error.InvalidMotd, config.setMotd(&(.{'a'} ** (max_motd_len + 1))));
}

test "addBackend rejects duplicates and overflow" {
    var config: Config = .{};
    try config.addBackend(.{ .ip4 = .loopback(1) });
    try std.testing.expectError(error.DuplicateBackend, config.addBackend(.{ .ip4 = .loopback(1) }));
    for (2..max_backends + 1) |port| try config.addBackend(.{ .ip4 = .loopback(@intCast(port)) });
    try std.testing.expectError(error.TooManyBackends, config.addBackend(.{ .ip4 = .loopback(9999) }));
}
