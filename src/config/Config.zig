const std = @import("std");
const IpAddress = std.Io.net.IpAddress;

const Config = @This();

pub const max_backends = 16;

listen: IpAddress = .{ .ip4 = .unspecified(19132) },
backend_storage: [max_backends]IpAddress = undefined,
backend_count: usize = 0,
advertisement: []const u8 = "MCPE;Bifrost;944;1.26.0;0;100;0;Bifrost;Survival;1;19132;19133;",
max_connections: u32 = 4096,
connect_timeout_ms: u32 = 5_000,
max_pending_packets: u32 = 64,
max_pending_bytes: usize = 1024 * 1024,

pub const Error = error{
    MissingValue,
    UnknownArgument,
    InvalidAddress,
    InvalidNumber,
    TooManyBackends,
    NoBackends,
    InvalidLimit,
};

pub fn backends(self: *const Config) []const IpAddress {
    return self.backend_storage[0..self.backend_count];
}

pub fn addBackend(self: *Config, address: IpAddress) Error!void {
    if (self.backend_count == max_backends) return error.TooManyBackends;
    self.backend_storage[self.backend_count] = address;
    self.backend_count += 1;
}

pub fn validate(self: *const Config) Error!void {
    if (self.backend_count == 0) return error.NoBackends;
    if (self.max_connections == 0) return error.InvalidLimit;
    if (self.connect_timeout_ms == 0 or self.max_pending_packets == 0 or self.max_pending_bytes == 0) return error.InvalidLimit;
}

pub fn parse(args: []const []const u8) Error!Config {
    var config: Config = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const flag = args[i];
        i += 1;
        if (i == args.len) return error.MissingValue;
        const value = args[i];
        if (std.mem.eql(u8, flag, "--listen")) {
            config.listen = IpAddress.parseLiteral(value) catch return error.InvalidAddress;
        } else if (std.mem.eql(u8, flag, "--backend")) {
            try config.addBackend(IpAddress.parseLiteral(value) catch return error.InvalidAddress);
        } else if (std.mem.eql(u8, flag, "--motd")) {
            config.advertisement = value;
        } else if (std.mem.eql(u8, flag, "--max-connections")) {
            config.max_connections = std.fmt.parseInt(u32, value, 10) catch return error.InvalidNumber;
        } else return error.UnknownArgument;
    }
    try config.validate();
    return config;
}

pub const usage =
    \\usage: bifrost --backend <ip:port> [--backend <ip:port>]... [options]
    \\
    \\  --listen <ip:port>         address to accept players on (default 0.0.0.0:19132)
    \\  --backend <ip:port>        backend server; repeat for round-robin (max 16)
    \\  --motd <advertisement>     raw RakNet server-list advertisement
    \\  --max-connections <n>      concurrent player limit (default 4096)
    \\
;

test "parse reads flags and repeated backends" {
    const config = try Config.parse(&.{
        "--listen",          "127.0.0.1:1000",
        "--backend",         "127.0.0.1:2000",
        "--backend",         "[::1]:3000",
        "--max-connections", "10",
    });
    try std.testing.expectEqual(@as(u16, 1000), config.listen.getPort());
    try std.testing.expectEqual(@as(usize, 2), config.backends().len);
    try std.testing.expectEqual(@as(u16, 3000), config.backends()[1].getPort());
    try std.testing.expectEqual(@as(u32, 10), config.max_connections);
}

test "parse rejects malformed input" {
    try std.testing.expectError(error.NoBackends, Config.parse(&.{}));
    try std.testing.expectError(error.MissingValue, Config.parse(&.{"--backend"}));
    try std.testing.expectError(error.UnknownArgument, Config.parse(&.{ "--nope", "1" }));
    try std.testing.expectError(error.InvalidAddress, Config.parse(&.{ "--backend", "localhost" }));
    try std.testing.expectError(error.InvalidNumber, Config.parse(&.{ "--backend", "127.0.0.1:1", "--max-connections", "-1" }));
    try std.testing.expectError(error.InvalidLimit, Config.parse(&.{ "--backend", "127.0.0.1:1", "--max-connections", "0" }));

    var args: [2 * (max_backends + 1)][]const u8 = undefined;
    for (0..max_backends + 1) |n| args[2 * n ..][0..2].* = .{ "--backend", "127.0.0.1:1" };
    try std.testing.expectError(error.TooManyBackends, Config.parse(&args));
}
