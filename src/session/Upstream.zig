const std = @import("std");
const raknet = @import("raknet");
const bedwire = @import("bedwire");
const Managed = @import("Managed.zig");
const Stats = @import("../proxy/Stats.zig");

const Upstream = @This();

pub const Phase = enum { connecting, settings, waiting_for_login, handshake, ready };
pub const Progress = enum { wants_login, logged_in };

pub const Context = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    stats: *Stats,
    shared: *Managed.Shared,
    client: *raknet.Client,
};

session: Managed.BackendSession,
phase: Phase = .connecting,

pub fn init(shared: *Managed.Shared) !Upstream {
    return .{ .session = try .init(.client, .{ .pool = &shared.pool }) };
}

pub fn deinit(self: *Upstream) void {
    self.session.deinit();
}

pub fn connected(self: *Upstream, ctx: Context) !void {
    std.debug.assert(self.phase == .connecting);
    var buffer: [16]u8 = undefined;
    try self.send(ctx, &.{try Managed.encodeTyped(&buffer, .{ .request_network_settings = .{
        .client_network_version = @intCast(Managed.BackendProfile.protocol_number),
    } })});
    self.phase = .settings;
}

pub fn login(self: *Upstream, ctx: Context, identity: *const bedwire.Identity, client_data: []const u8) !void {
    std.debug.assert(self.phase == .waiting_for_login);
    const expires = std.Io.Clock.real.now(ctx.io).toSeconds() + Managed.login_lifetime_s;
    const request = try bedwire.auth.login.buildProxyConnectionRequest(Managed.BackendProfile, ctx.gpa, ctx.shared.key, identity, client_data, expires, .envelope, Managed.limits);
    defer ctx.gpa.free(request);
    const storage = try ctx.gpa.alloc(u8, request.len + 32);
    defer ctx.gpa.free(storage);
    try self.send(ctx, &.{try bedwire.auth.login.encodeLoginPacket(Managed.BackendProfile, storage, request, Managed.limits)});
    ctx.stats.bump(.proxy_logins, 1);
    self.phase = .handshake;
}

pub fn receive(self: *Upstream, ctx: Context, packet: Managed.BackendSession.Packet) !Progress {
    if (packet.kind == .disconnect or packet.kind == .play_status) return error.BackendRefused;
    switch (self.phase) {
        .settings => {
            try self.session.negotiateFromSettings(packet);
            self.phase = .waiting_for_login;
            return .wants_login;
        },
        .handshake => {
            try self.session.acceptServerHandshakePacket(ctx.gpa, packet, ctx.shared.key.secret_key);
            var buffer: [8]u8 = undefined;
            try self.send(ctx, &.{try Managed.encodeTyped(&buffer, .{ .client_to_server_handshake = .{} })});
            try self.session.advance(.resource_packs);
            self.phase = .ready;
            return .logged_in;
        },
        .connecting, .waiting_for_login, .ready => return error.UnexpectedPacket,
    }
}

pub fn send(self: *Upstream, ctx: Context, packets: []const []const u8) !void {
    try Managed.send(&self.session, ctx.client, ctx.stats, .bytes_to_backend, packets);
}
