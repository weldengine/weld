//! The Forge-side translation of M1.1.13's two sensor deltas into
//! `TriggerEnter` / `TriggerExit` on the Tier 0 event bus (M1.1.15.2 G6).
//!
//! **M1.1.13 delivered the lower half by design and said so**: `forge_3d`
//! imports only `foundation/math` and `forge/api/` — a C1.1 exit metric — so the
//! solver produces an overlap STATE and two DELTAS, and the translation into
//! typed events belongs above it. This file is that upper half, and it lives in
//! `forge/` rather than in `forge_3d/` for exactly that reason.
//!
//! **The STATE stays the source of truth, never the event stream.** A Tier 0
//! queue drops its oldest entry on saturation, so an ownership set rebuilt from
//! the flow would be wrong on the first saturation — `getTriggerOverlaps` is
//! what answers "who is inside", and these events answer "what changed".
//!
//! **ONE TICK of latency, named rather than discovered.** The deltas exist only
//! after step 10 bis, and the interpreter's event sources drain at the head of a
//! tick. So a crossing that happens during tick N is observed by a rule in tick
//! N+1. There is no ordering that removes it: the producer runs after the point
//! where the consumer reads.

const std = @import("std");
const core = @import("weld_core");
const services = @import("weld_etch").services;
const forge_3d = @import("forge_3d");

const PhysicsWorld = forge_3d.PhysicsWorld;
const EventQueue = core.events.EventQueue;

/// Payload of both trigger events — an ORIENTED pair of entity identities, never
/// body handles (`engine-physics-solver.md` §1.13.8). `extern` because it crosses
/// a module boundary and its field order must be a fact.
///
/// The two identities are `u64` and not `EntityId`, which is a packed struct: the
/// event surface's scalar set carries `u64`, and a packed struct's field order is
/// a layout the emitter has no business publishing.
pub const TriggerPair = extern struct {
    /// The entity owning the trigger body.
    trigger: u64 = dead_entity,
    /// The entity it detects. Never equal to `trigger` (§1.13.8 rule 2).
    other: u64 = dead_entity,
};

/// The default of both fields, and **not `0`**: zero is a LIVE handle to slot 0
/// generation 0, the mistake `CharacterMoveResult.ground_body` made before
/// M1.1.12. The emitted declaration renders whatever this is, so a `0` here would
/// put a live handle in the `.d.etch` as the "absent" value and every reader of
/// that file would inherit it.
const dead_entity: u64 = @bitCast(core.ecs.EntityId.dead);

/// Fired the tick a pair APPEARS in the overlap set.
pub const enter_event = services.event(
    "TriggerEnter",
    "An entity entered a trigger's volume.",
    TriggerPair,
);

/// Fired the tick a pair DISAPPEARS from it. There is no `TriggerStay`: the
/// maintained state is readable at any instant through `getTriggerOverlaps`, and
/// an event per tick per maintained pair would be the bus's largest producer for
/// information already available without it (§1.13.12).
pub const exit_event = services.event(
    "TriggerExit",
    "An entity left a trigger's volume.",
    TriggerPair,
);

/// The emitted `TriggerEnter.d.etch`. Embedded, never hand-written.
pub const enter_declaration_source = @embedFile("TriggerEnter.d.etch");
/// The emitted `TriggerExit.d.etch`.
pub const exit_declaration_source = @embedFile("TriggerExit.d.etch");

/// What one publication moved.
pub const PublishResult = struct {
    entered: u32 = 0,
    exited: u32 = 0,
};

/// Translate the tick's two deltas onto the bus. Call AFTER `step`, which is
/// where the deltas come from.
///
/// The queues are the CALLER's: this file knows the shape of the payload and the
/// order of the deltas, and nothing about who consumes them.
pub fn publish(
    pw: *const PhysicsWorld,
    enter_queue: *EventQueue(TriggerPair),
    exit_queue: *EventQueue(TriggerPair),
) PublishResult {
    var r: PublishResult = .{};
    // §1.13.11's order is preserved, and it is the state's own: sorted on
    // `(trigger_entity, other_entity)` over the complete identity. Re-sorting here
    // would be a second declarant of an order the solver already fixes.
    for (pw.sensors.entered.items) |p| {
        enter_queue.enqueue(.{ .trigger = @bitCast(p.trigger), .other = @bitCast(p.other) });
        r.entered += 1;
    }
    for (pw.sensors.exited.items) |p| {
        exit_queue.enqueue(.{ .trigger = @bitCast(p.trigger), .other = @bitCast(p.other) });
        r.exited += 1;
    }
    return r;
}
