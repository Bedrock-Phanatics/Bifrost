const std = @import("std");
const bedwire = @import("bedwire");
const Rate = @import("../proxy/Rate.zig");

const Observer = @This();
const log = std.log.scoped(.observer);

// Login is the biggest thing we see before encryption
pub const limits: bedwire.Limits = .{
    .max_frame_bytes = 512 * 1024,
    .max_batch_bytes = 2 * 1024 * 1024,
    .max_packet_bytes = 2 * 1024 * 1024,
};

pub const Auth = union(enum) {
    off,
    verify: *const bedwire.auth.KeySet,
};

pub const Context = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    auth: Auth,
    now_ms: u64 = 0,
    logins: ?*Rate = null,
};

pub const Event = enum {
    none,
    encrypted,
    gave_up,
    login_verified,
    login_rejected,
    auth_unavailable,
    login_throttled,
    flooded,

    pub fn rejects(self: Event) bool {
        return switch (self) {
            .login_rejected, .auth_unavailable, .login_throttled, .flooded => true,
            .none, .encrypted, .gave_up, .login_verified => false,
        };
    }
};

tap: bedwire.Tap,
watching: bool = true,
verified: bool = false,
identity: ?bedwire.Identity = null,
inbound: Rate,

pub fn loadKeys(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !bedwire.auth.KeySet {
    const json = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(limits.max_jwks_bytes));
    defer gpa.free(json);
    return bedwire.auth.KeySet.parse(gpa, json, limits);
}

pub fn initPool(gpa: std.mem.Allocator) !bedwire.BufferPool {
    return bedwire.BufferPool.init(gpa, limits, bedwire.PoolConfig.observer());
}

pub fn init(pool: *bedwire.BufferPool, player_bytes_per_second: u32) !Observer {
    return .{ .tap = try bedwire.Tap.init(.{ .pool = pool }), .inbound = .bytes(player_bytes_per_second) };
}

pub fn deinit(self: *Observer) void {
    self.dropIdentity();
    self.tap.deinit();
}

pub fn observe(self: *Observer, ctx: Context, direction: bedwire.TapDirection, payload: []const u8) Event {
    std.debug.assert(self.watching);
    var packets = self.tap.observe(direction, payload) catch |err| return self.giveUp(ctx, err);
    defer packets.deinit();
    if (direction == .client_to_server and !self.inbound.take(ctx.now_ms, packets.reader.bytes.len)) {
        self.watching = false;
        return .flooded;
    }

    var event: Event = .none;
    while (packets.next()) |packet| {
        if (packet.kind == .login and ctx.auth == .verify) event = self.verify(ctx, packet);
    }
    if (event.rejects()) {
        self.watching = false;
        return event;
    }
    if (self.tap.phase() == .encrypted) {
        self.watching = false;
        if (event == .none) event = .encrypted;
    }
    return event;
}

fn verify(self: *Observer, ctx: Context, packet: bedwire.Tap.Packet) Event {
    if (ctx.logins) |logins| if (!logins.take(ctx.now_ms, 1)) return .login_throttled;
    const policy: bedwire.TrustPolicy = .{ .oidc = .{
        .now = std.Io.Clock.real.now(ctx.io).toSeconds(),
        .keys = ctx.auth.verify,
    } };
    const identity = self.tap.authenticateLoginPacket(ctx.gpa, packet, policy) catch |err| {
        if (err == error.OutOfMemory) {
            log.warn("login verification unavailable: {t}", .{err});
            return .auth_unavailable;
        }
        log.info("login rejected: {t}", .{err});
        return .login_rejected;
    };
    self.verified = true;
    log.info("verified {s} (xuid {s})", .{ identity.display_name, identity.xuid });
    self.dropIdentity();
    self.identity = identity;
    return .login_verified;
}

pub fn dropIdentity(self: *Observer) void {
    if (self.identity) |*identity| identity.deinit();
    self.identity = null;
}

fn giveUp(self: *Observer, ctx: Context, err: anyerror) Event {
    self.watching = false;
    if (ctx.auth == .verify and !self.verified) {
        log.info("can't verify login: {t}", .{err});
        return .auth_unavailable;
    }
    log.debug("handshake not followable, relaying opaquely: {t}", .{err});
    return .gave_up;
}
