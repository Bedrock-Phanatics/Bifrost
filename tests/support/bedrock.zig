const std = @import("std");
const bedwire = @import("bedwire");
const sample = @import("sample.zig");
const protocol = bedwire.protocol;
const Current = protocol.Current;

const gpa = std.testing.allocator;
const limits: bedwire.Limits = .{};

pub const Frames = struct {
    request: []u8,
    settings: []u8,
    login: []u8,
    status: []u8,

    pub fn init(protocol_version: i32) !Frames {
        var buffer: [1024]u8 = undefined;
        const request = try plain(try encode(&buffer, .{
            .header = .{ .packet_id = Current.packetId(.request_network_settings).? },
            .packet = .{ .request_network_settings = .{ .client_network_version = protocol_version } },
        }));
        errdefer gpa.free(request);
        const settings = try plain(try encode(&buffer, .{
            .header = .{ .packet_id = Current.packetId(.network_settings).? },
            .packet = .{ .network_settings = .{
                .compression_threshold = 0,
                .compression_algorithm = .snappy,
                .client_throttle_enabled = false,
                .client_throttle_threshold = 0,
                .client_throttle_scalar = 0,
            } },
        }));
        errdefer gpa.free(settings);
        const login = try compressed(try encode(&buffer, .{
            .header = .{ .packet_id = Current.packetId(.login).? },
            .packet = .{ .login = .{ .client_network_version = protocol_version, .connection_request = "not a real login" } },
        }));
        errdefer gpa.free(login);
        const status = try compressed(try encode(&buffer, .{
            .header = .{ .packet_id = Current.packetId(.play_status).? },
            .packet = .{ .play_status = .{ .status = .loginsuccess } },
        }));
        return .{ .request = request, .settings = settings, .login = login, .status = status };
    }

    pub fn deinit(self: *Frames) void {
        for ([_][]u8{ self.request, self.settings, self.login, self.status }) |frame| gpa.free(frame);
    }
};

pub const current_version: i32 = @intCast(Current.protocol_number);

fn encode(buffer: []u8, envelope: protocol.typed.Envelope) ![]const u8 {
    var writer = protocol.Writer.init(buffer);
    try protocol.typed.encode(&writer, envelope);
    return writer.written();
}

// NetherNet batches carry no 0xfe header
fn plain(packet: []const u8) ![]u8 {
    var frame: [1024]u8 = undefined;
    var writer = bedwire.framing.batch.Writer.init(&frame, limits);
    try writer.append(packet);
    return gpa.dupe(u8, writer.written());
}

fn compressed(packet: []const u8) ![]u8 {
    const raw = try gpa.alloc(u8, packet.len + 16);
    defer gpa.free(raw);
    var writer = bedwire.framing.batch.Writer.init(raw, limits);
    try writer.append(packet);
    var codec = bedwire.compression.Compression.init(Current.features);
    try codec.negotiate(.snappy, 0);
    const scratch = try gpa.create(bedwire.compression.Scratch);
    defer gpa.destroy(scratch);
    const frame = try gpa.alloc(u8, 2 * packet.len + 64);
    defer gpa.free(frame);
    const framed = try codec.encode(writer.written(), frame[1..], scratch);
    frame[0] = @backingInt(framed.algorithm);
    return gpa.dupe(u8, frame[0 .. 1 + framed.bytes.len]);
}

/// A real signed Login, compressed the way `Frames.settings` asks for.
pub fn loginFrame(key: sample.Ecdsa.KeyPair, name: []const u8, xuid: []const u8, now: i64) ![]u8 {
    const request = try sample.request(gpa, key, key, name, xuid, now);
    defer gpa.free(request);
    const storage = try gpa.alloc(u8, request.len + 32);
    defer gpa.free(storage);
    return compressed(try bedwire.auth.login.encodeLoginPacket(Current, storage, request, .{}));
}
