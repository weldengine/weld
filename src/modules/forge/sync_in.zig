//! The INWARD half of the ECS seam — gameplay's pose and velocity into the
//! solver (M1.1.15.2 G5b). `sync.zig` is the outward half and this file mirrors
//! its discipline rather than inventing one.
//!
//! **Authority is DECLARED, never detected**, and the model's motive is on
//! `api/authority.zig`: three earlier attempts asked who wrote a `Transform`,
//! and the ECS stores values, not authorship.
//!
//! **The matrix this file implements** (`body_type × authority`):
//!
//! | `body_type` | `authority` | `syncIn`                 | `syncOut`        | integrated |
//! |-------------|-------------|--------------------------|------------------|------------|
//! | `dynamic`   | `.solver`   | nothing                  | pose + velocity  | yes        |
//! | `dynamic`   | `.gameplay` | pose + velocity, on change | NOTHING        | yes, discarded |
//! | `kinematic` | `.solver`   | nothing                  | velocity only    | no         |
//! | `kinematic` | `.gameplay` | pose + velocity, on change | NOTHING        | no         |
//! | `static`    | either      | pose only, on change     | nothing          | no         |
//!
//! **TWO CONJOINT PREDICATES, and the conjunction is the point.** `changed_tick`
//! filters the bulk without reading any value — the question the tick answers
//! correctly. Value comparison then runs BEFORE the setter, because `getMut`
//! marks `changed_tick` unconditionally: a system that took a `getMut` and
//! changed nothing would mark, and the tick alone would wake a body for nothing.
//! Neither predicate alone is sufficient, and `sync.zig` already carries the
//! second half with its motive written out — this file mirrors it.
//!
//! **Why the wake matters so much here.** `setBodyTransform` composes the wake
//! UNCONDITIONALLY — itself, W4 on retained partners, `refreshProxy` — and the
//! velocity setters wake before writing. Without the change-driven guard every
//! `.gameplay` entity would stay awake forever and feed the broadphase for
//! nothing, which is the defect the load-bearing test of this gate pins.
//!
//! **Normative tick order**, on which the whole model depends:
//!
//! ```
//! gameplay rules and systems   (write Transform, Velocity)
//!   → syncIn                   (consume changes, mark the journal)
//!   → PhysicsModule.step
//!   → syncOut                  (publish per body_type × authority)
//! ```
//!
//! The SENSOR FOLLOWS from that order and from nothing else: `syncIn` precedes
//! `step`, so a gameplay-authored trigger is already at its new pose when the
//! sensor pass runs at step 10 bis. MEASURED rather than assumed — the test
//! moves a gameplay-authoritative trigger through the ECS and reads the overlap
//! set of the same tick.

const std = @import("std");
const core = @import("weld_core");
const api = @import("weld_forge");
const forge_3d = @import("forge_3d");
const sync = @import("sync.zig");

const World = core.ecs.World;
const EntityId = core.ecs.EntityId;
const Tick = core.ecs.Tick;
const Transform = core.ecs.components.Transform;
const Velocity = api.Velocity;
const RigidBody = api.RigidBody;
const PhysicsAuthority = api.PhysicsAuthority;
const PhysicsWorld = forge_3d.PhysicsWorld;
const cross = forge_3d.cross;
const WorldReal = api.precision.WorldReal;
const WorldVec3 = api.precision.WorldVec3;
const WorldQuat = api.precision.WorldQuat;

