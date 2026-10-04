const std = @import("std");

const Hasher = std.hash.Wyhash;
const max_depth = 64;

pub const Error = error{ InvalidNbt, NbtTooDeep };

pub fn hash(bytes: []const u8) Error!u64 {
    var cursor: Cursor = .{ .bytes = bytes };
    const tag = try cursor.byte();
    if (tag == 0) return Hasher.hash(0, "absent");
    const name = try cursor.string();
    const value = try cursor.payload(tag, 0);
    if (cursor.index != bytes.len) return error.InvalidNbt;
    return entry(tag, name, value);
}

fn entry(tag: u8, name: []const u8, value: u64) u64 {
    var hasher: Hasher = .init(tag);
    hasher.update(name);
    hasher.update(std.mem.asBytes(&value));
    return hasher.final();
}

const Cursor = struct {
    bytes: []const u8,
    index: usize = 0,

    fn take(self: *Cursor, len: usize) Error![]const u8 {
        if (len > self.bytes.len - self.index) return error.InvalidNbt;
        defer self.index += len;
        return self.bytes[self.index..][0..len];
    }

    fn byte(self: *Cursor) Error!u8 {
        return (try self.take(1))[0];
    }

    fn varint(self: *Cursor) Error!u64 {
        var value: u64 = 0;
        var shift: u7 = 0;
        while (shift < 70) : (shift += 7) {
            const b = try self.byte();
            value |= @as(u64, b & 0x7f) << @intCast(shift);
            if (b & 0x80 == 0) return value;
        }
        return error.InvalidNbt;
    }

    fn count(self: *Cursor) Error!usize {
        const raw = try self.varint();
        const zigzag: i64 = @bitCast((raw >> 1) ^ (0 -% (raw & 1)));
        if (zigzag < 0 or zigzag > self.bytes.len) return error.InvalidNbt;
        return @intCast(zigzag);
    }

    fn string(self: *Cursor) Error![]const u8 {
        const len = try self.varint();
        if (len > self.bytes.len) return error.InvalidNbt;
        return self.take(@intCast(len));
    }

    fn payload(self: *Cursor, tag: u8, depth: usize) Error!u64 {
        if (depth > max_depth) return error.NbtTooDeep;
        var hasher: Hasher = .init(tag);
        switch (tag) {
            1 => hasher.update(try self.take(1)),
            2 => hasher.update(try self.take(2)),
            5 => hasher.update(try self.take(4)),
            6 => hasher.update(try self.take(8)),
            3, 4 => hasher.update(std.mem.asBytes(&try self.varint())),
            7 => hasher.update(try self.take(try self.count())),
            8 => hasher.update(try self.string()),
            9 => {
                const child = try self.byte();
                const len = try self.count();
                hasher.update(&.{child});
                for (0..len) |_| hasher.update(std.mem.asBytes(&try self.payload(child, depth + 1)));
            },
            10 => {
                var sum: u64 = 0;
                while (true) {
                    const child = try self.byte();
                    if (child == 0) break;
                    const name = try self.string();
                    sum +%= entry(child, name, try self.payload(child, depth + 1));
                }
                hasher.update(std.mem.asBytes(&sum));
            },
            11, 12 => for (0..try self.count()) |_| hasher.update(std.mem.asBytes(&try self.varint())),
            else => return error.InvalidNbt,
        }
        return hasher.final();
    }
};

test "compound order doesn't change the hash, values and list order do" {
    const a = [_]u8{ 10, 0, 1, 1, 'a', 5, 3, 1, 'b', 2, 0 };
    const b = [_]u8{ 10, 0, 3, 1, 'b', 2, 1, 1, 'a', 5, 0 };
    const c = [_]u8{ 10, 0, 1, 1, 'a', 6, 3, 1, 'b', 2, 0 };
    try std.testing.expectEqual(try hash(&a), try hash(&b));
    try std.testing.expect(try hash(&a) != try hash(&c));

    const list_ab = [_]u8{ 9, 0, 1, 4, 1, 2 };
    const list_ba = [_]u8{ 9, 0, 1, 4, 2, 1 };
    try std.testing.expect(try hash(&list_ab) != try hash(&list_ba));
}

test "malformed documents are rejected" {
    try std.testing.expectError(error.InvalidNbt, hash(&.{ 10, 0, 1, 5, 'a' }));
    try std.testing.expectError(error.InvalidNbt, hash(&.{ 10, 0, 0, 0xff }));
    try std.testing.expectError(error.InvalidNbt, hash(&.{ 13, 0 }));
    var deep: [2 + 2 * 70 + 2]u8 = undefined;
    deep[0..2].* = .{ 9, 0 };
    for (0..70) |level| deep[2 + 2 * level ..][0..2].* = .{ 9, 2 };
    deep[deep.len - 2 ..][0..2].* = .{ 1, 0 };
    try std.testing.expectError(error.NbtTooDeep, hash(&deep));
}
