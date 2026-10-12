const std = @import("std");
const abi = @import("abi.zig");
const Backend = @import("../backend/Backend.zig");
pub const Library = @import("Library.zig").Library;
pub const Package = @import("Package.zig");
pub const Handles = @import("Handles.zig");
pub const Packets = @import("Packets.zig");
const Pool = @import("Pool.zig");
const Work = @import("Work.zig");
const injection = @import("injection.zig");
const sdk = @import("sdk.zig");
const Notify = @import("../net/Notify.zig");

const Plugins = @This();
const log = std.log.scoped(.plugin);

pub const max_name_len = 64;
pub const max_version_len = 64;
pub const max_command_len = 32;
pub const max_message_bytes = Work.max_message_bytes;

pub const Options = struct {
    workers: u32 = 1,
    packets: bool = true,
    slow_callback_ns: u64 = 5 * std.time.ns_per_ms,
    task_threads: u32 = 4,
    max_tasks: u32 = 128,
    max_tasks_per_plugin: u32 = 32,
    max_messages: u32 = 1024,
    max_injection_bytes: u32 = 4 * 1024 * 1024,
};

pub const Totals = struct {
    calls: u64 = 0,
    total_ns: u64 = 0,
    max_ns: u64 = 0,
    errors: u64 = 0,
    outstanding: u32 = 0,
};

pub const max_description_len = 256;

pub const Metadata = struct {
    name_buffer: [max_name_len]u8 = undefined,
    version_buffer: [max_version_len]u8 = undefined,
    description_buffer: [max_description_len]u8 = undefined,
    name_len: u8 = 0,
    version_len: u8 = 0,
    description_len: u16 = 0,
    package: []const u8 = "",

    pub fn name(self: *const Metadata) []const u8 {
        return self.name_buffer[0..self.name_len];
    }

    pub fn version(self: *const Metadata) []const u8 {
        return self.version_buffer[0..self.version_len];
    }

    pub fn description(self: *const Metadata) []const u8 {
        return self.description_buffer[0..self.description_len];
    }
};

pub const Command = struct {
    callback: abi.CommandFn,
    user: ?*anyopaque,
    loaded: *Loaded,
    permission: abi.CommandPermission = .any,
    description_buffer: [max_description_len]u8 = undefined,
    description_len: u16 = 0,

    pub fn description(self: *const Command) []const u8 {
        return self.description_buffer[0..self.description_len];
    }
};

const PendingCommand = struct {
    name: [max_command_len]u8,
    len: usize,
    command: Command,
};

const Subscriber = struct {
    callback: abi.EventFn,
    user: ?*anyopaque,
};

const Pending = struct {
    kind: abi.EventKind,
    subscriber: Subscriber,
};

const Loaded = struct {
    owner: *Plugins,
    host: abi.Host = undefined,
    plugin: abi.Plugin = .{},
    library: ?Library,
    metadata: Metadata = .{},
    metrics: []Packets.Metrics = &.{},
    outstanding: std.atomic.Value(u32) = .init(0),
    ready: std.atomic.Value(bool) = .init(false),

    fn label(self: *const Loaded) []const u8 {
        return self.metadata.name();
    }
};

gpa: std.mem.Allocator,
backends: []const Backend,
options: Options,
loaded: std.ArrayList(*Loaded) = .empty,
subscribers: [abi.EventKind.count]std.ArrayList(Subscriber) = @splat(.empty),
pending: std.ArrayList(Pending) = .empty,
pending_packets: std.ArrayList(Packets.Registration) = .empty,
registrations: std.ArrayList(Packets.Registration) = .empty,
tables: [2]Packets.Table = .{ .{}, .{} },
initializing: std.atomic.Value(?*Loaded) = .init(null),
handles: Handles = .{},
started: std.atomic.Value(bool) = .init(false),
stopping: std.atomic.Value(bool) = .init(false),
commands: std.StringHashMapUnmanaged(Command) = .empty,
pending_commands: std.ArrayList(PendingCommand) = .empty,
queues: []Work.Queue,
pool: ?*Pool = null,
outstanding: std.atomic.Value(u32) = .init(0),
messages: std.atomic.Value(u32) = .init(0),
injection_bytes: std.atomic.Value(u32) = .init(0),

pub fn init(gpa: std.mem.Allocator, backends: []const Backend, options: Options) !Plugins {
    if (options.task_threads == 0 or options.task_threads > Pool.max_threads) return error.InvalidOptions;
    const queues = try gpa.alloc(Work.Queue, options.workers);
    var ready: usize = 0;
    errdefer {
        for (queues[0..ready]) |*queue| queue.deinit(gpa);
        gpa.free(queues);
    }
    for (queues) |*queue| {
        queue.* = try .init(gpa, options.max_tasks + options.max_messages);
        ready += 1;
    }
    return .{ .gpa = gpa, .backends = backends, .options = options, .queues = queues };
}

pub fn deinit(self: *Plugins) void {
    self.unload();
    for (self.queues) |*queue| queue.deinit(self.gpa);
    self.gpa.free(self.queues);
    self.commands.deinit(self.gpa);
    self.pending_commands.deinit(self.gpa);
    for (&self.subscribers) |*list| list.deinit(self.gpa);
    self.loaded.deinit(self.gpa);
    self.pending.deinit(self.gpa);
    self.pending_packets.deinit(self.gpa);
    self.registrations.deinit(self.gpa);
    self.handles.deinit(self.gpa);
}

pub fn add(self: *Plugins, entry: abi.InitFn, library: ?Library) !void {
    return self.load(entry, library, null);
}

/// Takes ownership of `library` only on success.
pub fn load(self: *Plugins, entry: abi.InitFn, library: ?Library, manifest: ?*const Metadata) !void {
    try self.loaded.ensureUnusedCapacity(self.gpa, 1);
    const loaded = try self.gpa.create(Loaded);
    errdefer self.gpa.destroy(loaded);
    loaded.* = .{ .owner = self, .library = library };
    loaded.host = hostFor(loaded);
    loaded.metrics = try self.gpa.alloc(Packets.Metrics, self.options.workers);
    errdefer self.gpa.free(loaded.metrics);
    @memset(loaded.metrics, .{});
    if (manifest) |expected| loaded.metadata.package = try self.gpa.dupe(u8, expected.package);
    errdefer self.gpa.free(loaded.metadata.package);

    self.pending.clearRetainingCapacity();
    self.pending_packets.clearRetainingCapacity();
    self.pending_commands.clearRetainingCapacity();
    self.initializing.store(loaded, .release);
    const outer = Work.enter();
    const status = entry(&loaded.host, &loaded.plugin);
    Work.hosted = outer;
    self.initializing.store(null, .release);
    if (status != .ok) {
        log.warn("plugin init failed: {t}", .{status});
        return error.PluginInitFailed;
    }
    errdefer shutdown(loaded);

    const plugin = &loaded.plugin;
    if (plugin.abi_version != abi.version or plugin.struct_size < @sizeOf(abi.Plugin)) {
        log.warn("plugin targets ABI {d}, Bifrost has {d}", .{ plugin.abi_version, abi.version });
        return error.IncompatiblePlugin;
    }
    const meta = &loaded.metadata;
    const plugin_name = required(plugin.name, max_name_len) orelse {
        log.warn("plugin refused: its name must be 1 to {d} bytes of printable UTF-8", .{max_name_len});
        return error.InvalidMetadata;
    };
    const version = required(plugin.plugin_version, max_version_len) orelse {
        log.warn("plugin {s} refused: its version must be 1 to {d} bytes of printable UTF-8", .{ plugin_name, max_version_len });
        return error.InvalidMetadata;
    };
    if (manifest) |expected| {
        if (!std.mem.eql(u8, plugin_name, expected.name()) or !std.mem.eql(u8, version, expected.version())) {
            log.warn("plugin {s} {s} refused: plugin.toml says {s} {s}", .{ plugin_name, version, expected.name(), expected.version() });
            return error.MetadataMismatch;
        }
    }
    if (self.isLoaded(plugin_name)) {
        log.warn("plugin {s} refused: a plugin with that name is already loaded", .{plugin_name});
        return error.DuplicatePlugin;
    }
    @memcpy(meta.name_buffer[0..plugin_name.len], plugin_name);
    meta.name_len = @intCast(plugin_name.len);
    @memcpy(meta.version_buffer[0..version.len], version);
    meta.version_len = @intCast(version.len);
    if (manifest) |expected| {
        meta.description_buffer = expected.description_buffer;
        meta.description_len = expected.description_len;
    }
    const unsupported = @as(u64, @bitCast(plugin.capabilities)) & ~@as(u64, @bitCast(abi.Capabilities.supported));
    if (unsupported != 0) {
        log.warn("plugin {s} needs unsupported capabilities 0x{x}", .{ loaded.label(), unsupported });
        return error.UnsupportedCapability;
    }
    const caps = plugin.capabilities;
    const undeclared: ?[]const u8 = if (self.pending.items.len != 0 and !caps.events)
        "EVENTS"
    else if (self.pending_packets.items.len != 0 and !caps.packets)
        "PACKETS"
    else if (self.pending_commands.items.len != 0 and !caps.commands)
        "COMMANDS"
    else
        null;
    if (undeclared) |capability| {
        log.warn("plugin {s} registered hooks without declaring {s}", .{ loaded.label(), capability });
        return error.UndeclaredCapability;
    }

    if (plugin.capabilities.tasks and self.pool == null) try self.startPool();
    for (self.pending.items) |item| try self.subscribers[@backingInt(item.kind)].ensureUnusedCapacity(self.gpa, countKind(self.pending.items, item.kind));
    try self.commands.ensureUnusedCapacity(self.gpa, @intCast(self.pending_commands.items.len));
    const names = try self.gpa.alloc([]u8, self.pending_commands.items.len);
    defer self.gpa.free(names);
    var named: usize = 0;
    errdefer for (names[0..named]) |name| self.gpa.free(name);
    for (self.pending_commands.items, names) |*item, *name| {
        name.* = try self.gpa.dupe(u8, item.name[0..item.len]);
        named += 1;
    }
    if (self.pending_packets.items.len != 0) try self.addPacketHooks(loaded);
    for (self.pending_commands.items, names) |item, name| self.commands.putAssumeCapacityNoClobber(name, item.command);
    for (self.pending.items) |item| self.subscribers[@backingInt(item.kind)].appendAssumeCapacity(item.subscriber);
    self.loaded.appendAssumeCapacity(loaded);
    loaded.ready.store(true, .release);
    if (meta.package.len != 0) {
        log.info("loaded plugin {s} {s} from {s}: {s}", .{ meta.name(), meta.version(), meta.package, meta.description() });
    } else if (meta.description_len == 0) {
        log.info("loaded plugin {s} {s}", .{ meta.name(), meta.version() });
    } else {
        log.info("loaded plugin {s} {s}: {s}", .{ meta.name(), meta.version(), meta.description() });
    }
}

