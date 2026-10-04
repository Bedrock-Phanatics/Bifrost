const std = @import("std");
const bedwire = @import("bedwire");
const oidc_key = @import("oidc_key.zig");

const protocol = bedwire.protocol;
const Current = protocol.Current;
const Ecdsa = bedwire.crypto.spki.Ecdsa;

pub fn keySet(allocator: std.mem.Allocator) !bedwire.auth.KeySet {
    return bedwire.auth.KeySet.parse(allocator, oidc_key.jwks_json, .{});
}

pub fn rawPacket(buffer: []u8, id: u10, payload: []const u8) ![]const u8 {
    var writer = protocol.Writer.init(buffer);
    try writer.writeVarU32(id);
    try writer.writeRaw(payload);
    return writer.written();
}

pub fn typedPacket(buffer: []u8, packet: protocol.typed.Packet) ![]const u8 {
    var writer = protocol.Writer.init(buffer);
    try protocol.typed.encode(&writer, .{ .header = .{ .packet_id = Current.packetId(protocol.typed.packetKind(packet)).? }, .packet = packet });
    return writer.written();
}

fn signRsa(allocator: std.mem.Allocator, header: []const u8, payload: []const u8) ![]u8 {
    const encoder = std.base64.url_safe_no_pad.Encoder;
    const header_len = encoder.calcSize(header.len);
    const payload_len = encoder.calcSize(payload.len);
    const bytes = try allocator.alloc(u8, header_len + 1 + payload_len + 1 + encoder.calcSize(256));
    errdefer allocator.free(bytes);
    _ = encoder.encode(bytes[0..header_len], header);
    bytes[header_len] = '.';
    _ = encoder.encode(bytes[header_len + 1 ..][0..payload_len], payload);
    const signed_len = header_len + 1 + payload_len;

    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[0..signed_len], &hash, .{});
    const digest_info = "\x30\x31\x30\x0d\x06\x09\x60\x86\x48\x01\x65\x03\x04\x02\x01\x05\x00\x04\x20";
    var em: [256]u8 = @splat(0xff);
    em[0] = 0;
    em[1] = 1;
    em[256 - 52] = 0;
    @memcpy(em[256 - 51 ..][0..19], digest_info);
    @memcpy(em[256 - 32 ..], &hash);

    const Modulus = std.crypto.ff.Modulus(4096);
    const n = try Modulus.fromBytes(&oidc_key.n, .big);
    const d = try Modulus.Fe.fromBytes(n, &oidc_key.d, .big);
    const signature = try n.powPublic(try Modulus.Fe.fromBytes(n, &em, .big), d);
    var signature_bytes: [256]u8 = undefined;
    try signature.toBytes(&signature_bytes, .big);
    bytes[signed_len] = '.';
    _ = encoder.encode(bytes[signed_len + 1 ..], &signature_bytes);
    return bytes;
}

pub fn request(allocator: std.mem.Allocator, key: Ecdsa.KeyPair, client_data_signer: Ecdsa.KeyPair, name: []const u8, xuid: []const u8, now: i64) ![]u8 {
    const claims = try std.fmt.allocPrint(
        allocator,
        "{{\"iss\":\"https://authorization.franchise.minecraft-services.net/\",\"aud\":\"api://auth-minecraft-services/multiplayer\",\"exp\":{d},\"cpk\":\"{s}\",\"xname\":\"{s}\",\"xid\":\"{s}\"}}",
        .{ now + 3600, bedwire.auth.login.encodedPublicKey(key.public_key), name, xuid },
    );
    defer allocator.free(claims);
    const token = try signRsa(allocator, "{\"alg\":\"RS256\",\"kid\":\"" ++ oidc_key.kid ++ "\"}", claims);
    defer allocator.free(token);
    const client_data = try bedwire.auth.login.sign(allocator, client_data_signer, "{\"alg\":\"ES384\"}", "{\"SkinId\":\"bifrost-test\",\"ServerAddress\":\"proxy\"}", .{});
    defer allocator.free(client_data);
    const envelope = try std.fmt.allocPrint(allocator, "{{\"AuthenticationType\":0,\"Token\":\"{s}\"}}", .{token});
    defer allocator.free(envelope);
    return bedwire.auth.encodeConnectionRequest(allocator, .{ .chain_data = envelope, .client_data = client_data }, .{});
}
