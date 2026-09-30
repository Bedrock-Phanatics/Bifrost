const std = @import("std");
const zio = @import("zio");
const bifrost = @import("bifrost");
const Config = bifrost.Config;
const Proxy = bifrost.Proxy;

const log = std.log.scoped(.bifrost);

pub const std_options_debug_io = zio.debug_io;
pub const std_options: std.Options = .{
    .log_scope_levels = &.{.{ .scope = .zio, .level = .info }},
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const config = Config.parse(args[1..]) catch |err| {
        std.debug.print("error: {t}\n\n{s}", .{ err, bifrost.usage });
        std.process.exit(2);
    };

    const rt = try zio.Runtime.init(init.gpa, .{});
    defer rt.deinit();

    const proxy = try Proxy.create(init.gpa, rt.io(), config);
    defer proxy.destroy();

    var signals = try rt.spawn(stopOnSignal, .{proxy});
    defer signals.cancel();

    log.info("listening on {f}, {d} backend(s)", .{ proxy.localAddress(), config.backends().len });
    proxy.run();
    log.info("stopped", .{});
}

fn stopOnSignal(proxy: *Proxy) void {
    var interrupt = zio.Signal.init(.interrupt) catch |err| return log.warn("signal handling unavailable: {t}", .{err});
    defer interrupt.deinit();
    var terminate = zio.Signal.init(.terminate) catch |err| return log.warn("signal handling unavailable: {t}", .{err});
    defer terminate.deinit();
    _ = zio.select(.{ .interrupt = &interrupt, .terminate = &terminate }) catch return;
    log.info("shutting down", .{});
    proxy.stop();
}
