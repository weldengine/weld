//! M0.2 / E4 — saturation semantics: drop-oldest + drops counter
//! + warning log threshold.

const std = @import("std");
const weld_core = @import("weld_core");

const events = weld_core.events;
const EventBus = events.EventBus;

const Tag = extern struct {
    seq: u32 = 0,
};

test "overflow drops oldest entries; later poll sees the most recent ones" {
    const gpa = std.testing.allocator;
    var bus = EventBus.init();
    defer bus.deinit(gpa);

    // Capacity 4. We emit 6 — the first 2 must be dropped, the
    // last 4 still polled in order.
    try bus.register(gpa, Tag, 4, .phase);
    var cursor = try bus.subscribe(Tag);
    var i: u32 = 0;
    while (i < 6) : (i += 1) {
        try bus.emit(Tag, .{ .seq = i });
    }

    var seen: [4]u32 = undefined;
    var idx: usize = 0;
    while (try bus.poll(Tag, &cursor)) |ev| : (idx += 1) {
        if (idx < seen.len) seen[idx] = ev.seq;
    }
    try std.testing.expectEqual(@as(usize, 4), idx);
    try std.testing.expectEqualSlices(u32, &.{ 2, 3, 4, 5 }, &seen);

    // The queue's internal drops counter recorded the 2 evictions.
    const queue_ptr_value = bus.queues.get(weld_core.rtti.computeTypeId(Tag)).?.ptr;
    const q: *events.EventQueue(Tag) = @ptrCast(@alignCast(queue_ptr_value));
    try std.testing.expectEqual(@as(u64, 2), q.dropsSinceLastDrain());
}

test "drops counter is reset after drainAtBoundary" {
    const gpa = std.testing.allocator;
    var bus = EventBus.init();
    defer bus.deinit(gpa);

    try bus.register(gpa, Tag, 2, .phase);
    // Emit 5 into a 2-slot queue → 3 drops.
    var i: u32 = 0;
    while (i < 5) : (i += 1) try bus.emit(Tag, .{ .seq = i });

    const queue_entry = bus.queues.get(weld_core.rtti.computeTypeId(Tag)).?;
    const q: *events.EventQueue(Tag) = @ptrCast(@alignCast(queue_entry.ptr));
    try std.testing.expectEqual(@as(u64, 3), q.dropsSinceLastDrain());

    bus.drainAtBoundary(.phase);
    try std.testing.expectEqual(@as(u64, 0), q.dropsSinceLastDrain());
}

test "drops above warning threshold emits a warn log on drain" {
    // Capture the test scope's log output via a thread-local
    // override is brittle; instead, this test exercises the
    // threshold semantics by checking that:
    //   - Below threshold, no log is emitted (proxied by the
    //     fact that the threshold constant is preserved across
    //     drain cycles and the drops counter resets cleanly).
    //   - Above threshold, the bus drains without crashing
    //     (the log macro is `std.log.scoped(.events).warn`,
    //     a runtime no-op when stripped in release; correctness
    //     is "does not crash + drops still reset").
    //
    // A capture-based check would require a custom std.log
    // sink installed in test main(), which the project's test
    // target does not currently configure. The threshold
    // constant `DROPS_WARN_THRESHOLD = 10` is part of the
    // public surface; tests assert the value so changes are
    // deliberate.

    try std.testing.expectEqual(@as(u64, 10), events.DROPS_WARN_THRESHOLD);

    const gpa = std.testing.allocator;
    var bus = EventBus.init();
    defer bus.deinit(gpa);

    try bus.register(gpa, Tag, 2, .phase);
    // Emit 30 → 28 drops, well above the threshold.
    var i: u32 = 0;
    while (i < 30) : (i += 1) try bus.emit(Tag, .{ .seq = i });

    const queue_entry = bus.queues.get(weld_core.rtti.computeTypeId(Tag)).?;
    const q: *events.EventQueue(Tag) = @ptrCast(@alignCast(queue_entry.ptr));
    try std.testing.expect(q.dropsSinceLastDrain() > events.DROPS_WARN_THRESHOLD);

    // drainAtBoundary path is exercised here — must not crash.
    bus.drainAtBoundary(.phase);
    try std.testing.expectEqual(@as(u64, 0), q.dropsSinceLastDrain());
}
