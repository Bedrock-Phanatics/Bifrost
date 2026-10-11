const std = @import("std");
const bedwire = @import("bedwire");

pub const Ecdsa = bedwire.crypto.spki.Ecdsa;

const hex_len = Ecdsa.SecretKey.encoded_length * 2;
const owner_only: std.Io.File.Permissions = if (@hasDecl(std.Io.File.Permissions, "fromMode")) .fromMode(0o600) else .default_file;

// Creates the key if it's missing
pub fn load(io: std.Io, path: []const u8) !Ecdsa.KeyPair {
    var buffer: [hex_len + 16]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    const text = std.Io.Dir.cwd().readFile(io, path, &buffer) catch |err| switch (err) {
        error.FileNotFound => return create(io, path),
        else => return err,
    };
    return parse(std.mem.trim(u8, text, " \t\r\n"));
}

pub fn parse(text: []const u8) error{InvalidProxyKey}!Ecdsa.KeyPair {
    if (text.len != hex_len) return error.InvalidProxyKey;
    var secret: [Ecdsa.SecretKey.encoded_length]u8 = undefined;
    defer std.crypto.secureZero(u8, &secret);
    _ = std.fmt.hexToBytes(&secret, text) catch return error.InvalidProxyKey;
    const secret_key = Ecdsa.SecretKey.fromBytes(secret) catch return error.InvalidProxyKey;
    return Ecdsa.KeyPair.fromSecretKey(secret_key) catch error.InvalidProxyKey;
}

pub fn publicText(key: Ecdsa.KeyPair) [160]u8 {
    return bedwire.auth.login.encodedPublicKey(key.public_key);
}

fn create(io: std.Io, path: []const u8) !Ecdsa.KeyPair {
    const key = Ecdsa.KeyPair.generate(io);
    var line = std.fmt.bytesToHex(key.secret_key.toBytes(), .lower) ++ "\n".*;
    defer std.crypto.secureZero(u8, &line);
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true, .permissions = owner_only });
    defer file.close(io);
    try file.writeStreamingAll(io, &line);
    return key;
}

test "load creates a key once and reads the same key back" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, "proxy.key" });
    defer std.testing.allocator.free(path);

    const created = try load(io, path);
    const loaded = try load(io, path);
    try std.testing.expectEqualSlices(u8, &created.secret_key.toBytes(), &loaded.secret_key.toBytes());
    try std.testing.expectEqualSlices(u8, &publicText(created), &publicText(loaded));
}

test "parse rejects anything but a hex P-384 scalar" {
    try std.testing.expectError(error.InvalidProxyKey, parse(""));
    try std.testing.expectError(error.InvalidProxyKey, parse(&@as([hex_len]u8, @splat('z'))));
    try std.testing.expectError(error.InvalidProxyKey, parse(&@as([hex_len]u8, @splat('0'))));
    try std.testing.expectError(error.InvalidProxyKey, parse(&@as([hex_len - 2]u8, @splat('1'))));
}