pub fn metadata(self: *const Plugins, index: usize) *const Metadata {
    return &self.loaded.items[index].metadata;
}

pub fn isLoaded(self: *const Plugins, name: []const u8) bool {
    for (self.loaded.items) |other| if (std.ascii.eqlIgnoreCase(other.label(), name)) return true;
    return false;
}

pub fn unload(self: *Plugins) void {
    self.stopping.store(true, .release);
    const outer = Work.enter();
    defer Work.hosted = outer;
    if (self.pool) |pool| {
        pool.stop();
        while (pool.take()) |task| self.finish(task, .canceled, null);
        pool.destroy();
        self.pool = null;
    }
    for (self.queues) |*queue| {
        queue.close();
        for (queue.take()) |item| self.settle(item, null, null);
    }
    var names = self.commands.keyIterator();
    while (names.next()) |name| self.gpa.free(name.*);
    self.commands.clearRetainingCapacity();
    for (&self.subscribers) |*list| list.clearRetainingCapacity();
    for (&self.tables) |*table| table.deinit(self.gpa);
    self.registrations.clearRetainingCapacity();
    while (self.loaded.pop()) |loaded| {
        shutdown(loaded);
        if (loaded.library) |*library| library.close();
        self.gpa.free(loaded.metadata.package);
        self.gpa.free(loaded.metrics);
        self.gpa.destroy(loaded);
    }
}

pub fn attachWorker(self: *Plugins, worker: u32, notify: Notify) void {
    self.queues[worker].notify = notify;
}

pub fn drain(self: *Plugins, worker: u32, io: std.Io, sink: anytype) void {
    const outer = Work.enter();
    defer Work.hosted = outer;
    for (self.queues[worker].take()) |item| self.settle(item, .{ .worker = worker, .io = io }, sink);
}

pub fn hasCommands(self: *const Plugins) bool {
    return self.commands.count() != 0;
}

pub fn runCommand(self: *const Plugins, worker: u32, io: std.Io, player: abi.Player, line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " ");
    const text = if (std.mem.startsWith(u8, trimmed, "/")) trimmed[1..] else trimmed;
    const end = std.mem.indexOfScalar(u8, text, ' ') orelse text.len;
    if (end == 0 or end > max_command_len) return false;
    var name: [max_command_len]u8 = undefined;
    const lower = std.ascii.lowerString(&name, text[0..end]);
    const command = self.commands.get(lower) orelse return false;
    const request: abi.Command = .{
        .worker = worker,
        .player = player,
        .name = .of(lower),
        .args = .of(std.mem.trim(u8, text[end..], " ")),
    };
    const started = Packets.now(io);
    const outer = Work.enter();
    command.callback(command.user, &request);
    Work.hosted = outer;
    self.timed(command.loaded, worker, io, started, "on command {s}", .{lower});
    return true;
}

const Owner = struct {
    worker: u32,
    io: std.Io,
};

fn settle(self: *Plugins, item: Work.Item, owner: ?Owner, sink: anytype) void {
    switch (item) {
        .message => |message| {
            defer {
                self.gpa.destroy(message);
                Work.release(&self.messages);
            }
            if (@TypeOf(sink) == @TypeOf(null)) return;
            const route = self.handles.route(message.player) orelse return;
            sink.message(route.link, message.text[0..message.len]);
        },
        .task => |task| self.finish(task, self.liveStatus(task.then.player, owner), owner),
        .packet => |packet| {
            defer {
                const length: u32 = @intCast(packet.len);
                packet.destroy(self.gpa);
                _ = self.injection_bytes.fetchSub(length, .acq_rel);
                Work.release(&self.messages);
            }
            const status = self.deliverPacket(packet, owner, sink);
            if (packet.then) |*then| self.complete(then, status, owner);
        },
        .post => |post| {
            defer {
                self.gpa.destroy(post);
                Work.release(&self.messages);
            }
            self.complete(post, self.liveStatus(post.player, owner), owner);
        },
    }
}

fn deliverPacket(self: *Plugins, packet: *Work.Injection, owner: ?Owner, sink: anytype) abi.Status {
    if (self.stopping.load(.acquire) or owner == null) return .canceled;
    const route = self.handles.route(packet.player) orelse return .stale_handle;
    if (route.worker != owner.?.worker or route.epoch != packet.epoch) return .canceled;
    if (@TypeOf(sink) == @TypeOf(null)) return .unsupported;
    return sink.packet(route.link, packet.target, packet.bytes());
}

fn liveStatus(self: *Plugins, player: abi.Player, owner: ?Owner) abi.Status {
    return if (owner != null and self.handles.route(player) != null) .ok else .stale_handle;
}

fn complete(self: *Plugins, then: *const Work.Done, status: abi.Status, owner: ?Owner) void {
    const result: abi.TaskResult = .{ .status = status, .worker = if (owner) |at| at.worker else abi.no_worker, .player = then.player };
    const started = if (owner) |at| Packets.now(at.io) else 0;
    then.done(then.user, &result);
    if (owner) |at| {
        const elapsed = Packets.now(at.io) -| started;
        then.metrics[at.worker].timed(elapsed);
        if (elapsed >= self.options.slow_callback_ns) Packets.warnSlow(&then.metrics[at.worker], then.name, elapsed, at.io, "finishing a task", .{});
    }
}

fn finish(self: *Plugins, task: *Work.Task, status: abi.Status, owner: ?Owner) void {
    self.complete(&task.then, status, owner);
    Work.release(task.outstanding);
    Work.release(&self.outstanding);
    self.gpa.destroy(task);
}

fn timed(self: *const Plugins, loaded: *Loaded, worker: u32, io: std.Io, started: u64, comptime what: []const u8, args: anytype) void {
    const elapsed = Packets.now(io) -| started;
    const metrics = &loaded.metrics[worker];
    metrics.timed(elapsed);
    if (elapsed >= self.options.slow_callback_ns) Packets.warnSlow(metrics, loaded.label(), elapsed, io, what, args);
}

fn startPool(self: *Plugins) !void {
    self.pool = try .create(self.gpa, self.options.task_threads, self.options.max_tasks, self, runTask);
}

fn runTask(context: *anyopaque, task: *Work.Task) void {
    const self: *Plugins = @ptrCast(@alignCast(context));
    task.run(task.then.user);
    if (self.handles.route(task.then.player)) |route| {
        if (route.worker < self.queues.len and self.queues[route.worker].post(.{ .task = task })) return;
    }
    self.finish(task, if (task.then.player.id == 0) .ok else .stale_handle, null);
}

pub fn packetTable(self: *const Plugins, direction: abi.Direction) ?*const Packets.Table {
    const table = &self.tables[@backingInt(direction)];
    return if (table.subscribers.len == 0) null else table;
}

pub fn totals(self: *const Plugins, index: usize) Totals {
    var sum: Totals = .{};
    for (self.loaded.items[index].metrics) |*metrics| {
        sum.calls += metrics.calls.load(.monotonic);
        sum.total_ns += metrics.total_ns.load(.monotonic);
        sum.max_ns = @max(sum.max_ns, metrics.max_ns.load(.monotonic));
        sum.errors += metrics.errors.load(.monotonic);
    }
    sum.outstanding = self.loaded.items[index].outstanding.load(.acquire);
    return sum;
}

// Tables only change while plugins load, before any worker reads them
fn addPacketHooks(self: *Plugins, loaded: *Loaded) !void {
    const before = self.registrations.items.len;
    errdefer self.registrations.shrinkRetainingCapacity(before);
    for (self.pending_packets.items) |*item| {
        item.subscriber.name = loaded.label();
        item.subscriber.metrics = loaded.metrics;
        item.subscriber.context = loaded;
    }
    try self.registrations.appendSlice(self.gpa, self.pending_packets.items);
    var tables: [2]Packets.Table = undefined;
    tables[0] = try .build(self.gpa, .from_player, self.registrations.items);
    errdefer tables[0].deinit(self.gpa);
    tables[1] = try .build(self.gpa, .from_backend, self.registrations.items);
    for (&self.tables) |*table| table.deinit(self.gpa);
    self.tables = tables;
}

pub fn emit(self: *const Plugins, event: *const abi.Event, decision: ?*abi.TransferDecision) void {
    const outer = Work.enter();
    defer Work.hosted = outer;
    for (self.subscribers[@backingInt(event.kind)].items) |subscriber| subscriber.callback(subscriber.user, event, decision);
}

pub fn subscribed(self: *const Plugins, kind: abi.EventKind) bool {
    return self.subscribers[@backingInt(kind)].items.len != 0;
}

fn countKind(items: []const Pending, kind: abi.EventKind) usize {
    var count: usize = 0;
    for (items) |item| count += @intFromBool(item.kind == kind);
    return count;
}

fn input(str: abi.Str, max: usize) ?[]const u8 {
    if (str.len > max or (str.ptr == null and str.len != 0)) return null;
    return str.slice();
}

pub fn printable(bytes: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(bytes)) return false;
    for (bytes) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

fn required(str: abi.Str, max: usize) ?[]const u8 {
    const bytes = input(str, max) orelse return null;
    return if (bytes.len != 0 and printable(bytes)) bytes else null;
}

fn shutdown(loaded: *Loaded) void {
    if (loaded.plugin.shutdown) |stop| stop(loaded.plugin.state);
}

fn hostFor(loaded: *Loaded) abi.Host {
    return .{
        .context = loaded,
        .log = hostLog,
        .subscribe = hostSubscribe,
        .backend_count = hostBackendCount,
        .backend_name = hostBackendName,
        .player_name = hostPlayerName,
        .transfer = hostTransfer,
        .worker_count = hostWorkerCount,
        .subscribe_packet = hostSubscribePacket,
        .register_command = hostRegisterCommand,
        .spawn_task = hostSpawnTask,
        .send_message = hostSendMessage,
        .post = hostPost,
        .register_command_info = hostRegisterCommandInfo,
        .set_description = hostSetDescription,
        .decode_packet = Packets.decodePacket,
        .encode_packet = Packets.encodePacket,
        .send_packet = hostSendPacket,
    };
}

