const std = @import("std");
pub const abi = @import("abi.zig");

pub const Player = abi.Player;
pub const Event = abi.Event;
pub const EventKind = abi.EventKind;
pub const TransferDecision = abi.TransferDecision;
pub const Packet = abi.Packet;
pub const Handler = fn (event: *const Event, decision: ?*TransferDecision) void;
pub const PacketHandler = fn (packet: *Packet) abi.PacketAction;
pub const Command = abi.Command;
pub const CommandHandler = fn (command: *const Command) void;
pub const TaskResult = abi.TaskResult;

pub const Error = error{ Failed, Incompatible, StaleHandle, InvalidArgument, Unsupported, TooLate, Busy, WrongThread, Canceled };

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

    pub fn onPacket(self: Host, direction: abi.Direction, id: u10, phase: abi.PacketPhase, flags: abi.PacketFlags, comptime handler: PacketHandler) Error!void {
        const Trampoline = struct {
            fn call(_: ?*anyopaque, packet: *Packet) callconv(.c) abi.PacketAction {
                return handler(packet);
            }
        };
        try check(self.raw.subscribe_packet(self.raw.context, direction, id, phase, flags, Trampoline.call, null));
    }

    pub fn command(self: Host, name: []const u8, comptime handler: CommandHandler) Error!void {
        const Trampoline = struct {
            fn call(_: ?*anyopaque, request: *const Command) callconv(.c) void {
                handler(request);
            }
        };
        try check(self.raw.register_command(self.raw.context, .of(name), Trampoline.call, null));
    }

    pub fn spawn(self: Host, player: Player, comptime run: fn (user: ?*anyopaque) void, comptime done: fn (user: ?*anyopaque, result: *const TaskResult) void, user: ?*anyopaque) Error!void {
        const Trampoline = struct {
            fn runTask(state: ?*anyopaque) callconv(.c) void {
                run(state);
            }

            fn finish(state: ?*anyopaque, result: *const TaskResult) callconv(.c) void {
                done(state, result);
            }
        };
        try check(self.raw.spawn_task(self.raw.context, player, Trampoline.runTask, Trampoline.finish, user));
    }

    pub fn message(self: Host, player: Player, text: []const u8) Error!void {
        try check(self.raw.send_message(self.raw.context, player, .of(text)));
    }

    pub fn post(self: Host, player: Player, comptime done: fn (user: ?*anyopaque, result: *const TaskResult) void, user: ?*anyopaque) Error!void {
        const Trampoline = struct {
            fn finish(state: ?*anyopaque, result: *const TaskResult) callconv(.c) void {
                done(state, result);
            }
        };
        try check(self.raw.post(self.raw.context, player, Trampoline.finish, user));
    }

    pub fn workerCount(self: Host) u32 {
        return self.raw.worker_count(self.raw.context);
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

pub fn exportPlugin(comptime Plugin: type) void {
    const Entry = struct {
        fn init(raw: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
            if (raw.abi_version != abi.version or raw.struct_size < @sizeOf(abi.Host)) return .incompatible;
            plugin.* = .{
                .name = .of(Plugin.name),
                .plugin_version = .of(Plugin.version),
                .capabilities = if (@hasDecl(Plugin, "capabilities")) Plugin.capabilities else .{ .events = true },
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
        .wrong_thread => error.WrongThread,
        .canceled => error.Canceled,
        else => error.Failed,
    };
}
