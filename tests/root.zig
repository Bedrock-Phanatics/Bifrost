const std = @import("std");
const bifrost = @import("bifrost");

test {
    _ = @import("integration/relay.zig");
    _ = @import("integration/lifecycle.zig");
    _ = @import("integration/handshake.zig");
    _ = @import("integration/backends.zig");
    _ = @import("integration/workers.zig");
    _ = @import("integration/managed.zig");
    _ = @import("integration/transfer.zig");
    _ = @import("integration/content.zig");
    _ = @import("integration/handoff.zig");
    _ = @import("integration/plugins.zig");
    _ = @import("integration/chaos.zig");
    _ = @import("integration/runtime_ids.zig");
}

test "the shipped config parses" {
    var diag: bifrost.Diagnostic = .{};
    const config = bifrost.parseConfig(std.testing.allocator, @embedFile("default_config"), &diag) catch |err| {
        std.debug.print("{f}\n", .{diag});
        return err;
    };
    try std.testing.expectEqual(@as(usize, 2), config.backends().len);
}
