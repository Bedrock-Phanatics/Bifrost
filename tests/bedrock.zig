const std = @import("std");
const bedwire = @import("bedwire");
const protocol = bedwire.protocol;
const Current = protocol.Current;

const gpa = std.testing.allocator;
const limits: bedwire.Limits = .{};

pub const Frames = struct {
    request: []u8,
    settings: []u8,
    login: []u8,
    handshake: []u8,

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
        const handshake = try compressed(try encode(&buffer, .{
            .header = .{ .packet_id = Current.packetId(.server_to_client_handshake).? },
            .packet = .{ .server_to_client_handshake = .{ .handshake_web_token = "header.payload.signature" } },
        }));
        return .{ .request = request, .settings = settings, .login = login, .handshake = handshake };
    }

    pub fn deinit(self: *Frames) void {
        for ([_][]u8{ self.request, self.settings, self.login, self.handshake }) |frame| gpa.free(frame);
    }
};

pub const current_version: i32 = @intCast(Current.protocol_number);

fn encode(buffer: []u8, envelope: protocol.typed.Envelope) ![]const u8 {
    var writer = protocol.Writer.init(buffer);
    try protocol.typed.encode(&writer, envelope);
    return writer.written();
}

fn plain(packet: []const u8) ![]u8 {
    var frame: [1024]u8 = undefined;
    frame[0] = bedwire.framing.batch.header;
    var writer = bedwire.framing.batch.Writer.init(frame[1..], limits);
    try writer.append(packet);
    return gpa.dupe(u8, frame[0 .. 1 + writer.written().len]);
}

fn compressed(packet: []const u8) ![]u8 {
    var raw: [1024]u8 = undefined;
    var writer = bedwire.framing.batch.Writer.init(&raw, limits);
    try writer.append(packet);
    var codec = bedwire.compression.Compression.init(Current.features);
    try codec.negotiate(.snappy, 0);
    const scratch = try gpa.create(bedwire.compression.Scratch);
    defer gpa.destroy(scratch);
    var frame: [2048]u8 = undefined;
    const framed = try codec.encode(writer.written(), frame[2..], scratch);
    frame[0] = bedwire.framing.batch.header;
    frame[1] = @intFromEnum(framed.algorithm);
    return gpa.dupe(u8, frame[0 .. 2 + framed.bytes.len]);
}
