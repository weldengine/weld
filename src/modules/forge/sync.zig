//! `forge/sync.zig` — the solver → ECS publication.
//!
//! `PhysicsWorld` owns the tick and knows nothing of the ECS; this file is the seam between
//! them. **It publishes AFTER step 11**, so what reaches an entity is the pose the tick
//! resolved and never an intermediate one.
//!
//! **THE INWARD DIRECTION IS NOT HERE, and its absence is a decision.** ECS → solver — the
//! `Transform` and `Velocity` a rule writes reaching the solver — belongs to **M1.1.26**, with
//! the Tier 1 Etch service. The reason is a property of the ECS: the tick says WHEN a write
//! happened and never WHO produced it, and no comparison of change stamps can manufacture
//! that. A solver-side provenance does not close it either, since `moveKinematic` moves a
//! kinematic body whose pose this file deliberately does not publish — gameplay being its
//! authority — so the ECS copy would stay stale and the entity would render at the old pose.
//! Authority by `BodyType` cannot tell a kinematic driven by its component from one driven by
//! the API, and both are legal. The service is the first place that sees both paths.
//!
//! **What is published, per `BodyType`.**
//!
//!   - `dynamic` — the SOLVER is the authority over the pose, so the pose goes out. A gameplay
//!     write to `Transform` on a dynamic body is overwritten, and that is the contract rather
//!     than a bug: the legitimate ways to move one are `setBodyTransform`, a force or an
//!     impulse.
//!   - `kinematic` — GAMEPLAY owns the pose, so the pose is NOT written back; the velocity is,
//!     because `moveKinematic` derives it and a character standing on the platform reads it.
//!   - `static` — nothing is published. A static body that moves is a teleportation through
//!     the interface, which wakes by W4.
//!
//! **A value is written only when it CHANGED.** `World.getMut` marks `changed_tick`
//! UNCONDITIONALLY and the `Changed<T>` filter is built on that mark, so republishing a
//! bit-identical value would make every awake body report a change every tick: a rule gated on
//! `changed Velocity` would run for nothing, and `Velocity` being
//! `@replicated(strategy: .rollback)`, the false delta leaves on the wire. The `Sleeping`
//! marker covers the sleepers; the awake-and-immobile are the dominant case in an arena scene
//! and the marker says nothing about them. The guard asserts the SIGNAL — `changed_tick`
//! against the world's current tick — and never the value, because the value is already
//! correct under the defect; it is the signal that lies.
//!
//! **THE ORDER OF THE `Sleeping` MARKER AGAINST PUBLICATION, and why it is this way.** An
//! island falls asleep at step 11, AFTER steps 6 and 7 wrote its final pose, and this pass
//! runs after step 11 and skips marked bodies. Mark first and that final pose is NEVER
//! published: the entity keeps the pose of tick N−1 and holds it until the body wakes, so the
//! object rests at a slightly wrong place forever and jumps when woken. A test that only
//! checks "a sleeper's pose is bit-frozen" PASSES on that defect — the pose is frozen, on the
//! wrong value — which is why the order is written here and guarded by an assertion on the
//! VALUE. So: the marker is REMOVED before publication and ADDED after it. Both transition
//! ticks publish, and every tick in between is skipped.
//!
//! **A CHARACTER PRESENCE IS NEVER A PUBLISHER**, because it shares its character's ECS
//! entity: `character.zig` creates it with `.entity = desc.entity`, so one entity owns two
//! bodies and nothing in the body store separates them. Walked as an ordinary body it would
//! publish its own velocity — exactly zero forever, a presence being kinematic and moved by
//! pose write — over the entity's own, every tick. It is driven by `moveCharacter` and its
//! siblings and by nothing else. The distinction is carried on the registration record
//! (`world.BodyKind`) rather than inferred here, because it cannot be recovered from the
//! entity or from the body type.
//!
//! **ONE ELECTED PUBLISHER PER ENTITY.**
//! `engine-physics-solver.md` §1.13.1 states that a MIXED BODY DOES NOT EXIST: an entity that
//! must both collide and detect carries TWO bodies, and §1.13.8 rule 2 restates it when it
//! drops the reflexive pair, "without which an entity carrying a trigger body and a solid
//! body would detect itself". Two bodies on one entity is the normal shape here, and the
//! descriptor admits every combination — two solids and two triggers included — so the seam
//! must answer WHICH ONE speaks for the entity, for every combination and not just the
//! documented one.
//!
//! `electPublishers` answers it with one criterion at two levels, and everything else in this
//! file's outward direction defers to it. An earlier version excluded triggers outright and
//! was WRONG TWICE OVER.
//!
//! First, on the corpus. §1.13.7 denies a trigger a manifold, a constraint and an impulse, and
//! the amended text distinguishes TWO kinds of island entry: a CONSTRAINT island, which a
//! trigger cannot enter by construction since no pair reaches it, and an INTEGRATION
//! SINGLETON, which it enters explicitly — the singleton comes from the enumeration of
//! dynamic bodies and not from any pair, and without one a dynamic trigger could never sleep
//! and would be integrated forever. So a `.dynamic` trigger falls under gravity and its pose
//! IS a fact the solver resolved. An earlier version of this comment read the exclusion as
//! total and was corrected with the corpus.
//!
//! Second, on the arbitration itself: excluding triggers arbitrates only
//! solid-against-trigger, leaving two triggers or two solids in silent last-write-wins.
//! **Do not reintroduce a blanket skip here**: it is what this election replaced, and both
//! reasons above are why.
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

