const loader = @import("config/loader.zig");
const Observer = @import("protocol/Observer.zig");

pub const Config = @import("config/Config.zig");
pub const Diagnostic = loader.Diagnostic;
pub const loadConfig = loader.loadFile;
pub const parseConfig = loader.parse;
pub const Proxy = @import("proxy/Proxy.zig");
pub const Auth = Observer.Auth;
pub const KeySet = @import("bedwire").auth.KeySet;
pub const loadKeys = Observer.loadKeys;

test {
    _ = Config;
    _ = loader;
    _ = @import("backend/Router.zig");
    _ = @import("proxy/PacketQueue.zig");
}
