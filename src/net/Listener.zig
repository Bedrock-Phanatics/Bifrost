const std = @import("std");
const nethernet = @import("nethernet");
const NetherNet = @import("NetherNet.zig");

/// Answers HTTP signaling and hands every established connection to `sink`.
const Listener = @This();

pub const Sink = struct {
    context: *anyopaque,
    /// Takes ownership of the connection.
    accept: *const fn (*anyopaque, *NetherNet.Connection) void,
};

pub const Status = nethernet.EndpointStatusProvider;
pub const ServerStatus = nethernet.EndpointServerStatus;

pub const Options = struct {
    max_negotiations: u32 = 32,
    max_negotiations_per_ip: u32 = 4,
    status: ?Status = null,
};

io: std.Io,
endpoint: *nethernet.EndpointListener,
sink: Sink,
task: ?std.Io.Future(void) = null,

pub fn start(gpa: std.mem.Allocator, io: std.Io, transport: *NetherNet, address: std.Io.net.IpAddress, sink: Sink, options: Options) !*Listener {
    const self = try gpa.create(Listener);
    errdefer gpa.destroy(self);
    const endpoint = try nethernet.EndpointListener.listen(gpa, io, address, .{
        .connection = transport.serverOptions(),
        .maximum_negotiations = options.max_negotiations,
        .maximum_negotiations_per_address = options.max_negotiations_per_ip,
        .maximum_http_workers = @max(options.max_negotiations, 8),
        .status_provider = options.status,
    });
    errdefer endpoint.destroy();
    self.* = .{ .io = io, .endpoint = endpoint, .sink = sink };
    self.task = try io.concurrent(run, .{self});
    return self;
}

pub fn destroy(self: *Listener, gpa: std.mem.Allocator) void {
    if (self.task) |*task| task.cancel(self.io);
    self.endpoint.destroy();
    gpa.destroy(self);
}

pub fn localAddress(self: *const Listener) std.Io.net.IpAddress {
    return self.endpoint.server.socket.address;
}

fn run(self: *Listener) void {
    while (true) {
        const connection = self.endpoint.accept() catch return;
        self.sink.accept(self.sink.context, connection);
    }
}
