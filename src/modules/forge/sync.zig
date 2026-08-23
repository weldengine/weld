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
//! **ONE ELECTED PUBLISHER PER ENTITY, and the reception is a separate question.**
//! `engine-physics-solver.md` §1.13.1 states that a MIXED BODY DOES NOT EXIST: an entity that
//! must both collide and detect carries TWO bodies, and §1.13.8 rule 2 restates it when it
//! drops the reflexive pair, "without which an entity carrying a trigger body and a solid
//! body would detect itself". Two bodies on one entity is the normal shape here, and the
//! descriptor admits every combination — two solids and two triggers included — so the seam
//! must answer WHICH ONE speaks for the entity, for every combination and not just the
//! documented one.
//!
//! `electedPublisher` answers it with one criterion at two levels, and everything else in
//! this file's outward direction defers to it. An earlier version excluded triggers outright
//! and was WRONG TWICE OVER: §1.13.7 denies a trigger a manifold, a constraint, an impulse and
//! an island entry, and says nothing about INTEGRATION — `integration.zig` filters on body
//! type alone, so a `.dynamic` trigger falls under gravity and its pose IS a resolved fact —
//! and an exclusion arbitrates only solid-against-trigger, leaving two triggers or two solids
//! in silent last-write-wins. **Do not reintroduce a blanket skip here**: it is what this
//! election replaced, and the reasons above are why.
//!
//! RECEPTION is governed by TYPE and by nothing else: a kinematic pose belongs to gameplay
//! whether the body is a trigger or not, and a trigger that does not follow its entity
//! detects the wrong region. The character presence is the one registration excluded from
//! BOTH directions, for the reason stated above.
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

/// Whether `entity`'s `T` was stamped changed AFTER `since`.
///
/// **This is the exact question, not a heuristic.** `World.getMut` stamps `changed_tick`
/// unconditionally, and the outward direction of this file never calls it for a component it
/// does not own — a kinematic `Transform` is gameplay's and physics never publishes it. So
/// the stamp on such a component moves if and only if gameplay wrote it.
fn changedSince(ecs: *World, comptime T: type, entity: EntityId, since: u64) bool {
    const cid = ecs.componentId(@typeName(T)) orelse return false;
    const loc = ecs.dynamicLocation(entity) orelse return false;
    const arch = ecs.dynamicArchetype(loc.archetype_idx);
    const col = arch.componentIndex(cid) orelse return false;
    const chunk = arch.chunks.items[loc.chunk_idx];
    // `>=` AND NOT `>`, and the boundary case is the normal one. Sync-in runs in `pre_update`
    // and records the tick it ran at; a gameplay write in `update` of that SAME frame carries
    // that same tick number while being strictly later in time. A strict comparison drops it
    // for good — measured: the C1.1 write from an `update` system never reached the solver.
    // Re-pushing a value the publication wrote at the same tick is harmless, because the value
    // comparison below still has to find a difference before anything is written.
    return @as(u64, arch.changedTick(chunk, col, loc.slot)) >= since;
}

/// The ONE body that publishes on `entity`'s behalf, or null if none may.
///
/// **An ELECTION and not an exclusion, because exclusion only covered the normative case.**
/// Yielding "when a solid body exists" arbitrates solid + trigger and nothing else: two
/// triggers on one entity do not arbitrate each other, and two solids never enter the
/// arbitration at all. `BodyDescriptor` admits both, so both are legal configurations, and
/// under exclusion both were silent last-write-wins — which `engine-physics-solver.md`
/// §1.13.6 refuses in as many words.
///
/// ONE criterion at TWO levels: the non-trigger body of smallest identity if one exists,
/// otherwise the trigger of smallest identity. A character presence is never eligible — it is
/// the controller's inner body and answers for nobody.
///
/// **Identity is the COMPLETE handle**, index and generation together, exactly as §1.13.11's
/// ordering key is. That is what makes the election independent of insertion order, hence
/// deterministic: rebuilding the same scene in a different sequence elects the same body.
fn electedPublisher(pw: *const PhysicsWorld, entity: EntityId) ?api.BodyId {
    var best_solid: ?api.BodyId = null;
    var best_trigger: ?api.BodyId = null;
    for (pw.bodies.items) |other| {
        if (other.kind != .rigid_body) continue; // a presence answers for nobody
        const owner = pw.bm.entity(other.id) orelse continue;
        if (owner.index != entity.index or owner.generation != entity.generation) continue;
        if (pw.bm.isTrigger(other.id) orelse false) {
            if (best_trigger == null or other.id < best_trigger.?) best_trigger = other.id;
        } else {
            if (best_solid == null or other.id < best_solid.?) best_solid = other.id;
        }
    }
    return best_solid orelse best_trigger;
}

