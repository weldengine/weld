//! `forge/module.zig` — `Forge3DModule`, the Tier 1 adapter in front of `forge_3d`.
//!
//! **THE `Impl` IS THIS ADAPTER, AND NEVER `PhysicsWorld`** (`engine-tier-interfaces.md` §0,
//! §1). No entry of a Tier 1 interface takes an allocator: the implementation receives
//! `persistent_allocator` once, in `ModuleContext`, and allocates from its own state. A
//! solver core whose entries demand an allocator per call therefore does not satisfy the
//! interface as it stands, and `PhysicsWorld` is exactly such a core — it takes one on
//! several of its public entries because it is written unmanaged-first
//! (`engine-zig-conventions.md` §3). Confronting `PhysicsWorld`'s surface with the frozen
//! one compares the interface to a COMPONENT of its implementation rather than to its
//! implementation, and the gap measured that way is not a non-conformance: it is the
//! absence of this file.
//!
//! The rule is not stylistic. These interfaces are exercised from Etch through Tier 1
//! services (`etch-abi-zig.md` §8), and an Etch signature carries no allocator — so an entry
//! that requires one is unreachable from the engine's own scripting language.
//!
//! **FALLIBILITY IS DECLARED ENTRY BY ENTRY**, on one question: can this path allocate? An
//! entry that cannot returns `void` and keeps returning it; an entry that can carries an
//! error channel. What is forbidden is the third form — an entry that allocates and returns
//! `void`, swallowing the failure or turning it into a panic.
//!
//! **NOT WIRED INTO A RUNNING ENGINE, and that is this milestone's boundary.** `init` stores
//! the allocator and opens the world; it registers no system and publishes nothing. The
//! `world` and `system_scheduler` the context carries are for M1.1.15.2, which brings the
//! Tier 1 service, the Etch wrappers and the system registration — `forge/sync.zig` already
//! holds the registration and is driven by its own tests today. A `ModuleRegistry` populated
//! from `weld.toml` is that milestone's too.
//!
//! **NOT FROZEN.** `src/interfaces/PhysicsModule.zig` carries no comptime assert block and
//! no `WELD_PHYSICS_PROTOCOL_VERSION`; both are M1.1.15.2's. This file presents the frozen
//! SHAPE so the slice that follows is written against a surface that no longer moves, but
//! nothing here is guarded by comptime yet.

const std = @import("std");

const core = @import("weld_core");
const api = @import("weld_forge");
const forge_3d = @import("forge_3d");

const ModuleContext = core.ModuleContext;
const PhysicsWorld = forge_3d.PhysicsWorld;
const query = forge_3d.query;
const cross = forge_3d.cross;

const Real = forge_3d.Real;
const Vec3r = forge_3d.Vec3r;

const Vec3 = api.precision.WorldVec3;
const Quat = api.precision.WorldQuat;

const BodyId = api.BodyId;
const ShapeId = api.ShapeId;
const CharacterId = api.CharacterId;
const EntityId = api.EntityId;

/// Default gravity and timestep for a world opened through `init`.
///
/// `ModuleContext` carries neither, and a physics configuration resource does not exist
/// yet. These are the values `engine-physics-forge.md` §1 assumes throughout and the ones
/// every scene in the repository uses; the day a `PhysicsConfig` resource lands, `init`
/// reads it from `ctx.world` and these disappear. Named rather than inlined so that
/// disappearance is one edit.
pub const default_gravity = Vec3r.fromArray(.{ 0, -9.81, 0 });
/// Fixed timestep of a world opened through `init` — 60 Hz. Overwritten by `step`'s own
/// `dt`, which is the frozen entry's parameter; this is only what the world opens with.
pub const default_timestep: Real = 1.0 / 60.0;