/// THE precision crossing — see `forge/api/precision.zig`. This file narrows solver values to
/// the world scalar on every tick, so it is the seam most able to grow a second conversion; it
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

/// The solver's two velocity columns for `body`, in world-scalar array form — the shape the
/// ECS `Velocity` carries, so the comparison and the write read the same bytes.
fn solverVelocity(pw: *const PhysicsWorld, body: api.BodyId) struct { linear: [3]WorldReal, angular: [3]WorldReal } {
    return .{
        .linear = cross.vec3ToWorld(pw.bm.linearVelocity(body).?).toArray(),
        .angular = cross.vec3ToWorld(pw.bm.angularVelocity(body).?).toArray(),
    };
}

/// Which registrations publish, decided ONCE per tick.
///
/// **A PRE-PASS, because the per-body form was quadratic.** The first version asked
/// "who is my entity's publisher?" from inside each of the three publication passes, and each
/// answer swept the whole registration list: 3·N² comparisons, 363 million of them at C1.1's
/// 11 000 bodies, paid in full by a scene with no trigger and no multi-body entity at all.
/// The question is per ENTITY and its answer does not change during a tick, so it is answered
/// once.
///
/// **Deterministic and without a hashed container.** Candidates are sorted on the composite
/// key `(entity, is_trigger, body)` — total, since body handles are unique — and the FIRST
/// entry of each entity run wins: `is_trigger = false` sorts ahead, so the run's head is the
/// non-trigger of smallest identity when one exists and the trigger of smallest identity
/// otherwise. That is `electedPublisher`'s two-level criterion expressed as an ordering.
/// §1.13.11's discipline governs anything that could become a compared path, and a sort
/// answers it at no extra cost.
const PublisherTable = struct {
    /// One flag per registration, in registration order.
    publishes: []bool,

    fn deinit(self: PublisherTable, gpa: std.mem.Allocator) void {
        gpa.free(self.publishes);
    }
};

const Candidate = struct {
    entity: u64,
    /// `0` for a solid body, `1` for a trigger — the second level of the criterion, carried
    /// in the sort key rather than in a branch.
    trigger: u8,
    body: api.BodyId,
    registration: u32,

    fn lessThan(_: void, a: Candidate, b: Candidate) bool {
        if (a.entity != b.entity) return a.entity < b.entity;
        if (a.trigger != b.trigger) return a.trigger < b.trigger;
        return a.body < b.body;
    }
};

