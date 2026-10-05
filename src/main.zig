const std = @import("std");
const zio = @import("zio");
const bifrost = @import("bifrost");

const log = std.log.scoped(.bifrost);

pub const std_options_debug_io = zio.debug_io;
pub const std_options: std.Options = .{
    .log_scope_levels = &.{.{ .scope = .zio, .level = .info }},
};

const config_path = "config/bifrost.toml";

pub fn main(init: std.process.Init) !void {
    const config = loadConfig(init);

    var keys: ?bifrost.KeySet = if (config.keysFile()) |keys_path| bifrost.loadKeys(init.gpa, init.io, keys_path) catch |err|
        fatal("{s}: {t}", .{ keys_path, err }) else null;
    defer if (keys) |*set| set.deinit();
    const auth: bifrost.Auth = switch (config.auth) {
        .off => .off,
        .verify => .{ .verify = &keys.? },
    };

    const proxy_key = switch (config.session_mode) {
        .passthrough => null,
        .managed => bifrost.loadProxyKey(init.io, config.proxyKeyFile().?) catch |err|
            fatal("{s}: {t}", .{ config.proxyKeyFile().?, err }),
    };
    if (proxy_key) |key| log.info("managed sessions; backends must trust proxy key {s}", .{&bifrost.proxyKeyText(key)});

    const rt = try zio.Runtime.init(init.gpa, .{ .executors = .exact(config.workers) });
    defer rt.deinit();

    var plugins: bifrost.Plugins = .init(init.gpa, config.backends(), .{
        .workers = config.workers,
        .packets = config.session_mode == .managed,
        .slow_callback_ns = @as(u64, config.slow_plugin_callback_ms) * std.time.ns_per_ms,
    });
    defer plugins.deinit();
    for (0..config.plugin_count) |i| plugins.open(config.pluginPath(i)) catch |err| {
        log.err("plugin {s}: {t}", .{ config.pluginPath(i), err });
        return error.PluginLoadFailed;
    };

    const workers = try bifrost.Workers.create(init.gpa, rt.io(), config, .{ .auth = auth, .proxy_key = proxy_key, .plugins = &plugins });
    defer workers.destroy();
    defer plugins.unload();

    var signals = try rt.spawn(stopOnSignal, .{workers});
    defer signals.cancel();

    log.info("listening on {f} with {d} worker(s), {d} backend(s)", .{ workers.localAddress(), config.workers, config.backends().len });
    try workers.run();
    const totals = workers.totals();
    log.info("stopped after {d} players", .{totals.sessions_accepted});
}

fn loadConfig(init: std.process.Init) bifrost.Config {
    var diag: bifrost.Diagnostic = .{};
    return bifrost.loadConfig(init.gpa, init.io, config_path, &diag) catch |err| switch (err) {
        error.FileNotFound => {
            log.info("no {s}, using the built-in defaults", .{config_path});
            return bifrost.parseConfig(init.gpa, @embedFile("default_config"), &diag) catch |default_err|
                fatal("built-in config: {t}", .{default_err});
        },
        error.InvalidSyntax, error.InvalidConfig => fatal("{s}: {f}", .{ config_path, diag }),
        else => fatal("{s}: {t}", .{ config_path, err }),
    };
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    log.err(format, args);
    std.process.exit(1);
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
