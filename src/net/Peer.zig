const std = @import("std");
const nethernet = @import("nethernet");
const NetherNet = @import("NetherNet.zig");
const Notify = @import("Notify.zig");

/// One end of a link, the player or a backend. Worker only, except for the callback.
const Peer = @This();

// Long enough for a Disconnect to get out, short enough that a dead peer can't hold a slot
pub const drain_timeout_ms = 2_000;

connection: *NetherNet.Connection,
// Never below what the native buffers hold; refreshed only near the mark
buffered_bound: usize = 0,
closing_since_ms: ?u64 = null,
shutting_down: bool = false,

pub fn init(connection: *NetherNet.Connection) Peer {
    return .{ .connection = connection };
}

/// Runs `notify` on native threads whenever there is something to read, it closed, or sends drained.
pub fn watch(self: *Peer, notify: Notify) void {
    self.connection.setCallback(.{ .context = notify.context, .call = notify.call });
}

pub fn destroy(self: *Peer) void {
    self.connection.setCallback(null);
    self.connection.destroy();
}

pub fn open(self: *const Peer) bool {
    return self.closing_since_ms == null and self.connection.state() == .connected;
}

pub fn send(self: *Peer, bytes: []const u8) !void {
    try self.sendAs(bytes, .reliable);
}

pub fn sendAs(self: *Peer, bytes: []const u8, reliability: nethernet.Reliability) !void {
    if (self.closing_since_ms != null) return error.ConnectionClosed;
    self.connection.send(bytes, reliability) catch |err| {
        self.connection.close();
        return err;
    };
    self.buffered_bound +|= bytes.len;
}

/// Borrowed until the next call. Null when nothing is waiting.
pub fn next(self: *Peer) !?NetherNet.Message {
    while (try self.connection.poll()) |event| switch (event) {
        .message => |message| return message,
        .signal => {},
    };
    return null;
}

pub fn backlogged(self: *Peer, mark: usize) bool {
    if (self.buffered_bound < mark) return false;
    self.buffered_bound = self.connection.bufferedAmount() catch return false;
    return self.buffered_bound >= mark;
}

pub fn buffered(self: *Peer) usize {
    self.buffered_bound = self.connection.bufferedAmount() catch 0;
    return self.buffered_bound;
}

/// Lets queued sends drain before closing, see `drained`.
pub fn closeSoon(self: *Peer, now_ms: u64) void {
    if (self.closing_since_ms == null) self.closing_since_ms = now_ms;
}

/// True once the peer can be destroyed. Closing with data still in SCTP would abort and drop it,
/// so this waits for libdatachannel's queue and the far end's acknowledgements, then for the close.
/// Acknowledgements raise no event, so the sweep checks again.
pub fn drained(self: *Peer, now_ms: u64) bool {
    const since = self.closing_since_ms orelse return false;
    if (now_ms -| since < drain_timeout_ms) {
        if (!self.shutting_down) {
            if (self.buffered() != 0 or self.connection.unackedAmount() != 0) return false;
            self.connection.shutdown();
            self.shutting_down = true;
        }
        if (self.connection.state() == .connected) return false;
    }
    self.connection.close();
    return true;
}

pub fn identityKey(self: *const Peer) ?NetherNet.PublicKey {
    return self.connection.public_key;
}

pub fn remoteAddress(self: *const Peer) ?std.Io.net.IpAddress {
    return NetherNet.remoteAddress(self.connection);
}
