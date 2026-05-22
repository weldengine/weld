//! M0.2 / E4 — Event queue / bus basic semantics.

const std = @import("std");
const weld_core = @import("weld_core");

const events = weld_core.events;
const EventBus = events.EventBus;
const Lifetime = events.Lifetime;

const Ping = extern struct {
    seq: u32 = 0,
};

const Pong = extern struct {
    seq: u32 = 0,
    timestamp_us: u64 = 0,
};

test "emit then poll returns the event" {
    const gpa = std.testing.allocator;
    var bus = EventBus.init();
    defer bus.deinit(gpa);

    try bus.register(gpa, Ping, 16, .phase);
    var cursor = try bus.subscribe(Ping);
    try bus.emit(Ping, .{ .seq = 42 });

    const got = (try bus.poll(Ping, &cursor)).?;
    try std.testing.expectEqual(@as(u32, 42), got.seq);

    // The queue is now drained from this cursor's perspective.
    try std.testing.expect((try bus.poll(Ping, &cursor)) == null);
}

test "ordering FIFO per type" {
    const gpa = std.testing.allocator;
    var bus = EventBus.init();
    defer bus.deinit(gpa);

    try bus.register(gpa, Ping, 16, .phase);
    var cursor = try bus.subscribe(Ping);
    try bus.emit(Ping, .{ .seq = 1 });
    try bus.emit(Ping, .{ .seq = 2 });
    try bus.emit(Ping, .{ .seq = 3 });

    try std.testing.expectEqual(@as(u32, 1), (try bus.poll(Ping, &cursor)).?.seq);
    try std.testing.expectEqual(@as(u32, 2), (try bus.poll(Ping, &cursor)).?.seq);
    try std.testing.expectEqual(@as(u32, 3), (try bus.poll(Ping, &cursor)).?.seq);
    try std.testing.expect((try bus.poll(Ping, &cursor)) == null);
}

const ProducerCtx = struct {
    bus: *EventBus,
    start: u32,
    count: u32,
};

fn producerWorker(ctx: *ProducerCtx) void {
    var i: u32 = 0;
    while (i < ctx.count) : (i += 1) {
        bus_emit_loop: while (true) {
            ctx.bus.emit(Ping, .{ .seq = ctx.start + i }) catch unreachable;
            break :bus_emit_loop;
        }
    }
}

test "MPMC concurrent: 4 producers x 1000 emits = 4000 events with no loss" {
    const gpa = std.testing.allocator;
    var bus = EventBus.init();
    defer bus.deinit(gpa);

    // Cap > 4000 so we never trigger the drop-oldest path. Round
    // to the next power of two: 8192.
    try bus.register(gpa, Ping, 8192, .phase);
    var cursor = try bus.subscribe(Ping);

    const producer_count = 4;
    const per_producer = 1000;
    var ctxs: [producer_count]ProducerCtx = undefined;
    var threads: [producer_count]std.Thread = undefined;

    for (0..producer_count) |i| {
        ctxs[i] = .{
            .bus = &bus,
            .start = @as(u32, @intCast(i)) * per_producer,
            .count = per_producer,
        };
        threads[i] = try std.Thread.spawn(.{}, producerWorker, .{&ctxs[i]});
    }
    for (&threads) |*t| t.join();

    // Collect every event. Each event's `seq` is unique by
    // construction (start + i), so we count distinct values.
    var seen = std.AutoHashMap(u32, void).init(gpa);
    defer seen.deinit();
    while (try bus.poll(Ping, &cursor)) |ev| {
        try seen.put(ev.seq, {});
    }
    try std.testing.expectEqual(@as(usize, producer_count * per_producer), seen.count());
}

test "two distinct event types maintain independent queues" {
    const gpa = std.testing.allocator;
    var bus = EventBus.init();
    defer bus.deinit(gpa);

    try bus.register(gpa, Ping, 16, .phase);
    try bus.register(gpa, Pong, 16, .phase);
    var ping_cursor = try bus.subscribe(Ping);
    var pong_cursor = try bus.subscribe(Pong);

    try bus.emit(Ping, .{ .seq = 7 });
    try bus.emit(Pong, .{ .seq = 9, .timestamp_us = 1234 });

    // Pong cursor sees zero Ping events even though the bus
    // contains one. Same the other way around.
    const got_ping = (try bus.poll(Ping, &ping_cursor)).?;
    try std.testing.expectEqual(@as(u32, 7), got_ping.seq);

    const got_pong = (try bus.poll(Pong, &pong_cursor)).?;
    try std.testing.expectEqual(@as(u32, 9), got_pong.seq);
    try std.testing.expectEqual(@as(u64, 1234), got_pong.timestamp_us);
}

test "emit without prior register returns EventTypeNotRegistered" {
    const gpa = std.testing.allocator;
    var bus = EventBus.init();
    defer bus.deinit(gpa);

    try std.testing.expectError(
        error.EventTypeNotRegistered,
        bus.emit(Ping, .{ .seq = 0 }),
    );
}

test "queueCount reflects registered types" {
    const gpa = std.testing.allocator;
    var bus = EventBus.init();
    defer bus.deinit(gpa);

    try std.testing.expectEqual(@as(u32, 0), bus.queueCount());
    try bus.register(gpa, Ping, 16, .phase);
    try std.testing.expectEqual(@as(u32, 1), bus.queueCount());
    try bus.register(gpa, Pong, 16, .frame);
    try std.testing.expectEqual(@as(u32, 2), bus.queueCount());

    // Double-register is rejected.
    try std.testing.expectError(
        error.AlreadyRegistered,
        bus.register(gpa, Ping, 16, .phase),
    );
}
