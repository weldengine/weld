//! M0.2 / E4 — lifetime drain semantics + cursor invalidation.

const std = @import("std");
const weld_core = @import("weld_core");

const events = weld_core.events;
const EventBus = events.EventBus;

const TickEv = extern struct { seq: u32 = 0 };
const PhaseEv = extern struct { seq: u32 = 0 };
const FrameEv = extern struct { seq: u32 = 0 };

test "drainAtBoundary(.tick) only resets .tick-lifetime queues" {
    const gpa = std.testing.allocator;
    var bus = EventBus.init();
    defer bus.deinit(gpa);

    try bus.register(gpa, TickEv, 16, .tick);
    try bus.register(gpa, PhaseEv, 16, .phase);
    try bus.register(gpa, FrameEv, 16, .frame);

    var tick_cur = try bus.subscribe(TickEv);
    var phase_cur = try bus.subscribe(PhaseEv);
    var frame_cur = try bus.subscribe(FrameEv);

    try bus.emit(TickEv, .{ .seq = 1 });
    try bus.emit(PhaseEv, .{ .seq = 2 });
    try bus.emit(FrameEv, .{ .seq = 3 });

    bus.drainAtBoundary(.tick);

    // tick cursor is invalidated; phase / frame still valid.
    try std.testing.expectError(
        error.CursorInvalidated,
        bus.poll(TickEv, &tick_cur),
    );
    try std.testing.expectEqual(@as(u32, 2), (try bus.poll(PhaseEv, &phase_cur)).?.seq);
    try std.testing.expectEqual(@as(u32, 3), (try bus.poll(FrameEv, &frame_cur)).?.seq);
}

test "queue with lifetime .phase survives a .tick drain" {
    const gpa = std.testing.allocator;
    var bus = EventBus.init();
    defer bus.deinit(gpa);

    try bus.register(gpa, PhaseEv, 16, .phase);
    var cur = try bus.subscribe(PhaseEv);
    try bus.emit(PhaseEv, .{ .seq = 99 });

    bus.drainAtBoundary(.tick);

    // Cursor and event still alive.
    const got = (try bus.poll(PhaseEv, &cur)).?;
    try std.testing.expectEqual(@as(u32, 99), got.seq);
}

test "queue with lifetime .frame survives .phase and .tick drains" {
    const gpa = std.testing.allocator;
    var bus = EventBus.init();
    defer bus.deinit(gpa);

    try bus.register(gpa, FrameEv, 16, .frame);
    var cur = try bus.subscribe(FrameEv);
    try bus.emit(FrameEv, .{ .seq = 7 });

    bus.drainAtBoundary(.phase);
    bus.drainAtBoundary(.tick);

    const got = (try bus.poll(FrameEv, &cur)).?;
    try std.testing.expectEqual(@as(u32, 7), got.seq);
}

test "cursor is invalidated after drain of its queue" {
    const gpa = std.testing.allocator;
    var bus = EventBus.init();
    defer bus.deinit(gpa);

    try bus.register(gpa, TickEv, 16, .tick);
    var cur = try bus.subscribe(TickEv);
    try bus.emit(TickEv, .{ .seq = 1 });

    bus.drainAtBoundary(.tick);

    try std.testing.expectError(
        error.CursorInvalidated,
        bus.poll(TickEv, &cur),
    );
}

test "re-subscribe after drain returns a fresh cursor" {
    const gpa = std.testing.allocator;
    var bus = EventBus.init();
    defer bus.deinit(gpa);

    try bus.register(gpa, TickEv, 16, .tick);
    var cur = try bus.subscribe(TickEv);
    try bus.emit(TickEv, .{ .seq = 1 });
    bus.drainAtBoundary(.tick);

    // Old cursor invalid.
    try std.testing.expectError(error.CursorInvalidated, bus.poll(TickEv, &cur));

    // Fresh cursor sees events emitted after re-subscribe.
    var fresh = try bus.subscribe(TickEv);
    try std.testing.expect((try bus.poll(TickEv, &fresh)) == null);

    try bus.emit(TickEv, .{ .seq = 2 });
    const got = (try bus.poll(TickEv, &fresh)).?;
    try std.testing.expectEqual(@as(u32, 2), got.seq);
}
