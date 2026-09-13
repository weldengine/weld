//! `forge/sync.zig` — the solver → ECS publication.
//!
//! `PhysicsWorld` owns the tick and knows nothing of the ECS; this file is the seam between
//! them. **It publishes AFTER step 11**, so what reaches an entity is the pose the tick
//! resolved and never an intermediate one.
//!
//! **THE INWARD DIRECTION IS NOT HERE, and its absence is a decision.** ECS → solver — the
//! `Transform` and `Velocity` a rule writes reaching the solver — belongs with the Tier 1
//! Etch service. The reason is a property of the ECS: the tick says WHEN a write
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
//! file's outward direction defers to it. Excluding triggers outright would be WRONG
//! TWICE OVER.
//!
//! First, on the corpus. §1.13.7 denies a trigger a manifold, a constraint and an impulse, and
//! the amended text distinguishes TWO kinds of island entry: a CONSTRAINT island, which a
//! trigger cannot enter by construction since no pair reaches it, and an INTEGRATION
//! SINGLETON, which it enters explicitly — the singleton comes from the enumeration of
//! dynamic bodies and not from any pair, and without one a dynamic trigger could never sleep
//! and would be integrated forever. So a `.dynamic` trigger falls under gravity and its pose
//! IS a fact the solver resolved, and the exclusion is NOT total.
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
const RigidBody = api.RigidBody;
const PhysicsWorld = forge_3d.PhysicsWorld;
const CommandBuffer = core.ecs.CommandBuffer;
const Vec3r = forge_3d.Vec3r;

/// THE precision crossing — see `forge/api/precision.zig`. This file narrows solver values to
/// the world scalar on every tick, so it is the seam most able to grow a second conversion; it
/// spells none of its own, and `no_precision_crossing` is what enforces that.
/// The INWARD half of this seam. Re-exported here so `forge_sync`
/// carries both directions through one module root — they share the election, and a
/// caller reaching one must be able to reach the other.
pub const in = @import("sync_in.zig");

comptime {
    // §13 wire-in guard: the `pub const` above pulls `sync_in.zig`'s DECLARATIONS,
    // not its `test` blocks. Without this reference the suite silently skips them.
    _ = @import("sync_in.zig");
}

const cross = forge_3d.cross;
const WorldReal = api.precision.WorldReal;
const WorldVec3 = api.precision.WorldVec3;
const WorldQuat = api.precision.WorldQuat;

/// The solver pose of `body`, in the ECS `Transform`'s own layout, or null on a stale
/// handle. One conversion site, so the two representations cannot drift apart in two
/// places.
pub fn solverPose(pw: *const PhysicsWorld, body: api.BodyId) ?struct { pos: [3]WorldReal, rot: [4]WorldReal } {
    const p = pw.bm.position(body) orelse return null;
    const r = pw.bm.rotation(body).?;
    return .{ .pos = cross.vec3ToWorld(p).toArray(), .rot = cross.quatToWorld(r).toArray() };
}

/// The solver's two velocity columns for `body`, in world-scalar array form — the shape the
/// ECS `Velocity` carries, so the comparison and the write read the same bytes.
pub fn solverVelocity(pw: *const PhysicsWorld, body: api.BodyId) struct { linear: [3]WorldReal, angular: [3]WorldReal } {
    return .{
        .linear = cross.vec3ToWorld(pw.bm.linearVelocity(body).?).toArray(),
        .angular = cross.vec3ToWorld(pw.bm.angularVelocity(body).?).toArray(),
    };
}

