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
pub const Plugins = @import("plugin/Plugins.zig");
pub const plugin_abi = @import("plugin/abi.zig");
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
    _ = @import("content/nbt.zig");
    _ = @import("content/registries.zig");
    _ = @import("content/packs.zig");
    _ = @import("session/ClientState.zig");
    _ = @import("transfer/Handoff.zig");
    _ = @import("session/self_id.zig");
    _ = @import("session/commands.zig");
    _ = @import("plugin/Plugins.zig");
    _ = @import("plugin/Handles.zig");
    _ = @import("plugin/Packets.zig");
    _ = @import("plugin/Work.zig");
    _ = @import("plugin/sdk.zig");
}
