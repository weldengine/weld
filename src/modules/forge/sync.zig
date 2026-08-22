//! `forge/sync.zig` — ECS ↔ solver synchronisation, both directions.
//!
//! `PhysicsWorld` owns the tick and knows nothing of the ECS; this file is the seam
//! between them. **Sync-in runs before step 1 and sync-out after step 11**, so the
//! sensor pass at step 10 bis sees the poses the tick publishes, which is its stated
//! premise (`engine-physics-solver.md` §1.13.4).
//!
//! **Authority per `BodyType`, and one authority per fact.**
//!
//!   - `dynamic` — the SOLVER is the authority over the pose. A gameplay write to
//!     `Transform` on a dynamic body is overwritten at the next sync-out, and that is
//!     the contract rather than a bug: the legitimate ways to move a dynamic body are
//!     `setBodyTransform`, a force or an impulse. Making the sync detect and honour a
//!     direct write would give two authorities over one fact, which is the defect class
//!     this module refuses everywhere.
//!   - `kinematic` — GAMEPLAY is the authority over the pose. A `Transform` written by a
//!     rule is pushed in at sync-in; `moveKinematic` is what derives velocities from a
//!     target pose when the caller wants a platform a standing character inherits.
//!   - `static` — no per-tick synchronisation in either direction. A static body that
//!     moves is a teleportation through the interface, which wakes by W4.
//!
//! **A write is pushed only when it CHANGED, IN BOTH DIRECTIONS.** The rule has one motive
//! per side and neither side may skip it.
//!
//!   - INWARD, because an unchanged value is not a mutation and pushing it every tick would
//!     compose a wake every tick — nothing resting on a kinematic platform could ever sleep,
//!     and §1.8.4's whole separation would be undone by the seam meant to respect it.
//!   - OUTWARD, because `World.getMut` marks `changed_tick` UNCONDITIONALLY and the
//!     `Changed<T>` filter is built on that mark. Publishing a bit-identical value would
//!     make every awake body report a change every tick: a rule gated on
//!     `changed Velocity` would run for nothing, and `Velocity` being
//!     `@replicated(strategy: .rollback)`, the false delta leaves on the wire. The
//!     `Sleeping` marker covers the sleepers; the awake-and-immobile are the dominant case
//!     in an arena scene and the marker says nothing about them.
//!
//! Both halves read before they write. The guard on the outward half asserts the SIGNAL —
//! `changed_tick` against the world's current tick — and never the value, because the value
//! is already correct under the defect; it is the signal that lies.
//!
//! **THE ORDER OF THE `Sleeping` TAG AGAINST PUBLICATION, and why it is this way.** An
//! island falls asleep at step 11, AFTER steps 6 and 7 wrote its final pose. Sync-out
//! runs after step 11 and skips tagged bodies. Tag first and that final pose is NEVER
//! published: the entity's `Transform` keeps the pose of tick N−1 and holds it until the
//! body wakes, so the object rests at a slightly wrong place forever and jumps when
//! woken. The test that "a sleeper's pose is bit-frozen" PASSES on that defect — the pose
//! is frozen, on the wrong value — which is why the order is written here and guarded by
//! an assertion on the VALUE and not only on its immobility.
//!
//! So: the tag is REMOVED before publication and ADDED after it. Both transition ticks
//! publish — the sleeping tick publishes the last pose the solver computed, the waking
//! tick publishes the first pose it moved to — and every tick in between is skipped. The
//! mirror ordering (add before, remove after) trades the first defect for its twin on
//! wake, where the first moved pose would go unpublished.
//!
//! **What the tag buys, stated at the size the measurement supports.** `Sleeping` is what
//! lets a gameplay query step over a whole archetype of resting bodies
//! (`engine-physics-solver.md` §1.8.6) — that is the archetype-level skip
//! `engine-physics-forge.md` §1.4 credits to native ECS integration. This file itself
//! walks the SOLVER's body list, which is a SoA indexed by `BodyId` and has no archetypes;
//! the skip it delivers is to the queries downstream, not to its own loop.

const std = @import("std");
const core = @import("weld_core");
const api = @import("weld_forge");
const forge_3d = @import("forge_3d");

