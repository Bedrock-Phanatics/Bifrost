const std = @import("std");

pub fn build(b: *std.Build) void {
    const version = @import("builtin").zig_version;
    if (comptime version.major != 0 or version.minor != 16 or version.patch != 0) {
        @compileError("Bifrost requires Zig 0.16.0");
    }

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const raknet = dependencyModule(b, "zig_raknet", "raknet", target, optimize);
    const zio = dependencyModule(b, "zio", "zio", target, optimize);

    const bifrost = b.addModule("bifrost", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "raknet", .module = raknet },
            .{ .name = "bedwire", .module = dependencyModule(b, "bedwire", "bedwire", target, optimize) },
        },
    });

    const exe = b.addExecutable(.{ .name = "bifrost", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "bifrost", .module = bifrost },
            .{ .name = "zio", .module = zio },
        },
    }) });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run Bifrost").dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{ .root_module = bifrost });
    const integration_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/proxy.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "bifrost", .module = bifrost },
            .{ .name = "raknet", .module = raknet },
            .{ .name = "zio", .module = zio },
        },
    }) });
    const test_step = b.step("test", "Run unit and integration tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    test_step.dependOn(&b.addRunArtifact(integration_tests).step);
}

fn dependencyModule(
    b: *std.Build,
    dependency: []const u8,
    module: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.dependency(dependency, .{ .target = target, .optimize = optimize }).module(module);
}
