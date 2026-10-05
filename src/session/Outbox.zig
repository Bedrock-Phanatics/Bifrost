const std = @import("std");
const bedwire = @import("bedwire");

const protocol = bedwire.protocol;
const Current = protocol.Current;

const Outbox = @This();

gpa: std.mem.Allocator,
bytes: std.ArrayList(u8) = .empty,
lengths: std.ArrayList(u32) = .empty,

pub fn init(gpa: std.mem.Allocator) Outbox {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *Outbox) void {
    self.bytes.deinit(self.gpa);
    self.lengths.deinit(self.gpa);
}

pub fn emit(self: *Outbox, packet: protocol.typed.Packet) !void {
    const envelope: protocol.typed.Envelope = .{ .header = .{ .packet_id = Current.packetId(protocol.typed.packetKind(packet)).? }, .packet = packet };
    const size = try protocol.typed.encodedSize(envelope);
    try self.lengths.ensureUnusedCapacity(self.gpa, 1);
    try self.bytes.ensureUnusedCapacity(self.gpa, size);
    var writer = protocol.Writer.init(self.bytes.unusedCapacitySlice()[0..size]);
    try protocol.typed.encode(&writer, envelope);
    self.bytes.items.len += size;
    self.lengths.appendAssumeCapacity(@intCast(size));
}

pub fn count(self: *const Outbox) usize {
    return self.lengths.items.len;
}

pub fn slices(self: *const Outbox, start: usize, out: [][]const u8) []const []const u8 {
    var offset: usize = 0;
    for (self.lengths.items[0..start]) |len| offset += len;
    const n = @min(out.len, self.lengths.items.len - start);
    for (self.lengths.items[start..][0..n], out[0..n]) |len, *slice| {
        slice.* = self.bytes.items[offset..][0..len];
        offset += len;
    }
    return out[0..n];
}
