const std = @import("std");
const abi = @import("abi.zig");
const Backend = @import("../backend/Backend.zig");
const Library = @import("Library.zig").Library;
pub const Handles = @import("Handles.zig");
pub const Packets = @import("Packets.zig");
const Pool = @import("Pool.zig");
const Work = @import("Work.zig");
const Notify = @import("../net/Notify.zig");

const Plugins = @This();
const log = std.log.scoped(.plugin);

pub const max_name_len = 64;
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
};

pub const Totals = struct {
    calls: u64 = 0,
    total_ns: u64 = 0,
    max_ns: u64 = 0,
    errors: u64 = 0,
    outstanding: u32 = 0,
};

pub const max_description_len = 256;

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
    name: [max_name_len]u8 = undefined,
    name_len: usize = 0,
    metrics: []Packets.Metrics = &.{},
    outstanding: std.atomic.Value(u32) = .init(0),

    fn label(self: *const Loaded) []const u8 {
        return self.name[0..self.name_len];
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

pub fn open(self: *Plugins, path: []const u8) !void {
    var library = try Library.open(path);
    errdefer library.close();
    const entry = library.lookup(abi.InitFn, abi.entrypoint) orelse return error.MissingEntrypoint;
    try self.add(entry, library);
}

pub fn add(self: *Plugins, entry: abi.InitFn, library: ?Library) !void {
    try self.loaded.ensureUnusedCapacity(self.gpa, 1);
    const loaded = try self.gpa.create(Loaded);
    errdefer self.gpa.destroy(loaded);
    loaded.* = .{ .owner = self, .library = library };
    loaded.host = hostFor(loaded);
    loaded.metrics = try self.gpa.alloc(Packets.Metrics, self.options.workers);
    errdefer self.gpa.free(loaded.metrics);
    @memset(loaded.metrics, .{});

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
    loaded.name_len = @min(plugin.name.len, max_name_len);
    @memcpy(loaded.name[0..loaded.name_len], plugin.name.slice()[0..loaded.name_len]);
    if (plugin.abi_version != abi.version or plugin.struct_size < @sizeOf(abi.Plugin)) {
        log.warn("plugin {s} targets ABI {d}, Bifrost has {d}", .{ loaded.label(), plugin.abi_version, abi.version });
        return error.IncompatiblePlugin;
    }
    const unsupported = @as(u64, @bitCast(plugin.capabilities)) & ~@as(u64, @bitCast(abi.Capabilities.supported));
    if (unsupported != 0) {
        log.warn("plugin {s} needs unsupported capabilities 0x{x}", .{ loaded.label(), unsupported });
        return error.UnsupportedCapability;
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
    log.info("loaded plugin {s} {s}", .{ loaded.label(), plugin.plugin_version.slice() });
}

pub fn unload(self: *Plugins) void {
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
        .post => |post| {
            defer {
                self.gpa.destroy(post);
                Work.release(&self.messages);
            }
            self.complete(post, self.liveStatus(post.player, owner), owner);
        },
    }
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

fn hostSubscribePacket(context: *anyopaque, direction: abi.Direction, id: u32, phase: abi.PacketPhase, flags: abi.PacketFlags, callback: ?abi.PacketFn, user: ?*anyopaque) callconv(.c) abi.Status {
    const loaded = from(context);
    const owner = loaded.owner;
    if (!Work.hosted) return .wrong_thread;
    if (owner.initializing.load(.acquire) != loaded) return .too_late;
    if (!owner.options.packets) return .unsupported;
    if (@backingInt(direction) > 1 or id >= Packets.id_count or @backingInt(phase) > 2) return .invalid_argument;
    const packet_callback = callback orelse return .invalid_argument;
    for (owner.pending_packets.items) |item| {
        if (item.direction == direction and item.id == id and item.subscriber.callback == packet_callback and item.subscriber.user == user) return .invalid_argument;
    }
    owner.pending_packets.append(owner.gpa, .{ .direction = direction, .id = @intCast(id), .subscriber = .{
        .callback = packet_callback,
        .user = user,
        .phase = phase,
        .validated = flags.validated,
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
    const text = info.name.slice();
    const description = info.description.slice();
    if (text.len == 0 or text.len > max_command_len) return .invalid_argument;
    if (description.len > max_description_len or !std.unicode.utf8ValidateSlice(description)) return .invalid_argument;
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
    if (!loaded.plugin.capabilities.tasks) return .unsupported;
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
    var shutdowns: [4]u8 = undefined;
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

    fn describe(plugin: *abi.Plugin, id: usize) void {
        plugin.name = .of("probe");
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

const Tasker = struct {
    var host: ?abi.Host = null;
    var gate: std.atomic.Value(bool) = .init(true);
    var started: std.atomic.Value(u32) = .init(0);
    var results: [4]std.atomic.Value(u32) = @splat(.init(0));

    fn reset() void {
        gate.store(true, .release);
        started.store(0, .release);
        for (&results) |*counter| counter.store(0, .release);
    }

    fn init(api: *const abi.Host, plugin: *abi.Plugin) callconv(.c) abi.Status {
        plugin.name = .of("tasker");
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
