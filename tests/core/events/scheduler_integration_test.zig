//! M0.2 / E4 — scheduler integration: events drained at the
//! lifetime-appropriate boundary by a mini phase-walking driver.
//!
//! The "mini-scheduler" exercised here drives the bus's drain
//! cadence directly — `bus.drainAtBoundary(.phase)` between every
//! phase, `.tick` + `.frame` at end of frame. This is the same
//! sequence the M0.1 `SystemScheduler.dispatchFrame` performs
//! (cf. `src/core/ecs/scheduler.zig`, post-E4 edit). The test
//! lives outside the full scheduler so it can express assertions
//! at intermediate boundaries without spinning up job system
//! infrastructure.

const std = @import("std");
const weld_core = @import("weld_core");

const events = weld_core.events;
const EventBus = events.EventBus;
const Lifetime = events.Lifetime;

const PhaseEv = extern struct { seq: u32 = 0 };
const FrameEv = extern struct { seq: u32 = 0 };

/// Simulate the scheduler's drain cadence for one frame.
fn frameDrain(bus: *EventBus) void {
    bus.drainAtBoundary(.phase); // post-PreUpdate
    bus.drainAtBoundary(.phase); // post-FixedUpdate
    bus.drainAtBoundary(.phase); // post-Update
    bus.drainAtBoundary(.phase); // post-PostUpdate
    bus.drainAtBoundary(.phase); // post-LateUpdate
    bus.drainAtBoundary(.phase); // post-PreRender
    bus.drainAtBoundary(.tick); // end of tick
    bus.drainAtBoundary(.frame); // end of frame
}

test "events emitted in Update are drained before PostUpdate when lifetime=.phase" {
    const gpa = std.testing.allocator;
    var bus = EventBus.init();
    defer bus.deinit(gpa);

    try bus.register(gpa, PhaseEv, 16, .phase);

    // Phase Update: system A emits.
    try bus.emit(PhaseEv, .{ .seq = 1 });

    // Phase transition Update → PostUpdate.
    bus.drainAtBoundary(.phase);

    // Phase PostUpdate: system B subscribes + polls.
    var cur = try bus.subscribe(PhaseEv);
    try std.testing.expect((try bus.poll(PhaseEv, &cur)) == null);
}

test "events emitted in frame N are invisible in frame N+1 when lifetime=.frame" {
    const gpa = std.testing.allocator;
    var bus = EventBus.init();
    defer bus.deinit(gpa);

    try bus.register(gpa, FrameEv, 16, .frame);

    // Frame N — subscribe + emit + poll within frame.
    var cur_n = try bus.subscribe(FrameEv);
    try bus.emit(FrameEv, .{ .seq = 10 });
    const got = (try bus.poll(FrameEv, &cur_n)).?;
    try std.testing.expectEqual(@as(u32, 10), got.seq);

    // Boundary — full frame drain.
    frameDrain(&bus);

    // Frame N+1 — old cursor invalid; fresh cursor sees nothing.
    try std.testing.expectError(error.CursorInvalidated, bus.poll(FrameEv, &cur_n));
    var cur_n1 = try bus.subscribe(FrameEv);
    try std.testing.expect((try bus.poll(FrameEv, &cur_n1)) == null);
}

test "events lifetime=.phase survive within the same phase" {
    const gpa = std.testing.allocator;
    var bus = EventBus.init();
    defer bus.deinit(gpa);

    try bus.register(gpa, PhaseEv, 16, .phase);
    var cur = try bus.subscribe(PhaseEv);

    // Two systems running in the same phase Update: A emits, B
    // polls — B sees A's event because no phase transition has
    // happened.
    try bus.emit(PhaseEv, .{ .seq = 42 });
    const got = (try bus.poll(PhaseEv, &cur)).?;
    try std.testing.expectEqual(@as(u32, 42), got.seq);
    try std.testing.expect((try bus.poll(PhaseEv, &cur)) == null);
}

test "world.event_bus is wired into the scheduler dispatch path" {
    // Smoke test: a freshly initialised World carries an empty
    // EventBus, registering an event type is fine, and the bus
    // can be reached through the world reference exactly as
    // `src/core/ecs/scheduler.zig` does.
    const gpa = std.testing.allocator;
    var world = weld_core.ecs.world.World.init();
    defer world.deinit(gpa);

    try world.event_bus.register(gpa, PhaseEv, 16, .phase);
    // Subscribe before emit — the bus semantic is "subscribe
    // starts at the current head, so future emits are visible".
    var cur = try world.event_bus.subscribe(PhaseEv);
    try world.event_bus.emit(PhaseEv, .{ .seq = 99 });

    const got = (try world.event_bus.poll(PhaseEv, &cur)).?;
    try std.testing.expectEqual(@as(u32, 99), got.seq);

    // Drain via the world reference exactly as the post-E4
    // scheduler does at each phase transition.
    world.event_bus.drainAtBoundary(.phase);
    try std.testing.expectError(error.CursorInvalidated, world.event_bus.poll(PhaseEv, &cur));
}
