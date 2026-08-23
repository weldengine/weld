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
//! **A CHARACTER PRESENCE IS SKIPPED IN BOTH DIRECTIONS, and the reason is that it shares
//! its character's ECS entity.** `character.zig` creates the presence with
//! `.entity = desc.entity`, so one entity owns two bodies and nothing in the body store
//! separates them. Walked as an ordinary body the presence corrupts BOTH directions of this
//! seam, and neither failure is exotic — it is the controller, on its central path:
//!
//!   - OUTWARD, it publishes the presence's `Velocity` — exactly zero forever, since a
//!     presence is kinematic and moved by pose write — into the character entity's
//!     `Velocity`, every tick, overwriting whatever the entity's own body published.
//!   - INWARD, a gameplay write to the character's `Transform` reads as a kinematic pose
//!     change and goes through `setBodyTransform`, which TELEPORTS the presence past
//!     `moveCharacter`'s sweep and depenetration — the two things that make a controller a
//!     controller.
//!
//! The presence is driven by `moveCharacter` and its siblings and by nothing else. The
//! distinction is carried on the registration record (`world.BodyKind`) rather than inferred
//! here, because it cannot be recovered from the entity or from the body type.
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
const CommandBuffer = core.ecs.CommandBuffer;
const Vec3r = forge_3d.Vec3r;

/// THE precision crossing — see `forge/api/precision.zig`. This file converts in both
/// directions on every tick, so it is the seam most able to grow a second conversion; it
/// spells none of its own, and `no_precision_crossing` is what enforces that.
const cross = forge_3d.cross;
const WorldReal = api.precision.WorldReal;
const WorldVec3 = api.precision.WorldVec3;
const WorldQuat = api.precision.WorldQuat;

/// The solver pose of `body`, in the ECS `Transform`'s own layout, or null on a stale
/// handle. One conversion site, so the two representations cannot drift apart in two
/// places.
fn solverPose(pw: *const PhysicsWorld, body: api.BodyId) ?struct { pos: [3]WorldReal, rot: [4]WorldReal } {
    const p = pw.bm.position(body) orelse return null;
    const r = pw.bm.rotation(body).?;
    return .{ .pos = cross.vec3ToWorld(p).toArray(), .rot = cross.quatToWorld(r).toArray() };
}

fn vecFrom(a: [3]WorldReal) Vec3r {
    return cross.vec3ToSolver(WorldVec3.fromArray(a));
}

/// The solver's two velocity columns for `body`, in world-scalar array form — the shape the
/// ECS `Velocity` carries, so the comparison and the write read the same bytes.
fn solverVelocity(pw: *const PhysicsWorld, body: api.BodyId) struct { linear: [3]WorldReal, angular: [3]WorldReal } {
    return .{
        .linear = cross.vec3ToWorld(pw.bm.linearVelocity(body).?).toArray(),
        .angular = cross.vec3ToWorld(pw.bm.angularVelocity(body).?).toArray(),
    };
}

/// Push what gameplay owns INTO the solver — before step 1 of the cycle.
///
/// `kinematic` poses and `Velocity` writes on any simulated body, each only when it
/// differs from what the solver already holds. An entity that has lost its `Transform`,
/// or died, is skipped rather than guessed at.
pub fn syncIn(gpa: std.mem.Allocator, pw: *PhysicsWorld, ecs: *World) !void {
    for (pw.bodies.items) |entry| {
        if (entry.kind == .character_presence) continue; // see the header: one entity, two bodies
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
                if (!std.mem.eql(WorldReal, &current.pos, &t.pos) or
                    !std.mem.eql(WorldReal, &current.rot, &t.rot))
                {
                    // Through `setBodyTransform` and NOT through a hand-rolled sequence:
                    // that entry already composes the wake, W4 on the retained partners
                    // and the proxy refresh, and a second composition here would be the
                    // one that drifts.
                    try pw.setBodyTransform(
                        gpa,
                        body,
                        vecFrom(t.pos),
                        cross.quatToSolver(WorldQuat.fromArray(t.rot)),
                    );
                }
            }
        }

        // `Velocity` written by a rule reaches the solver BEFORE step 3, so the tick that
        // follows integrates it. C1.1 requires exactly this — an Etch system can write
        // `Velocity` and the solver applies it — and the write composes wake + write like
        // any other external mutation.
        if (ecs.get(Velocity, entity)) |v| {
            const held = solverVelocity(pw, body);
            const same_lin = std.mem.eql(WorldReal, &held.linear, &v.linear);
            const same_ang = std.mem.eql(WorldReal, &held.angular, &v.angular);
            if (!same_lin or !same_ang) {
                pw.setLinearVelocity(body, vecFrom(v.linear));
                pw.setAngularVelocity(body, vecFrom(v.angular));
            }
        }
    }
}

