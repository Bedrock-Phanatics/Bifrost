pub const Config = @import("config/Config.zig");
pub const usage = Config.usage;
pub const Proxy = @import("proxy/Proxy.zig");

test {
    _ = @import("config/Config.zig");
    _ = @import("backend/Router.zig");
    _ = @import("proxy/PacketQueue.zig");
}