fn from(context: *anyopaque) *Loaded {
    return @ptrCast(@alignCast(context));
}

fn hostLog(context: *anyopaque, level: abi.LogLevel, message: abi.Str) callconv(.c) void {
    const loaded = from(context);
    const text = message.slice();
    switch (level) {
        .err => log.err("{s}: {s}", .{ loaded.label(), text }),
        .warn => log.warn("{s}: {s}", .{ loaded.label(), text }),
        .info => log.info("{s}: {s}", .{ loaded.label(), text }),
        else => log.debug("{s}: {s}", .{ loaded.label(), text }),
    }
}

fn hostSubscribe(context: *anyopaque, kind: abi.EventKind, callback: ?abi.EventFn, user: ?*anyopaque) callconv(.c) abi.Status {
    const loaded = from(context);
    const owner = loaded.owner;
    if (!Work.hosted) return .wrong_thread;
    if (owner.initializing.load(.acquire) != loaded) return .too_late;
    if (@backingInt(kind) >= abi.EventKind.count) return .invalid_argument;
    const subscriber: Subscriber = .{ .callback = callback orelse return .invalid_argument, .user = user };
    for (owner.pending.items) |item| if (item.kind == kind and std.meta.eql(item.subscriber, subscriber)) return .invalid_argument;
    owner.pending.append(owner.gpa, .{ .kind = kind, .subscriber = subscriber }) catch return .failed;
    return .ok;
}

fn hostSetDescription(context: *anyopaque, description: abi.Str) callconv(.c) abi.Status {
    const loaded = from(context);
    if (!Work.hosted) return .wrong_thread;
    if (loaded.owner.initializing.load(.acquire) != loaded) return .too_late;
    const bytes = input(description, max_description_len) orelse return .invalid_argument;
    if (!printable(bytes)) return .invalid_argument;
    @memcpy(loaded.metadata.description_buffer[0..bytes.len], bytes);
    loaded.metadata.description_len = @intCast(bytes.len);
    return .ok;
}

fn hostSubscribePacket(context: *anyopaque, direction: abi.Direction, id: u32, phase: abi.PacketPhase, flags: abi.PacketFlags, callback: ?abi.PacketFn, user: ?*anyopaque) callconv(.c) abi.Status {
    const loaded = from(context);
    const owner = loaded.owner;
    if (!Work.hosted) return .wrong_thread;
    if (owner.initializing.load(.acquire) != loaded) return .too_late;
    if (!owner.options.packets) return .unsupported;
    if (@backingInt(direction) > 1 or id >= Packets.id_count or @backingInt(phase) > 2) return .invalid_argument;
    if (@as(u32, @bitCast(flags)) & ~@as(u32, @bitCast(abi.PacketFlags.supported)) != 0) return .invalid_argument;
    const packet_callback = callback orelse return .invalid_argument;
    for (owner.pending_packets.items) |item| {
        if (item.direction == direction and item.id == id and item.subscriber.callback == packet_callback and item.subscriber.user == user) return .invalid_argument;
    }
    owner.pending_packets.append(owner.gpa, .{ .direction = direction, .id = @intCast(id), .subscriber = .{
        .callback = packet_callback,
        .user = user,
        .phase = phase,
        .validated = flags.validated,
        .fields = flags.fields,
        .name = "",
        .metrics = &.{},
    } }) catch return .failed;
    return .ok;
}

fn hostRegisterCommand(context: *anyopaque, name: abi.Str, callback: ?abi.CommandFn, user: ?*anyopaque) callconv(.c) abi.Status {
    return registerCommand(from(context), &.{ .name = name, .callback = callback, .user = user });
}

fn hostRegisterCommandInfo(context: *anyopaque, info: ?*const abi.CommandInfo) callconv(.c) abi.Status {
    const command = info orelse return .invalid_argument;
    if (command.struct_size < @sizeOf(abi.CommandInfo)) return .invalid_argument;
    return registerCommand(from(context), command);
}

fn registerCommand(loaded: *Loaded, info: *const abi.CommandInfo) abi.Status {
    const owner = loaded.owner;
    if (!Work.hosted) return .wrong_thread;
    if (owner.initializing.load(.acquire) != loaded) return .too_late;
    if (!owner.options.packets) return .unsupported;
    const text = input(info.name, max_command_len) orelse return .invalid_argument;
    const description = input(info.description, max_description_len) orelse return .invalid_argument;
    if (text.len == 0 or !std.unicode.utf8ValidateSlice(description)) return .invalid_argument;
    if (@backingInt(info.permission) > @backingInt(abi.CommandPermission.owner)) return .invalid_argument;
    var item: PendingCommand = .{ .name = undefined, .len = text.len, .command = .{
        .callback = info.callback orelse return .invalid_argument,
        .user = info.user,
        .loaded = loaded,
        .permission = info.permission,
        .description_len = @intCast(description.len),
    } };
    @memcpy(item.command.description_buffer[0..description.len], description);
    for (text, item.name[0..text.len]) |char, *out| {
        if (!std.ascii.isAlphanumeric(char) and char != '_' and char != '-') return .invalid_argument;
        out.* = std.ascii.toLower(char);
    }
    const lower = item.name[0..text.len];
    if (owner.commands.contains(lower)) return .invalid_argument;
    for (owner.pending_commands.items) |*other| if (std.mem.eql(u8, other.name[0..other.len], lower)) return .invalid_argument;
    owner.pending_commands.append(owner.gpa, item) catch return .failed;
    return .ok;
}

fn hostSpawnTask(context: *anyopaque, player: abi.Player, run: ?abi.TaskFn, done: ?abi.TaskDoneFn, user: ?*anyopaque) callconv(.c) abi.Status {
    const loaded = from(context);
    const owner = loaded.owner;
    if (!Work.hosted) return .wrong_thread;
    if (!loaded.plugin.capabilities.tasks or owner.initializing.load(.acquire) == loaded) return .unsupported;
    const pool = owner.pool orelse return .unsupported;
    const run_fn = run orelse return .invalid_argument;
    const done_fn = done orelse return .invalid_argument;
    if (!Work.reserve(&owner.outstanding, owner.options.max_tasks)) return .busy;
    if (!Work.reserve(&loaded.outstanding, owner.options.max_tasks_per_plugin)) {
        Work.release(&owner.outstanding);
        return .busy;
    }
    const task = owner.gpa.create(Work.Task) catch {
        Work.release(&loaded.outstanding);
        Work.release(&owner.outstanding);
        return .failed;
    };
    task.* = .{
        .run = run_fn,
        .outstanding = &loaded.outstanding,
        .then = .{ .done = done_fn, .user = user, .player = player, .name = loaded.label(), .metrics = loaded.metrics },
    };
    if (pool.submit(task)) return .ok;
    Work.release(&loaded.outstanding);
    Work.release(&owner.outstanding);
    owner.gpa.destroy(task);
    return .busy;
}

fn hostSendMessage(context: *anyopaque, player: abi.Player, text: abi.Str) callconv(.c) abi.Status {
    const owner = from(context).owner;
    if (!owner.options.packets) return .unsupported;
    const bytes = text.slice();
    if (bytes.len == 0 or bytes.len > Work.max_message_bytes or !std.unicode.utf8ValidateSlice(bytes)) return .invalid_argument;
    const route = owner.handles.route(player) orelse return .stale_handle;
    if (route.worker >= owner.queues.len) return .invalid_argument;
    if (!Work.reserve(&owner.messages, owner.options.max_messages)) return .busy;
    const message = owner.gpa.create(Work.Message) catch {
        Work.release(&owner.messages);
        return .failed;
    };
    message.* = .{ .player = player, .len = bytes.len, .text = undefined };
    @memcpy(message.text[0..bytes.len], bytes);
    if (owner.queues[route.worker].post(.{ .message = message })) return .ok;
    owner.gpa.destroy(message);
    Work.release(&owner.messages);
    return .unsupported;
}

fn hostPost(context: *anyopaque, player: abi.Player, callback: ?abi.TaskDoneFn, user: ?*anyopaque) callconv(.c) abi.Status {
    const loaded = from(context);
    const owner = loaded.owner;
    const done = callback orelse return .invalid_argument;
    if (owner.initializing.load(.acquire) == loaded) return .unsupported;
    const route = owner.handles.route(player) orelse return .stale_handle;
    if (route.worker >= owner.queues.len) return .invalid_argument;
    if (!Work.reserve(&owner.messages, owner.options.max_messages)) return .busy;
    const post = owner.gpa.create(Work.Done) catch {
        Work.release(&owner.messages);
        return .failed;
    };
    post.* = .{ .done = done, .user = user, .player = player, .name = loaded.label(), .metrics = loaded.metrics };
    if (owner.queues[route.worker].post(.{ .post = post })) return .ok;
    owner.gpa.destroy(post);
    Work.release(&owner.messages);
    return .unsupported;
}

fn hostSendPacket(context: *anyopaque, player: abi.Player, target: abi.PacketTarget, bytes: abi.Str, callback: ?abi.TaskDoneFn, user: ?*anyopaque) callconv(.c) abi.Status {
    const loaded = from(context);
    const owner = loaded.owner;
    if (!owner.options.packets or !loaded.ready.load(.acquire)) return .unsupported;
    if (!loaded.plugin.capabilities.packets) return .unsupported;
    if (owner.stopping.load(.acquire)) return .canceled;
    if (bytes.ptr == null or bytes.len == 0 or bytes.len > injection.max_packet_bytes) return .invalid_argument;
    const status = injection.validate(target, bytes.slice());
    if (status != .ok) return status;
    const route = owner.handles.route(player) orelse return .stale_handle;
    if (route.worker >= owner.queues.len) return .invalid_argument;
    if (!Work.reserve(&owner.messages, owner.options.max_messages)) return .busy;
    const length: u32 = @intCast(bytes.len);
    if (!Work.reserveBytes(&owner.injection_bytes, owner.options.max_injection_bytes, length)) {
        Work.release(&owner.messages);
        return .busy;
    }
    const then: ?Work.Done = if (callback) |done| .{ .done = done, .user = user, .player = player, .name = loaded.label(), .metrics = loaded.metrics } else null;
    const packet = Work.Injection.create(owner.gpa, player, target, route.epoch, bytes.slice(), then) catch {
        _ = owner.injection_bytes.fetchSub(length, .acq_rel);
        Work.release(&owner.messages);
        return .failed;
    };
    if (owner.queues[route.worker].post(.{ .packet = packet })) return .ok;
    packet.destroy(owner.gpa);
    _ = owner.injection_bytes.fetchSub(length, .acq_rel);
    Work.release(&owner.messages);
    return .canceled;
}