/// Which registrations publish, decided ONCE per tick.
///
/// **A PRE-PASS, because the per-body form is quadratic.** Asking "who is my entity's
/// publisher?" from inside each of the three publication passes sweeps the whole
/// registration list per answer: 3·N² comparisons, 363 million of them at C1.1's
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
pub const PublisherTable = struct {
    /// One flag per registration, in registration order.
    publishes: []bool,

    pub fn deinit(self: PublisherTable, gpa: std.mem.Allocator) void {
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
pub fn electPublishers(gpa: std.mem.Allocator, pw: *const PhysicsWorld) !PublisherTable {
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

/// Write one body's SOLVER state into the ECS, read-first. Returns whether
/// anything was actually written.
///
/// **ONE mirror, three callers**, and that is the point rather than an economy:
/// `syncIn` publishes here at a `solver -> gameplay` transition and again when an
/// explicit wrapper has already applied this tick, and the Tier 1 mutation
/// wrappers publish here after they move a body. Three copies of a read-first
/// publish would be three chances to omit the read.
///
/// **READ FIRST, `getMut` ONLY ON A REAL DIFFERENCE.** `World.getMut` marks
/// `changed_tick` UNCONDITIONALLY and `Changed<T>` is built on that mark, so
/// writing a bit-identical value reports a change that did not happen — and
/// `Velocity` is `@replicated(strategy: .rollback)`, so that false delta leaves on
/// the wire. Measured: an immobile kinematic platform
/// held awake republished a constant zero forever.
///
/// `with_velocity` is false for a STATIC body, which has no velocity columns a
/// consumer would read.
///
/// `ecs` is either a `*World` or a declared-access `View`, and the shape it must
/// answer to is `get(comptime T, EntityId)` and `getMut(comptime T, EntityId)`.
/// Both regimes are real and neither is a fallback: inside a dispatched system
/// the accessor is a view, and every caller outside one holds the world.
pub fn mirrorSolverState(
    ecs: anytype,
    entity: EntityId,
    pw: *const PhysicsWorld,
    body: api.BodyId,
    with_velocity: bool,
) bool {
    var wrote = false;
    if (ecs.get(Transform, entity)) |t| {
        const pose = solverPose(pw, body).?;
        if (!std.mem.eql(WorldReal, &t.pos, &pose.pos) or
            !std.mem.eql(WorldReal, &t.rot, &pose.rot))
        {
            const w = ecs.getMut(Transform, entity).?;
            w.pos = pose.pos;
            w.rot = pose.rot;
            wrote = true;
        }
    }
    if (with_velocity) {
        if (ecs.get(Velocity, entity)) |v| {
            const out = solverVelocity(pw, body);
            if (!std.mem.eql(WorldReal, &v.linear, &out.linear) or
                !std.mem.eql(WorldReal, &v.angular, &out.angular))
            {
                const w = ecs.getMut(Velocity, entity).?;
                w.linear = out.linear;
                w.angular = out.angular;
                wrote = true;
            }
        }
    }
    return wrote;
}

/// The body an ENTITY is driven through, or null when it owns none.
///
/// **THE SAME CRITERION AS `electPublishers`, and it is shared rather than
/// restated.** The mutation wrappers write through the body `syncOut` publishes
/// from and `syncIn` consumes into; a wrapper electing differently would write to
/// one collider while the seam read from another, and one entity would answer
/// with two poses. The `Candidate` record and its `lessThan` are the criterion,
/// used here on a running minimum instead of a sort — a sorted run's head IS the
/// minimum of that run, so the two agree by construction and not by review. That
/// agreement is nonetheless asserted, over a scene built to make every level of
/// the criterion bite.
///
/// ALLOCATION-FREE, which is why it is not `electPublishers` restricted: a
/// wrapper is called from a rule body, and a per-call table allocation on the
/// gameplay path is a cost the seam pays once per tick and a rule would pay once
/// per call.
pub fn electedBodyOf(pw: *const PhysicsWorld, entity: EntityId) ?api.BodyId {
    const key = (@as(u64, entity.generation) << 32) | entity.index;
    var best: ?Candidate = null;
    for (pw.bodies.items, 0..) |entry, reg| {
        // A character presence answers for nobody — the same exclusion, for the same
        // reason, and it is why a character entity that also owns a rigid body is
        // driven through the body.
        if (entry.kind != .rigid_body) continue;
        const owner = pw.bm.entity(entry.id) orelse continue;
        if (((@as(u64, owner.generation) << 32) | owner.index) != key) continue;
        const c: Candidate = .{
            .entity = key,
            .trigger = if (pw.bm.isTrigger(entry.id) orelse false) 1 else 0,
            .body = entry.id,
            .registration = @intCast(reg),
        };
        if (best == null or Candidate.lessThan({}, c, best.?)) best = c;
    }
    return if (best) |b| b.body else null;
}

/// The character an ENTITY owns, or null when it owns none.
///
/// No election to share: a character has no publisher role and `syncOut` never
/// reads one. What it does share is the DISCIPLINE — the smallest handle among
/// the live characters owning the entity, so the answer is a deterministic
/// function of the creation sequence and never of a scan order that could change.
/// One character per entity is the shape every consumer in the corpus assumes;
/// the tie-break exists so that assumption is not what the answer rests on.
pub fn characterOf(pw: *const PhysicsWorld, entity: EntityId) ?api.CharacterId {
    const key = (@as(u64, entity.generation) << 32) | entity.index;
    var best: ?api.CharacterId = null;
    for (pw.chars.characters.items, 0..) |c, i| {
        const id = pw.chars.alloc.idAtIndex(@intCast(i)) orelse continue;
        if (((@as(u64, c.entity.generation) << 32) | c.entity.index) != key) continue;
        if (best == null or id < best.?) best = id;
    }
    return best;
}

/// Who owns a body's pose and velocity, read from the ECS.
///
/// An entity without a `RigidBody` is `.solver`, which is the declared default and
/// not a fallback invented here: the model's whole point is that `.gameplay` is
/// explicit, so anything that has not said so is the solver's.
///
/// Shared by BOTH directions on purpose. `syncOut` publishes per
/// `body_type × authority` and `syncIn` consumes per the same product; two
/// readings of one field are two things that can disagree about the same body.
///
/// `ecs` answers to `get(comptime T, EntityId)` — a `*World` or a view. The read
/// is why `RigidBody` belongs in the registered system's declared set, and why
/// the set was incomplete before that declaration became the view's type.
pub fn authorityOf(ecs: anytype, entity: EntityId) api.PhysicsAuthority {
    const rb = ecs.get(RigidBody, entity) orelse return .solver;
    return rb.authority;
}

/// Whether `E` can mutate structure directly. False for every declared-access
/// view: structural change is the one effect the access model has no category
/// for, and it routes through the command buffer instead.
fn mutatesStructure(comptime E: type) bool {
    const Accessor = switch (@typeInfo(E)) {
        .pointer => |ptr| ptr.child,
        else => E,
    };
    return @hasDecl(Accessor, "addComponent");
}

/// Apply a `Sleeping` transition immediately, on the direct path only.
///
/// **The capability test is comptime and the failure is a typed error, and that
/// split is forced rather than chosen.** `cmd` is a run-time optional, so Zig
/// analyses the else-branch whatever the caller passed — a `@compileError` here
/// would fire on the nominal system path, which always HAS a command buffer.
/// What is decidable at compile time is whether the accessor can mutate at all;
/// what is not is whether this particular call was given somewhere to record.
/// So the branch a view cannot take is compiled away, and the combination that
/// has no meaning — a view and no buffer — names itself at run time instead of
/// silently skipping the transition.
fn immediateStructural(
    gpa: std.mem.Allocator,
    ecs: anytype,
    entity: EntityId,
    comptime T: type,
    comptime op: enum { add, remove },
) !void {
    if (comptime !mutatesStructure(@TypeOf(ecs))) return error.StructuralChangeNeedsCommandBuffer;
    switch (op) {
        .add => try ecs.addComponent(gpa, entity, T, .{}),
        .remove => try ecs.removeComponent(gpa, entity, T),
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
/// **The two regimes are separated by the TYPE of `ecs`.** A declared-access view
/// cannot mutate structure at all, so passing one with `cmd = null` is
/// `error.StructuralChangeNeedsCommandBuffer` rather than a transition that
/// silently does not happen — see `immediateStructural` above for why that test
/// cannot be a compile error. `ecs` answers to `get` / `getMut`, and to
/// `addComponent` / `removeComponent` only on the direct path.
///
/// Three passes, and the order between them is the contract this file's header argues:
/// untag the woken, publish everything untagged, tag the newly asleep.
pub fn syncOut(gpa: std.mem.Allocator, pw: *PhysicsWorld, ecs: anytype, cmd: ?*CommandBuffer) !void {
    const table = try electPublishers(gpa, pw);
    defer table.deinit(gpa);

    // (1) UNTAG THE WOKEN, BEFORE publishing — so the first pose a waking body moved to
    // is published on the very tick it moved, instead of a tick later.
    for (pw.bodies.items, 0..) |entry, reg| {
        if (!table.publishes[reg]) continue;
        const entity = pw.bm.entity(entry.id) orelse continue;
        if (pw.bm.isSleeping(entry.id).?) continue;
        if (ecs.get(Sleeping, entity) == null) continue;
        if (cmd) |c| try c.removeComponent(entity, Sleeping) else try immediateStructural(gpa, ecs, entity, Sleeping, .remove);
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
        // The condition is `body_type × authority`, not
        // `body_type` alone. A `.gameplay` body publishes NOTHING — neither pose nor
        // velocity — because gameplay owns both and publishing either would be this
        // seam overwriting the authority `syncIn` just read from the ECS. It is the
        // same reason the pose was already withheld from a kinematic body, applied to
        // the axis the old condition could not see.
        //
        // A `.gameplay` body publishes nothing, and what it DOES during `step` is
        // declared in ONE place — `api/authority.zig`, which transcribes
        // `engine-physics-forge.md` § *Autorite d'ecriture*. This site refers and does
        // not restate: the prose that stood here said the body "is integrated normally
        // and its result is discarded", which was the superseded regime and survived
        // its correction by two gates. A comment that paraphrases a rule is a second
        // declarant of it, and two declarants diverge.
        if (authorityOf(ecs, entity) == .gameplay) continue;
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
        if (cmd) |c| try c.addComponent(entity, Sleeping, .{}) else try immediateStructural(gpa, ecs, entity, Sleeping, .add);
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
const Access = core.ecs.Access;

/// The handle the registered systems reach the solver through, held as an ECS resource.
///
/// **A `SystemFn` receives only a context**, which carries no channel for a module's own
/// state — and since declared-access enforcement, not even an unrestricted world: the body
/// gets a `View` over the set it declared. So the pointer has to live somewhere the context
/// can reach, and a resource is what a view reaches by its declared type.
/// `FrameContext.user` exists and was REFUSED: it is ONE `?*anyopaque` slot shared by the
/// whole engine, so the first module to claim it wins and the second silently loses. A
/// resource keyed on this type collides with nothing by construction.
///
/// **It carries the allocator too, and that is not a convenience.** `ctx.gpa` is the
/// PER-FRAME allocator, while `step` grows structures the solver keeps ACROSS ticks — the
/// retained candidate set, the constraint array, the island partition, the warm-start cache
/// and the sensor state. Handing a frame allocator to those would free them out from under
/// the solver at the end of the frame.
///
/// Stored as three raw words rather than as typed fields, because the ECS registry builds a
/// resource's default bytes from a default-constructed value and a pointer has no meaningful
/// default. Zero means "nothing published", which `resolve` reports as absence.
pub const PhysicsWorldRef = extern struct {
    world: usize = 0,
    /// The two halves of a `std.mem.Allocator`, which is `{ ptr, vtable }`.
    alloc_ptr: usize = 0,
    alloc_vtable: usize = 0,
    /// The inward pass's journal, or `0` when no caller attached
    /// one. A RAW POINTER for the same reason the two above are: this resource is
    /// an `extern struct` of POD and cannot own anything, so the journal's
    /// lifetime is the caller's.
    ///
    /// **The inward pass is OPT-IN, and that is a bound with a reason rather than
    /// a hole.** `authority` defaults to `.solver` for every body, so a world in
    /// which nothing declared `.gameplay` has nothing for `syncIn` to consume and
    /// pays nothing for its absence. A world that DOES declare `.gameplay` and
    /// attaches no journal has bodies nothing drives — `syncOut` withholds their
    /// publication and no inward pass moves them — which is visible as a body
    /// that does not move, and is what `attachSyncInJournal` exists to prevent.
    journal: usize = 0,

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

    fn journalPtr(self: PhysicsWorldRef) ?*in.Journal {
        if (self.journal == 0) return null;
        return @ptrFromInt(self.journal);
    }

    fn allocator(self: PhysicsWorldRef) std.mem.Allocator {
        return .{
            .ptr = @ptrFromInt(self.alloc_ptr),
            .vtable = @ptrFromInt(self.alloc_vtable),
        };
    }
};

/// Publish `pw` into `ecs` so the registered system can find it.
///
/// **REFUSES to replace a live publication**, with `error.PhysicsWorldAlreadyPublished`. A
/// silent replacement is the exact counterpart of a blind withdrawal: it makes the first world
/// disappear without anyone having withdrawn it, and the frames that follow drive a world its
/// owner believes is still wired. Withdraw first, then publish — the two entries are a pair.
///
/// The signature is not frozen: `PhysicsModule` does not carry it, so an error channel costs
/// nothing that a later milestone would have to live with.
pub fn publishPhysicsWorld(gpa: std.mem.Allocator, ecs: *World, pw: *PhysicsWorld) !void {
    const id = try ecs.ensureComponentRegistered(gpa, PhysicsWorldRef);
    const ref = PhysicsWorldRef.pack(pw, gpa);
    if (ecs.resources.getMutResource(id)) |slot| {
        if (slot.len != @sizeOf(PhysicsWorldRef)) return error.PhysicsWorldAlreadyPublished;
        var current: PhysicsWorldRef = undefined;
        @memcpy(std.mem.asBytes(&current), slot);
        if (current.world != 0) return error.PhysicsWorldAlreadyPublished;
        @memcpy(slot, std.mem.asBytes(&ref));
        return;
    }
    try ecs.addResource(gpa, id, std.mem.asBytes(&ref));
}

/// Withdraw the published handle. The SYMMETRIC half of `publishPhysicsWorld`, and the caller
/// that published is the one that withdraws.
///
/// **Without it the resource outlives the world it names.** `publishPhysicsWorld` writes raw
/// pointers, `PhysicsWorld.deinit` frees and poisons, and nothing cleared the resource — the
/// accessor kept answering with a dead address and the next dispatch dereferenced it. That the
/// runtime's ordinary order happens to be safe changes nothing: a lifetime contract nothing
/// enforces is not a contract, and this is the same shape as `removeBody` accepting a
/// character presence — two operations each correct, whose sequence breaks.
///
/// **`expected` is checked, and that is the second half of the same defect.** A withdrawal
/// that cleared whatever it found would let a LATE teardown erase a world published after it:
/// publish A, publish B, then run A's deferred cleanup, and every frame afterwards is a silent
/// no-op. A withdrawal that finds someone else's handle is a NO-OP, matching the repository's
/// pattern for an unhandleable handle rather than raising on a teardown path.
///
/// **THE CHECK IS ON THE ADDRESS, and that bounds what it protects.** It separates two worlds
/// ALIVE AT THE SAME TIME, which is the case above and the only one any path in this
/// repository produces. It does NOT separate two GENERATIONS occupying the same storage: a
/// world destroyed, a second one allocated at the same address, and a late withdrawal aimed at
/// the first would clear the second. Closing that needs an opaque publication token rather
/// than a pointer comparison, which is recorded with its owner.
/// The limit is written here rather than widened.
///
/// The handle is ZEROED rather than the resource removed: the accessor already reads zero as
/// absence, the slot keeps its registered id so a later publication reuses it, and nothing has
/// to be freed. `PhysicsWorld` still knows nothing of the ECS, which is the invariant this
/// seam has held since it was written.
pub fn unpublishPhysicsWorld(ecs: *World, expected: *PhysicsWorld) void {
    const id = ecs.componentId(@typeName(PhysicsWorldRef)) orelse return;
    const slot = ecs.resources.getMutResource(id) orelse return;
    if (slot.len != @sizeOf(PhysicsWorldRef)) return;
    var current: PhysicsWorldRef = undefined;
    @memcpy(std.mem.asBytes(&current), slot);
    if (current.world != @intFromPtr(expected)) return; // someone else's publication
    const cleared = PhysicsWorldRef{};
    @memcpy(slot, std.mem.asBytes(&cleared));
}

/// Read the published handle back, or null if nothing was published.
///
/// **A PURE LOOKUP, and that is the point.** Obtaining the id by REGISTERING the type
/// here, on `ctx.gpa` — the FRAME allocator — would keep the type's name for the world's
/// whole life. A frame allocator handing out memory the registry retains
/// is the same defect this file avoids one level up, arriving through the lookup instead of
/// through the physics. `componentId` resolves an already-registered name and allocates
/// nothing; a world where nothing was published has no such name, which is absence and not
/// failure. `publishPhysicsWorld` is the only site that registers, and it takes the
/// persistent allocator.
fn resolve(ecs: anytype) ?PhysicsWorldRef {
    const bytes = ecs.resourceBytes(PhysicsWorldRef) orelse return null;
    if (bytes.len != @sizeOf(PhysicsWorldRef)) return null;
    var ref: PhysicsWorldRef = undefined;
    // Copied out rather than pointer-cast: the resource store hands back a byte slice whose
    // alignment is the store's, not this type's.
    @memcpy(std.mem.asBytes(&ref), bytes);
    if (ref.world == 0) return null;
    return ref;
}

/// Attach the inward pass's journal to the published world, so
/// the registered system runs `syncIn` before `step`.
///
/// Separate from `publishPhysicsWorld` rather than a parameter on it: that entry's
/// signature is the publication contract, and the inward pass is opt-in
/// (see the field). BORROWED — the journal must outlive the publication.
pub fn attachSyncInJournal(ecs: *World, journal: *in.Journal) !void {
    const rid = ecs.registry.idOf(@typeName(PhysicsWorldRef)) orelse return error.PhysicsWorldNotPublished;
    const slot = ecs.resources.getMutResource(rid) orelse return error.PhysicsWorldNotPublished;
    var current: PhysicsWorldRef = undefined;
    @memcpy(std.mem.asBytes(&current), slot);
    if (current.world == 0) return error.PhysicsWorldNotPublished;
    current.journal = @intFromPtr(journal);
    @memcpy(slot, std.mem.asBytes(&current));
}

/// The world published into `ecs`, or null if none is.
///
/// Answers with the IDENTITY and not a boolean, because a boolean cannot tell "B is still
/// published" from "B was erased and something else answers": the tests that guard this
/// lifetime need the difference, and a caller asserting its own wiring does too.
pub fn publishedPhysicsWorld(ecs: *World) ?*PhysicsWorld {
    const ref = resolve(ecs) orelse return null;
    return ref.worldPtr();
}

fn stepAndPublishSystem(ctx: core.ecs.SystemContextOf(&step_spec)) anyerror!void {
    const ref = resolve(ctx.view) orelse return;
    // THE NORMATIVE ORDER, inside the registered system and not in a caller's
    // discipline: gameplay rules and systems have already run in this phase's
    // predecessors, `syncIn` consumes what they wrote, `step` simulates, `syncOut`
    // publishes. A caller-side `syncIn` would put the order back into a discipline
    // someone has to remember — the defect that registering the outward half at
    // all avoids.
    if (ref.journalPtr()) |j| {
        _ = try in.syncIn(ref.allocator(), ref.worldPtr().?, ctx.view, j);
    }
    try ref.worldPtr().?.step(ref.allocator());
    try syncOut(ref.allocator(), ref.worldPtr().?, ctx.view, ctx.cmd);
}

const step_name = "forge_step_and_publish";

/// The system's declared access set — the ONE declaration this file writes.
///
/// It parameterises `stepAndPublishSystem`'s view AND produces the descriptors the DAG
/// orders on, so the two cannot disagree. A file-scope constant is still the right form,
/// for a reason that predates the enforcement: `SystemScheduler` stores the descriptor
/// without duplicating its slice, so a `&.{ ... }` literal written inside the registering
/// function left every `type_name` pointing at dead stack once that function returned —
/// an empty string, then a fault. Derived descriptors are comptime constants and cannot
/// dangle at all, which retires the hazard rather than avoiding it.
const step_spec = [_]core.ecs.Access{
    Access.writes(Transform),
    Access.writes(Velocity),
    // The `Sleeping` transitions are STRUCTURAL — they migrate the entity between archetypes —
    // so `writes` is the closest the access model can express, not a description of the effect.
    Access.writes(Sleeping),
    // READ, and it was missing. `authorityOf` reads `RigidBody` from inside this
    // system and the set said nothing about it, which is exactly the omission a
    // declaration nobody checks produces. The system never writes it.
    Access.reads(RigidBody),
    Access.writesResource(PhysicsWorldRef),
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
/// ECS → solver direction belongs to the service and registers nothing here.
///
/// The declared accesses are exactly what the system does, and that is now CHECKED rather
/// than claimed: the set parameterises the view the body receives, so an access it does not
/// name does not compile. It names five — `Transform`, `Velocity` and the `Sleeping` marker
/// it migrates, the `RigidBody` it reads through `authorityOf`, and the solver resource it
/// mutates through the published pointer. Undeclared, two physics modules could sit in one
/// phase with no edge between them and nothing would catch them.
///
/// **PREFLIGHT AND NOT IDEMPOTENCE, because of which failure is real.** Calling this twice on
/// one scheduler is the failure a caller can actually produce, and it is deterministic: the
/// name and the write conflicts are checked BEFORE the registration, so a second call mutates
/// nothing and reports `error.SystemAlreadyRegistered`. Idempotence would accept it in
/// silence, hiding a double wiring rather than naming it.
///
/// **The preflight covers TWO of the three deterministic failures — the name and the write
/// conflicts — and covers OOM not at all.** The third is `error.DependencyCycle`, and it is
/// not screened here for a reason rather than by omission: a cycle is a property of the
/// phase's whole DAG, so predicting it means rebuilding the scheduler's edge construction
/// inside this module, and a second implementation of that is how the two come to disagree.
/// It surfaces from `sched.registerSystem` below instead, which refuses it AHEAD of its commit
/// — so the scheduler is left untouched exactly as by a write conflict, and only the world's
/// registry carries the types the resolution registered, which is the bound `registerSystem`'s
/// own doc states.
///
/// **It is reachable and not theoretical.** `step_spec` declares writes on `Transform`,
/// `Velocity` and `Sleeping` plus a read of `RigidBody`, all in `fixed_update`. Any later
/// Tier 1 system in that phase which READS one of those three and WRITES `RigidBody` closes a
/// two-node cycle — and `wouldConflict` cannot see it, because it compares write against write
/// on `type_name` and nothing else. The ECS → solver direction this module deliberately does
/// not register has exactly that shape.
///
/// `registerSystem` appends edges and several tracker entries before
/// any allocation can fail, and its `errdefer`s do not undo all of them: after an allocation
/// failure INSIDE ITS COMMIT the scheduler must be treated as UNUSABLE, and a retry can report
/// `WriteWriteConflict` against a `systemCount()` of zero. An allocation that fails before that
/// commit — the access resolution, or the cycle walk's scratch — leaves it byte-unchanged. Moving to one system removed the
/// residual BETWEEN two calls and nothing inside one. The real fix is that `registerSystem` be
/// TRANSACTIONAL FOR ITSELF — a Tier 0 debt recorded in `engine-ecs-internals.md`, and a
/// different one from the absence of a group removal recorded beside it. Promising an absence
/// of residue that no mechanism holds would be worse than saying nothing, because it excuses
/// the next reader from checking.
pub fn registerSystems(gpa: std.mem.Allocator, sched: *SystemScheduler, ecs: *World) !void {
    if (isRegistered(sched, .fixed_update, step_name)) return error.SystemAlreadyRegistered;
    // The preflight reads the DERIVED accesses, never a descriptor: `of` is
    // private now, and a pair of `run` and `accesses` supplied separately is
    // what `registerSystem` refuses to accept at all. Deriving the accesses
    // alone carries no pairing risk — there is no `run` beside them to
    // disagree with.
    if (wouldConflict(sched, .fixed_update, core.ecs.descriptorsOf(&step_spec))) {
        return error.WriteWriteConflict;
    }

    try sched.registerSystem(
        gpa,
        ecs,
        .fixed_update,
        step_name,
        &step_spec,
        stepAndPublishSystem,
    );
}
