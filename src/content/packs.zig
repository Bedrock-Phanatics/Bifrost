const std = @import("std");
const bedwire = @import("bedwire");

const packets = bedwire.protocol.packets;
const Info = packets.resource_packs_info.Packet;
const Stack = packets.resource_pack_stack.Packet;
const Hasher = std.hash.Wyhash;

pub const Fingerprint = struct {
    info: ?u64 = null,
    stack: ?u64 = null,

    pub fn complete(self: Fingerprint) bool {
        return self.info != null and self.stack != null;
    }

    pub fn eql(self: Fingerprint, other: Fingerprint) bool {
        return self.info == other.info and self.stack == other.stack;
    }
};

pub fn infoHash(info: Info) !u64 {
    var packs: u64 = 0;
    var it = info.resource_packs.iterator();
    while (try it.next()) |pack| {
        var hasher: Hasher = .init(0);
        hasher.update(&pack.pack_id_version.pack_uuid);
        hashString(&hasher, pack.pack_id_version.pack_version);
        hashString(&hasher, pack.subpack_name);
        hasher.update(&.{ @intFromBool(pack.has_scripts), @intFromBool(pack.is_addon_pack) });
        packs +%= hasher.final();
    }
    var hasher: Hasher = .init(1);
    hasher.update(std.mem.asBytes(&packs));
    hasher.update(&.{ @intFromBool(info.resource_pack_required), @intFromBool(info.has_addon_packs), @intFromBool(info.has_scripts) });
    hasher.update(&info.world_template_id_and_version.pack_uuid);
    hashString(&hasher, info.world_template_id_and_version.pack_version);
    return hasher.final();
}

pub fn stackHash(stack: Stack) !u64 {
    var hasher: Hasher = .init(2);
    hasher.update(&.{@intFromBool(stack.texture_pack_required)});
    var it = stack.texture_pack_list.iterator();
    while (try it.next()) |pack| {
        hashString(&hasher, pack.pack_id);
        hashString(&hasher, pack.version);
        hashString(&hasher, pack.sub_pack_name);
    }
    return hasher.final();
}

fn hashString(hasher: *Hasher, text: []const u8) void {
    hasher.update(std.mem.asBytes(&@as(u32, @intCast(@min(text.len, std.math.maxInt(u32))))));
    hasher.update(text);
}
