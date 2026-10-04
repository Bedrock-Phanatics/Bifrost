const loader = @import("config/loader.zig");
const Observer = @import("protocol/Observer.zig");

pub const Config = @import("config/Config.zig");
pub const Diagnostic = loader.Diagnostic;
pub const loadConfig = loader.loadFile;
pub const parseConfig = loader.parse;

pub const Proxy = @import("proxy/Proxy.zig");
pub const Workers = @import("proxy/Workers.zig");
pub const Admission = @import("proxy/Admission.zig");
pub const Stats = @import("proxy/Stats.zig");
pub const Backend = @import("backend/Backend.zig");
pub const Health = @import("backend/Health.zig");

pub const Auth = Observer.Auth;
pub const KeySet = @import("bedwire").auth.KeySet;
pub const loadKeys = Observer.loadKeys;
pub const advertisedPlayers = @import("protocol/advertisement.zig").players;
pub const Managed = @import("session/Managed.zig");
pub const loadProxyKey = @import("session/proxy_key.zig").load;
pub const proxyKeyText = @import("session/proxy_key.zig").publicText;

test {
    _ = Config;
    _ = loader;
    _ = Admission;
    _ = Backend;
    _ = Health;
    _ = @import("backend/Router.zig");
    _ = @import("protocol/advertisement.zig");
    _ = @import("proxy/PacketQueue.zig");
    _ = @import("session/proxy_key.zig");
    _ = @import("transfer/State.zig");
}