fn hostWorkerCount(context: *anyopaque) callconv(.c) u32 {
    return from(context).owner.options.workers;
}

fn hostBackendCount(context: *anyopaque) callconv(.c) u32 {
    return @intCast(from(context).owner.backends.len);
}

fn hostBackendName(context: *anyopaque, backend: u32, name: ?*abi.Str) callconv(.c) abi.Status {
    const backends = from(context).owner.backends;
    if (backend >= backends.len) return .invalid_argument;
    (name orelse return .invalid_argument).* = .of(backends[backend].name());
    return .ok;
}

fn hostPlayerName(context: *anyopaque, player: abi.Player, out: ?[*]u8, capacity: usize, len: ?*usize) callconv(.c) abi.Status {
    const full_len = len orelse return .invalid_argument;
    const buffer: []u8 = if (capacity == 0) &.{} else (out orelse return .invalid_argument)[0..capacity];
    full_len.* = from(context).owner.handles.copyName(player, buffer) orelse return .stale_handle;
    return .ok;
}

fn hostTransfer(context: *anyopaque, player: abi.Player, backend: u32) callconv(.c) abi.Status {
    const owner = from(context).owner;
    if (!Work.hosted) return .wrong_thread;
    if (backend >= owner.backends.len) return .invalid_argument;
    const route = owner.handles.route(player) orelse return .stale_handle;
    return route.transfer(route.context, route.link, backend);
}

const testing = std.testing;

const Probe = struct {
    var shutdowns: [32]u8 = undefined;
    var shutdown_count: usize = 0;
    var events: usize = 0;
    var seen_host: ?abi.Host = null;

    fn reset() void {
        shutdown_count = 0;
        events = 0;
        seen_host = null;
    }

    fn onEvent(_: ?*anyopaque, _: *const abi.Event, _: ?*abi.TransferDecision) callconv(.c) void {
        events += 1;
    }

    fn onShutdown(state: ?*anyopaque) callconv(.c) void {
        shutdowns[shutdown_count] = @intCast(@intFromPtr(state));
        shutdown_count += 1;
    }

    const names = blk: {
        var list: [16][]const u8 = undefined;
        for (&list, 0..) |*name, i| name.* = std.fmt.comptimePrint("probe{d}", .{i});
        break :blk list;
    };

    fn describe(plugin: *abi.Plugin, id: usize) void {
        plugin.name = .of(names[id]);
        plugin.plugin_version = .of("1.0.0");
        plugin.capabilities = .{ .events = true };
        plugin.state = @ptrFromInt(id);
        plugin.shutdown = onShutdown;
    }

    fn first(host: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
        describe(plugin, 1);
        seen_host = host.*;
        return host.subscribe(host.context, .player_connected, onEvent, null);
    }

    fn doubled(host: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
        describe(plugin, 6);
        plugin.capabilities = .{ .events = true, .packets = true, .commands = true };
        seen_host = host.*;
        if (host.subscribe(host.context, .player_connected, onEvent, null) != .ok) return .failed;
        if (host.subscribe(host.context, .player_connected, onEvent, null) != .invalid_argument) return .failed;
        if (host.subscribe_packet(host.context, .from_player, 7, .any, .{}, onPacket, null) != .ok) return .failed;
        if (host.subscribe_packet(host.context, .from_player, 7, .in_game, .{}, onPacket, null) != .invalid_argument) return .failed;
        if (host.register_command(host.context, .of("probe"), onCommand, null) != .ok) return .failed;
        return .ok;
    }

    fn described(host: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
        describe(plugin, 7);
        plugin.capabilities = .{ .commands = true };
        const long: [max_description_len + 1]u8 = @splat('a');
        const refused = [_]abi.CommandInfo{
            .{ .name = .of("long"), .description = .of(&long), .callback = onCommand },
            .{ .name = .of("bytes"), .description = .of("\xff"), .callback = onCommand },
            .{ .name = .of("rank"), .permission = @fromBackingInt(@intCast(5)), .callback = onCommand },
            .{ .struct_size = 8, .name = .of("old"), .callback = onCommand },
            .{ .name = .of("nobody"), .callback = null },
        };
        for (&refused) |*info| if (host.register_command_info(host.context, info) != .invalid_argument) return .failed;
        if (host.register_command_info(host.context, null) != .invalid_argument) return .failed;
        const warp: abi.CommandInfo = .{ .name = .of("Warp"), .description = .of("Go places"), .permission = .owner, .callback = onCommand };
        return host.register_command_info(host.context, &warp);
    }

    fn onPacket(_: ?*anyopaque, _: *abi.Packet) callconv(.c) abi.PacketAction {
        return .pass;
    }

    fn onCommand(_: ?*anyopaque, _: *const abi.Command) callconv(.c) void {
        events += 1;
    }

    fn second(host: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
        describe(plugin, 2);
        return host.subscribe(host.context, .player_connected, onEvent, null);
    }

    fn failing(host: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
        describe(plugin, 3);
        _ = host.subscribe(host.context, .player_connected, onEvent, null);
        return .failed;
    }

    fn future(host: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
        describe(plugin, 4);
        plugin.abi_version = abi.version + 1;
        return host.subscribe(host.context, .player_connected, onEvent, null);
    }

    fn greedy(host: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
        describe(plugin, 5);
        plugin.capabilities = @bitCast(@as(u64, 1) << 40);
        return host.subscribe(host.context, .player_connected, onEvent, null);
    }
};

const Meta = struct {
    var name: abi.Str = .{};
    var version: abi.Str = .{};
    var description: abi.Str = .{};
    var described: abi.Status = .ok;

    fn init(host: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
        Probe.describe(plugin, 8);
        Probe.seen_host = host.*;
        plugin.name = name;
        plugin.plugin_version = version;
        described = host.set_description(host.context, description);
        return host.subscribe(host.context, .player_connected, Probe.onEvent, null);
    }
};

fn routedTransfer(context: *anyopaque, link: u64, backend: u32) abi.Status {
    const seen: *[2]u64 = @ptrCast(@alignCast(context));
    seen.* = .{ link, backend };
    return .ok;
}

test "plugins that fail or don't fit are turned away without leaving hooks behind" {
    Probe.reset();
    var plugins: Plugins = try .init(testing.allocator, &.{}, .{});
    defer plugins.deinit();

    try testing.expectError(error.PluginInitFailed, plugins.add(Probe.failing, null));
    try testing.expectError(error.IncompatiblePlugin, plugins.add(Probe.future, null));
    try testing.expectError(error.UnsupportedCapability, plugins.add(Probe.greedy, null));
    try testing.expectEqualSlices(u8, &.{ 4, 5 }, Probe.shutdowns[0..Probe.shutdown_count]);
    try testing.expect(!plugins.subscribed(.player_connected));
    plugins.emit(&.{ .kind = .player_connected }, null);
    try testing.expectEqual(@as(usize, 0), Probe.events);
}

test "plugins get events, can't subscribe late and shut down newest first" {
    Probe.reset();
    var plugins: Plugins = try .init(testing.allocator, &.{}, .{});
    try plugins.add(Probe.first, null);
    try plugins.add(Probe.second, null);
    plugins.emit(&.{ .kind = .player_connected }, null);
    plugins.emit(&.{ .kind = .proxy_started }, null);
    try testing.expectEqual(@as(usize, 2), Probe.events);

    const host = Probe.seen_host.?;
    try testing.expectEqual(abi.Status.wrong_thread, host.subscribe(host.context, .proxy_started, Probe.onEvent, null));
    Work.hosted = true;
    defer Work.hosted = false;
    try testing.expectEqual(abi.Status.too_late, host.subscribe(host.context, .proxy_started, Probe.onEvent, null));
    plugins.deinit();
    try testing.expectEqualSlices(u8, &.{ 2, 1 }, Probe.shutdowns[0..Probe.shutdown_count]);
}

test "host calls check handles and backends" {
    Probe.reset();
    Work.hosted = true;
    defer Work.hosted = false;
    const backends = [_]Backend{try .init("lobby", .{ .ip4 = .loopback(19133) })};
    var plugins: Plugins = try .init(testing.allocator, &backends, .{});
    defer plugins.deinit();
    try plugins.add(Probe.first, null);
    const host = Probe.seen_host.?;

    var seen: [2]u64 = .{ 0, 0 };
    const player = try plugins.handles.acquire(testing.allocator, .{ .context = &seen, .link = 7, .transfer = routedTransfer });
    plugins.handles.setName(player, "Steve");
    try testing.expectEqual(abi.Status.ok, host.transfer(host.context, player, 0));
    try testing.expectEqual([2]u64{ 7, 0 }, seen);
    try testing.expectEqual(abi.Status.invalid_argument, host.transfer(host.context, player, 1));

    var name: [16]u8 = undefined;
    var len: usize = 0;
    try testing.expectEqual(abi.Status.ok, host.player_name(host.context, player, &name, name.len, &len));
    try testing.expectEqualStrings("Steve", name[0..len]);
    var backend_name: abi.Str = .{};
    try testing.expectEqual(abi.Status.ok, host.backend_name(host.context, 0, &backend_name));
    try testing.expectEqualStrings("lobby", backend_name.slice());

    plugins.handles.release(player);
    try testing.expectEqual(abi.Status.stale_handle, host.transfer(host.context, player, 0));
    try testing.expectEqual(abi.Status.stale_handle, host.player_name(host.context, player, &name, name.len, &len));
}

test "commands keep their description and permission, and bad ones are refused" {
    Probe.reset();
    var plugins: Plugins = try .init(testing.allocator, &.{}, .{});
    defer plugins.deinit();
    try plugins.add(Probe.described, null);
    try testing.expectEqual(@as(usize, 1), plugins.commands.count());
    const warp = plugins.commands.getPtr("warp").?;
    try testing.expectEqualStrings("Go places", warp.description());
    try testing.expectEqual(abi.CommandPermission.owner, warp.permission);
}

