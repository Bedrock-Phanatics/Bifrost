const std = @import("std");

// Plugin replies reach a worker from any thread, so only multi-producer designs apply. Spin mirrors Work.Queue.
pub const Kind = enum { spin, mutex, ring };

pub const Result = struct {
    kind: Kind,
    producers: usize,
    items_per_s: f64,
    p99_ns: f64,
};

const capacity = 1024;
const futex_io = std.Io.Threaded.global_single_threaded.io();

const Spin = struct {
    lock: std.atomic.Value(bool) = .init(false),
    items: [capacity]u64 = undefined,
    len: usize = 0,
    taken: [capacity]u64 = undefined,

    fn post(self: *Spin, item: u64) bool {
        while (self.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
        defer self.lock.store(false, .release);
        if (self.len == capacity) return false;
        self.items[self.len] = item;
        self.len += 1;
        return true;
    }

    fn take(self: *Spin) []const u64 {
        while (self.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
        defer self.lock.store(false, .release);
        const count = self.len;
        @memcpy(self.taken[0..count], self.items[0..count]);
        self.len = 0;
        return self.taken[0..count];
    }
};

const Mutex = struct {
    mutex: std.Io.Mutex = .init,
    items: [capacity]u64 = undefined,
    len: usize = 0,
    taken: [capacity]u64 = undefined,

    fn post(self: *Mutex, item: u64) bool {
        self.mutex.lockUncancelable(futex_io);
        defer self.mutex.unlock(futex_io);
        if (self.len == capacity) return false;
        self.items[self.len] = item;
        self.len += 1;
        return true;
    }

    fn take(self: *Mutex) []const u64 {
        self.mutex.lockUncancelable(futex_io);
        defer self.mutex.unlock(futex_io);
        const count = self.len;
        @memcpy(self.taken[0..count], self.items[0..count]);
        self.len = 0;
        return self.taken[0..count];
    }
};

// Vyukov's bounded queue, lock free for producers and the single consumer
const Ring = struct {
    const Slot = struct { sequence: std.atomic.Value(usize), item: u64 };
    slots: [capacity]Slot = undefined,
    head: std.atomic.Value(usize) align(std.atomic.cache_line) = .init(0),
    tail: std.atomic.Value(usize) align(std.atomic.cache_line) = .init(0),
    taken: [capacity]u64 = undefined,

    fn init(self: *Ring) void {
        for (&self.slots, 0..) |*slot, i| slot.sequence = .init(i);
        self.head = .init(0);
        self.tail = .init(0);
    }

    fn post(self: *Ring, item: u64) bool {
        var position = self.tail.load(.monotonic);
        while (true) {
            const slot = &self.slots[position % capacity];
            const sequence = slot.sequence.load(.acquire);
            if (sequence == position) {
                position = self.tail.cmpxchgWeak(position, position + 1, .monotonic, .monotonic) orelse {
                    slot.item = item;
                    slot.sequence.store(position + 1, .release);
                    return true;
                };
            } else if (sequence < position) {
                return false;
            } else position = self.tail.load(.monotonic);
        }
    }

    fn take(self: *Ring) []const u64 {
        var count: usize = 0;
        var position = self.head.raw;
        while (count < capacity) : (count += 1) {
            const slot = &self.slots[position % capacity];
            if (slot.sequence.load(.acquire) != position + 1) break;
            self.taken[count] = slot.item;
            slot.sequence.store(position + capacity, .release);
            position += 1;
        }
        self.head.store(position, .monotonic);
        return self.taken[0..count];
    }
};

fn Bench(comptime Queue: type) type {
    return struct {
        queue: Queue = undefined,
        start: std.atomic.Value(bool) = .init(false),
        per_producer: usize,

        fn produce(self: *@This()) void {
            while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
            var sent: usize = 0;
            while (sent < self.per_producer) {
                if (self.queue.post(now())) sent += 1 else std.Thread.yield() catch {};
            }
        }

        fn run(self: *@This(), producers: usize, samples: []u64) !struct { ns: u64, count: usize } {
            var threads: [64]std.Thread = undefined;
            for (threads[0..producers]) |*thread| thread.* = try std.Thread.spawn(.{}, produce, .{self});
            const total = producers * self.per_producer;
            const started = now();
            self.start.store(true, .release);
            var received: usize = 0;
            var sampled: usize = 0;
            while (received < total) {
                const batch = self.queue.take();
                if (batch.len == 0) {
                    std.atomic.spinLoopHint();
                    continue;
                }
                const at = now();
                for (batch) |sent_at| {
                    if (sampled < samples.len and received % 64 == 0) {
                        samples[sampled] = at -| sent_at;
                        sampled += 1;
                    }
                    received += 1;
                }
            }
            const elapsed = now() - started;
            for (threads[0..producers]) |thread| thread.join();
            return .{ .ns = elapsed, .count = sampled };
        }
    };
}

fn now() u64 {
    return @intCast(std.Io.Clock.awake.now(futex_io).nanoseconds);
}

pub fn run(gpa: std.mem.Allocator, quick: bool, producer_counts: []const usize) ![]Result {
    const per_producer: usize = if (quick) 200_000 else 1_000_000;
    var results: std.ArrayList(Result) = .empty;
    errdefer results.deinit(gpa);
    const samples = try gpa.alloc(u64, 1 << 16);
    defer gpa.free(samples);
    for (producer_counts) |producers| {
        inline for (.{ Kind.spin, Kind.mutex, Kind.ring }) |kind| {
            const Queue = switch (kind) {
                .spin => Spin,
                .mutex => Mutex,
                .ring => Ring,
            };
            const state = try gpa.create(Bench(Queue));
            defer gpa.destroy(state);
            state.* = .{ .per_producer = per_producer / producers };
            state.queue = .{};
            if (kind == .ring) state.queue.init();
            const outcome = try state.run(producers, samples);
            const used = samples[0..outcome.count];
            std.mem.sort(u64, used, {}, std.sort.asc(u64));
            try results.append(gpa, .{
                .kind = kind,
                .producers = producers,
                .items_per_s = @as(f64, @floatFromInt(state.per_producer * producers)) * std.time.ns_per_s / @as(f64, @floatFromInt(outcome.ns)),
                .p99_ns = if (used.len == 0) 0 else @floatFromInt(used[used.len * 99 / 100]),
            });
        }
    }
    return results.toOwnedSlice(gpa);
}

test "queue designs deliver every item" {
    const results = try run(std.testing.allocator, true, &.{ 1, 3 });
    defer std.testing.allocator.free(results);
    try std.testing.expectEqual(@as(usize, 6), results.len);
    for (results) |result| try std.testing.expect(result.items_per_s > 0);
}
