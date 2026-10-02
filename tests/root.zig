const std = @import("std");
const bifrost = @import("bifrost");

test {
    _ = @import("relay.zig");
    _ = @import("lifecycle.zig");
    _ = @import("handshake.zig");
    _ = @import("backends.zig");
    _ = @import("workers.zig");
}

test "the shipped config parses" {
    var diag: bifrost.Diagnostic = .{};
    const config = bifrost.parseConfig(std.testing.allocator, @embedFile("default_config"), &diag) catch |err| {
        std.debug.print("{f}\n", .{diag});
        return err;
    };
    try std.testing.expectEqual(@as(usize, 2), config.backends().len);
}
