const std = @import("std");

const Stats = @This();

sessions_accepted: u64 = 0,
sessions_rejected: u64 = 0,
backends_connected: u64 = 0,
backend_failures: u64 = 0,
links_closed: u64 = 0,
listener_errors: u64 = 0,
bytes_to_backend: u64 = 0,
bytes_to_player: u64 = 0,
handshakes_observed: u64 = 0,
observer_gave_up: u64 = 0,
logins_verified: u64 = 0,
logins_rejected: u64 = 0,
auth_unavailable: u64 = 0,
proxy_logins: u64 = 0,
transfers_started: u64 = 0,
transfers_committed: u64 = 0,
transfers_failed_before_commit: u64 = 0,
transfers_failed_after_commit: u64 = 0,
transfers_timed_out: u64 = 0,
transfers_rejected: u64 = 0,

// Only the worker writes these, so a plain atomic store is enough
pub fn bump(self: *Stats, comptime field: std.meta.FieldEnum(Stats), amount: u64) void {
    const counter = &@field(self, @tagName(field));
    @atomicStore(u64, counter, counter.* +% amount, .monotonic);
}

pub fn snapshot(self: *const Stats) Stats {
    var copy: Stats = .{};
    inline for (@typeInfo(Stats).@"struct".field_names) |name| {
        @field(copy, name) = @atomicLoad(u64, &@field(self, name), .monotonic);
    }
    return copy;
}

pub fn add(self: *Stats, other: Stats) void {
    inline for (@typeInfo(Stats).@"struct".field_names) |name| @field(self, name) += @field(other, name);
}
