const std = @import("std");

pub const enabled = @import("build_options").tracy;

const Location = extern struct {
    name: [*:0]const u8,
    function: [*:0]const u8,
    file: [*:0]const u8,
    line: u32,
    color: u32,
};

const Context = extern struct { id: u32, active: i32 };

extern fn ___tracy_emit_zone_begin(location: *const Location, active: i32) Context;
extern fn ___tracy_emit_zone_end(context: Context) void;
extern fn ___tracy_set_thread_name(name: [*:0]const u8) void;
extern fn ___tracy_emit_plot(name: [*:0]const u8, value: f64) void;

// Zones must not span a suspension point, ZIO can resume the task on another thread
pub const Zone = struct {
    context: if (enabled) Context else void,

    pub inline fn end(self: Zone) void {
        if (enabled) ___tracy_emit_zone_end(self.context);
    }
};

pub inline fn zone(comptime src: std.builtin.SourceLocation, comptime name: [:0]const u8) Zone {
    if (!enabled) return .{ .context = {} };
    const Static = struct {
        const location: Location = .{ .name = name, .function = src.fn_name, .file = src.file, .line = src.line, .color = 0 };
    };
    return .{ .context = ___tracy_emit_zone_begin(&Static.location, 1) };
}

pub inline fn threadName(comptime name: [:0]const u8) void {
    if (enabled) ___tracy_set_thread_name(name);
}

pub inline fn plot(comptime name: [:0]const u8, value: anytype) void {
    if (enabled) ___tracy_emit_plot(name, std.math.lossyCast(f64, value));
}

test "disabled zones compile to nothing" {
    const span = zone(@src(), "test");
    span.end();
    if (!enabled) try std.testing.expectEqual(@as(usize, 0), @sizeOf(Zone));
}
