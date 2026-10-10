const std = @import("std");

const Context = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    bifrost: *std.Build.Module,
    raknet: *std.Build.Module,
    bedwire: *std.Build.Module,
    zio: *std.Build.Module,

    fn module(self: Context, path: []const u8, imports: []const std.Build.Module.Import) *std.Build.Module {
        return self.b.createModule(.{ .root_source_file = self.b.path(path), .target = self.target, .optimize = self.optimize, .imports = imports });
    }

    fn dependency(self: Context, name: []const u8, module_name: []const u8) *std.Build.Module {
        return self.b.dependency(name, .{ .target = self.target, .optimize = self.optimize }).module(module_name);
    }
};

const Plugin = struct {
    example: *std.Build.Step.Compile,
    c_fixture: *std.Build.Step.Compile,
    header: *std.Build.Module,
};

pub fn build(b: *std.Build) void {
    const version = @import("builtin").zig_version;
    if (comptime version.major != 0 or version.minor != 17 or version.patch != 0) {
        @compileError("Bifrost requires Zig 0.17.0");
    }

    var ctx: Context = .{
        .b = b,
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
        .bifrost = undefined,
        .raknet = undefined,
        .bedwire = undefined,
        .zio = undefined,
    };
    ctx.raknet = ctx.dependency("zig_raknet", "raknet");
    ctx.bedwire = ctx.dependency("bedwire", "bedwire");
    ctx.zio = ctx.dependency("zio", "zio");
    ctx.bifrost = b.addModule("bifrost", .{
        .root_source_file = b.path("src/root.zig"),
        .target = ctx.target,
        .optimize = ctx.optimize,
        .imports = &.{
            .{ .name = "raknet", .module = ctx.raknet },
            .{ .name = "toml", .module = ctx.dependency("toml", "toml") },
            .{ .name = "bedwire", .module = ctx.bedwire },
        },
    });

    addProxy(ctx);
    const plugin = addPluginSdk(ctx);
    addTests(ctx, plugin);
    addBench(ctx);
}

fn addProxy(ctx: Context) void {
    const b = ctx.b;
    const exe = b.addExecutable(.{ .name = "bifrost", .root_module = ctx.module("src/main.zig", &.{
        .{ .name = "bifrost", .module = ctx.bifrost },
        .{ .name = "zio", .module = ctx.zio },
    }) });
    exe.root_module.addAnonymousImport("default_config", .{ .root_source_file = b.path("config/bifrost.toml") });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    b.step("run", "Run Bifrost").dependOn(&run_cmd.step);
}

fn addPluginSdk(ctx: Context) Plugin {
    const b = ctx.b;
    const sdk = b.addModule("bifrost_plugin", .{ .root_source_file = b.path("src/plugin/sdk.zig") });
    const example = b.addLibrary(.{ .name = "maintenance", .linkage = .dynamic, .root_module = ctx.module("examples/maintenance.zig", &.{
        .{ .name = "bifrost_plugin", .module = sdk },
    }) });
    b.installArtifact(example);
    const header = b.addTranslateC(.{
        .root_source_file = b.path("include/bifrost_plugin.h"),
        .target = ctx.target,
        .optimize = ctx.optimize,
        .link_libc = true,
    });
    const c_fixture = b.addLibrary(.{ .name = "c_fixture", .linkage = .dynamic, .root_module = b.createModule(.{
        .target = ctx.target,
        .optimize = ctx.optimize,
        .link_libc = true,
    }) });
    c_fixture.root_module.addCSourceFile(.{ .file = b.path("tests/plugin/fixture.c"), .flags = &.{ "-std=c99", "-Wall", "-Wextra", "-Werror" } });
    c_fixture.root_module.addIncludePath(b.path("include"));
    return .{ .example = example, .c_fixture = c_fixture, .header = header.createModule() };
}

fn addTests(ctx: Context, plugin: Plugin) void {
    const b = ctx.b;
    const unit_tests = b.addTest(.{ .root_module = ctx.bifrost });
    const integration_tests = b.addTest(.{ .root_module = ctx.module("tests/root.zig", &.{
        .{ .name = "bifrost", .module = ctx.bifrost },
        .{ .name = "raknet", .module = ctx.raknet },
        .{ .name = "bedwire", .module = ctx.bedwire },
        .{ .name = "zio", .module = ctx.zio },
        .{ .name = "bifrost_plugin_h", .module = plugin.header },
    }) });
    integration_tests.root_module.addAnonymousImport("default_config", .{ .root_source_file = b.path("config/bifrost.toml") });
    const options = b.addOptions();
    options.addOption(bool, "report", b.option(bool, "transfer-report", "Print transfer stress timings and memory") orelse false);
    options.addOption(u32, "soak", b.option(u32, "soak", "Multiply the transfer stress rounds, e.g. 25 for a soak run") orelse 1);
    options.addOptionPath("example_plugin", plugin.example.getEmittedBin());
    options.addOptionPath("c_plugin", plugin.c_fixture.getEmittedBin());
    integration_tests.root_module.addImport("test_options", options.createModule());

    const step = b.step("test", "Run unit and integration tests");
    step.dependOn(&b.addRunArtifact(unit_tests).step);
    step.dependOn(&b.addRunArtifact(integration_tests).step);

    const stress = b.addRunArtifact(integration_tests);
    stress.has_side_effects = true;
    b.step("stress", "Run the integration tests again, never from cache").dependOn(&stress.step);
}

fn addBench(ctx: Context) void {
    const b = ctx.b;
    const scheduling = b.option(enum { work_stealing, pinned }, "scheduling", "ZIO scheduling of the benchmarked proxy (default: work_stealing)") orelse .work_stealing;
    const options = b.addOptions();
    options.addOption([]const u8, "scheduling", @tagName(scheduling));
    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "bifrost", .module = ctx.bifrost },
        .{ .name = "raknet", .module = ctx.raknet },
        .{ .name = "bedwire", .module = ctx.bedwire },
        .{ .name = "bench_options", .module = options.createModule() },
        .{ .name = "sample", .module = ctx.module("tests/support/sample.zig", &.{.{ .name = "bedwire", .module = ctx.bedwire }}) },
    };
    // The driver keeps the default scheduler so only the proxy under test changes
    const driver = benchExe(ctx, "bifrost-bench", imports, ctx.zio);
    const proxy = benchExe(ctx, "bifrost-bench-proxy", imports, b.dependency("zio", .{
        .target = ctx.target,
        .optimize = ctx.optimize,
        .scheduling = scheduling,
    }).module("zio"));
    const run = b.addRunArtifact(driver);
    run.addArg("--proxy-exe");
    run.addArtifactArg(proxy);
    run.addPassthruArgs();
    b.step("bench", "Run the proxy benchmarks (use -Doptimize=ReleaseFast)").dependOn(&run.step);
}

fn benchExe(ctx: Context, name: []const u8, imports: []const std.Build.Module.Import, zio: *std.Build.Module) *std.Build.Step.Compile {
    const module = ctx.module("tests/bench/main.zig", imports);
    module.addImport("zio", zio);
    return ctx.b.addExecutable(.{ .name = name, .root_module = module });
}