/// **THE TWO JOINT ENTRIES ARE ABSENT, and it is a finding rather than an omission.**
/// `engine-tier-interfaces.md` §1 declares `createJoint: fn (*Impl, JointDescriptor)
/// anyerror!JointId` and `destroyJoint: fn (*Impl, JointId) void`, and **not one of
/// `JointId`, `JointDescriptor`, `JointType`, `JointLimits` or `JointMotor` is declared
/// anywhere in this repository** — measured across `src/modules/forge/` at M1.1.15.1, zero
/// occurrences. So the two entries cannot be presented here even as typed stubs: a stub
/// needs its parameter type to exist.
///
/// The same shape as `ModuleContext` at M1.1.15: a type the frozen interface names, that
/// nothing declares. Minting the family is the joint milestone's work (M1.1.16-18) or the
/// freeze's, not this one's — C1.1 authorises a typed `error.NotImplemented` BODY behind a
/// frozen SIGNATURE, which presumes the signature is expressible. Recorded so the freeze
/// meets it knowingly rather than discovering it while writing its assert block, which is
/// exactly what this milestone exists to prevent.
pub const joint_entries_absent = true;

/// The Tier 1 physics module: `forge_3d` behind the frozen `PhysicsModule` shape.
///
/// It owns the allocator and the solver world, and every entry below is the interface's own
/// signature with no allocator on it. The file header carries why that arrangement is the
/// contract rather than a preference.
pub const Forge3DModule = struct {
    /// The allocator received once, at `init`, and used by every entry that allocates.
    /// THE reason this type exists.
    gpa: std.mem.Allocator,
    /// The solver core. Owned by value: nothing in it points into itself, so moving the
    /// adapter moves the world with it.
    world: PhysicsWorld,

    /// Reusable staging for the entries that fill a caller slice, ABOVE the stack floor.
    ///
    /// The solver family writes solver-scalar records and the frozen family reads
    /// world-scalar ones, so the two cannot share a buffer and a staging step is
    /// unavoidable. What IS avoidable — and was the F2 defect — is letting that step BOUND
    /// the answer. These grow on demand and are never shrunk, so a steady query load
    /// allocates once and then never again; below `stack_hits` they are not touched at all.
    /// How many times the entity-major premise below was found VIOLATED. Observable so the
    /// guard can be tested, and so a violation in the field is a number rather than a
    /// silence. See `dedupEntities`.
    unordered_projections: u32 = 0,

    scratch_bodies: std.ArrayListUnmanaged(BodyId) = .empty,
    scratch_hits: std.ArrayListUnmanaged(query.RayHit) = .empty,

    // --- Lifecycle ---

    /// Open a physics world for this module.
    ///
    /// Stores `ctx.persistent_allocator` — the only field this milestone consumes, and the
    /// one the no-allocator-on-an-entry rule depends on being stored.
    pub fn init(ctx: *ModuleContext) anyerror!Forge3DModule {
        return .{
            .gpa = ctx.persistent_allocator,
            .world = PhysicsWorld.init(default_gravity, default_timestep),
        };
    }

    pub fn deinit(self: *Forge3DModule) void {
        self.scratch_bodies.deinit(self.gpa);
        self.scratch_hits.deinit(self.gpa);
        self.world.deinit(self.gpa);
    }

    /// Advance the simulation by one fixed step.
    ///
    /// **THE FAILURE CONTRACT — the tick is NOT atomic and does not become atomic.** An
    /// `error.OutOfMemory` out of this entry leaves the world in a state that is
    /// **UNSPECIFIED but NOT CORRUPTED**: the structural invariants hold — no dangling
    /// index, no orphan proxy, no retained pair naming a dead body — and the simulation
    /// semantics do not. Some steps of the eleven ran and others did not, and no partial
    /// tick is a physical state.
    ///
    /// **The only permitted recovery is to stop ticking this world and `deinit` it.**
    /// Replaying the tick, resuming at the next one, or publishing to the ECS after a
    /// failed step are CALLER ERRORS, not degraded modes. `forge/sync.zig` obeys this by
    /// construction: its `try` on this call returns before the publication runs.
    ///
    /// **Why the channel exists at all.** Eight allocation sites live in the cycle — pair
    /// generation, the retained candidate set, the constraint array, the island partition,
    /// the warm-start cache, the sensor pass, and the two the substep loop reaches. The
    /// reservation seam of M1.1.15.1 closed exactly one of them, step 10's proxy update.
    /// The other seven grow structures whose size follows the scene, and no up-front
    /// reservation bounds them without bounding the scene itself. A `void` signature would
    /// have only two exits and both are refused: swallow the failure, and return a tick
    /// whose result is wrong without saying so; or panic, and turn memory pressure into a
    /// process abort.
    ///
    /// **WHAT THIS SIGNATURE DOES NOT AUTHORISE: allocating in steady state.** The eight
    /// sites are AMORTISED growths on capacity-retaining lists, so once the scene is stable
    /// the tick allocates nothing — and a fallible signature would say nothing on the day a
    /// non-amortised site is added. The property is therefore MEASURED and not deduced:
    /// instrumented allocator, zero allocations in steady state, on the C1.1 bench.
    ///
    /// `dt` is the caller's, and it is written into the world. The frozen entry takes the
    /// timestep per call while `PhysicsWorld` holds one; this is where the two meet, and
    /// the caller's value wins.
    pub fn step(self: *Forge3DModule, dt: f32) anyerror!void {
        std.debug.assert(std.math.isFinite(dt) and dt > 0);
        self.world.dt = dt;
        return self.world.step(self.gpa);
    }

    // --- Bodies ---

    pub fn addBody(self: *Forge3DModule, desc: api.BodyDescriptor) anyerror!BodyId {
        return self.world.addBody(self.gpa, desc);
    }

    pub fn removeBody(self: *Forge3DModule, id: BodyId) void {
        self.world.removeBody(id);
    }

    /// TELEPORTATION: writes the pose and derives no velocity. `void`, and that is
    /// conditional on the moved-log uniqueness invariant of M1.1.15.1 — see
    /// `Broadphase.update`. If that invariant falls, THIS signature has to change; the
    /// implementation must not start panicking instead.
    pub fn setBodyTransform(self: *Forge3DModule, id: BodyId, position: Vec3, rotation: Quat) void {
        self.world.setBodyTransform(id, cross.vec3ToSolver(position), cross.quatToSolver(rotation));
    }

    /// Move a kinematic body to a target pose over `dt`, deriving BOTH velocities from it.
    /// `void` under the same condition as `setBodyTransform`.
    pub fn moveKinematic(self: *Forge3DModule, id: BodyId, position: Vec3, rotation: Quat, dt: f32) void {
        self.world.moveKinematic(id, cross.vec3ToSolver(position), cross.quatToSolver(rotation), dt);
    }

    /// The body's pose.
    ///
    /// **RESIDUAL OF THE FROZEN SURFACE, named rather than hidden.** The signature returns a
    /// value and carries no channel, so a STALE handle has no honest answer: this returns
    /// the identity pose for one. Every other frozen entry taking a caller-supplied handle
    /// and returning a value separates the dead handle from the real result — `shapeCast`,
    /// `moveCharacter`, `getCharacterInnerBody` all do (§1.11.7) — and this one cannot,
    /// because it has nowhere to put the distinction. Adding that channel is a change to the
    /// frozen surface and belongs to M1.1.15.2, which still has the window; it is recorded
    /// there rather than taken here.
    pub fn getBodyTransform(self: *Forge3DModule, id: BodyId) api.Transform {
        const p = self.world.bm.position(id) orelse return .{
            .position = Vec3.zero,
            .rotation = Quat.identity,
        };
        return .{
            .position = cross.vec3ToWorld(p),
            .rotation = cross.quatToWorld(self.world.bm.rotation(id).?),
        };
    }

    pub fn setLinearVelocity(self: *Forge3DModule, id: BodyId, velocity: Vec3) void {
        self.world.setLinearVelocity(id, cross.vec3ToSolver(velocity));
    }

    pub fn setAngularVelocity(self: *Forge3DModule, id: BodyId, velocity: Vec3) void {
        self.world.setAngularVelocity(id, cross.vec3ToSolver(velocity));
    }

    pub fn addForce(self: *Forge3DModule, id: BodyId, force: Vec3) void {
        self.world.addForce(id, cross.vec3ToSolver(force));
    }

    pub fn addImpulse(self: *Forge3DModule, id: BodyId, impulse: Vec3) void {
        self.world.addImpulse(id, cross.vec3ToSolver(impulse));
    }

    // --- Shapes ---

    pub fn createShape(self: *Forge3DModule, desc: api.ShapeDescriptor) anyerror!ShapeId {
        return self.world.store.createShape(self.gpa, desc);
    }

    /// The allocator does NOT appear on this entry, and the frozen signature is unchanged
    /// since M1.1.11.1 made the shape store own memory: the interface tier holds the
    /// allocator and supplies it, which is precisely what this adapter is.
    pub fn destroyShape(self: *Forge3DModule, id: ShapeId) void {
        self.world.store.destroyShape(self.gpa, id);
    }

    // --- Queries ---
    //
    // THE EIGHT ENTRIES ARE WRAPPED HERE AND NOWHERE ELSE. M1.1.10 moved the solver-side
    // family to the solver scalar and left `api/types.zig` untouched, recording that the
    // two halves would be joined in ONE place. This is that place: the translation is
    // field-for-field and the only arithmetic in it is the named precision crossing.

    pub fn raycast(self: *Forge3DModule, q: api.RaycastQuery) ?api.RaycastHit {
        const hit = query.raycast(&self.world.bp, &self.world.bm, &self.world.store, rayQuery(q)) orelse return null;
        return rayHit(hit);
    }

    pub fn raycastAny(self: *Forge3DModule, q: api.RaycastQuery) bool {
        return query.raycastAny(&self.world.bp, &self.world.bm, &self.world.store, rayQuery(q));
    }

    /// Fills the caller's slice, and **`out.len` is the only bound**.
    ///
    /// No deduplication here, deliberately: a `RaycastHit` carries `body` alongside
    /// `entity` plus its own position, normal and distance, so two bodies of one entity are
    /// two real hits and collapsing them would destroy information the caller was handed.
    /// §1.11.14's mandatory deduplication governs the tier that DISCARDS the body — the
    /// three `[]EntityId` entries — and this entry does not discard it.
    ///
    /// Staging above `stack_hits` uses the reusable buffer; if it cannot grow, the answer
    /// degrades to the largest correct prefix rather than panicking, this entry being frozen
    /// as a bare `u32`.
    pub fn raycastAll(self: *Forge3DModule, q: api.RaycastQuery, out: []api.RaycastHit) u32 {
        if (out.len == 0) return 0;
        var stack: [stack_hits]query.RayHit = undefined;
        const buf: []query.RayHit = if (out.len <= stack.len) blk: {
            break :blk stack[0..out.len];
        } else blk: {
            self.scratch_hits.resize(self.gpa, out.len) catch break :blk stack[0..];
            break :blk self.scratch_hits.items[0..out.len];
        };
        const found = query.raycastAll(&self.world.bp, &self.world.bm, &self.world.store, rayQuery(q), buf);
        for (0..found) |i| out[i] = rayHit(buf[i]);
        return found;
    }

    pub fn shapeCast(self: *Forge3DModule, q: api.ShapeCastQuery) anyerror!?api.ShapeCastHit {
        const hit = try query.shapeCast(&self.world.bp, &self.world.bm, &self.world.store, castQuery(q));
        return if (hit) |h| castHit(h) else null;
    }

    pub fn overlapShape(self: *Forge3DModule, q: api.OverlapQuery, out: []EntityId) anyerror!u32 {
        const Filler = struct {
            /// Frozen `anyerror!u32`: this entry CAN report, so it must.
            const reports_allocation_failure = true;

            w: *PhysicsWorld,
            req: query.OverlapRequest,
            fn fill(f: @This(), buf: []BodyId) anyerror!u32 {
                return query.overlapShape(&f.w.bp, &f.w.bm, &f.w.store, f.req, buf);
            }
        };
        return self.collectEntities(out, Filler{ .w = &self.world, .req = overlapRequest(q) });
    }

    pub fn overlapAabb(self: *Forge3DModule, min: Vec3, max: Vec3, filter: api.PhysicsQueryFilter, out: []EntityId) u32 {
        const Filler = struct {
            /// Frozen bare `u32`: no channel, so an exhausted allocator degrades to a
            /// correct prefix. See `stageBodies`.
            const reports_allocation_failure = false;

            w: *PhysicsWorld,
            lo: Vec3r,
            hi: Vec3r,
            f: query.Filter,
            /// `error{}` and not `anyerror`: this entry is frozen as a bare `u32`, and an
            /// empty error set is what lets `collectEntities` be shared with the fallible
            /// `overlapShape` without either of them lying about its channel.
            fn fill(self_: @This(), buf: []BodyId) error{}!u32 {
                return query.overlapAabb(&self_.w.bp, &self_.w.bm, &self_.w.store, self_.lo, self_.hi, self_.f, buf);
            }
        };
        return self.collectEntities(out, Filler{
            .w = &self.world,
            .lo = cross.vec3ToSolver(min),
            .hi = cross.vec3ToSolver(max),
            .f = solverFilter(filter),
        }) catch |e| switch (e) {};
    }

    pub fn pointQuery(self: *Forge3DModule, point: Vec3, filter: api.PhysicsQueryFilter, out: []EntityId) u32 {
        const Filler = struct {
            /// Frozen bare `u32`: no channel, so an exhausted allocator degrades to a
            /// correct prefix. See `stageBodies`.
            const reports_allocation_failure = false;

            w: *PhysicsWorld,
            p: Vec3r,
            f: query.Filter,
            fn fill(self_: @This(), buf: []BodyId) error{}!u32 {
                return query.pointQuery(&self_.w.bp, &self_.w.bm, &self_.w.store, self_.p, self_.f, buf);
            }
        };
        return self.collectEntities(out, Filler{
            .w = &self.world,
            .p = cross.vec3ToSolver(point),
            .f = solverFilter(filter),
        }) catch |e| switch (e) {};
    }

    pub fn closestPoint(self: *Forge3DModule, point: Vec3, max_distance: f32, filter: api.PhysicsQueryFilter) ?api.ClosestPointResult {
        const hit = query.closestPoint(
            &self.world.bp,
            &self.world.bm,
            &self.world.store,
            cross.vec3ToSolver(point),
            max_distance,
            solverFilter(filter),
        ) orelse return null;
        return .{
            .entity = hit.entity,
            .body = hit.body,
            .subshape_id = hit.subshape_id,
            .position = cross.vec3ToWorld(hit.position),
            .distance = cross.realToWorld(hit.distance),
        };
    }

    // --- Character controller ---

    pub fn createCharacter(self: *Forge3DModule, desc: api.CharacterDescriptor) anyerror!CharacterId {
        return self.world.createCharacter(self.gpa, desc);
    }

    pub fn destroyCharacter(self: *Forge3DModule, id: CharacterId) void {
        self.world.destroyCharacter(self.gpa, id);
    }

    pub fn moveCharacter(self: *Forge3DModule, id: CharacterId, displacement: Vec3, dt: f32) anyerror!api.CharacterMoveResult {
        const r = try self.world.moveCharacter(id, cross.vec3ToSolver(displacement), dt);
        return .{
            .position = cross.vec3ToWorld(r.position),
            .ground_state = r.ground.state,
            .ground_normal = cross.vec3ToWorld(r.ground.normal),
            .ground_entity = r.ground.entity,
            .ground_body = r.ground.body,
            .ground_velocity = cross.vec3ToWorld(r.ground.velocity),
        };
    }

    /// **KEEPS ITS ERROR CHANNEL, and it is the one pose-adjacent entry that cannot join the
    /// three `void` ones.** It CREATES a capsule shape, and that allocation has nothing to do
    /// with the moved log the M1.1.15.1 reservation seam bounded. Three outcomes a bare
    /// `bool` would conflate: a typed error for the caller's fault, `false` for a target
    /// volume that is occupied — a legitimate gameplay answer — and `true` for success. The
    /// allocator comes from the adapter, which is exactly why it must live on the `Impl` and
    /// not on an entry.
    pub fn resizeCharacter(self: *Forge3DModule, id: CharacterId, radius: f32, height: f32) anyerror!bool {
        return self.world.resizeCharacter(self.gpa, id, radius, height);
    }

    pub fn setCharacterPosition(self: *Forge3DModule, id: CharacterId, position: Vec3) void {
        self.world.setCharacterPosition(id, cross.vec3ToSolver(position));
    }

    pub fn getCharacterInnerBody(self: *Forge3DModule, id: CharacterId) anyerror!?BodyId {
        return self.world.chars.getCharacterInnerBody(id);
    }

    // --- helpers -------------------------------------------------------------

    /// The staging depth held on the STACK, and the floor below which no query allocates.
    ///
    /// It is a floor, never a ceiling: F2 was exactly this constant used as `@min(out.len,
    /// 256)`, which capped four public entries below the caller's own slice — a caller who
    /// sized 512 and received 256 could not tell a truncated answer from a scene that really
    /// held 256. The frozen interface declares `out.len` as the ONLY bound.
    pub const stack_hits: usize = 256;

    /// Kept for the tests that assert the cap is gone. Same value, and the name says what it
    /// now is.
    pub const max_hits: usize = stack_hits;

    /// Body handles to their entities, DEDUPLICATED, writing at most `out.len`.
    ///
    /// **The deduplication is MANDATORY here and nowhere else.**
    /// `engine-physics-queries.md` §1.11.14: *"No deduplication in the solver. The solver's
    /// identity is the body; it returns bodies. Deduplication belongs to the tier that
    /// PROJECTS BODIES ONTO ENTITIES and is MANDATORY there: an entity returned twice by an
    /// overlap would translate into damage applied twice."* The frozen signatures of
    /// `overlapShape`, `overlapAabb` and `pointQuery` return `[]EntityId`, so this function
    /// IS that tier. Deferring it to the Tier 1 service would defer it to a caller that
    /// receives entities already projected — nothing would ever deduplicate.
    ///
    /// **`raycastAll` is NOT in this class, and the distinction is the body identity.** Its
    /// frozen result is `[]RaycastHit`, and a hit carries `body` alongside `entity` plus its
    /// own position, normal and distance. Nothing is projected away, so two bodies of one
    /// entity are two real hits and collapsing them would DESTROY information the caller was
    /// handed. §1.11.14's damage-applied-twice argument is about the tier that discards the
    /// body; this one does not discard it.
    ///
    /// **ADJACENT deduplication is exact here, and that is a property of the solver's key,
    /// not an approximation.** `query/overlap.zig`'s `OverlapCollector.finish` sorts on
    /// `root.keyLess`, which is ENTITY-MAJOR with `BodyId` only as the final tie-break, so
    /// every body of one entity forms one contiguous run. The debug assertion below states
    /// that dependency where it is relied on rather than in a comment far from it.
    /// **THE PREMISE IS GUARDED IN EVERY MODE, and a `std.debug.assert` could not do it.**
    /// This function used to assert the entity-major order and nothing more. That assert is
    /// compiled to NOTHING in ReleaseFast — the mode the C1.1 bench runs in and the mode a
    /// game ships — so the guard was live in exactly the two matrix cells where its breach
    /// costs nothing and absent in the one where it silently reproduces the defect F1 closed:
    /// an entity returned twice, damage applied twice.
    ///
    /// And the premise is NOT this file's to keep. Entity-major order is a property of
    /// `query/overlap.zig`'s `OverlapCollector.finish`; it can stop being true through a
    /// change in ITS owner with nothing here moving, which is precisely the case a guard
    /// exists for. The repository already applies this doctrine next door — `query/root.zig`
    /// replaces a release-stripped class assert with an ACTIVE `probeAdmissible` check for
    /// the same reason, in the same words.
    ///
    /// **The answer is never wrong, not even under a violated premise.** On detection the
    /// function stops trusting adjacency and scans what it has already written — which is
    /// exact, because everything written before the break was deduplicated adjacently over an
    /// ordered run. Cost: one integer comparison per projected body on the fast path, inside
    /// a loop that already performs one; and O(n^2) only on a path that is by construction
    /// never taken.
    ///
    /// The violation is COUNTED rather than swallowed. Two of the three callers are frozen
    /// bare `u32` and have nowhere to report it, so a counter is what makes "detected" true
    /// rather than a word.
    ///
    /// Public for the guard's own test: the counter-factual has to feed this function an
    /// order the solver will not produce, which no caller of the four entries can arrange.
    pub fn dedupEntities(self: *Forge3DModule, bodies: []const BodyId, out: []EntityId) u32 {
        var n: u32 = 0;
        var ordered = true;
        var have_last = false;
        var last: EntityId = undefined;
        for (bodies) |b| {
            const e = self.world.bm.entity(b) orelse continue;
            if (have_last and ordered and query.keyLess(e, b, last, b)) {
                ordered = false;
                self.unordered_projections +|= 1;
            }
            const already = if (ordered)
                have_last and std.meta.eql(e, last)
            else
                containsEntity(out[0..n], e);
            if (already) continue;
            if (n >= out.len) break;
            out[n] = e;
            n += 1;
            last = e;
            have_last = true;
        }
        return n;
    }

    /// Linear membership, reached only once the entity-major premise has been observed
    /// broken. Its cost is the reason the fast path exists, not a reason to skip the check.
    fn containsEntity(written: []const EntityId, e: EntityId) bool {
        for (written) |w| {
            if (std.meta.eql(w, e)) return true;
        }
        return false;
    }

    /// A staging slice of `n` body handles, PROPAGATING an allocation failure.
    ///
    /// The stack below the floor, the reusable buffer above it.
    fn stageBodiesFallible(self: *Forge3DModule, n: usize, stack: []BodyId) ![]BodyId {
        if (n <= stack.len) return stack[0..n];
        try self.scratch_bodies.resize(self.gpa, n);
        return self.scratch_bodies.items[0..n];
    }

    /// The same staging, ABSORBING an allocation failure into a shorter slice.
    ///
    /// **THE ENUMERATION IS FOUR CALLERS, THREE OF THEM BARE, and getting it wrong is what
    /// made the earlier arbitration invalid.** This comment used to read "two of the three
    /// callers are frozen as bare `u32`"; measured, the staging has FOUR callers —
    /// `raycastAll`, `overlapAabb` and `pointQuery` are frozen `u32` with no channel, and
    /// `overlapShape` is frozen `anyerror!u32` and therefore CAN report. An arbitration is
    /// worth exactly what the enumeration of its scope is worth, and this one silently
    /// swallowed an `OutOfMemory` on the one entry whose frozen signature declares it
    /// transmissible.
    ///
    /// For the three bare entries the alternatives really are to panic on memory pressure or
    /// to answer with the largest correct prefix the floor allows. The prefix IS correct —
    /// any prefix of the solver's ordered answer is the right prefix — and this is a
    /// DEGRADATION UNDER EXHAUSTION, not a designed cap: it cannot fire on a healthy
    /// allocator, where the old 256 fired on every call. Whether three frozen signatures
    /// SHOULD be unable to report an allocation failure is a contract decision that belongs
    /// to M1.1.15.2, before its assert block, and is recorded there rather than settled here.
    ///
    /// `overlapShape` is the exception, and it reports.
    fn stageBodies(self: *Forge3DModule, n: usize, stack: []BodyId) []BodyId {
        return self.stageBodiesFallible(n, stack) catch stack;
    }

    /// Project bodies onto DEDUPLICATED entities, retaining under the §1.11.14 key.
    ///
    /// **Retention is on the entity set and never on the bodies, which is why this is a
    /// LOOP and not one call.** Collecting `out.len` bodies and collapsing them afterwards
    /// under-fills the slice and evicts unique entities that were entitled to it: with the
    /// entity-major key, one entity holding three bodies consumes three of four slots and
    /// the answer names two entities where four exist. So when duplicates eat the budget and
    /// the solver was saturated, the staging DOUBLES and the query runs again.
    ///
    /// Termination: `want` doubles and the world holds finitely many bodies, so the
    /// `found < buf.len` exit — the solver was not saturated, hence exhaustive — is reached.
    /// The loop also exits the moment the slice is full, which is the common case and costs
    /// exactly one query.
    fn collectEntities(self: *Forge3DModule, out: []EntityId, filler: anytype) !u32 {
        if (out.len == 0) return 0;
        var stack: [stack_hits]BodyId = undefined;
        var want: usize = out.len;
        while (true) {
            // ROUTED BY THE FILLER'S DECLARED CHANNEL, and declared per call site rather
            // than inferred here — a single enumeration written in one place is exactly what
            // was wrong before, and a `const` on each filler cannot drift from the signature
            // it sits next to.
            const buf = if (@TypeOf(filler).reports_allocation_failure)
                try self.stageBodiesFallible(want, &stack)
            else
                self.stageBodies(want, &stack);
            const found = try filler.fill(buf);
            const n = self.dedupEntities(buf[0..found], out);
            if (n == out.len) return n; // the slice is full: exact
            if (found < buf.len) return n; // the solver was not saturated: exhaustive
            if (buf.len < want) return n; // the staging could not grow: degraded prefix
            want = buf.len * 2;
        }
    }

    fn solverFilter(f: api.PhysicsQueryFilter) query.Filter {
        return .{ .layer_mask = f.layer_mask, .exclude = f.exclude };
    }

    fn rayQuery(q: api.RaycastQuery) query.RayQuery {
        return .{
            .origin = cross.vec3ToSolver(q.origin),
            .direction = cross.vec3ToSolver(q.direction),
            .max_distance = q.max_distance,
            .filter = solverFilter(q.filter),
            .back_face_mode = q.back_face_mode,
        };
    }

    fn castQuery(q: api.ShapeCastQuery) query.CastQuery {
        return .{
            .shape = q.shape,
            .origin = cross.vec3ToSolver(q.origin),
            .rotation = cross.quatToSolver(q.rotation),
            .direction = cross.vec3ToSolver(q.direction),
            .max_distance = q.max_distance,
            .filter = solverFilter(q.filter),
            .back_face_mode = q.back_face_mode,
        };
    }

    fn overlapRequest(q: api.OverlapQuery) query.OverlapRequest {
        return .{
            .shape = q.shape,
            .position = cross.vec3ToSolver(q.position),
            .rotation = cross.quatToSolver(q.rotation),
            .filter = solverFilter(q.filter),
            .back_face_mode = q.back_face_mode,
        };
    }

    fn rayHit(h: query.RayHit) api.RaycastHit {
        return .{
            .entity = h.entity,
            .body = h.body,
            .subshape_id = h.subshape_id,
            .position = cross.vec3ToWorld(h.position),
            .normal = cross.vec3ToWorld(h.normal),
            .distance = cross.realToWorld(h.distance),
        };
    }

    fn castHit(h: query.CastHit) api.ShapeCastHit {
        return .{
            .entity = h.entity,
            .body = h.body,
            .subshape_id = h.subshape_id,
            .cast_subshape_id = h.cast_subshape_id,
            .position = cross.vec3ToWorld(h.position),
            .normal = cross.vec3ToWorld(h.normal),
            .distance = cross.realToWorld(h.distance),
        };
    }
};