const World = core.ecs.World;
const EntityId = core.ecs.EntityId;
const Transform = core.ecs.components.Transform;
const Velocity = api.Velocity;
const Sleeping = api.Sleeping;
const PhysicsWorld = forge_3d.PhysicsWorld;
const Vec3r = forge_3d.Vec3r;
const Quatr = forge_3d.Quatr;
const Real = forge_3d.Real;

/// The solver pose of `body`, in the ECS `Transform`'s own layout, or null on a stale
/// handle. One conversion site, so the two representations cannot drift apart in two
/// places.
fn solverPose(pw: *const PhysicsWorld, body: api.BodyId) ?struct { pos: [3]f32, rot: [4]f32 } {
    const p = pw.bm.position(body) orelse return null;
    const r = pw.bm.rotation(body).?;
    const pa = p.toArray();
    return .{
        .pos = .{ @floatCast(pa[0]), @floatCast(pa[1]), @floatCast(pa[2]) },
        .rot = .{ @floatCast(r.x), @floatCast(r.y), @floatCast(r.z), @floatCast(r.w) },
    };
}

fn vecFrom(a: [3]f32) Vec3r {
    return Vec3r.fromArray(.{ @floatCast(a[0]), @floatCast(a[1]), @floatCast(a[2]) });
}

/// Push what gameplay owns INTO the solver — before step 1 of the cycle.
///
/// `kinematic` poses and `Velocity` writes on any simulated body, each only when it
/// differs from what the solver already holds. An entity that has lost its `Transform`,
/// or died, is skipped rather than guessed at.
pub fn syncIn(gpa: std.mem.Allocator, pw: *PhysicsWorld, ecs: *World) !void {
    for (pw.bodies.items) |entry| {
        const body = entry.id;
        const entity = pw.bm.entity(body) orelse continue;
        const body_type = pw.bm.bodyType(body).?;
        if (body_type == .static) continue; // no per-tick sync in either direction

        if (body_type == .kinematic) {
            // GAMEPLAY IS THE AUTHORITY over a kinematic pose. Pushed only on a real
            // change: an unchanged pose is not a mutation, and composing a wake for it
            // every tick would keep everything resting on the platform permanently awake.
            if (ecs.get(Transform, entity)) |t| {
                const current = solverPose(pw, body).?;
                if (!std.mem.eql(f32, &current.pos, &t.pos) or !std.mem.eql(f32, &current.rot, &t.rot)) {
                    // Through `setBodyTransform` and NOT through a hand-rolled sequence:
                    // that entry already composes the wake, W4 on the retained partners
                    // and the proxy refresh, and a second composition here would be the
                    // one that drifts.
                    try pw.setBodyTransform(gpa, body, vecFrom(t.pos), Quatr{
                        .x = @floatCast(t.rot[0]),
                        .y = @floatCast(t.rot[1]),
                        .z = @floatCast(t.rot[2]),
                        .w = @floatCast(t.rot[3]),
                    });
                }
            }
        }

        // `Velocity` written by a rule reaches the solver BEFORE step 3, so the tick that
        // follows integrates it. C1.1 requires exactly this — an Etch system can write
        // `Velocity` and the solver applies it — and the write composes wake + write like
        // any other external mutation.
        if (ecs.get(Velocity, entity)) |v| {
            const lin = pw.bm.linearVelocity(body).?.toArray();
            const ang = pw.bm.angularVelocity(body).?.toArray();
            const same_lin = @as(f32, @floatCast(lin[0])) == v.linear[0] and
                @as(f32, @floatCast(lin[1])) == v.linear[1] and
                @as(f32, @floatCast(lin[2])) == v.linear[2];
            const same_ang = @as(f32, @floatCast(ang[0])) == v.angular[0] and
                @as(f32, @floatCast(ang[1])) == v.angular[1] and
                @as(f32, @floatCast(ang[2])) == v.angular[2];
            if (!same_lin or !same_ang) {
                pw.setLinearVelocity(body, vecFrom(v.linear));
                pw.setAngularVelocity(body, vecFrom(v.angular));
            }
        }
    }
}

