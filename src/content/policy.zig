const registries = @import("registries.zig");

pub const Policy = enum {
    initial,
    match,
};

pub const Mismatch = enum {
    packs,
    start_game,
    blocks,
    items,
    biomes,
    dimensions,
    actors,

    pub fn of(kind: registries.Kind) Mismatch {
        return switch (kind) {
            inline else => |tag| @field(Mismatch, @tagName(tag)),
        };
    }
};