/// Whether this registration is the entity's elected publisher.
fn publishes(pw: *const PhysicsWorld, entry: forge_3d.BodyProxy, entity: EntityId) bool {
    const elected = electedPublisher(pw, entity) orelse return false;
    return elected == entry.id;
}

/// Push what gameplay owns INTO the solver — before step 1 of the cycle.
///
/// `kinematic` poses and `Velocity` writes on any simulated body, each only when it
/// differs from what the solver already holds. An entity that has lost its `Transform`,
/// or died, is skipped rather than guessed at.
pub fn syncIn(gpa: std.mem.Allocator, pw: *PhysicsWorld, ecs: *World) !void {
    // THE WATERMARK, and without it this direction UNDOES the other entries of the module.
    // `moveKinematic` writes the pose and both velocities into the SOLVER; the ECS `Transform`
    // is untouched, because gameplay owns a kinematic pose and physics never publishes it. A
    // value comparison then reads "they differ" and pushes the STALE ECS pose back through
    // `setBodyTransform`, cancelling the move before the step — and the same for the velocity
    // setters and for teleporting a kinematic. Comparing VALUES cannot tell "gameplay wrote"
    // from "the solver moved"; the change stamp can, and it is exact here (see
    // `changedSince`). This is F-D1's rule in the other direction: push only what was written.
    const ref = resolve(ecs) orelse return error.PhysicsWorldNotPublished;
    const since = ref.last_in_tick;
    defer recordSyncInTick(ecs, ecs.current_tick);

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
                if (!changedSince(ecs, Transform, entity, since)) continue;
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
            if (!changedSince(ecs, Velocity, entity, since)) continue;
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
        const entity = pw.bm.entity(entry.id) orelse continue;
        if (!publishes(pw, entry, entity)) continue;
        if (pw.bm.isSleeping(entry.id).?) continue;
        if (ecs.get(Sleeping, entity) == null) continue;
        if (cmd) |c| try c.removeComponent(entity, Sleeping) else try ecs.removeComponent(gpa, entity, Sleeping);
    }

    // (2) PUBLISH everything not tagged. A body that fell asleep at step 11 of THIS tick
    // is not tagged yet, so its final pose is published here — the whole reason pass (3)
    // comes after this one.
    for (pw.bodies.items) |entry| {
        const body = entry.id;
        const entity = pw.bm.entity(body) orelse continue;
        if (!publishes(pw, entry, entity)) continue;
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
        const entity = pw.bm.entity(entry.id) orelse continue;
        if (!publishes(pw, entry, entity)) continue;
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
const WritesResource = core.ecs.WritesResource;

/// The handle the registered systems reach the solver through, held as an ECS resource.
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
    /// The ECS tick at which sync-in last ran. A component whose `changed_tick` is at or
    /// below this was not written by gameplay since, so pushing it would be pushing back a
    /// value the solver has already moved past.
    last_in_tick: u64 = 0,

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
///
/// **A PURE LOOKUP, and that is the point.** The first version obtained the id by REGISTERING
/// the type here, on `ctx.gpa` — the FRAME allocator — and a registration keeps the type's
/// name for the world's whole life. A frame allocator handing out memory the registry retains
/// is the same defect this file avoids one level up, arriving through the lookup instead of
/// through the physics. `componentId` resolves an already-registered name and allocates
/// nothing; a world where nothing was published has no such name, which is absence and not
/// failure. `publishPhysicsWorld` is the only site that registers, and it takes the
/// persistent allocator.
fn resolve(ecs: *World) ?PhysicsWorldRef {
    const id = ecs.componentId(@typeName(PhysicsWorldRef)) orelse return null;
    const bytes = ecs.resources.getResource(id) orelse return null;
    if (bytes.len != @sizeOf(PhysicsWorldRef)) return null;
    var ref: PhysicsWorldRef = undefined;
    // Copied out rather than pointer-cast: the resource store hands back a byte slice whose
    // alignment is the store's, not this type's.
    @memcpy(std.mem.asBytes(&ref), bytes);
    if (ref.world == 0) return null;
    return ref;
}

/// Advance the sync-in watermark. Written through the resource because that is the ONE
/// storage both call paths share — a second copy for the direct path is a second thing to
/// drift.
fn recordSyncInTick(ecs: *World, tick: u32) void {
    const id = ecs.componentId(@typeName(PhysicsWorldRef)) orelse return;
    const slot = ecs.resources.getMutResource(id) orelse return;
    if (slot.len != @sizeOf(PhysicsWorldRef)) return;
    var ref: PhysicsWorldRef = undefined;
    @memcpy(std.mem.asBytes(&ref), slot);
    ref.last_in_tick = tick;
    @memcpy(slot, std.mem.asBytes(&ref));
}

/// Whether a physics world has been published into `ecs` — so a caller can assert its wiring
/// instead of discovering its absence as a frame that silently did nothing.
pub fn hasPhysicsWorld(ecs: *World) bool {
    return resolve(ecs) != null;
}

fn syncInSystem(ctx: SystemContext) anyerror!void {
    const ref = resolve(ctx.world) orelse return;
    try syncIn(ref.allocator(), ref.worldPtr().?, ctx.world);
}

/// The tick AND the publication, in ONE system, and the merge is the fix rather than a tidy.
///
/// **They were two systems, and a gameplay write to `Velocity` was lost between them.** The
/// phases run `pre_update → fixed_update → update → post_update`. A rule writing `Velocity`
/// in `update` writes it AFTER sync-in has read it, and a publication in `post_update`
/// overwrote it before the next frame's sync-in could see it — so the write never reached the
/// solver at all, while C1.1 requires in as many words that an Etch system can write
/// `Velocity` and the solver apply it.
///
/// **An intra-phase ordering constraint cannot fix it**, and that is a property of the
/// scheduler and not a gap in it: there is no `runs_before` / `runs_after`, and the only
/// intra-phase order is the `Writes(X) → Reads(X)` edge. Giving the tick a declared access
/// purely to manufacture that edge would make the declared set a lie, and `ARCH-030` makes
/// the declared set the TYPE of the view a system receives — the fabricated access would be
/// the defect and not the fix. Merging moves the order out of the scheduler and into code,
/// where it is a line and not a graph property. The sequence then holds: `update` observes
/// the poses of the tick that just ran, and its writes survive to the next `pre_update`.
fn stepAndPublishSystem(ctx: SystemContext) anyerror!void {
    const ref = resolve(ctx.world) orelse return;
    try ref.worldPtr().?.step(ref.allocator());
    try syncOut(ref.allocator(), ref.worldPtr().?, ctx.world, ctx.cmd);
}

const sync_in_name = "forge_sync_in";
const step_name = "forge_step_and_publish";

/// The two access sets, as FILE-SCOPE constants and not as `&.{ ... }` temporaries inside
/// `registerSystems`.
///
/// **This is a defect fixed, not a style choice, and it was measured.** A `&.{ ... }` literal
/// in the struct passed to `registerSystem` is a temporary whose lifetime ends with the
/// enclosing block. `SystemScheduler` stores the descriptor — slice included — so once
/// `registerSystems` returns, every `type_name` in it points at dead stack: reading them
/// printed an empty string and then took a FAULT. Nothing crashed earlier because the DAG
/// edges are computed AT registration and no later path reads the accesses; the first thing
/// that did was the test asserting they are declared. The tree's other call sites survive by
/// accident — they register inside the same function that consumes the scheduler — so the API
/// invites this, and the safe form is the one that does not depend on where the caller lives.
const sync_in_accesses = [_]core.ecs.AccessDescriptor{
    Reads(Transform),
    Reads(Velocity),
    WritesResource(PhysicsWorldRef),
};
const step_accesses = [_]core.ecs.AccessDescriptor{
    Writes(Transform),
    Writes(Velocity),
    WritesResource(PhysicsWorldRef),
};

fn isRegistered(sched: *const SystemScheduler, phase: core.ecs.Phase, wanted: []const u8) bool {
    for (sched.systemsInPhase(phase)) |d| {
        if (std.mem.eql(u8, d.name, wanted)) return true;
    }
    return false;
}

/// Whether any write in `accesses` already has a writer in `phase`.
///
/// **The preflight checks DESCRIPTORS and not just names, because that is the failure that
/// actually happens.** A `WriteWriteConflict` is ordinary and deterministic — some other
/// system already writes `Transform` in `fixed_update` — and checking only for a duplicate
/// name would let the first registration land and the second be refused, which is the partial
/// state the preflight exists to prevent. Matched on `type_name`, which is what
/// `registerSystem` itself reports the conflict on.
fn wouldConflict(
    sched: *const SystemScheduler,
    phase: core.ecs.Phase,
    accesses: []const core.ecs.AccessDescriptor,
) bool {
    for (accesses) |mine| {
        if (mine.kind != .writes and mine.kind != .writes_resource) continue;
        for (sched.systemsInPhase(phase)) |d| {
            for (d.accesses) |theirs| {
                if (theirs.kind != .writes and theirs.kind != .writes_resource) continue;
                if (std.mem.eql(u8, theirs.type_name, mine.type_name)) return true;
            }
        }
    }
    return false;
}

/// Register the two systems that drive the physics frame.
///
/// **TWO, with the publication riding the tick** — `stepAndPublishSystem` carries why three
/// was wrong. `pre_update` takes what gameplay owns into the solver; `fixed_update` advances
/// the tick and publishes what the solver resolved, and that is the phase `ARCH-031` names as
/// inside the float discipline's perimeter and where a fixed-timestep tick belongs. Each
/// system's declared accesses are exactly what it does, which is what a future `ARCH-030`
/// enforcement will check.
///
/// **PREFLIGHT AND NOT IDEMPOTENCE, because of which failure is real.** Calling this twice on
/// one scheduler is the failure a caller can actually produce, and it is deterministic: both
/// names are checked absent from their phases BEFORE the first registration, so a second call
/// mutates nothing and reports `error.SystemAlreadyRegistered`. Idempotence would accept it
/// in silence, which hides a double wiring rather than naming it — and a partial state is
/// exactly what this check exists to prevent.
///
/// BOTH DESCRIPTORS are preflighted, names and write conflicts alike, before the first
/// registration touches the scheduler — a `WriteWriteConflict` is an ordinary deterministic
/// failure and not a residual, so leaving it to land halfway through would be the partial
/// state this check exists to prevent.
///
/// RESIDUAL, stated rather than hidden: an ALLOCATION failure between the two registrations
/// leaves the first standing, because `SystemScheduler` exposes no removal. Closing that needs
/// a scheduler change and not a change here — the same Tier 0 gap the Closing notes name.
pub fn registerSystems(gpa: std.mem.Allocator, sched: *SystemScheduler, ecs: *World) !void {
    if (isRegistered(sched, .pre_update, sync_in_name)) return error.SystemAlreadyRegistered;
    if (isRegistered(sched, .fixed_update, step_name)) return error.SystemAlreadyRegistered;
    if (wouldConflict(sched, .pre_update, &sync_in_accesses)) return error.WriteWriteConflict;
    if (wouldConflict(sched, .fixed_update, &step_accesses)) return error.WriteWriteConflict;

    try sched.registerSystem(gpa, ecs, .{
        .phase = .pre_update,
        .name = sync_in_name,
        .run = syncInSystem,
        .accesses = &sync_in_accesses,
    });
    try sched.registerSystem(gpa, ecs, .{
        .phase = .fixed_update,
        .name = step_name,
        .run = stepAndPublishSystem,
        .accesses = &step_accesses,
    });
}