test "duplicate subscriptions are refused and random host input only gets a status back" {
    Probe.reset();
    Work.hosted = true;
    defer Work.hosted = false;
    const backends = [_]Backend{try .init("lobby", .{ .ip4 = .loopback(19133) })};
    var plugins: Plugins = try .init(testing.allocator, &backends, .{});
    defer plugins.deinit();
    try plugins.add(Probe.doubled, null);
    const host = Probe.seen_host.?;
    try testing.expectEqual(@as(usize, 1), plugins.subscribers[@backingInt(abi.EventKind.player_connected)].items.len);

    var prng: std.Random.DefaultPrng = .init(0xab1);
    var line: [48]u8 = undefined;
    var name: [8]u8 = undefined;
    var name_len: usize = 0;
    for (0..20_000) |_| {
        const random = prng.random();
        const text = line[0..random.uintAtMost(usize, line.len)];
        for (text) |*char| char.* = "/ probePROBE\x00\xff"[random.uintLessThan(usize, 14)];
        _ = plugins.runCommand(0, testing.io, .{ .id = random.int(u64) }, text);
        const player: abi.Player = .{ .id = random.int(u64) };
        try testing.expectEqual(abi.Status.stale_handle, host.player_name(host.context, player, &name, name.len, &name_len));
        const status = host.transfer(host.context, player, random.int(u32));
        try testing.expect(status == .stale_handle or status == .invalid_argument);
        try testing.expect(host.send_message(host.context, player, .of(text)) != .ok);
        try testing.expect(host.post(host.context, player, Delivery.done, null) != .ok);
        try testing.expectEqual(abi.Status.unsupported, host.spawn_task(host.context, player, null, null, null));
    }
    const before = Probe.events;
    try testing.expect(plugins.runCommand(0, testing.io, .{}, "  /PROBE  now "));
    try testing.expectEqual(before + 1, Probe.events);
    try testing.expect(!plugins.runCommand(0, testing.io, .{}, "/probes"));
}

const Delivery = struct {
    worker: u32,
    ok: std.atomic.Value(u32) = .init(0),
    stale: std.atomic.Value(u32) = .init(0),
    misplaced: std.atomic.Value(u32) = .init(0),

    fn done(user: ?*anyopaque, result: *const abi.TaskResult) callconv(.c) void {
        const self: *Delivery = @ptrCast(@alignCast(user.?));
        switch (result.status) {
            .ok => _ = self.ok.fetchAdd(1, .monotonic),
            .stale_handle => _ = self.stale.fetchAdd(1, .monotonic),
            else => {},
        }
        if (result.status == .ok and (result.worker != self.worker or !Work.hosted)) _ = self.misplaced.fetchAdd(1, .monotonic);
    }
};

fn callFromPluginThread(host: abi.Host, player: abi.Player, delivery: *Delivery, statuses: *[6]abi.Status) void {
    statuses.* = .{
        host.subscribe(host.context, .proxy_started, Probe.onEvent, null),
        host.subscribe_packet(host.context, .from_player, 9, .any, .{}, Probe.onPacket, null),
        host.register_command(host.context, .of("late"), Probe.onCommand, null),
        host.transfer(host.context, player, 0),
        host.spawn_task(host.context, player, null, null, null),
        host.post(host.context, player, Delivery.done, delivery),
    };
}

test "a plugin thread gets wrong_thread from callback-only calls and changes nothing" {
    Probe.reset();
    const backends = [_]Backend{try .init("lobby", .{ .ip4 = .loopback(19133) })};
    var plugins: Plugins = try .init(testing.allocator, &backends, .{});
    defer plugins.deinit();
    try plugins.add(Probe.doubled, null);
    const host = Probe.seen_host.?;
    var seen: [2]u64 = .{ 0, 0 };
    const player = try plugins.handles.acquire(testing.allocator, .{ .context = &seen, .link = 7, .transfer = routedTransfer });

    var delivery: Delivery = .{ .worker = 0 };
    var statuses: [6]abi.Status = undefined;
    const thread = try std.Thread.spawn(.{}, callFromPluginThread, .{ host, player, &delivery, &statuses });
    thread.join();
    for (statuses[0..5]) |status| try testing.expectEqual(abi.Status.wrong_thread, status);
    try testing.expectEqual(abi.Status.ok, statuses[5]);
    try testing.expectEqual([2]u64{ 0, 0 }, seen);
    try testing.expect(!plugins.subscribed(.proxy_started));
    try testing.expectEqual(@as(usize, 1), plugins.commands.count());
    try testing.expectEqual(@as(usize, 1), plugins.registrations.items.len);
    plugins.drain(0, testing.io, null);
    try testing.expectEqual(@as(u32, 1), delivery.ok.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), delivery.misplaced.load(.monotonic));
}

fn postMany(host: abi.Host, players: [2]abi.Player, deliveries: *[2]Delivery, count: usize) void {
    for (0..count) |i| {
        while (host.post(host.context, players[i % 2], Delivery.done, &deliveries[i % 2]) == .busy) std.Thread.yield() catch {};
    }
}

test "posts from many threads run once each on the player's worker" {
    Probe.reset();
    var plugins: Plugins = try .init(testing.allocator, &.{}, .{ .workers = 2, .max_messages = 64 });
    defer plugins.deinit();
    try plugins.add(Probe.first, null);
    const host = Probe.seen_host.?;
    var context: u8 = 0;
    const players: [2]abi.Player = .{
        try plugins.handles.acquire(testing.allocator, .{ .context = &context, .worker = 0, .link = 1, .transfer = routedTransfer }),
        try plugins.handles.acquire(testing.allocator, .{ .context = &context, .worker = 1, .link = 2, .transfer = routedTransfer }),
    };
    var deliveries: [2]Delivery = .{ .{ .worker = 0 }, .{ .worker = 1 } };

    const per_thread = 500;
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, postMany, .{ host, players, &deliveries, per_thread });
    const total = threads.len * per_thread;
    while (deliveries[0].ok.load(.monotonic) + deliveries[1].ok.load(.monotonic) < total) {
        plugins.drain(0, testing.io, null);
        plugins.drain(1, testing.io, null);
        std.Thread.yield() catch {};
    }
    for (threads) |thread| thread.join();
    for (&deliveries) |*delivery| {
        try testing.expectEqual(@as(u32, total / 2), delivery.ok.load(.monotonic));
        try testing.expectEqual(@as(u32, 0), delivery.stale.load(.monotonic));
        try testing.expectEqual(@as(u32, 0), delivery.misplaced.load(.monotonic));
    }
    try testing.expectEqual(@as(u32, 0), plugins.messages.load(.monotonic));
}

test "posts are bounded, go stale with the player and are settled once at unload" {
    Probe.reset();
    var plugins: Plugins = try .init(testing.allocator, &.{}, .{ .max_messages = 2 });
    try plugins.add(Probe.first, null);
    const host = Probe.seen_host.?;
    var context: u8 = 0;
    const player = try plugins.handles.acquire(testing.allocator, .{ .context = &context, .link = 1, .transfer = routedTransfer });
    var delivery: Delivery = .{ .worker = 0 };

    try testing.expectEqual(abi.Status.invalid_argument, host.post(host.context, player, null, null));
    try testing.expectEqual(abi.Status.ok, host.post(host.context, player, Delivery.done, &delivery));
    try testing.expectEqual(abi.Status.ok, host.post(host.context, player, Delivery.done, &delivery));
    try testing.expectEqual(abi.Status.busy, host.post(host.context, player, Delivery.done, &delivery));
    try testing.expect(host.send_message(host.context, player, .of("hi")) == .busy);
    plugins.handles.release(player);
    plugins.drain(0, testing.io, null);
    try testing.expectEqual(@as(u32, 2), delivery.stale.load(.monotonic));
    try testing.expectEqual(abi.Status.stale_handle, host.post(host.context, player, Delivery.done, &delivery));

    const other = try plugins.handles.acquire(testing.allocator, .{ .context = &context, .link = 2, .transfer = routedTransfer });
    try testing.expectEqual(abi.Status.ok, host.post(host.context, other, Delivery.done, &delivery));
    plugins.queues[0].close();
    try testing.expectEqual(abi.Status.unsupported, host.post(host.context, other, Delivery.done, &delivery));
    try testing.expectEqual(abi.Status.unsupported, host.send_message(host.context, other, .of("hi")));
    plugins.deinit();
    try testing.expectEqual(@as(u32, 3), delivery.stale.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), delivery.ok.load(.monotonic));
}

const InjectProbe = struct {
    delivered: usize = 0,
    completed: usize = 0,
    statuses: [8]abi.Status = undefined,
    lengths: [8]usize = undefined,
    targets: [8]abi.PacketTarget = undefined,
    last: [128]u8 = undefined,
    status: abi.Status = .ok,

    pub fn message(_: *InjectProbe, _: u64, _: []const u8) void {}

    pub fn packet(self: *InjectProbe, _: u64, target: abi.PacketTarget, bytes: []const u8) abi.Status {
        self.lengths[self.delivered] = bytes.len;
        self.targets[self.delivered] = target;
        @memcpy(self.last[0..bytes.len], bytes);
        self.delivered += 1;
        return self.status;
    }

    fn done(user: ?*anyopaque, result: *const abi.TaskResult) callconv(.c) void {
        const self: *InjectProbe = @ptrCast(@alignCast(user.?));
        self.statuses[self.completed] = result.status;
        self.completed += 1;
    }
};

test "packet injection copies, preserves FIFO, bounds bytes and reports delivery" {
    Probe.reset();
    var plugins: Plugins = try .init(testing.allocator, &.{}, .{ .max_messages = 2, .max_injection_bytes = 16 });
    defer plugins.deinit();
    try plugins.add(Probe.doubled, null);
    const host = Probe.seen_host.?;
    var sink: InjectProbe = .{};
    const player = try plugins.handles.acquire(testing.allocator, .{ .context = &sink, .link = 7, .transfer = routedTransfer });
    var bytes = [_]u8{ 9, 0, 0, 0, 2, 'h', 'i', 0, 0, 0 };
    const expected = bytes;
    try testing.expectEqual(abi.Status.ok, host.send_packet(host.context, player, .player, .of(&bytes), InjectProbe.done, &sink));
    @memset(&bytes, 0);
    try testing.expectEqual(abi.Status.busy, host.send_packet(host.context, player, .backend, .of(&expected), null, null));
    plugins.drain(0, testing.io, &sink);
    try testing.expectEqualSlices(u8, &expected, sink.last[0..expected.len]);
    try testing.expectEqual(abi.Status.ok, sink.statuses[0]);
    try testing.expectEqual(@as(u32, 0), plugins.messages.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), plugins.injection_bytes.load(.monotonic));

    const radius = [_]u8{ 69, 16, 12 };
    try testing.expectEqual(abi.Status.ok, host.send_packet(host.context, player, .backend, .of(&radius), InjectProbe.done, &sink));
    try testing.expectEqual(abi.Status.ok, host.send_packet(host.context, player, .player, .of(&expected), InjectProbe.done, &sink));
    try testing.expectEqual(abi.Status.busy, host.send_packet(host.context, player, .player, .of(&expected), null, null));
    sink.status = .too_late;
    plugins.drain(0, testing.io, &sink);
    try testing.expectEqual(abi.PacketTarget.backend, sink.targets[1]);
    try testing.expectEqual(abi.PacketTarget.player, sink.targets[2]);
    try testing.expectEqual(abi.Status.too_late, sink.statuses[1]);
    try testing.expectEqual(abi.Status.too_late, sink.statuses[2]);
}

