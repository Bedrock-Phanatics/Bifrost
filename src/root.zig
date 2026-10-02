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
pub const Health = @import("backend/Health.zig");

pub const Auth = Observer.Auth;
pub const KeySet = @import("bedwire").auth.KeySet;
pub const loadKeys = Observer.loadKeys;
pub const advertisedPlayers = @import("protocol/advertisement.zig").players;

test {
    _ = Config;
    _ = loader;
    _ = Admission;
    _ = Health;
    _ = @import("backend/Router.zig");
    _ = @import("protocol/advertisement.zig");
    _ = @import("proxy/PacketQueue.zig");
}
