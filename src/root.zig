const loader = @import("config/loader.zig");

pub const Config = @import("config/Config.zig");
pub const Diagnostic = loader.Diagnostic;
pub const loadConfig = loader.loadFile;
pub const parseConfig = loader.parse;
pub const Proxy = @import("proxy/Proxy.zig");

test {
    _ = Config;
    _ = loader;
    _ = @import("backend/Router.zig");
    _ = @import("proxy/PacketQueue.zig");
}