test "packet injection rejects stale routes and transfers and cancels on shutdown" {
    Probe.reset();
    var plugins: Plugins = try .init(testing.allocator, &.{}, .{});
    defer plugins.deinit();
    try plugins.add(Probe.doubled, null);
    const host = Probe.seen_host.?;
    var sink: InjectProbe = .{};
    var player = try plugins.handles.acquire(testing.allocator, .{ .context = &sink, .link = 7, .transfer = routedTransfer });
    const bytes = [_]u8{ 9, 0, 0, 0, 2, 'h', 'i', 0, 0, 0 };
    try testing.expectEqual(abi.Status.ok, host.send_packet(host.context, player, .player, .of(&bytes), InjectProbe.done, &sink));
    plugins.handles.invalidatePackets(player);
    plugins.drain(0, testing.io, &sink);
    try testing.expectEqual(abi.Status.canceled, sink.statuses[0]);
    try testing.expectEqual(abi.Status.ok, host.send_packet(host.context, player, .backend, .of(&bytes), InjectProbe.done, &sink));
    plugins.handles.release(player);
    player = try plugins.handles.acquire(testing.allocator, .{ .context = &sink, .link = 8, .transfer = routedTransfer });
    plugins.drain(0, testing.io, &sink);
    try testing.expectEqual(abi.Status.stale_handle, sink.statuses[1]);
    try testing.expectEqual(abi.Status.ok, host.send_packet(host.context, player, .player, .of(&bytes), InjectProbe.done, &sink));
    plugins.queues[0].close();
    try testing.expectEqual(abi.Status.canceled, host.send_packet(host.context, player, .player, .of(&bytes), null, null));
    plugins.unload();
    try testing.expectEqual(abi.Status.canceled, sink.statuses[2]);
    try testing.expectEqual(@as(usize, 0), sink.delivered);
    try testing.expectEqual(@as(u32, 0), plugins.messages.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), plugins.injection_bytes.load(.monotonic));
}

fn injectMany(host: abi.Host, players: [2]abi.Player, deliveries: *[2]Delivery, errors: *std.atomic.Value(u32)) void {
    const bytes = [_]u8{ 9, 0, 0, 0, 2, 'h', 'i', 0, 0, 0 };
    for (0..250) |i| {
        while (true) {
            const status = host.send_packet(host.context, players[i % 2], .player, .of(&bytes), Delivery.done, &deliveries[i % 2]);
            if (status == .busy) {
                std.Thread.yield() catch {};
                continue;
            }
            if (status != .ok) _ = errors.fetchAdd(1, .monotonic);
            break;
        }
    }
}

test "packet injection from many threads completes on the owning workers" {
    Probe.reset();
    var plugins: Plugins = try .init(testing.allocator, &.{}, .{ .workers = 2, .max_messages = 32 });
    defer plugins.deinit();
    try plugins.add(Probe.doubled, null);
    const host = Probe.seen_host.?;
    const Sink = struct {
        link: u64,
        calls: usize = 0,
        misplaced: usize = 0,
        pub fn message(_: *@This(), _: u64, _: []const u8) void {}
        pub fn packet(self: *@This(), link: u64, _: abi.PacketTarget, _: []const u8) abi.Status {
            self.calls += 1;
            if (link != self.link) self.misplaced += 1;
            return .ok;
        }
    };
    var sinks: [2]Sink = .{ .{ .link = 1 }, .{ .link = 2 } };
    const players: [2]abi.Player = .{
        try plugins.handles.acquire(testing.allocator, .{ .context = &sinks[0], .worker = 0, .link = 1, .transfer = routedTransfer }),
        try plugins.handles.acquire(testing.allocator, .{ .context = &sinks[1], .worker = 1, .link = 2, .transfer = routedTransfer }),
    };
    var deliveries: [2]Delivery = .{ .{ .worker = 0 }, .{ .worker = 1 } };
    var errors: std.atomic.Value(u32) = .init(0);
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, injectMany, .{ host, players, &deliveries, &errors });
    while (deliveries[0].ok.load(.monotonic) + deliveries[1].ok.load(.monotonic) + errors.load(.monotonic) < 1000) {
        plugins.drain(0, testing.io, &sinks[0]);
        plugins.drain(1, testing.io, &sinks[1]);
        std.Thread.yield() catch {};
    }
    for (threads) |thread| thread.join();
    try testing.expectEqual(@as(u32, 0), errors.load(.monotonic));
    for (sinks, &deliveries) |sink, *delivery| {
        try testing.expectEqual(@as(usize, 500), sink.calls);
        try testing.expectEqual(@as(usize, 0), sink.misplaced);
        try testing.expectEqual(@as(u32, 0), delivery.misplaced.load(.monotonic));
    }
    try testing.expectEqual(@as(u32, 0), plugins.messages.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), plugins.injection_bytes.load(.monotonic));
}

test "packet injection allocation failure releases reservations and old SDK hosts are rejected" {
    Probe.reset();
    var failing: testing.FailingAllocator = .init(testing.allocator, .{});
    var plugins: Plugins = try .init(failing.allocator(), &.{}, .{});
    defer plugins.deinit();
    try plugins.add(Probe.doubled, null);
    var host = Probe.seen_host.?;
    var sink: InjectProbe = .{};
    const player = try plugins.handles.acquire(plugins.gpa, .{ .context = &sink, .link = 7, .transfer = routedTransfer });
    const bytes = [_]u8{ 9, 0, 0, 0, 2, 'h', 'i', 0, 0, 0 };
    failing.fail_index = failing.alloc_index;
    try testing.expectEqual(abi.Status.failed, host.send_packet(host.context, player, .player, .of(&bytes), InjectProbe.done, &sink));
    try testing.expectEqual(@as(u32, 0), plugins.messages.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), plugins.injection_bytes.load(.monotonic));
    try testing.expectEqual(@as(usize, 0), sink.completed);
    host.struct_size = @offsetOf(abi.Host, "send_packet");
    try testing.expectError(error.Unsupported, (sdk.Host{ .raw = &host }).sendPacket(player, .player, &bytes, null, null));
}

test "packet injection requires capability and defers completion submissions to a later drain" {
    Probe.reset();
    var plugins: Plugins = try .init(testing.allocator, &.{}, .{});
    defer plugins.deinit();
    try plugins.add(Probe.first, null);
    const first = Probe.seen_host.?;
    const bytes = [_]u8{ 9, 0, 0, 0, 2, 'h', 'i', 0, 0, 0 };
    try testing.expectEqual(abi.Status.unsupported, first.send_packet(first.context, .{}, .player, .of(&bytes), null, null));
    try plugins.add(Probe.doubled, null);
    const host = Probe.seen_host.?;
    const Chain = struct {
        host: abi.Host,
        player: abi.Player = .{},
        completions: usize = 0,
        calls: usize = 0,
        status: abi.Status = .ok,
        pub fn message(_: *@This(), _: u64, _: []const u8) void {}
        pub fn packet(self: *@This(), _: u64, _: abi.PacketTarget, _: []const u8) abi.Status {
            self.calls += 1;
            return .ok;
        }
        fn done(user: ?*anyopaque, _: *const abi.TaskResult) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(user.?));
            self.completions += 1;
            if (self.completions == 1) self.status = self.host.send_packet(self.host.context, self.player, .player, .of(&bytes), done, self);
        }
    };
    var chain: Chain = .{ .host = host };
    chain.player = try plugins.handles.acquire(testing.allocator, .{ .context = &chain, .link = 1, .transfer = routedTransfer });
    try testing.expectEqual(abi.Status.ok, host.send_packet(host.context, chain.player, .player, .of(&bytes), Chain.done, &chain));
    plugins.drain(0, testing.io, &chain);
    try testing.expectEqual(abi.Status.ok, chain.status);
    try testing.expectEqual(@as(usize, 1), chain.completions);
    try testing.expectEqual(@as(usize, 1), chain.calls);
    plugins.drain(0, testing.io, &chain);
    try testing.expectEqual(@as(usize, 2), chain.completions);
    try testing.expectEqual(@as(usize, 2), chain.calls);
    plugins.options.packets = false;
    try testing.expectEqual(abi.Status.unsupported, host.send_packet(host.context, chain.player, .player, .of(&bytes), null, null));
}

test "packet injection stays unavailable until plugin initialization commits" {
    const Init = struct {
        fn call(host: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
            plugin.name = .of("init-injection");
            plugin.plugin_version = .of("1");
            plugin.capabilities.packets = true;
            const bytes = [_]u8{ 9, 0, 0, 0, 2, 'h', 'i', 0, 0, 0 };
            return if (host.send_packet(host.context, .{}, .player, .of(&bytes), null, null) == .unsupported) .ok else .failed;
        }
    };
    var plugins: Plugins = try .init(testing.allocator, &.{}, .{});
    defer plugins.deinit();
    try plugins.add(Init.call, null);
    try testing.expect(plugins.loaded.items[0].ready.load(.acquire));
}

