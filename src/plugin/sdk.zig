const std = @import("std");
pub const abi = @import("abi.zig");

pub const Player = abi.Player;
pub const Event = abi.Event;
pub const EventKind = abi.EventKind;
pub const TransferDecision = abi.TransferDecision;
pub const Handler = fn (event: *const Event, decision: ?*TransferDecision) void;

pub const Error = error{ Failed, Incompatible, StaleHandle, InvalidArgument, Unsupported, TooLate, Busy };

pub const Host = struct {
    raw: *const abi.Host,

    pub fn log(self: Host, level: abi.LogLevel, comptime format: []const u8, args: anytype) void {
        var buffer: [512]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, format, args) catch &buffer;
        self.raw.log(self.raw.context, level, .of(text));
    }

    pub fn on(self: Host, kind: EventKind, comptime handler: Handler) Error!void {
        const Trampoline = struct {
            fn call(_: ?*anyopaque, event: *const Event, decision: ?*TransferDecision) callconv(.c) void {
                handler(event, decision);
            }
        };
        try check(self.raw.subscribe(self.raw.context, kind, Trampoline.call, null));
    }

    pub fn transfer(self: Host, player: Player, backend: u32) Error!void {
        try check(self.raw.transfer(self.raw.context, player, backend));
    }

    pub fn playerName(self: Host, player: Player, buffer: []u8) Error![]const u8 {
        var len: usize = 0;
        try check(self.raw.player_name(self.raw.context, player, buffer.ptr, buffer.len, &len));
        return buffer[0..@min(len, buffer.len)];
    }

    pub fn backendCount(self: Host) u32 {
        return self.raw.backend_count(self.raw.context);
    }

    pub fn backendName(self: Host, backend: u32) Error![]const u8 {
        var name: abi.Str = .{};
        try check(self.raw.backend_name(self.raw.context, backend, &name));
        return name.slice();
    }
};

/// Exports `bifrost_plugin_init` for a plugin type with `name`, `version`, `init(Host) !void` and an optional `deinit()`.
pub fn exportPlugin(comptime Plugin: type) void {
    const Entry = struct {
        fn init(raw: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
            if (raw.abi_version != abi.version or raw.struct_size < @sizeOf(abi.Host)) return .incompatible;
            plugin.* = .{
                .name = .of(Plugin.name),
                .plugin_version = .of(Plugin.version),
                .capabilities = .{ .events = true },
                .shutdown = shutdown,
            };
            Plugin.init(.{ .raw = raw }) catch return .failed;
            return .ok;
        }

        fn shutdown(_: ?*anyopaque) callconv(.c) void {
            if (@hasDecl(Plugin, "deinit")) Plugin.deinit();
        }
    };
    @export(&Entry.init, .{ .name = abi.entrypoint });
}

fn check(status: abi.Status) Error!void {
    return switch (status) {
        .ok => {},
        .incompatible => error.Incompatible,
        .stale_handle => error.StaleHandle,
        .invalid_argument => error.InvalidArgument,
        .unsupported => error.Unsupported,
        .too_late => error.TooLate,
        .busy => error.Busy,
        else => error.Failed,
    };
}
