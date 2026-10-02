const std = @import("std");
const bedwire = @import("bedwire");

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
};

pub const Event = enum {
    none,
    encrypted,
    gave_up,
    login_verified,
    login_rejected,
    auth_unavailable,

    pub fn rejects(self: Event) bool {
        return self == .login_rejected or self == .auth_unavailable;
    }
};

tap: bedwire.Tap,
watching: bool = true,
verified: bool = false,

pub fn loadKeys(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !bedwire.auth.KeySet {
    const json = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(limits.max_jwks_bytes));
    defer gpa.free(json);
    return bedwire.auth.KeySet.parse(gpa, json, limits);
}

pub fn initPool(gpa: std.mem.Allocator) !bedwire.BufferPool {
    return bedwire.BufferPool.init(gpa, limits, bedwire.PoolConfig.observer());
}

pub fn init(pool: *bedwire.BufferPool) !Observer {
    return .{ .tap = try bedwire.Tap.init(.{ .pool = pool }) };
}

pub fn deinit(self: *Observer) void {
    self.tap.deinit();
}

pub fn observe(self: *Observer, ctx: Context, direction: bedwire.TapDirection, payload: []const u8) Event {
    std.debug.assert(self.watching);
    var packets = self.tap.observe(direction, payload) catch |err| return self.giveUp(ctx, err);
    defer packets.deinit();

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
    const policy: bedwire.TrustPolicy = .{ .oidc = .{
        .now = std.Io.Clock.real.now(ctx.io).toSeconds(),
        .keys = ctx.auth.verify,
    } };
    var identity = self.tap.authenticateLoginPacket(ctx.gpa, packet, policy) catch |err| {
        if (err == error.OutOfMemory) {
            log.warn("login verification unavailable: {t}", .{err});
            return .auth_unavailable;
        }
        log.info("login rejected: {t}", .{err});
        return .login_rejected;
    };
    defer identity.deinit();
    self.verified = true;
    log.info("verified {s} (xuid {s})", .{ identity.display_name, identity.xuid });
    return .login_verified;
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