const Tasker = struct {
    var host: ?abi.Host = null;
    var name: []const u8 = "tasker";
    var gate: std.atomic.Value(bool) = .init(true);
    var started: std.atomic.Value(u32) = .init(0);
    var results: [4]std.atomic.Value(u32) = @splat(.init(0));

    fn reset() void {
        gate.store(true, .release);
        started.store(0, .release);
        for (&results) |*counter| counter.store(0, .release);
    }

    fn init(api: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
        plugin.name = .of(name);
        plugin.plugin_version = .of("1.0.0");
        plugin.capabilities = .{ .tasks = true };
        host = api.*;
        return .ok;
    }

    fn run(_: ?*anyopaque) callconv(.c) void {
        _ = started.fetchAdd(1, .acq_rel);
        while (!gate.load(.acquire)) std.Thread.yield() catch {};
    }

    fn slot(status: abi.Status) usize {
        return switch (status) {
            .ok => 0,
            .stale_handle => 1,
            .canceled => 2,
            else => 3,
        };
    }

    fn done(_: ?*anyopaque, result: *const abi.TaskResult) callconv(.c) void {
        _ = results[slot(result.status)].fetchAdd(1, .acq_rel);
    }

    fn spawn(api: abi.Host, player: abi.Player) abi.Status {
        return api.spawn_task(api.context, player, run, done, null);
    }

    fn count(status: abi.Status) u32 {
        return results[slot(status)].load(.acquire);
    }

    fn settle(plugins: *Plugins, total: u32) void {
        while (count(.ok) + count(.stale_handle) + count(.canceled) < total) {
            plugins.drain(0, testing.io, null);
            std.Thread.yield() catch {};
        }
    }
};

fn taskPlayer(plugins: *Plugins) !abi.Player {
    return plugins.handles.acquire(testing.allocator, .{ .context = plugins, .link = 1, .transfer = routedTransfer });
}

test "tasks respect the per-plugin and global limits and finish on the player's worker" {
    Tasker.reset();
    Work.hosted = true;
    defer Work.hosted = false;
    var plugins: Plugins = try .init(testing.allocator, &.{}, .{ .task_threads = 1, .max_tasks = 4, .max_tasks_per_plugin = 3 });
    defer plugins.deinit();
    try plugins.add(Tasker.init, null);
    const first = Tasker.host.?;
    Tasker.name = "tasker2";
    defer Tasker.name = "tasker";
    try plugins.add(Tasker.init, null);
    const second = Tasker.host.?;
    const player = try taskPlayer(&plugins);

    Tasker.gate.store(false, .release);
    for (0..3) |_| try testing.expectEqual(abi.Status.ok, Tasker.spawn(first, player));
    try testing.expectEqual(abi.Status.busy, Tasker.spawn(first, player));
    try testing.expectEqual(abi.Status.ok, Tasker.spawn(second, player));
    try testing.expectEqual(abi.Status.busy, Tasker.spawn(second, player));
    try testing.expectEqual(@as(u32, 3), plugins.totals(0).outstanding);

    Tasker.gate.store(true, .release);
    Tasker.settle(&plugins, 4);
    try testing.expectEqual(@as(u32, 4), Tasker.count(.ok));
    try testing.expectEqual(@as(u32, 0), plugins.outstanding.load(.acquire));
    try testing.expectEqual(abi.Status.ok, Tasker.spawn(second, player));
    Tasker.settle(&plugins, 5);
}

test "ten thousand tasks over four threads each finish once and leave nothing behind" {
    Tasker.reset();
    Work.hosted = true;
    defer Work.hosted = false;
    var plugins: Plugins = try .init(testing.allocator, &.{}, .{ .task_threads = 4, .max_tasks_per_plugin = 128 });
    defer plugins.deinit();
    try plugins.add(Tasker.init, null);
    const api = Tasker.host.?;
    const player = try taskPlayer(&plugins);

    const total = 10_000;
    var submitted: u32 = 0;
    while (submitted < total) {
        while (submitted < total and Tasker.spawn(api, player) == .ok) submitted += 1;
        plugins.drain(0, testing.io, null);
    }
    Tasker.settle(&plugins, total);
    try testing.expectEqual(@as(u32, total), Tasker.count(.ok));
    try testing.expectEqual(@as(u32, total), Tasker.started.load(.acquire));
    try testing.expectEqual(@as(u32, 0), plugins.outstanding.load(.acquire));
    try testing.expectEqual(@as(usize, 0), plugins.pool.?.len);
}

test "a task whose player leaves reports a stale handle" {
    Tasker.reset();
    Work.hosted = true;
    defer Work.hosted = false;
    var plugins: Plugins = try .init(testing.allocator, &.{}, .{ .task_threads = 1 });
    defer plugins.deinit();
    try plugins.add(Tasker.init, null);
    const player = try taskPlayer(&plugins);

    Tasker.gate.store(false, .release);
    try testing.expectEqual(abi.Status.ok, Tasker.spawn(Tasker.host.?, player));
    plugins.handles.release(player);
    Tasker.gate.store(true, .release);
    Tasker.settle(&plugins, 1);
    try testing.expectEqual(@as(u32, 1), Tasker.count(.stale_handle));
}

fn openAfterStop(pool: *Pool) void {
    while (!pool.stopping.load(.acquire)) std.Thread.yield() catch {};
    Tasker.gate.store(true, .release);
}

test "shutdown finishes running tasks, cancels queued ones and calls every done once" {
    Tasker.reset();
    Work.hosted = true;
    defer Work.hosted = false;
    var plugins: Plugins = try .init(testing.allocator, &.{}, .{ .task_threads = 1 });
    try plugins.add(Tasker.init, null);
    const player = try taskPlayer(&plugins);

    Tasker.gate.store(false, .release);
    for (0..3) |_| try testing.expectEqual(abi.Status.ok, Tasker.spawn(Tasker.host.?, player));
    while (Tasker.started.load(.acquire) == 0) std.Thread.yield() catch {};
    const opener = try std.Thread.spawn(.{}, openAfterStop, .{plugins.pool.?});
    plugins.deinit();
    opener.join();
    try testing.expectEqual(@as(u32, 1), Tasker.started.load(.acquire));
    try testing.expectEqual(@as(u32, 1), Tasker.count(.stale_handle));
    try testing.expectEqual(@as(u32, 2), Tasker.count(.canceled));
    try testing.expectEqual(@as(u32, 0), Tasker.count(.ok));
}

test "a task that can't be allocated is refused and gives its reservations back" {
    Tasker.reset();
    Work.hosted = true;
    defer Work.hosted = false;
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
    var plugins: Plugins = try .init(failing.allocator(), &.{}, .{ .task_threads = 1 });
    defer plugins.deinit();
    try plugins.add(Tasker.init, null);
    const player = try plugins.handles.acquire(failing.allocator(), .{ .context = &plugins, .link = 1, .transfer = routedTransfer });

    failing.fail_index = failing.alloc_index;
    try testing.expectEqual(abi.Status.failed, Tasker.spawn(Tasker.host.?, player));
    try testing.expectEqual(@as(u32, 0), plugins.outstanding.load(.acquire));
    try testing.expectEqual(@as(u32, 0), plugins.totals(0).outstanding);
    failing.fail_index = std.math.maxInt(usize);
    try testing.expectEqual(abi.Status.ok, Tasker.spawn(Tasker.host.?, player));
    Tasker.settle(&plugins, 1);
}

test "plugin names and versions are checked before they're copied, and refused plugins leave nothing behind" {
    Probe.reset();
    var plugins: Plugins = try .init(testing.allocator, &.{}, .{});
    defer plugins.deinit();
    const long: [max_name_len + 1]u8 = @splat('n');
    const refused = [_]abi.Str{ .{}, .{ .ptr = null, .len = 4 }, .of(&long), .of("bad\xff"), .of("two\nlines"), .of("bell\x07"), .of("del\x7f") };
    Meta.description = .{};
    Meta.version = .of("1.0.0");
    for (refused) |name| {
        Meta.name = name;
        try testing.expectError(error.InvalidMetadata, plugins.add(Meta.init, null));
    }
    Meta.name = .of("meta");
    for (refused) |version| {
        Meta.version = version;
        try testing.expectError(error.InvalidMetadata, plugins.add(Meta.init, null));
    }
    try testing.expectEqual(2 * refused.len, Probe.shutdown_count);
    try testing.expectEqual(@as(usize, 0), plugins.loaded.items.len);
    try testing.expect(!plugins.subscribed(.player_connected));

    const description: [max_description_len]u8 = @splat('d');
    Meta.name = .of(long[0..max_name_len]);
    Meta.version = .of("1.0.0-rc.1+build.7 \u{e9}t\u{e9}");
    Meta.description = .of(&description);
    try plugins.add(Meta.init, null);
    try testing.expectEqual(abi.Status.ok, Meta.described);
    const meta = plugins.metadata(0);
    try testing.expectEqualStrings(long[0..max_name_len], meta.name());
    try testing.expectEqualStrings("1.0.0-rc.1+build.7 \u{e9}t\u{e9}", meta.version());
    try testing.expectEqualStrings(&description, meta.description());
}

test "a bad description is refused without failing the plugin, and can only be set during init" {
    Probe.reset();
    var plugins: Plugins = try .init(testing.allocator, &.{}, .{});
    defer plugins.deinit();
    const long: [max_description_len + 1]u8 = @splat('d');
    const refused = [_]abi.Str{ .{ .ptr = null, .len = 1 }, .of(&long), .of("\xc3"), .of("a\tb") };
    const names = [_][]const u8{ "meta0", "meta1", "meta2", "meta3" };
    Meta.version = .of("1.0.0");
    for (refused, names, 0..) |description, name, i| {
        Meta.name = .of(name);
        Meta.description = description;
        try plugins.add(Meta.init, null);
        try testing.expectEqual(abi.Status.invalid_argument, Meta.described);
        try testing.expectEqualStrings("", plugins.metadata(i).description());
    }

    const host = Probe.seen_host.?;
    try testing.expectEqual(abi.Status.wrong_thread, host.set_description(host.context, .of("late")));
    Work.hosted = true;
    defer Work.hosted = false;
    try testing.expectEqual(abi.Status.too_late, host.set_description(host.context, .of("late")));
}

const SdkPlugin = struct {
    pub const name = "sdk";
    pub const version = "2.0.0";
    pub const description = "Built with the SDK";

    pub fn init(_: sdk.Host) !void {}
};

const OldHost = struct {
    var asked: bool = false;

    fn setDescription(_: *anyopaque, _: abi.Str) callconv(.c) abi.Status {
        asked = true;
        return .ok;
    }
};

