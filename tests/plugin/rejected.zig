const abi = @import("bifrost_plugin").abi;

var mode: u32 = 0;
var shutdowns: u32 = 0;
var inits: u32 = 0;

export fn bifrost_fixture_mode(value: u32) callconv(.c) void {
    mode = value;
}

export fn bifrost_fixture_shutdowns() callconv(.c) u32 {
    return shutdowns;
}

export fn bifrost_fixture_inits() callconv(.c) u32 {
    return inits;
}

export fn bifrost_plugin_get_manifest(out: ?*abi.Str) callconv(.c) abi.Status {
    const value = out orelse return .invalid_argument;
    value.* = switch (mode) {
        1 => .of("name = "),
        2 => .of("name = \"c-fixture\"\nversion = \"1.0.0\""),
        3 => .{ .ptr = @ptrFromInt(1), .len = abi.max_manifest_bytes + 1 },
        4 => .of("name = \"\xff\""),
        5 => .{ .ptr = null, .len = 4 },
        6 => .{},
        else => .of(@embedFile("fixture.toml")),
    };
    return if (mode == 7) .failed else .ok;
}

export fn bifrost_plugin_init(host: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
    inits += 1;
    plugin.capabilities = .{ .events = true, .packets = true, .commands = true };
    plugin.shutdown = stop;
    if (host.subscribe(host.context, .player_connected, event, null) != .ok) return .failed;
    if (host.subscribe_packet(host.context, .from_player, 9, .any, .{}, packet, null) != .ok) return .failed;
    if (host.register_command(host.context, .of("rejected"), command, null) != .ok) return .failed;
    switch (mode) {
        8 => plugin.name = .of("different"),
        9 => plugin.plugin_version = .of("2.0.0"),
        10 => plugin.abi_version = 0,
        11 => plugin.abi_version = abi.version + 1,
        12 => return .failed,
        else => {},
    }
    return .ok;
}

fn stop(_: ?*anyopaque) callconv(.c) void {
    shutdowns += 1;
}

fn event(_: ?*anyopaque, _: *const abi.Event, _: ?*abi.TransferDecision) callconv(.c) void {}
fn packet(_: ?*anyopaque, _: *abi.Packet) callconv(.c) abi.PacketAction {
    return .pass;
}
fn command(_: ?*anyopaque, _: *const abi.Command) callconv(.c) void {}
