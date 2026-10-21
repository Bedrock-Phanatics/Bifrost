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
    bifrost.tuneAllocator();
    const config = loadConfig(init);

    const keys_json: ?[]u8 = if (config.keysFile()) |keys_path| bifrost.readKeys(init.gpa, init.io, keys_path) catch |err|
        fatal("{s}: {t}", .{ keys_path, err }) else null;
    defer if (keys_json) |json| init.gpa.free(json);
    var keys: ?bifrost.KeySet = if (keys_json) |json| bifrost.parseKeys(init.gpa, json) catch |err|
        fatal("{s}: {t}", .{ config.keysFile().?, err }) else null;
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
    if (config.auth == .off) log.warn("auth is off: logins aren't checked, and without Minecraft encryption over NetherNet anyone can replay one", .{});

    // Players confirm this key once, so it has to survive restarts
    const identity = bifrost.loadIdentity(init.io, init.gpa, config.identityFile()) catch |err|
        fatal("{s}: {t}", .{ config.identityFile(), err });
    if (config.auth == .verify)
        log.info("{s} sessions; backends must trust proxy key {s}", .{ @tagName(config.session_mode), &bifrost.proxyKeyText(proxy_key orelse identity) })
    else
        log.info("auth is off, so backends see a throwaway key and can't be told to trust Bifrost", .{});
    if (config.native_threads != 0) bifrost.setNativeThreads(config.native_threads) catch |err|
        fatal("nethernet threads: {t}", .{err});

    const rt = try zio.Runtime.init(init.gpa, .{ .executors = .exact(config.workers) });
    defer rt.deinit();

    var plugins: bifrost.Plugins = try .init(init.gpa, config.backends(), .{
        .workers = config.workers,
        .packets = config.session_mode == .managed,
        .slow_callback_ns = @as(u64, config.slow_plugin_callback_ms) * std.time.ns_per_ms,
        .task_threads = config.plugin_task_threads,
    });
    defer plugins.deinit();
    var disabled: [bifrost.Config.max_disabled_plugins][]const u8 = undefined;
    for (disabled[0..config.disabled_count], 0..) |*name, i| name.* = config.disabledPlugin(i);
    bifrost.Plugins.Package.discover(&plugins, init.io, config.pluginsDir(), disabled[0..config.disabled_count]) catch |err| {
        log.err("plugins from {s}: {t}", .{ config.pluginsDir(), err });
        return error.PluginLoadFailed;
    };

    const workers = bifrost.Workers.create(init.gpa, rt.io(), config, .{
        .auth = auth,
        .proxy_key = proxy_key,
        .plugins = &plugins,
        .identity = identity,
        .issuer_keys = if (config.auth == .verify) keys_json else null,
    }) catch |err| fatal("can't listen on {f}: {t}", .{ config.bind, err });
    defer workers.destroy();
    defer plugins.unload();

    var signals = try rt.spawn(stopOnSignal, .{workers});
    defer signals.cancel();

    log.info("Bifrost {s} listening on {f} (NetherNet) with {d} worker(s), {d} backend(s)", .{ bifrost.version, workers.localAddress(), config.workers, config.backends().len });
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
