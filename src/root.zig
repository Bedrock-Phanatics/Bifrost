const builtin = @import("builtin");
const loader = @import("config/loader.zig");
const Observer = @import("protocol/Observer.zig");

pub const Config = @import("config/Config.zig");
pub const Diagnostic = loader.Diagnostic;
pub const loadConfig = loader.loadFile;
pub const parseConfig = loader.parse;

pub const Proxy = @import("proxy/Proxy.zig");
pub const Workers = @import("proxy/Workers.zig");
pub const Admission = @import("proxy/Admission.zig");
pub const Budget = @import("proxy/Budget.zig");
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

// glibc gives the heap top back after every burst of frees and faults it in again on the next one,
// so keep a few MiB of slack
pub fn tuneAllocator() void {
    if (comptime builtin.os.tag != .linux or !builtin.abi.isGnu() or !builtin.link_libc) return;
    const top_pad = -2;
    _ = mallopt(top_pad, 4 * 1024 * 1024);
}

extern "c" fn mallopt(param: c_int, value: c_int) c_int;

test {
    _ = Proxy;
    _ = Config;
    _ = loader;
    _ = Admission;
    _ = Backend;
    _ = Health;
    _ = @import("backend/Router.zig");
    _ = @import("protocol/advertisement.zig");
    _ = @import("proxy/PacketQueue.zig");
    _ = Budget;
    _ = @import("proxy/Rate.zig");
    _ = @import("transfer/Queue.zig");
    _ = @import("session/proxy_key.zig");
    _ = @import("transfer/State.zig");
    _ = @import("content/nbt.zig");
    _ = @import("content/registries.zig");
    _ = @import("content/packs.zig");
    _ = @import("session/ClientState.zig");
    _ = @import("session/Gameplay.zig");
    _ = Managed;
    _ = @import("transfer/Handoff.zig");
    _ = @import("session/self_id.zig");
    _ = @import("session/commands.zig");
    _ = @import("plugin/Plugins.zig");
    _ = @import("plugin/Package.zig");
    _ = @import("plugin/Library.zig");
    _ = @import("plugin/abi.zig");
    _ = @import("plugin/Handles.zig");
    _ = @import("plugin/Packets.zig");
    _ = @import("plugin/Decoded.zig");
    _ = @import("plugin/injection.zig");
    _ = @import("plugin/Work.zig");
    _ = @import("plugin/sdk.zig");
    _ = @import("trace.zig");
    _ = @import("proxy/Metrics.zig");
}