/// Build the table. A character presence is never a candidate — it is the controller's inner
/// body and answers for nobody.
fn electPublishers(gpa: std.mem.Allocator, pw: *const PhysicsWorld) !PublisherTable {
    const n = pw.bodies.items.len;
    const flags = try gpa.alloc(bool, n);
    errdefer gpa.free(flags);
    @memset(flags, false);
    if (n == 0) return .{ .publishes = flags };

    const cands = try gpa.alloc(Candidate, n);
    defer gpa.free(cands);

    var count: usize = 0;
    for (pw.bodies.items, 0..) |entry, reg| {
        if (entry.kind != .rigid_body) continue;
        const owner = pw.bm.entity(entry.id) orelse continue;
        cands[count] = .{
            // Index AND generation, as §1.13.11's ordering key is: the complete identity, so
            // a recycled slot never inherits the previous entity's election.
            .entity = (@as(u64, owner.generation) << 32) | owner.index,
            .trigger = if (pw.bm.isTrigger(entry.id) orelse false) 1 else 0,
            .body = entry.id,
            .registration = @intCast(reg),
        };
        count += 1;
    }
    const live = cands[0..count];
    std.mem.sort(Candidate, live, {}, Candidate.lessThan);

    var i: usize = 0;
    while (i < live.len) {
        flags[live[i].registration] = true; // head of the run: the elected body
        const key = live[i].entity;
        i += 1;
        while (i < live.len and live[i].entity == key) i += 1;
    }
    return .{ .publishes = flags };
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
    const table = try electPublishers(gpa, pw);
    defer table.deinit(gpa);

    // (1) UNTAG THE WOKEN, BEFORE publishing — so the first pose a waking body moved to
    // is published on the very tick it moved, instead of a tick later.
    for (pw.bodies.items, 0..) |entry, reg| {
        if (!table.publishes[reg]) continue;
        const entity = pw.bm.entity(entry.id) orelse continue;
        if (pw.bm.isSleeping(entry.id).?) continue;
        if (ecs.get(Sleeping, entity) == null) continue;
        if (cmd) |c| try c.removeComponent(entity, Sleeping) else try ecs.removeComponent(gpa, entity, Sleeping);
    }

    // (2) PUBLISH everything not tagged. A body that fell asleep at step 11 of THIS tick
    // is not tagged yet, so its final pose is published here — the whole reason pass (3)
    // comes after this one.
    for (pw.bodies.items, 0..) |entry, reg| {
        if (!table.publishes[reg]) continue;
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
        // READ FIRST, `getMut` ONLY ON A REAL DIFFERENCE. `World.getMut` marks
        // `changed_tick` UNCONDITIONALLY and
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
    for (pw.bodies.items, 0..) |entry, reg| {
        if (!table.publishes[reg]) continue;
        const entity = pw.bm.entity(entry.id) orelse continue;
        if (!pw.bm.isSleeping(entry.id).?) continue;
        if (ecs.get(Sleeping, entity) != null) continue;
        if (cmd) |c| try c.addComponent(entity, Sleeping, .{}) else try ecs.addComponent(gpa, entity, Sleeping, .{});
    }
}

/// One full tick followed by its publication — the shape the registered system drives, and
/// the one the tests exercise so the order is measured rather than left to each call site to
/// remember. There is no inward half here any more: see the header.
pub fn stepAndPublish(gpa: std.mem.Allocator, pw: *PhysicsWorld, ecs: *World) !void {
    try pw.step(gpa);
    try syncOut(gpa, pw, ecs, null);
}

// --- registration ------------------------------------------------------------

const SystemScheduler = core.ecs.SystemScheduler;
const SystemContext = core.ecs.SystemContext;
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

/// Withdraw the published handle. The SYMMETRIC half of `publishPhysicsWorld`, and the caller
/// that published is the one that withdraws.
///
/// **Without it the resource outlives the world it names.** `publishPhysicsWorld` writes raw
/// pointers, `PhysicsWorld.deinit` frees and poisons, and nothing clears the resource —
/// `hasPhysicsWorld` kept answering true and the next dispatch dereferenced a dead address.
/// That the runtime's ordinary order happens to be safe changes nothing: a lifetime contract
/// nothing enforces is not a contract, and this is the same shape as `removeBody` accepting a
/// character presence — two operations each correct, whose sequence breaks.
///
/// The handle is ZEROED rather than the resource removed: `resolve` already reads zero as
/// absence, the slot keeps its registered id so a later `publishPhysicsWorld` reuses it, and
/// nothing has to be freed on a path a caller may run during teardown. `PhysicsWorld` still
/// knows nothing of the ECS, which is the invariant this seam has held since it was written.
pub fn unpublishPhysicsWorld(ecs: *World) void {
    const id = ecs.componentId(@typeName(PhysicsWorldRef)) orelse return;
    const slot = ecs.resources.getMutResource(id) orelse return;
    if (slot.len != @sizeOf(PhysicsWorldRef)) return;
    const cleared = PhysicsWorldRef{};
    @memcpy(slot, std.mem.asBytes(&cleared));
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

/// Whether a physics world has been published into `ecs` — so a caller can assert its wiring
/// instead of discovering its absence as a frame that silently did nothing.
pub fn hasPhysicsWorld(ecs: *World) bool {
    return resolve(ecs) != null;
}

/// The tick AND the publication, in ONE system, and the merge is the fix rather than a tidy.
///
/// **The publication rides the tick rather than sitting in a later phase.** With the two
/// separate — the tick in `fixed_update`, the publication in `post_update` — `update` would
/// observe the poses of the PREVIOUS tick, a frame of latency nothing asks for. The merge is
/// also what removed a defect the inward direction used to suffer, before that direction left
/// for M1.1.26: a `Velocity` written in `update` was overwritten by a later publication before
/// anything could read it.
///
/// **An intra-phase ordering constraint cannot fix it**, and that is a property of the
/// scheduler and not a gap in it: there is no `runs_before` / `runs_after`, and the only
/// intra-phase order is the `Writes(X) → Reads(X)` edge. Giving the tick a declared access
/// purely to manufacture that edge would make the declared set a lie, and `ARCH-030` makes
/// the declared set the TYPE of the view a system receives — the fabricated access would be
/// the defect and not the fix. Merging moves the order out of the scheduler and into code,
/// where it is a line and not a graph property. The sequence then holds: `update` observes the
/// poses of the tick that just ran.
fn stepAndPublishSystem(ctx: SystemContext) anyerror!void {
    const ref = resolve(ctx.world) orelse return;
    try ref.worldPtr().?.step(ref.allocator());
    try syncOut(ref.allocator(), ref.worldPtr().?, ctx.world, ctx.cmd);
}

const step_name = "forge_step_and_publish";

/// The system's access set, as a FILE-SCOPE constant and not as a `&.{ ... }` temporary inside
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
/// It was two sets when the seam registered two systems; it is one now, and the reason to keep
/// it at file scope is unchanged.
const step_accesses = [_]core.ecs.AccessDescriptor{
    Writes(Transform),
    Writes(Velocity),
    // The `Sleeping` transitions are STRUCTURAL — they migrate the entity between archetypes —
    // so `Writes` is the closest the access model can express, not a description of the effect.
    Writes(Sleeping),
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

/// Register the ONE system that drives the physics frame.
///
/// `fixed_update` advances the tick and publishes what the solver resolved — the phase
/// `ARCH-031` names as inside the float discipline's perimeter, and where a fixed-timestep
/// tick belongs. The publication rides the tick rather than sitting in a later phase, so
/// `update` observes the poses of the tick that just ran instead of the previous one. The
/// ECS → solver direction is M1.1.26's and registers nothing here.
///
/// The declared accesses are exactly what the system does, which is what a future `ARCH-030`
/// enforcement will check — `Transform`, `Velocity` and the `Sleeping` marker it migrates,
/// plus the solver resource it mutates through the published pointer. Undeclared, two physics
/// modules could sit in one phase with no edge between them and the enforcement would have
/// nothing to catch them on.
///
/// **PREFLIGHT AND NOT IDEMPOTENCE, because of which failure is real.** Calling this twice on
/// one scheduler is the failure a caller can actually produce, and it is deterministic: the
/// name and the write conflicts are checked BEFORE the registration, so a second call mutates
/// nothing and reports `error.SystemAlreadyRegistered`. Idempotence would accept it in
/// silence, hiding a double wiring rather than naming it.
///
/// **The preflight covers the DETERMINISTIC failures — the name and the write conflicts — and
/// covers OOM not at all.** `registerSystem` appends edges and several tracker entries before
/// any allocation can fail, and its `errdefer`s do not undo all of them: after an allocation
/// failure the scheduler must be treated as UNUSABLE, and a retry can report
/// `WriteWriteConflict` against a `systemCount()` of zero. Moving to one system removed the
/// residual BETWEEN two calls and nothing inside one. The real fix is that `registerSystem` be
/// TRANSACTIONAL FOR ITSELF — a Tier 0 debt recorded in `engine-ecs-internals.md`, and a
/// different one from the absence of a group removal recorded beside it. Promising an absence
/// of residue that no mechanism holds would be worse than saying nothing, because it excuses
/// the next reader from checking.
pub fn registerSystems(gpa: std.mem.Allocator, sched: *SystemScheduler, ecs: *World) !void {
    if (isRegistered(sched, .fixed_update, step_name)) return error.SystemAlreadyRegistered;
    if (wouldConflict(sched, .fixed_update, &step_accesses)) return error.WriteWriteConflict;

    try sched.registerSystem(gpa, ecs, .{
        .phase = .fixed_update,
        .name = step_name,
        .run = stepAndPublishSystem,
        .accesses = &step_accesses,
    });
}