/// What `syncIn` remembers between ticks, one entry per body registration.
///
/// **A journal and not a cache**: it records what was CONSUMED, so a change
/// already applied is not applied twice. That is what keeps an explicit wrapper
/// call — `physics_move_kinematic`, which mirrors its own effect into the ECS —
/// from being replayed by `syncIn` in the same tick as a second, derived-free
/// application.
pub const Journal = struct {
    /// Keyed by the COMPLETE `BodyId` — index AND generation — and never by a
    /// position (M1.1.15.2 G9).
    ///
    /// **It was keyed by registration position, and `removeBody` shifts.**
    /// `PhysicsWorld.removeBody` uses `orderedRemove` deliberately — its own
    /// comment says "ordered: the sweep order stays stable" — so every body after
    /// the removed one moves down one slot and INHERITS the removed body's
    /// `consumed_tick`, `last_authority` and `seen`. Two observable corruptions
    /// follow: a FABRICATED authority transition, when the neighbour inherits a
    /// `.gameplay` that was never its own and `syncIn` reads a change of field
    /// that never happened; and a LEGITIMATE CHANGE IGNORED, when it inherits a
    /// baseline later than its own write. Silent in both directions — no assertion
    /// in the tree could see it, and none did.
    ///
    /// The generation is part of the key and not decoration: a slot is recycled
    /// LIFO, so a reissued index names a different body, and keying on the index
    /// alone would reintroduce the same inheritance through the recycling path
    /// rather than through the shift.
    ///
    /// A HASH MAP, and the determinism rule is untouched: it is only ever LOOKED
    /// UP, never iterated, so no observable order is derived from it. The iteration
    /// stays `pw.bodies.items` in registration order, which is where the order the
    /// tick depends on lives.
    entries: std.AutoHashMapUnmanaged(api.BodyId, Entry) = .empty,

    pub const Entry = struct {
        /// Tick at which an inbound change for this body was last consumed —
        /// by `syncIn` or by a wrapper that applied it itself.
        ///
        /// `null` means NEVER CONSUMED, and it is a sentinel rather than a zero
        /// for a reason a test found: `Tick` starts at 0, so a write made before
        /// the world's first `beginFrame` is stamped 0, and a `changed_tick > 0`
        /// predicate filters it out. A body that has never been consumed has no
        /// baseline to compare against, so the TICK predicate must not filter it —
        /// the VALUE predicate still does, which is why admitting it costs
        /// nothing.
        consumed_tick: ?Tick = null,
        /// The authority seen at the previous pass. A difference IS the
        /// transition, which is how the model works without the wrapper being
        /// the guardian: `authority` is a public field a rule can write
        /// directly, so the transition is detected here and performed here.
        last_authority: PhysicsAuthority = .solver,
        /// Whether `last_authority` has ever been written. Without it the first
        /// pass over a body already authored `.gameplay` would read a default
        /// `.solver` and manufacture a transition that never happened.
        seen: bool = false,
    };

    pub fn deinit(self: *Journal, gpa: std.mem.Allocator) void {
        self.entries.deinit(gpa);
    }

    fn slot(self: *Journal, gpa: std.mem.Allocator, body: api.BodyId) !*Entry {
        const gop = try self.entries.getOrPut(gpa, body);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        return gop.value_ptr;
    }

    /// The entry for `body`, or null when the journal has never seen it. Exposed
    /// for the guard that proves a neighbour inherits nothing.
    pub fn entryOf(self: *const Journal, body: api.BodyId) ?Entry {
        return self.entries.get(body);
    }

    /// Record that an inbound change for `body` was applied OUTSIDE `syncIn`, so
    /// the same tick's pass does not apply it again. The explicit call path —
    /// `physics_move_kinematic` and its siblings — calls this after mirroring
    /// into the ECS.
    pub fn markApplied(self: *Journal, gpa: std.mem.Allocator, body: api.BodyId, tick: Tick) !void {
        const e = try self.slot(gpa, body);
        e.consumed_tick = tick;
    }
};

/// What one pass consumed. Telemetry, and the load-bearing half of the guard:
/// `woke` is what a test asserts is ZERO on an unchanged gameplay body.
pub const SyncInResult = struct {
    poses_applied: u32 = 0,
    velocities_applied: u32 = 0,
    transitions: u32 = 0,
    /// Bodies this pass touched with a waking setter. The number that must stay
    /// at zero when nothing changed.
    woke: u32 = 0,
};

/// Was `T`'s slot for `entity` stamped after `since`?
///
/// Reads the SIGNAL `Changed<T>` is built on (`world.getMut` → `markChanged`)
/// and deliberately not the value — the two predicates answer different
/// questions and the second one runs later, on the value.
fn changedSince(ecs: *World, comptime T: type, entity: EntityId, since: ?Tick) bool {
    const baseline = since orelse return true; // never consumed: no baseline to filter by
    const loc = ecs.dynamicLocation(entity) orelse return false;
    const arch = ecs.dynamicArchetype(loc.archetype_idx);
    const chunk = arch.chunks.items[loc.chunk_idx];
    const cid = ecs.componentId(@typeName(T)) orelse return false;
    const col = arch.componentIndex(cid) orelse return false;
    return arch.changedTick(chunk, col, loc.slot) > baseline;
}

