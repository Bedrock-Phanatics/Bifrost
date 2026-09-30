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

    const rt = try zio.Runtime.init(init.gpa, .{ .executors = .exact(config.workers) });
    defer rt.deinit();

    const workers = try bifrost.Workers.create(init.gpa, rt.io(), config, auth);
    defer workers.destroy();

    var signals = try rt.spawn(stopOnSignal, .{workers});
    defer signals.cancel();

    log.info("listening on {f} with {d} worker(s), {d} backend(s)", .{ workers.localAddress(), config.workers, config.backends().len });
    try workers.run();
    const totals = workers.totals();
    log.info("stopped after {d} players", .{totals.sessions_accepted});
}

fn configPath(args: []const []const u8) ?[]const u8 {
    if (args.len == 0) return "bifrost.toml";
    if (args.len == 2 and std.mem.eql(u8, args[0], "--config")) return args[1];
    return null;
}

fn stopOnSignal(workers: *bifrost.Workers) void {
    var interrupt = zio.Signal.init(.interrupt) catch |err| return log.warn("signal handling unavailable: {t}", .{err});
    defer interrupt.deinit();
    var terminate = zio.Signal.init(.terminate) catch |err| return log.warn("signal handling unavailable: {t}", .{err});
    defer terminate.deinit();
    _ = zio.select(.{ .interrupt = &interrupt, .terminate = &terminate }) catch return;
    log.info("shutting down", .{});
    workers.stop();
}