/// Publish what the solver owns OUT to the ECS — after step 11 of the cycle.
///
/// `cmd` is the per-system command buffer when this runs as a registered system, and `null`
/// on the direct path. The two `Sleeping` transitions are STRUCTURAL — they migrate the
/// entity between archetypes — so inside a scheduler they must be recorded and applied at the
/// phase flush: a system in the same topological level may be iterating archetypes
/// concurrently, and a migration under it is the defect `engine-ecs-internals.md` §6 defers
/// structural changes to prevent. Nothing else in this function is structural.
///
/// Three passes, and the order between them is the contract this file's header argues:
/// untag the woken, publish everything untagged, tag the newly asleep.
pub fn syncOut(gpa: std.mem.Allocator, pw: *PhysicsWorld, ecs: *World, cmd: ?*CommandBuffer) !void {
    // (1) UNTAG THE WOKEN, BEFORE publishing — so the first pose a waking body moved to
    // is published on the very tick it moved, instead of a tick later.
    for (pw.bodies.items) |entry| {
        if (entry.kind == .character_presence) continue; // see the header: one entity, two bodies
        const entity = pw.bm.entity(entry.id) orelse continue;
        if (pw.bm.isSleeping(entry.id).?) continue;
        if (ecs.get(Sleeping, entity) == null) continue;
        if (cmd) |c| try c.removeComponent(entity, Sleeping) else try ecs.removeComponent(gpa, entity, Sleeping);
    }

    // (2) PUBLISH everything not tagged. A body that fell asleep at step 11 of THIS tick
    // is not tagged yet, so its final pose is published here — the whole reason pass (3)
    // comes after this one.
    for (pw.bodies.items) |entry| {
        if (entry.kind == .character_presence) continue; // see the header: one entity, two bodies
        const body = entry.id;
        const entity = pw.bm.entity(body) orelse continue;
        const body_type = pw.bm.bodyType(body).?;
        if (body_type == .static) continue;
        // SKIP IFF TAGGED **AND** STILL ASLEEP. The tag alone was the predicate until the
        // systems landed, and it was correct only because pass (1) removed it immediately,
        // in this same call, before this loop read it. Inside a scheduler a structural change
        // is DEFERRED to the phase flush, so that removal is no longer visible here — and the
        // tag alone would then skip a body that woke this tick, which is the waking half of
        // the very trap this file's ordering exists to avoid. Conjoining the solver's own
        // state removes the dependency on when the untag applies: a woken body still carries
        // the tag and is no longer asleep, so it publishes either way.
        //
        // The solver state alone is NOT a substitute — that is the sleeping half of the trap,
        // measured: a body that falls asleep at step 11 is asleep here and would never
        // publish its final pose.
        if (ecs.get(Sleeping, entity) != null and pw.bm.isSleeping(body).?) continue;

        // The POSE goes out for a DYNAMIC body only: gameplay owns a kinematic pose, and
        // publishing it back would be this seam overwriting the authority it just read.
        // READ FIRST, `getMut` ONLY ON A REAL DIFFERENCE — the symmetric half of the rule
        // sync-in applies. `World.getMut` marks `changed_tick` UNCONDITIONALLY and
        // `Changed<T>` is built on that mark, so republishing a bit-identical pose would
        // report a change that did not happen, every tick, for every awake body.
        if (body_type == .dynamic) {
            if (ecs.get(Transform, entity)) |t| {
                const pose = solverPose(pw, body).?;
                if (!std.mem.eql(WorldReal, &t.pos, &pose.pos) or
                    !std.mem.eql(WorldReal, &t.rot, &pose.rot))
                {
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
            const out = solverVelocity(pw, body);
            if (!std.mem.eql(WorldReal, &v.linear, &out.linear) or
                !std.mem.eql(WorldReal, &v.angular, &out.angular))
            {
                const w = ecs.getMut(Velocity, entity).?;
                w.linear = out.linear;
                w.angular = out.angular;
            }
        }
    }

    // (3) TAG THE NEWLY ASLEEP, AFTER publishing. From the next tick on, pass (2) skips
    // them and their `Transform` holds the last pose the solver computed.
    for (pw.bodies.items) |entry| {
        if (entry.kind == .character_presence) continue; // see the header: one entity, two bodies
        const entity = pw.bm.entity(entry.id) orelse continue;
        if (!pw.bm.isSleeping(entry.id).?) continue;
        if (ecs.get(Sleeping, entity) != null) continue;
        if (cmd) |c| try c.addComponent(entity, Sleeping, .{}) else try ecs.addComponent(gpa, entity, Sleeping, .{});
    }
}

/// One full tick with both halves of the synchronisation around it — the shape a
/// registered system pair will drive, and the one the tests exercise so the ORDER is
/// measured rather than left to each call site to remember.
pub fn stepSynchronised(gpa: std.mem.Allocator, pw: *PhysicsWorld, ecs: *World) !void {
    try syncIn(gpa, pw, ecs);
    try pw.step(gpa);
    try syncOut(gpa, pw, ecs, null);
}

// --- registration ------------------------------------------------------------

const SystemScheduler = core.ecs.SystemScheduler;
const SystemContext = core.ecs.SystemContext;
const Reads = core.ecs.Reads;
const Writes = core.ecs.Writes;

/// The handle the three systems reach the solver through, held as an ECS resource.
///
/// **A `SystemFn` receives only a `SystemContext`**, which carries the `World` and no channel
/// for a module's own state, so the pointer has to live somewhere the context can reach.
/// `FrameContext.user` exists and was REFUSED: it is ONE `?*anyopaque` slot shared by the
/// whole engine, so the first module to claim it wins and the second silently loses. A
/// resource keyed on this type collides with nothing by construction.
///
/// **It carries the allocator too, and that is not a convenience.** `ctx.gpa` is the
/// PER-FRAME allocator, while `refreshProxy` reaches `Broadphase.update`, which RESERVES
/// memory the broadphase keeps across ticks. Handing a frame allocator to it would free that
/// memory out from under the tree at the end of the frame.
/// Stored as three raw words rather than as typed fields, because the ECS registry builds a
/// resource's default bytes from a default-constructed value and a pointer has no meaningful
/// default. Zero means "nothing published", which `resolve` reports as absence.
pub const PhysicsWorldRef = extern struct {
    world: usize = 0,
    /// The two halves of a `std.mem.Allocator`, which is `{ ptr, vtable }`.
    alloc_ptr: usize = 0,
    alloc_vtable: usize = 0,

    fn pack(world: *PhysicsWorld, gpa: std.mem.Allocator) PhysicsWorldRef {
        return .{
            .world = @intFromPtr(world),
            .alloc_ptr = @intFromPtr(gpa.ptr),
            .alloc_vtable = @intFromPtr(gpa.vtable),
        };
    }

    fn worldPtr(self: PhysicsWorldRef) ?*PhysicsWorld {
        if (self.world == 0) return null;
        return @ptrFromInt(self.world);
    }

    fn allocator(self: PhysicsWorldRef) std.mem.Allocator {
        return .{
            .ptr = @ptrFromInt(self.alloc_ptr),
            .vtable = @ptrFromInt(self.alloc_vtable),
        };
    }
};

/// Publish `pw` into `ecs` so the registered systems can find it. Idempotent per world.
pub fn publishPhysicsWorld(gpa: std.mem.Allocator, ecs: *World, pw: *PhysicsWorld) !void {
    const id = try ecs.ensureComponentRegistered(gpa, PhysicsWorldRef);
    const ref = PhysicsWorldRef.pack(pw, gpa);
    if (ecs.resources.getMutResource(id)) |slot| {
        @memcpy(slot, std.mem.asBytes(&ref));
        return;
    }
    try ecs.addResource(gpa, id, std.mem.asBytes(&ref));
}

/// Read the published handle back, or null if nothing was published.
fn resolve(ecs: *World, gpa: std.mem.Allocator) !?PhysicsWorldRef {
    const id = try ecs.ensureComponentRegistered(gpa, PhysicsWorldRef);
    const bytes = ecs.resources.getResource(id) orelse return null;
    if (bytes.len != @sizeOf(PhysicsWorldRef)) return null;
    var ref: PhysicsWorldRef = undefined;
    // Copied out rather than pointer-cast: the resource store hands back a byte slice whose
    // alignment is the store's, not this type's.
    @memcpy(std.mem.asBytes(&ref), bytes);
    if (ref.world == 0) return null;
    return ref;
}

fn syncInSystem(ctx: SystemContext) anyerror!void {
    const ref = (try resolve(ctx.world, ctx.gpa)) orelse return;
    try syncIn(ref.allocator(), ref.worldPtr().?, ctx.world);
}

fn stepSystem(ctx: SystemContext) anyerror!void {
    const ref = (try resolve(ctx.world, ctx.gpa)) orelse return;
    try ref.worldPtr().?.step(ref.allocator());
}

fn syncOutSystem(ctx: SystemContext) anyerror!void {
    const ref = (try resolve(ctx.world, ctx.gpa)) orelse return;
    try syncOut(ref.allocator(), ref.worldPtr().?, ctx.world, ctx.cmd);
}

/// Register the three systems that drive the physics frame, in the order they must run.
///
/// **THREE AND NOT TWO, and the reading is deliberate.** The milestone's scope names the two
/// synchronisation systems "and their registration". A sync-in and a sync-out registered with
/// nothing between them would advance no simulation: it is the same defect as an unregistered
/// pair, one level down. The tick is what the two halves synchronise around, so it is
/// registered with them.
///
/// **THE ORDER COMES FROM THE PHASES, NOT FROM THE ACCESSES, and that is forced.** The DAG is
/// forward dataflow — a writer precedes its readers — and two writers of one component in one
/// phase is a `WriteWriteConflict` by construction. All three of these write the solver, so
/// no access declaration can sequence them; phases execute in enum order and do. Sync-in sits
/// in `pre_update`, the tick in `fixed_update` — which `ARCH-031` names as inside the float
/// discipline's perimeter, and which is where a fixed-timestep tick belongs — and sync-out in
/// `post_update`, after the gameplay of `update` has had the previous frame's poses.
///
/// The accesses declared are real and are what a future `ARCH-030` enforcement will check:
/// sync-in READS what gameplay owns, sync-out WRITES what the solver resolved.
pub fn registerSystems(gpa: std.mem.Allocator, sched: *SystemScheduler, ecs: *World) !void {
    try sched.registerSystem(gpa, ecs, .{
        .phase = .pre_update,
        .name = "forge_sync_in",
        .run = syncInSystem,
        .accesses = &.{ Reads(Transform), Reads(Velocity) },
    });
    try sched.registerSystem(gpa, ecs, .{
        .phase = .fixed_update,
        .name = "forge_physics_step",
        .run = stepSystem,
    });
    try sched.registerSystem(gpa, ecs, .{
        .phase = .post_update,
        .name = "forge_sync_out",
        .run = syncOutSystem,
        .accesses = &.{ Writes(Transform), Writes(Velocity) },
    });
}