test "an SDK plugin loads on hosts older than its header and refuses ones older than v1" {
    var plugins: Plugins = try .init(testing.allocator, &.{}, .{});
    defer plugins.deinit();
    try plugins.add(sdk.entry(SdkPlugin), null);
    try testing.expectEqualStrings("Built with the SDK", plugins.metadata(0).description());

    var loaded: Loaded = .{ .owner = &plugins, .library = null };
    var old = hostFor(&loaded);
    old.set_description = OldHost.setDescription;
    old.struct_size = @offsetOf(abi.Host, "set_description");
    try testing.expect(old.has(.register_command_info) and !old.has(.set_description));
    var plugin: abi.Plugin = .{};
    try testing.expectEqual(abi.Status.ok, sdk.entry(SdkPlugin)(&old, &plugin));
    try testing.expect(!OldHost.asked);
    try testing.expectEqualStrings("sdk", plugin.name.slice());
    var packet: abi.Packet = undefined;
    const old_sdk: sdk.Host = .{ .raw = &old };
    try testing.expectError(error.Unsupported, old_sdk.decodePacket(&packet, abi.Text));
    try testing.expectError(error.Unsupported, old_sdk.encodePacket(&packet, abi.Text{}));

    old.struct_size = @offsetOf(abi.Host, "register_command_info");
    try testing.expectEqual(abi.Status.incompatible, sdk.entry(SdkPlugin)(&old, &plugin));
    old.struct_size = @sizeOf(abi.Host);
    old.abi_version = abi.version + 1;
    try testing.expectEqual(abi.Status.incompatible, sdk.entry(SdkPlugin)(&old, &plugin));
}

const Undeclared = struct {
    var flags: abi.Status = .ok;

    fn events(host: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
        Probe.describe(plugin, 9);
        plugin.capabilities = .{ .packets = true, .commands = true };
        return host.subscribe(host.context, .player_connected, Probe.onEvent, null);
    }

    fn packets(host: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
        Probe.describe(plugin, 10);
        flags = host.subscribe_packet(host.context, .from_player, 7, .any, @bitCast(@as(u32, 4)), Probe.onPacket, null);
        return host.subscribe_packet(host.context, .from_player, 7, .any, .{ .validated = true }, Probe.onPacket, null);
    }

    fn commands(host: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
        Probe.describe(plugin, 11);
        return host.register_command(host.context, .of("hub"), Probe.onCommand, null);
    }
};

test "hooks need their capability declared, and unknown packet flags are refused" {
    Probe.reset();
    var plugins: Plugins = try .init(testing.allocator, &.{}, .{});
    defer plugins.deinit();
    try testing.expectError(error.UndeclaredCapability, plugins.add(Undeclared.events, null));
    try testing.expectError(error.UndeclaredCapability, plugins.add(Undeclared.packets, null));
    try testing.expectError(error.UndeclaredCapability, plugins.add(Undeclared.commands, null));
    try testing.expectEqual(abi.Status.invalid_argument, Undeclared.flags);
    try testing.expectEqualSlices(u8, &.{ 9, 10, 11 }, Probe.shutdowns[0..Probe.shutdown_count]);
    try testing.expect(!plugins.subscribed(.player_connected) and !plugins.hasCommands());
    try testing.expectEqual(@as(?*const Packets.Table, null), plugins.packetTable(.from_player));
}

const Eager = struct {
    var spawned: abi.Status = .ok;
    var posted: abi.Status = .ok;
    var player: abi.Player = .{};

    fn init(host: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
        plugin.capabilities = .{ .tasks = true };
        spawned = host.spawn_task(host.context, .{}, Tasker.run, Tasker.done, null);
        posted = host.post(host.context, player, Tasker.done, null);
        return .ok;
    }
};

test "a plugin can't start work during init that could outlive its refusal" {
    Tasker.reset();
    var plugins: Plugins = try .init(testing.allocator, &.{}, .{ .task_threads = 1 });
    defer plugins.deinit();
    try plugins.add(Tasker.init, null);
    Eager.player = try taskPlayer(&plugins);
    try testing.expectError(error.InvalidMetadata, plugins.add(Eager.init, null));
    try testing.expectEqual(abi.Status.unsupported, Eager.spawned);
    try testing.expectEqual(abi.Status.unsupported, Eager.posted);
    try testing.expectEqual(@as(u32, 0), plugins.outstanding.load(.acquire));
    try testing.expectEqual(@as(u32, 0), plugins.messages.load(.acquire));
}

const Full = struct {
    var succeeded: bool = false;
    var shutdowns: usize = 0;

    fn init(host: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
        plugin.name = .of("full");
        plugin.plugin_version = .of("1.0.0");
        plugin.capabilities = .{ .events = true, .commands = true, .packets = true, .tasks = true };
        plugin.shutdown = onShutdown;
        const info: abi.CommandInfo = .{ .name = .of("full"), .description = .of("Everything"), .callback = Probe.onCommand };
        const statuses = [_]abi.Status{
            host.set_description(host.context, .of("Uses everything")),
            host.subscribe(host.context, .player_connected, Probe.onEvent, null),
            host.subscribe(host.context, .transfer_requested, Probe.onEvent, null),
            host.subscribe_packet(host.context, .from_player, 7, .any, .{}, Probe.onPacket, null),
            host.subscribe_packet(host.context, .from_backend, 9, .in_game, .{}, Probe.onPacket, null),
            host.register_command_info(host.context, &info),
        };
        for (statuses) |status| if (status != .ok) return status;
        succeeded = true;
        return .ok;
    }

    fn onShutdown(_: ?*anyopaque) callconv(.c) void {
        shutdowns += 1;
    }
};

test "running out of memory anywhere while loading leaves nothing registered" {
    var fail_after: usize = 0;
    while (true) : (fail_after += 1) {
        var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
        var plugins: Plugins = try .init(failing.allocator(), &.{}, .{ .task_threads = 1 });
        defer plugins.deinit();
        failing.fail_index = failing.alloc_index + fail_after;
        Full.succeeded = false;
        Full.shutdowns = 0;
        plugins.load(Full.init, null, &testManifest("full", "1.0.0")) catch |err| {
            try testing.expect(err == error.OutOfMemory or err == error.PluginInitFailed);
            try testing.expectEqual(@as(usize, @intFromBool(Full.succeeded)), Full.shutdowns);
            try testing.expectEqual(@as(usize, 0), plugins.loaded.items.len);
            try testing.expect(!plugins.subscribed(.player_connected) and !plugins.subscribed(.transfer_requested));
            try testing.expect(!plugins.hasCommands());
            try testing.expectEqual(@as(usize, 0), plugins.registrations.items.len);
            try testing.expectEqual(@as(?*const Packets.Table, null), plugins.packetTable(.from_player));
            continue;
        };
        try testing.expect(fail_after > 0);
        try testing.expect(plugins.hasCommands() and plugins.packetTable(.from_backend) != null);
        break;
    }
}

fn testManifest(name: []const u8, version: []const u8) Metadata {
    var meta: Metadata = .{ .package = "plugins" ++ std.fs.path.sep_str ++ "Probe" };
    @memcpy(meta.name_buffer[0..name.len], name);
    meta.name_len = @intCast(name.len);
    @memcpy(meta.version_buffer[0..version.len], version);
    meta.version_len = @intCast(version.len);
    const description = "From plugin.toml";
    @memcpy(meta.description_buffer[0..description.len], description);
    meta.description_len = description.len;
    return meta;
}

test "a packaged plugin must match its manifest, which supplies its description and package path" {
    Probe.reset();
    var plugins: Plugins = try .init(testing.allocator, &.{}, .{});
    defer plugins.deinit();
    Meta.name = .of("meta");
    Meta.version = .of("1.0.0");
    Meta.description = .of("From the library");
    try testing.expectError(error.MetadataMismatch, plugins.load(Meta.init, null, &testManifest("Meta", "1.0.0")));
    try testing.expectError(error.MetadataMismatch, plugins.load(Meta.init, null, &testManifest("meta", "1.0.1")));
    try testing.expectError(error.PluginInitFailed, plugins.load(Probe.failing, null, &testManifest("probe3", "1.0.0")));
    try testing.expectEqualSlices(u8, &.{ 8, 8 }, Probe.shutdowns[0..Probe.shutdown_count]);
    try testing.expect(!plugins.subscribed(.player_connected));

    try plugins.load(Meta.init, null, &testManifest("meta", "1.0.0"));
    const meta = plugins.metadata(0);
    try testing.expectEqualStrings("From plugin.toml", meta.description());
    try testing.expectEqualStrings("plugins" ++ std.fs.path.sep_str ++ "Probe", meta.package);
    try testing.expect(plugins.isLoaded("META"));

    Meta.name = .of("Meta");
    try testing.expectError(error.DuplicatePlugin, plugins.add(Meta.init, null));
    try testing.expectEqual(@as(usize, 1), plugins.loaded.items.len);
    try testing.expectEqual(@as(usize, 3), Probe.shutdown_count);
}

const Poster = struct {
    var host: abi.Host = undefined;
    var player: abi.Player = .{};
    var delivery: Delivery = .{ .worker = 0 };
    var accepted: std.atomic.Value(u32) = .init(0);
    var threads: [4]std.Thread = undefined;
    var running: usize = 0;

    fn init(api: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
        plugin.name = .of("poster");
        plugin.plugin_version = .of("1.0.0");
        plugin.shutdown = stop;
        host = api.*;
        return .ok;
    }

    fn loop() void {
        while (true) switch (host.post(host.context, player, Delivery.done, &delivery)) {
            .ok => _ = accepted.fetchAdd(1, .acq_rel),
            .busy => std.Thread.yield() catch {},
            else => return,
        };
    }

    fn stop(_: ?*anyopaque) callconv(.c) void {
        for (threads[0..running]) |thread| thread.join();
    }
};

test "posts from plugin threads racing unload are each settled once before shutdown" {
    var plugins: Plugins = try .init(testing.allocator, &.{}, .{ .max_messages = 64 });
    try plugins.add(Poster.init, null);
    var context: u8 = 0;
    Poster.player = try plugins.handles.acquire(testing.allocator, .{ .context = &context, .link = 1, .transfer = routedTransfer });
    for (&Poster.threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, Poster.loop, .{});
        Poster.running += 1;
    }
    for (0..200) |_| {
        plugins.drain(0, testing.io, null);
        std.Thread.yield() catch {};
    }
    plugins.deinit();
    const delivery = &Poster.delivery;
    try testing.expectEqual(Poster.accepted.load(.acquire), delivery.ok.load(.acquire) + delivery.stale.load(.acquire));
    try testing.expectEqual(@as(u32, 0), delivery.misplaced.load(.acquire));
}
