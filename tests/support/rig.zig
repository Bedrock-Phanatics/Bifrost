const std = @import("std");
const bifrost = @import("bifrost");
const fixtures = @import("fixtures.zig");
const managed = @import("managed.zig");
const sample = @import("sample.zig");

const Running = fixtures.Running;
const Player = managed.Player;
const io = std.testing.io;
const IpAddress = std.Io.net.IpAddress;

pub const Rig = struct {
    keys: bifrost.KeySet,
    a: managed.Backend,
    b: managed.Backend,
    running: Running,
    player: *Player,

    const Options = struct {
        b: managed.Backend.Mode = .normal,
        a: managed.Backend.Mode = .normal,
        a_content: sample.Content = .{},
        b_content: sample.Content = .{},
        content_policy: @FieldType(bifrost.Config, "content_policy") = .initial,
        target: ?IpAddress = null,
        connect_timeout_ms: u32 = 500,
        phase_timeout_ms: u32 = 5_000,
        timeout_ms: u32 = 15_000,
        cache: ?bool = null,
        allocator: std.mem.Allocator = std.testing.allocator,
    };

    pub fn start(self: *Rig, options: Options) !void {
        const proxy_key = try managed.proxyKey(1);
        self.keys = try managed.keySet();
        errdefer self.keys.deinit();
        try self.a.start(io, proxy_key.public_key);
        errdefer self.a.deinit();
        try self.b.start(io, proxy_key.public_key);
        errdefer self.b.deinit();
        self.a.mode = options.a;
        self.b.mode = options.b;
        self.a.content = options.a_content;
        self.b.content = options.b_content;
        var proxy_config = try managed.config(&.{ self.a.address(), options.target orelse self.b.address() });
        proxy_config.connect_timeout_ms = options.connect_timeout_ms;
        proxy_config.transfer_phase_timeout_ms = options.phase_timeout_ms;
        proxy_config.transfer_timeout_ms = options.timeout_ms;
        proxy_config.content_policy = options.content_policy;
        try self.running.startWith(io, options.allocator, proxy_config, .{ .auth = .{ .verify = &self.keys }, .proxy_key = proxy_key });
        errdefer self.running.deinit();
        self.player = try Player.connect(io, self.running.address(), 2);
        errdefer self.player.destroy();
        try self.player.login("Steve", "2535400000000001");
        if (options.cache) |supported| {
            var buffer: [8]u8 = undefined;
            try self.player.send(&.{try sample.typedPacket(&buffer, .{ .client_cache_status = .{ .is_cache_supported = supported } })});
        }
        try self.player.spawn();
        // Waits until the proxy has the player in game
        if (options.a != .chatter) try self.expectOn(&self.a);
    }

    pub fn deinit(self: *Rig) void {
        self.player.destroy();
        self.running.deinit();
        self.b.deinit();
        self.a.deinit();
        self.keys.deinit();
    }

    pub fn waitFor(self: *Rig, comptime field: std.meta.FieldEnum(bifrost.Stats), value: u64) !void {
        const saved = self.player.timeout_ms;
        defer self.player.timeout_ms = saved;
        self.player.timeout_ms = 20;
        for (0..500) |_| {
            if (@field(self.stats(), @tagName(field)) >= value) return;
            self.player.pump() catch |err| if (err != error.NoMessage) return err;
        }
        return error.WaitTimedOut;
    }

    pub fn pumpUntil(self: *Rig, context: anytype, comptime check: fn (@TypeOf(context)) bool) !void {
        const saved = self.player.timeout_ms;
        defer self.player.timeout_ms = saved;
        self.player.timeout_ms = 20;
        for (0..500) |_| {
            if (check(context)) return;
            self.player.pump() catch |err| if (err != error.NoMessage) return err;
        }
        return error.WaitTimedOut;
    }

    pub fn transfer(self: *Rig, target: usize) !void {
        try self.running.proxy.requestTransfer(1, .of(target));
    }

    pub fn stats(self: *Rig) bifrost.Stats {
        return self.running.proxy.stats.snapshot();
    }

    pub fn expectOn(self: *Rig, backend: *managed.Backend) !void {
        const before = backend.echoes.load(.acquire);
        try self.player.echo("still here");
        try std.testing.expectEqual(before + 1, backend.echoes.load(.acquire));
    }
};
