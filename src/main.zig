const std = @import("std");
const zio = @import("zio");
const bifrost = @import("bifrost");

const log = std.log.scoped(.bifrost);

pub const std_options_debug_io = zio.debug_io;
pub const std_options: std.Options = .{
    .log_scope_levels = &.{.{ .scope = .zio, .level = .info }},
};

const usage =
    \\usage: bifrost [--config <path>]
    \\
    \\  --config <path>   TOML config file (default: bifrost.toml)
    \\
;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const path = configPath(args[1..]) orelse {
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    };

    var diag: bifrost.Diagnostic = .{};
    const config = bifrost.loadConfig(init.gpa, init.io, path, &diag) catch |err| {
        switch (err) {
            error.InvalidSyntax, error.InvalidConfig => log.err("{s}: {f}", .{ path, diag }),
            else => log.err("{s}: {t}", .{ path, err }),
        }
        std.process.exit(1);
    };

    var keys: ?bifrost.KeySet = if (config.keysFile()) |keys_path| bifrost.loadKeys(init.gpa, init.io, keys_path) catch |err| {
        log.err("{s}: {t}", .{ keys_path, err });
        std.process.exit(1);
    } else null;
    defer if (keys) |*set| set.deinit();
    const auth: bifrost.Auth = switch (config.auth) {
        .off => .off,
        .verify => .{ .verify = &keys.? },
    };

    const rt = try zio.Runtime.init(init.gpa, .{});
    defer rt.deinit();

    const proxy = try bifrost.Proxy.create(init.gpa, rt.io(), config, auth);
    defer proxy.destroy();

    var signals = try rt.spawn(stopOnSignal, .{proxy});
    defer signals.cancel();

    log.info("listening on {f}, {d} backend(s)", .{ proxy.localAddress(), config.backends().len });
    proxy.run();
    log.info("stopped", .{});
}

fn configPath(args: []const []const u8) ?[]const u8 {
    if (args.len == 0) return "bifrost.toml";
    if (args.len == 2 and std.mem.eql(u8, args[0], "--config")) return args[1];
    return null;
}

fn stopOnSignal(proxy: *bifrost.Proxy) void {
    var interrupt = zio.Signal.init(.interrupt) catch |err| return log.warn("signal handling unavailable: {t}", .{err});
    defer interrupt.deinit();
    var terminate = zio.Signal.init(.terminate) catch |err| return log.warn("signal handling unavailable: {t}", .{err});
    defer terminate.deinit();
    _ = zio.select(.{ .interrupt = &interrupt, .terminate = &terminate }) catch return;
    log.info("shutting down", .{});
    proxy.stop();
}
