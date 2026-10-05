const std = @import("std");

pub fn build(b: *std.Build) void {
    const version = @import("builtin").zig_version;
    if (comptime version.major != 0 or version.minor != 17 or version.patch != 0) {
        @compileError("Bifrost requires Zig 0.17.0");
    }

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const raknet = dependencyModule(b, "zig_raknet", "raknet", target, optimize);
    const zio = dependencyModule(b, "zio", "zio", target, optimize);
    const bedwire_module = dependencyModule(b, "bedwire", "bedwire", target, optimize);

    const bifrost = b.addModule("bifrost", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "raknet", .module = raknet },
            .{ .name = "toml", .module = dependencyModule(b, "toml", "toml", target, optimize) },
            .{ .name = "bedwire", .module = bedwire_module },
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
    exe.root_module.addAnonymousImport("default_config", .{ .root_source_file = b.path("config/bifrost.toml") });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run Bifrost").dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{ .root_module = bifrost });
    const integration_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "bifrost", .module = bifrost },
            .{ .name = "raknet", .module = raknet },
            .{ .name = "bedwire", .module = bedwire_module },
            .{ .name = "zio", .module = zio },
        },
    }) });
    integration_tests.root_module.addAnonymousImport("default_config", .{ .root_source_file = b.path("config/bifrost.toml") });
    const test_options = b.addOptions();
    test_options.addOption(bool, "report", b.option(bool, "transfer-report", "Print transfer stress timings and memory") orelse false);
    integration_tests.root_module.addImport("test_options", test_options.createModule());
    const test_step = b.step("test", "Run unit and integration tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    test_step.dependOn(&b.addRunArtifact(integration_tests).step);

    const scheduling = b.option(enum { work_stealing, pinned }, "scheduling", "ZIO scheduling of the benchmarked proxy (default: work_stealing)") orelse .work_stealing;
    const bench_options = b.addOptions();
    bench_options.addOption([]const u8, "scheduling", @tagName(scheduling));
    const bench_imports: []const std.Build.Module.Import = &.{
        .{ .name = "bifrost", .module = bifrost },
        .{ .name = "raknet", .module = raknet },
        .{ .name = "bedwire", .module = bedwire_module },
        .{ .name = "bench_options", .module = bench_options.createModule() },
        .{ .name = "sample", .module = b.createModule(.{
            .root_source_file = b.path("tests/support/sample.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "bedwire", .module = bedwire_module }},
        }) },
    };
    // The driver keeps the default scheduler so only the proxy under test changes
    const bench = addBench(b, "bifrost-bench", target, optimize, bench_imports, zio);
    const bench_proxy = addBench(b, "bifrost-bench-proxy", target, optimize, bench_imports, b.dependency("zio", .{
        .target = target,
        .optimize = optimize,
        .scheduling = scheduling,
    }).module("zio"));
    const bench_cmd = b.addRunArtifact(bench);
    bench_cmd.addArg("--proxy-exe");
    bench_cmd.addArtifactArg(bench_proxy);
    bench_cmd.addPassthruArgs();
    b.step("bench", "Run the proxy benchmarks (use -Doptimize=ReleaseFast)").dependOn(&bench_cmd.step);
}

fn addBench(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    imports: []const std.Build.Module.Import,
    zio: *std.Build.Module,
) *std.Build.Step.Compile {
    const module = b.createModule(.{ .root_source_file = b.path("bench/main.zig"), .target = target, .optimize = optimize, .imports = imports });
    module.addImport("zio", zio);
    return b.addExecutable(.{ .name = name, .root_module = module });
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