/// Consume gameplay's writes into the solver. Runs BEFORE `step`.
///
/// `cmd` is absent on purpose: nothing here is structural. The pass writes body
/// poses and velocities and touches no archetype.
pub fn syncIn(
    gpa: std.mem.Allocator,
    pw: *PhysicsWorld,
    ecs: *World,
    journal: *Journal,
) !SyncInResult {
    // THE SAME ELECTION AS `syncOut`, and it must be: if the two directions
    // elected different bodies, `syncOut` would publish from a body `syncIn`
    // does not drive, and one entity's pose would be read from one collider and
    // written to another. Two sources answering differently about the same
    // geometric fact are a defect, never an envelope.
    const table = try sync.electPublishers(gpa, pw);
    defer table.deinit(gpa);

    var result: SyncInResult = .{};
    const now = ecs.current_tick;

    for (pw.bodies.items, 0..) |entry, reg| {
        if (!table.publishes[reg]) continue;
        const body = entry.id;
        const entity = pw.bm.entity(body) orelse continue;
        const body_type = pw.bm.bodyType(body) orelse continue;
        const auth = sync.authorityOf(ecs, entity);
        const e = try journal.slot(gpa, body);

        // TRANSITION, detected here because `authority` is a PUBLIC field: a rule
        // writes it directly, so no wrapper can be the guardian of the invariant.
        const transitioned = e.seen and e.last_authority != auth;
        if (transitioned) result.transitions += 1;
        const to_solver = transitioned and auth == .solver;
        e.last_authority = auth;
        e.seen = true;

        // `.solver → .gameplay` SEEDS FROM THE PUBLISHED POSE and pushes nothing:
        // the ECS `Transform` already holds what `syncOut` last published, so the
        // seed is already correct and a push would be a write with no difference.
        // `.gameplay → .solver` DOES push once, so the solver resumes from where
        // gameplay left the body rather than from the state it last computed for
        // itself and had discarded ever since.
        const consume = auth == .gameplay or to_solver;
        if (!consume) continue;

        // A STATIC body takes its pose and nothing else — it has no velocity
        // columns the solver would read.
        const takes_velocity = body_type != .static;

        var applied_here = false;
        // **F8 — THE BASELINE ADVANCES ON A COMPARISON WITHOUT DIFFERENCE.** It used
        // to advance only when a value was APPLIED, so a body whose ECS and solver
        // agree — which is every `.gameplay` body from its creation until gameplay
        // first moves it — kept `consumed_tick` at `null` forever and was RE-COMPARED
        // on every tick. The tick predicate then filtered nothing at all, and the
        // guard the two-predicate design exists for was carried entirely by the value
        // comparison it was supposed to spare.
        //
        // What is recorded is that the change was CONSUMED, which examining it and
        // finding no difference is: the write that stamped `changed_tick` has been
        // looked at and answered.
        var examined = false;

        if (ecs.get(Transform, entity)) |t| {
            // PREDICATE 1 — the tick, which filters the bulk without reading a
            // value. A transition forces the read regardless: the authority
            // changed, not the pose, so nothing stamped the component.
            if (to_solver or changedSince(ecs, Transform, entity, e.consumed_tick)) {
                examined = true;
                const pose = sync.solverPose(pw, body).?;
                // PREDICATE 2 — the value, because `getMut` marks unconditionally
                // and a system that took one and changed nothing would otherwise
                // wake this body every tick forever.
                if (!std.mem.eql(WorldReal, &t.pos, &pose.pos) or
                    !std.mem.eql(WorldReal, &t.rot, &pose.rot))
                {
                    pw.setBodyTransform(
                        body,
                        cross.vec3ToSolver(WorldVec3.fromArray(t.pos)),
                        cross.quatToSolver(WorldQuat.fromArray(t.rot)),
                    );
                    result.poses_applied += 1;
                    applied_here = true;
                }
            }
        }

        if (takes_velocity) {
            if (ecs.get(Velocity, entity)) |v| {
                if (to_solver or changedSince(ecs, Velocity, entity, e.consumed_tick)) {
                    examined = true;
                    const out = sync.solverVelocity(pw, body);
                    if (!std.mem.eql(WorldReal, &v.linear, &out.linear)) {
                        pw.setLinearVelocity(body, cross.vec3ToSolver(WorldVec3.fromArray(v.linear)));
                        result.velocities_applied += 1;
                        applied_here = true;
                    }
                    if (!std.mem.eql(WorldReal, &v.angular, &out.angular)) {
                        pw.setAngularVelocity(body, cross.vec3ToSolver(WorldVec3.fromArray(v.angular)));
                        result.velocities_applied += 1;
                        applied_here = true;
                    }
                }
            }
        }

        if (applied_here) {
            // Every setter above composes a wake — `setBodyTransform`
            // unconditionally, the velocity setters before writing — so ONE
            // count covers them and it is the number the guard watches.
            result.woke += 1;
        }
        // The baseline moves on EXAMINATION, not on application. `woke` stays on
        // application, which is what the no-wake guard reads — the two counters
        // answer different questions and are deliberately not merged.
        if (examined) e.consumed_tick = now;
    }

    return result;
}