/// Publish what the solver owns OUT to the ECS — after step 11 of the cycle.
///
/// Three passes, and the order between them is the contract this file's header argues:
/// untag the woken, publish everything untagged, tag the newly asleep.
pub fn syncOut(gpa: std.mem.Allocator, pw: *PhysicsWorld, ecs: *World) !void {
    // (1) UNTAG THE WOKEN, BEFORE publishing — so the first pose a waking body moved to
    // is published on the very tick it moved, instead of a tick later.
    for (pw.bodies.items) |entry| {
        const entity = pw.bm.entity(entry.id) orelse continue;
        if (pw.bm.isSleeping(entry.id).?) continue;
        if (ecs.get(Sleeping, entity) == null) continue;
        try ecs.removeComponent(gpa, entity, Sleeping);
    }

    // (2) PUBLISH everything not tagged. A body that fell asleep at step 11 of THIS tick
    // is not tagged yet, so its final pose is published here — the whole reason pass (3)
    // comes after this one.
    for (pw.bodies.items) |entry| {
        const body = entry.id;
        const entity = pw.bm.entity(body) orelse continue;
        const body_type = pw.bm.bodyType(body).?;
        if (body_type == .static) continue;
        if (ecs.get(Sleeping, entity) != null) continue;

        // The POSE goes out for a DYNAMIC body only: gameplay owns a kinematic pose, and
        // publishing it back would be this seam overwriting the authority it just read.
        // READ FIRST, `getMut` ONLY ON A REAL DIFFERENCE — the symmetric half of the rule
        // sync-in applies. `World.getMut` marks `changed_tick` UNCONDITIONALLY and
        // `Changed<T>` is built on that mark, so republishing a bit-identical pose would
        // report a change that did not happen, every tick, for every awake body.
        if (body_type == .dynamic) {
            if (ecs.get(Transform, entity)) |t| {
                const pose = solverPose(pw, body).?;
                if (!std.mem.eql(f32, &t.pos, &pose.pos) or !std.mem.eql(f32, &t.rot, &pose.rot)) {
                    const w = ecs.getMut(Transform, entity).?;
                    w.pos = pose.pos;
                    w.rot = pose.rot;
                }
            }
        }

        // The VELOCITY goes out for both simulated kinds — resolved by the solver for a
        // dynamic body, derived by `moveKinematic` for a kinematic one. Same read-first
        // rule, and it is the channel that bites hardest: an immobile kinematic platform
        // held awake by a character standing on it republishes a constant zero forever, and
        // `Velocity` is `@replicated(strategy: .rollback)` — a false mark ships a delta.
        if (ecs.get(Velocity, entity)) |v| {
            const lin = pw.bm.linearVelocity(body).?.toArray();
            const ang = pw.bm.angularVelocity(body).?.toArray();
            const out_lin: [3]f32 = .{ @floatCast(lin[0]), @floatCast(lin[1]), @floatCast(lin[2]) };
            const out_ang: [3]f32 = .{ @floatCast(ang[0]), @floatCast(ang[1]), @floatCast(ang[2]) };
            if (!std.mem.eql(f32, &v.linear, &out_lin) or !std.mem.eql(f32, &v.angular, &out_ang)) {
                const w = ecs.getMut(Velocity, entity).?;
                w.linear = out_lin;
                w.angular = out_ang;
            }
        }
    }

    // (3) TAG THE NEWLY ASLEEP, AFTER publishing. From the next tick on, pass (2) skips
    // them and their `Transform` holds the last pose the solver computed.
    for (pw.bodies.items) |entry| {
        const entity = pw.bm.entity(entry.id) orelse continue;
        if (!pw.bm.isSleeping(entry.id).?) continue;
        if (ecs.get(Sleeping, entity) != null) continue;
        try ecs.addComponent(gpa, entity, Sleeping, .{});
    }
}

/// One full tick with both halves of the synchronisation around it — the shape a
/// registered system pair will drive, and the one the tests exercise so the ORDER is
/// measured rather than left to each call site to remember.
pub fn stepSynchronised(gpa: std.mem.Allocator, pw: *PhysicsWorld, ecs: *World) !void {
    try syncIn(gpa, pw, ecs);
    try pw.step(gpa);
    try syncOut(gpa, pw, ecs);
}
