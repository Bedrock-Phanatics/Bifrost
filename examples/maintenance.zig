const std = @import("std");
const bifrost = @import("bifrost_plugin");

pub const name = "maintenance";
pub const version = "1.0.0";

var host: bifrost.Host = undefined;

comptime {
    bifrost.exportPlugin(@This());
}

pub fn init(api: bifrost.Host) !void {
    host = api;
    try host.on(.player_authenticated, greet);
    try host.on(.transfer_requested, guard);
}

fn greet(event: *const bifrost.Event, _: ?*bifrost.TransferDecision) void {
    host.log(.info, "{s} joined", .{event.name.slice()});
}

fn guard(event: *const bifrost.Event, decision: ?*bifrost.TransferDecision) void {
    const target = host.backendName(event.backend) catch return;
    if (!std.mem.eql(u8, target, "maintenance")) return;
    if (decision) |out| out.action = .cancel;
    host.log(.info, "kept a player off {s}", .{target});
}
