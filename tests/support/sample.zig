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

// Real packets from protocol-zig's corpus, so the proxy can decode them
const start_game_hex = "0bffffffffffffffffff01ffffffffffffffffff010a09fe2f49712131c9f7d74f49eb3107c8fcb2e0c7ffffffffffffffff010000d392fba6010c02010afeffffff0fc4db9aaa09feffffff0f00020000feffffff0f020103343732a1df5cc969754fc801000102080101000200000000010668c3a96c6c6f0001000003ae80974c010000010101010000000130000000809abf562600126d696e6563726166743a73746f6e6531313705537465766501010000060008537465766533393909e697a5e69cace8aa9e0339373800bc90f98201010000000000000000ffffffff0f0301300a000105782079207a200005782079207a0a000107f09f9982206f6bac0001300a00000968c3a96c6c6f3338380109e697a5e69cace8aa9e0a0000b1514ca91695eb8a6f96a16dfc9c80dd5b802003d0fe7379010100000668c3a96c6c6f05782079207a0ce697a5e69cace8aa9e32343100";
const item_registry_hex = "a201010668c3a96c6c6ff61801040a00080f6d696e6563726166743a73746f6e650000";
const biome_definitions_hex = "7a00030668c3a96c6c6f000161";

pub const biome_definitions = fromHex(biome_definitions_hex);
const empty_compound = [_]u8{ 10, 0, 0 };

pub const Content = struct {
    pack: ?[]const u8 = null,
    custom_block: ?[]const u8 = null,
    custom_item: ?[]const u8 = null,
    authoritative_block_breaking: ?bool = null,
    dimension: ?i32 = null,
    position: ?protocol.Vec3f = null,
    runtime_id: ?u64 = null,
    unique_id: ?i64 = null,
};

pub fn runtimeId() u64 {
    const source = comptime fromHex(start_game_hex);
    return (Current.decodeBorrowed(&source, .{}) catch unreachable).value.typed.start_game.runtime_id;
}

pub fn startGame(buffer: []u8, content: Content) ![]const u8 {
    const source = comptime fromHex(start_game_hex);
    var envelope = try Current.decodeBorrowed(&source, .{});
    var value = envelope.value.typed.start_game;
    const blocks = [_]protocol.packets.start_game.ServerBlockProperty{.{ .block_name = content.custom_block orelse "", .block_definition = &empty_compound }};
    if (content.custom_block != null) value.block_properties = .init(&blocks);
    if (content.authoritative_block_breaking) |enabled| value.movement_settings.server_authoritative_block_breaking = enabled;
    value.settings.spawn_settings.dimension = content.dimension orelse 0;
    if (content.position) |position| value.position = position;
    if (content.runtime_id) |id| value.runtime_id = id;
    if (content.unique_id) |id| value.entity_id = id;
    envelope.value = .{ .typed = .{ .start_game = value } };
    return encodeEnvelope(buffer, envelope);
}

pub fn itemRegistry(buffer: []u8, content: Content) ![]const u8 {
    const source = comptime fromHex(item_registry_hex);
    var envelope = try Current.decodeBorrowed(&source, .{});
    var value = envelope.value.typed.item_registry;
    const items = [_]protocol.packets.item_registry.ItemData{.{
        .item_name = content.custom_item orelse "",
        .item_id = 1000,
        .is_component_based = true,
        .item_version = .datadriven,
        .item_component_data = &empty_compound,
    }};
    if (content.custom_item != null) value.item_data = .init(&items);
    envelope.value = .{ .typed = .{ .item_registry = value } };
    return encodeEnvelope(buffer, envelope);
}

pub fn packStack(buffer: []u8, content: Content) ![]const u8 {
    const packs = [_]protocol.packets.resource_pack_stack.StackResourcePack{.{ .pack_id = content.pack orelse "", .version = "1.0.0", .sub_pack_name = "" }};
    return typedPacket(buffer, .{ .resource_pack_stack = .{
        .texture_pack_required = false,
        .texture_pack_list = if (content.pack != null) .init(&packs) else .empty,
        .base_game_version = "",
        .experiments = .{ .toggles = .empty, .experiments_ever_toggled = false },
        .include_editor_packs = false,
    } });
}

fn encodeEnvelope(buffer: []u8, envelope: protocol.BorrowedEnvelope) ![]const u8 {
    var writer = protocol.Writer.init(buffer);
    try Current.encode(&writer, envelope);
    return writer.written();
}

fn fromHex(comptime hex: []const u8) [hex.len / 2]u8 {
    @setEvalBranchQuota(10_000);
    var bytes: [hex.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, hex) catch unreachable;
    return bytes;
}
