//! `src/interfaces/PhysicsModule.zig` — the Tier 1 physics interface, and the first file of
//! `src/interfaces/`.
//!
//! **THIS FILE IS FROZEN.** `WELD_PHYSICS_PROTOCOL_VERSION` is declared below and the
//! comptime surface guard covers all thirty-two entries; no entry may be added, removed or
//! re-typed without bumping the constant.
//!
//! **THIS PARAGRAPH AND THE TEST BELOW MOVE TOGETHER.** They are two halves of one claim,
//! and inverting one without the other is how this header came to state the opposite of what
//! its own guard asserted. A test asserting a fact ABOUT the file, while the file says the
//! opposite in prose, is a guard that cannot see the thing it guards. Do NOT trust proximity
//! to catch that: both halves fit in one editor window, and adjacency is what MASKS the
//! divergence rather than what prevents it.
//!
//! **The count, and the two numbers are distinct rather than one of them being wrong.**
//! `engine-tier-interfaces.md` §12 disambiguates them: the surface carries **thirty-two**
//! `assertFn`, of which **twenty-nine** exclude `init`, `deinit` and `step`. The block guards
//! the SURFACE, so it is the thirty-two that bound it; a guard built on twenty-nine passes an
//! implementation missing any of the three lifecycle entries, which is the very failure mode a
//! surface guard exists to close. Both are exported below so a consumer reads them rather than
//! recounting.
//!
//! **AND THE THIRTY-TWO IS MEASURED, not declared.** A constant stating a size with nothing
//! in front of the block is a size nobody checks: delete one `assertFn` line and the whole
//! tree stays green, the adapter still declaring the entry so every walk over its
//! declarations passes. `guardedNames` reads the block's own text, so the size, the absence
//! of a duplicate, and the agreement between what is GUARDED and what is DELEGATED are all
//! confronted rather than declared.
//!
//! **The wrapper DELEGATES.** §1 declares one function per entry on the returned type, so a
//! `struct { impl: Impl }` carrying nothing else validates an implementation and exposes none
//! of it — and a freeze test asserting only that the field exists cannot see that.
//! `hasCapability` rides along and is NOT a thirty-third entry: it answers `false` for an
//! implementation declaring none, which is why it is absent from the assert block.
//!
//! What DOES land here is the thing the freeze cannot wait for: the contract of the three
//! body pose and velocity entries, which lived in `forge/api/types.zig` as a day-1 mirror
//! and named this file as its destination. It is MOVED and not copied — two copies of a
//! contract are two things that can disagree, which is the whole subject of the contract.
//!
//! **The scalar.** `engine-tier-interfaces.md` §1 states that the positions and poses of
//! this section are written at the WORLD scalar and are not literally `f32` — reading them
//! as `f32` in every circumstance would contradict `ARCH-022`. So the signatures below name
//! `WorldVec3` and `WorldQuat` from `forge/api/precision.zig`, and this file is that alias's
//! first consumer outside the module that defines it. Quantities carrying no length
//! dimension — masses, coefficients, ratios, durations — stay `f32` under both settings and
//! do not follow that scalar, which is why `dt` below is `f32` and the positions are not.

const std = @import("std");
const core = @import("weld_core");
const api = @import("weld_forge");

const BodyId = api.BodyId;
const WorldVec3 = api.precision.WorldVec3;
const WorldQuat = api.precision.WorldQuat;

// --- Body pose and velocity entries — semantics frozen here ---
//
// These semantics live HERE and nowhere else. `forge/api/types.zig` points at this file
// and must not carry a second copy: two copies of a contract are two things that can
// disagree, which is the whole subject of the contract.
//
//   - `setBodyTransform(id, position, rotation)` is a TELEPORTATION. It writes the pose
//     and derives NO velocity: a kinematic body moved through it keeps velocity columns
//     of exactly zero. That is not an oversight to be repaired — it is the same split the
//     reference draws between `SetPositionAndRotation` and `MoveKinematic`.
//
//     The consequence is load-bearing for the character controller and it is why this
//     note exists: `CharacterMoveResult.ground_velocity` is measured AT THE CONTACT
//     POINT, so it reads the support's `v + ω × r`. A platform teleported through this
//     entry therefore reports a ground velocity of ZERO while visibly moving
//     (`engine-physics-forge.md` §1.12.5). The fix is to drive such a platform with
//     `moveKinematic`, never to make this entry guess a velocity from two poses it was
//     not given a `dt` for.
//
//   - `moveKinematic(id, target_position, target_rotation, dt)` is what DERIVES both
//     velocities from a target pose over a `dt`, on the shape of
//     `BodyInterface::MoveKinematic`. The derivation belongs to the tick cycle and the
//     wake composition, so it is realised in `forge_3d/world.zig`:
//     `ω = 2 · vec(q_target · conj(q_current)) / dt`, sign normalised for the short path.
//
//   - `setAngularVelocity(id, ω)` closes an asymmetry: `PhysicsModule2D` carries
//     `setAngularVelocity2D` and the reference carries both, so a 3D surface with only
//     the linear setter leaves `ω` authorable by NO caller at all and the rotational
//     term of `ground_velocity` with no source. `BodyManager` carries the column setter;
//     what this entry adds is the interface half.
//
// Write intent, unchanged from §1.8.4: a pose or velocity WRITE is non-activating (it is
// the solver's own path), while an external mutation — force, torque, impulse — wakes. The
// interface tier composes wake + write for every setter it exposes to gameplay, and a
// character presence moved by pose write is wake cause W4, never W3 (§1.12.10).

/// Teleport a body: write the pose, derive no velocity. See the block above.
pub const SetBodyTransform = fn (BodyId, WorldVec3, WorldQuat) void;

/// Move a kinematic body to a target pose over `dt`, deriving BOTH velocities from it.
/// `dt` is a duration and therefore `f32` under both scalar settings.
pub const MoveKinematic = fn (BodyId, WorldVec3, WorldQuat, f32) void;

/// Set a body's angular velocity. The entry without which `ω` had no author at all.
pub const SetAngularVelocity = fn (BodyId, WorldVec3) void;

// --- The tick, and what its error channel means -------------------------------
//
// `step` is `anyerror!void` and NOT `void`, on eight allocation sites MEASURED inside the
// cycle — pair generation, the retained candidate set, the constraint array, the island
// partition, the warm-start cache, the sensor pass and the two the substep loop reaches.
// A reservation seam closes exactly one of them, step 10's proxy update; the other seven
// grow structures whose size follows the scene, and no up-front reservation bounds them
// without bounding the scene. A `void` signature would have only
// two exits, both refused: swallow the failure and return a tick whose result is wrong
// without saying so, or panic and turn memory pressure into a process abort.
//
// **THE FAILURE CONTRACT — the tick is NOT atomic and does not become atomic.** This is the
// half a signature cannot state, and it is stated HERE rather than inherited — do NOT
// delete it on the assumption that an owner document carries it. An `error.OutOfMemory`
// out of `step` leaves the world **UNSPECIFIED but NOT CORRUPTED**. The
// structural invariants hold — no dangling index, no orphan proxy, no retained pair naming
// a dead body — and the simulation semantics do not, some of the eleven steps having run
// and others not.
//
// **The only permitted recovery is to stop ticking that world and `deinit` it.** Replaying
// the tick, resuming at the next one, and publishing to the ECS after a failed step are
// CALLER ERRORS, not degraded modes. An implementation is not required to make any of the
// three safe, and `forge/sync.zig` obeys the third by construction: its `try` on the call
// returns before the publication runs.
//
// **WHAT THE SIGNATURE DOES NOT AUTHORISE: allocating in steady state.** The eight sites
// are amortised growths on capacity-retaining lists, so a stabilised scene ticks without
// allocating — and a fallible signature would say nothing the day a non-amortised site is
// added. The property is MEASURED, not deduced: instrumented allocator, zero allocations in
// steady state, on the C1.1 bench.

/// Advance the simulation by one fixed step. See the contract above — the error is not a
/// precaution, and what it leaves behind is specified.
pub const Step = fn (f32) anyerror!void;

// --- THE FREEZE ---------------------------------------------------------------

/// **THE SURFACE IS FROZEN AT THIS VERSION.**
///
/// From here on, an entry may not be added, removed or re-typed without bumping
/// this constant — which is what makes a substitutable `physics_3d` backend
/// possible at all: a Tier 3 solver compiles against a surface, and a surface
/// that can move under it is not one.
///
pub const WELD_PHYSICS_PROTOCOL_VERSION: u32 = 1;

/// The comptime surface guard: `PhysicsModule(Impl)` fails to compile unless
/// `Impl` presents all **thirty-two** entries with the exact declared signature.
///
/// **THIRTY-TWO AND NOT TWENTY-NINE, and the two are easy to confuse.**
/// `engine-tier-interfaces.md` §12 carries both numbers: the surface has 32
/// `assertFn` of which 29 exclude `init`, `deinit` and `step`. The block guards
/// the SURFACE, so it is the 32 that bound it — a guard built on 29 passes an
/// implementation missing any one of the three lifecycle entries, which is the
/// very failure mode a surface guard exists to close.
///
/// **THE SIGNATURE IS COMPARED, not merely the name.** §1's own `assertFn` says
/// "full signature checking omitted for brevity — in production, compare
/// `@typeInfo` of the decl vs Expected", and this is production: a guard that
/// checked `@hasDecl` alone would pass an implementation whose `raycastAll`
/// returns `void`, which is precisely the class the multi-result entries' error
/// channel was added to close.
pub fn PhysicsModule(comptime Impl: type) type {
    comptime {
        // --- Lifecycle (3) ---
        assertFn(Impl, "init", fn (*core.ModuleContext) anyerror!Impl);
        assertFn(Impl, "deinit", fn (*Impl) void);
        assertFn(Impl, "step", fn (*Impl, f32) anyerror!void);

        // --- Bodies (9) ---
        assertFn(Impl, "addBody", fn (*Impl, api.BodyDescriptor) anyerror!api.BodyId);
        assertFn(Impl, "removeBody", fn (*Impl, api.BodyId) void);
        assertFn(Impl, "setBodyTransform", fn (*Impl, api.BodyId, WorldVec3, WorldQuat) void);
        assertFn(Impl, "moveKinematic", fn (*Impl, api.BodyId, WorldVec3, WorldQuat, f32) void);
        assertFn(Impl, "getBodyTransform", fn (*Impl, api.BodyId) anyerror!api.Transform);
        assertFn(Impl, "setLinearVelocity", fn (*Impl, api.BodyId, WorldVec3) void);
        assertFn(Impl, "setAngularVelocity", fn (*Impl, api.BodyId, WorldVec3) void);
        assertFn(Impl, "addForce", fn (*Impl, api.BodyId, WorldVec3) void);
        assertFn(Impl, "addImpulse", fn (*Impl, api.BodyId, WorldVec3) void);

        // --- Shapes (2) ---
        assertFn(Impl, "createShape", fn (*Impl, api.ShapeDescriptor) anyerror!api.ShapeId);
        assertFn(Impl, "destroyShape", fn (*Impl, api.ShapeId) void);

        // --- Queries (8) ---
        assertFn(Impl, "raycast", fn (*Impl, api.RaycastQuery) ?api.RaycastHit);
        assertFn(Impl, "raycastAny", fn (*Impl, api.RaycastQuery) bool);
        assertFn(Impl, "raycastAll", fn (*Impl, api.RaycastQuery, []api.RaycastHit) anyerror!u32);
        assertFn(Impl, "shapeCast", fn (*Impl, api.ShapeCastQuery) anyerror!?api.ShapeCastHit);
        assertFn(Impl, "overlapShape", fn (*Impl, api.OverlapQuery, []api.EntityId) anyerror!u32);
        assertFn(Impl, "overlapAabb", fn (*Impl, WorldVec3, WorldVec3, api.PhysicsQueryFilter, []api.EntityId) anyerror!u32);
        assertFn(Impl, "pointQuery", fn (*Impl, WorldVec3, api.PhysicsQueryFilter, []api.EntityId) anyerror!u32);
        assertFn(Impl, "closestPoint", fn (*Impl, WorldVec3, f32, api.PhysicsQueryFilter) ?api.ClosestPointResult);

        // --- Triggers (1) ---
        assertFn(Impl, "getTriggerOverlaps", fn (*Impl, []api.TriggerOverlap) anyerror!u32);

        // --- Joints (3) ---
        assertFn(Impl, "createJoint", fn (*Impl, api.JointDescriptor) anyerror!api.JointId);
        assertFn(Impl, "destroyJoint", fn (*Impl, api.JointId) void);
        assertFn(Impl, "setJointMotor", fn (*Impl, api.JointId, ?api.JointMotor) anyerror!void);

        // --- Character controller (6) ---
        assertFn(Impl, "createCharacter", fn (*Impl, api.CharacterDescriptor) anyerror!api.CharacterId);
        assertFn(Impl, "destroyCharacter", fn (*Impl, api.CharacterId) void);
        assertFn(Impl, "moveCharacter", fn (*Impl, api.CharacterId, WorldVec3, f32) anyerror!api.CharacterMoveResult);
        assertFn(Impl, "resizeCharacter", fn (*Impl, api.CharacterId, f32, f32) anyerror!bool);
        assertFn(Impl, "setCharacterPosition", fn (*Impl, api.CharacterId, WorldVec3) void);
        assertFn(Impl, "getCharacterInnerBody", fn (*Impl, api.CharacterId) anyerror!?api.BodyId);
    }
    return struct {
        impl: Impl,

        // --- The delegated surface ------------------------------------------------
        //
        // **§1 declares ONE function per entry.** Returning nothing but the field gives
        // a type that validates an implementation and exposes none of it — half the
        // interface: the assert block is the CONTRACT, and these are the SURFACE a
        // caller holds. Without them `PhysicsModule(Impl)` is a compile-time predicate
        // wearing the name of a type, and no caller can use the thing it guards — which
        // a freeze test asserting only that the field exists cannot see.
        //
        // Each body is the delegation and nothing else: no defaulting, no logging, no
        // conversion. A wrapper that did anything of its own would be a second place
        // where the interface's semantics live.

        pub fn init(ctx: *core.ModuleContext) anyerror!@This() {
            return .{ .impl = try Impl.init(ctx) };
        }
        pub fn deinit(self: *@This()) void {
            self.impl.deinit();
        }
        pub fn step(self: *@This(), dt: f32) anyerror!void {
            return self.impl.step(dt);
        }

        pub fn addBody(self: *@This(), desc: api.BodyDescriptor) anyerror!api.BodyId {
            return self.impl.addBody(desc);
        }
        pub fn removeBody(self: *@This(), id: api.BodyId) void {
            self.impl.removeBody(id);
        }
        pub fn setBodyTransform(self: *@This(), id: api.BodyId, pos: WorldVec3, rot: WorldQuat) void {
            self.impl.setBodyTransform(id, pos, rot);
        }
        pub fn moveKinematic(self: *@This(), id: api.BodyId, pos: WorldVec3, rot: WorldQuat, dt: f32) void {
            self.impl.moveKinematic(id, pos, rot, dt);
        }
        pub fn getBodyTransform(self: *@This(), id: api.BodyId) anyerror!api.Transform {
            return self.impl.getBodyTransform(id);
        }
        pub fn setLinearVelocity(self: *@This(), id: api.BodyId, vel: WorldVec3) void {
            self.impl.setLinearVelocity(id, vel);
        }
        pub fn setAngularVelocity(self: *@This(), id: api.BodyId, vel: WorldVec3) void {
            self.impl.setAngularVelocity(id, vel);
        }
        pub fn addForce(self: *@This(), id: api.BodyId, force: WorldVec3) void {
            self.impl.addForce(id, force);
        }
        pub fn addImpulse(self: *@This(), id: api.BodyId, impulse: WorldVec3) void {
            self.impl.addImpulse(id, impulse);
        }

        pub fn createShape(self: *@This(), desc: api.ShapeDescriptor) anyerror!api.ShapeId {
            return self.impl.createShape(desc);
        }
        pub fn destroyShape(self: *@This(), id: api.ShapeId) void {
            self.impl.destroyShape(id);
        }

        pub fn raycast(self: *@This(), q: api.RaycastQuery) ?api.RaycastHit {
            return self.impl.raycast(q);
        }
        pub fn raycastAny(self: *@This(), q: api.RaycastQuery) bool {
            return self.impl.raycastAny(q);
        }
        pub fn raycastAll(self: *@This(), q: api.RaycastQuery, out: []api.RaycastHit) anyerror!u32 {
            return self.impl.raycastAll(q, out);
        }
        pub fn shapeCast(self: *@This(), q: api.ShapeCastQuery) anyerror!?api.ShapeCastHit {
            return self.impl.shapeCast(q);
        }
        pub fn overlapShape(self: *@This(), q: api.OverlapQuery, out: []api.EntityId) anyerror!u32 {
            return self.impl.overlapShape(q, out);
        }
        pub fn overlapAabb(self: *@This(), min: WorldVec3, max: WorldVec3, filter: api.PhysicsQueryFilter, out: []api.EntityId) anyerror!u32 {
            return self.impl.overlapAabb(min, max, filter, out);
        }
        pub fn pointQuery(self: *@This(), point: WorldVec3, filter: api.PhysicsQueryFilter, out: []api.EntityId) anyerror!u32 {
            return self.impl.pointQuery(point, filter, out);
        }
        pub fn closestPoint(self: *@This(), point: WorldVec3, max_distance: f32, filter: api.PhysicsQueryFilter) ?api.ClosestPointResult {
            return self.impl.closestPoint(point, max_distance, filter);
        }

        pub fn getTriggerOverlaps(self: *@This(), out: []api.TriggerOverlap) anyerror!u32 {
            return self.impl.getTriggerOverlaps(out);
        }

        pub fn createJoint(self: *@This(), desc: api.JointDescriptor) anyerror!api.JointId {
            return self.impl.createJoint(desc);
        }
        pub fn destroyJoint(self: *@This(), id: api.JointId) void {
            self.impl.destroyJoint(id);
        }
        pub fn setJointMotor(self: *@This(), id: api.JointId, motor: ?api.JointMotor) anyerror!void {
            return self.impl.setJointMotor(id, motor);
        }

        pub fn createCharacter(self: *@This(), desc: api.CharacterDescriptor) anyerror!api.CharacterId {
            return self.impl.createCharacter(desc);
        }
        pub fn destroyCharacter(self: *@This(), id: api.CharacterId) void {
            self.impl.destroyCharacter(id);
        }
        pub fn moveCharacter(self: *@This(), id: api.CharacterId, displacement: WorldVec3, dt: f32) anyerror!api.CharacterMoveResult {
            return self.impl.moveCharacter(id, displacement, dt);
        }
        pub fn resizeCharacter(self: *@This(), id: api.CharacterId, radius: f32, height: f32) anyerror!bool {
            return self.impl.resizeCharacter(id, radius, height);
        }
        pub fn setCharacterPosition(self: *@This(), id: api.CharacterId, pos: WorldVec3) void {
            self.impl.setCharacterPosition(id, pos);
        }
        pub fn getCharacterInnerBody(self: *@This(), id: api.CharacterId) anyerror!?api.BodyId {
            return self.impl.getCharacterInnerBody(id);
        }

        /// Optional extensions — the caller checks before calling.
        ///
        /// NOT a thirty-third entry, and it is the one function here that is not a
        /// bare delegation: it answers `false` for an implementation that declares
        /// none, which is why it is absent from the assert block. Counting it among
        /// the entries would make the block's size 33 and every number derived from
        /// it wrong.
        pub fn hasCapability(self: *@This(), cap: api.Capability) bool {
            if (@hasDecl(Impl, "hasCapability")) return self.impl.hasCapability(cap);
            return false;
        }
    };
}

/// The entry names the assert block guards, READ FROM THE BLOCK'S OWN TEXT.
///
/// **A constant declaring a size, never confronted with the thing it sizes, guards
/// nothing.** Delete one `assertFn` line from the block and the whole tree stays
/// green: `frozen_entry_count` is a number and the block is a list, and without
/// this function nothing puts the two in front of each other. The adapter still
/// declares the entry, so the delegation walk passes; the guard simply stops
/// guarding it, in silence, which is exactly what a surface guard exists to make
/// impossible.
///
/// The block's text is therefore the source and the constant is what it is
/// confronted with. Nothing else in this file can substitute: the block runs at
/// comptime and leaves no runtime trace, and a `@typeInfo` of the returned type
/// sees the DELEGATIONS, which are a different list that happens to have the same
/// names — as the test below then asserts, rather than assumes.
///
/// **THE NEEDLE IS CONCATENATED, and the reason is measured rather than
/// theoretical.** This file embeds itself, so a literal needle would appear in
/// the searched corpus by virtue of being written here — the count would be one
/// too high, and a future reader would "fix" it by making the constant wrong. The
/// split falls between `assert` and `Fn(`, so no contiguous match exists outside
/// the block.
fn guardedNames() []const []const u8 {
    @setEvalBranchQuota(200_000);
    const src = @embedFile("PhysicsModule.zig");
    const needle = "assert" ++ "Fn(Impl, \"";
    comptime var count: usize = 0;
    comptime var scan: usize = 0;
    inline while (std.mem.indexOfPos(u8, src, scan, needle)) |at| {
        count += 1;
        scan = at + needle.len;
    }
    comptime var names: [count][]const u8 = undefined;
    comptime var i: usize = 0;
    comptime var pos: usize = 0;
    inline while (std.mem.indexOfPos(u8, src, pos, needle)) |at| {
        const start = at + needle.len;
        const end = start + (std.mem.indexOfScalarPos(u8, src, start, '"') orelse
            @compileError("unterminated entry name in the surface guard")) - start;
        names[i] = src[start..end];
        i += 1;
        pos = end;
    }
    const frozen = names;
    return &frozen;
}

/// How many entries the block above guards. Read by the freeze test rather than
/// recounted there — two numbers derived from one count that a reader has to
/// keep in step is the defect §12 records having paid for.
pub const frozen_entry_count: usize = 32;
/// The same count without `init`, `deinit` and `step`.
pub const frozen_non_lifecycle_count: usize = frozen_entry_count - 3;

/// One entry of the surface guard.
///
/// **Two things are checked and the second is the one §1 left out.** The
/// declaration must EXIST, and its type must MATCH — parameter for parameter and
/// return type for return type, with one deliberate tolerance: where the expected
/// return is `anyerror!T`, an implementation's INFERRED error set is accepted, its
/// payload being what the contract is about. Zig gives an inferred error set no
/// nameable type, so demanding `anyerror` literally would force every
/// implementation to widen its errors for the guard's benefit — a guard that
/// changes the code it guards.
fn assertFn(comptime T: type, comptime name: []const u8, comptime Expected: type) void {
    if (!@hasDecl(T, name)) {
        @compileError("PhysicsModule implementation must declare '" ++ name ++ "'");
    }
    const Actual = @TypeOf(@field(T, name));
    const a = @typeInfo(Actual).@"fn";
    const e = @typeInfo(Expected).@"fn";
    if (a.params.len != e.params.len) {
        @compileError("PhysicsModule entry '" ++ name ++ "' has the wrong arity: expected " ++
            std.fmt.comptimePrint("{d}", .{e.params.len}) ++ ", found " ++
            std.fmt.comptimePrint("{d}", .{a.params.len}));
    }
    for (a.params, e.params, 0..) |ap, ep, i| {
        if (ap.type.? != ep.type.?) {
            @compileError("PhysicsModule entry '" ++ name ++ "' parameter " ++
                std.fmt.comptimePrint("{d}", .{i}) ++ ": expected " ++ @typeName(ep.type.?) ++
                ", found " ++ @typeName(ap.type.?));
        }
    }
    const ar = a.return_type.?;
    const er = e.return_type.?;
    if (ar == er) return;
    const ai = @typeInfo(ar);
    const ei = @typeInfo(er);
    if (ai == .error_union and ei == .error_union and
        ai.error_union.payload == ei.error_union.payload) return;
    @compileError("PhysicsModule entry '" ++ name ++ "' returns " ++ @typeName(ar) ++
        ", expected " ++ @typeName(er));
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;

test "the interface IS frozen, and the surface guard has the size of the surface" {
    // **THE FREEZE'S ATTESTATION.** It asserts the constant is PRESENT and carries the
    // value the header claims. That looks obvious, and the obviousness is the point: it
    // is the record that the surface was frozen by a decision rather than by accretion.
    try testing.expect(@hasDecl(@This(), "WELD_PHYSICS_PROTOCOL_VERSION"));
    try testing.expectEqual(@as(u32, 1), WELD_PHYSICS_PROTOCOL_VERSION);

    // NON-VACUITY: `@hasDecl` on this namespace does report a false for something
    // really absent, so the positive above is not the answer it always gives.
    try testing.expect(!@hasDecl(@This(), "WELD_PHYSICS_PROTOCOL_VERSION_2"));
    try testing.expect(@hasDecl(@This(), "SetBodyTransform"));
    try testing.expect(@hasDecl(@This(), "Step"));

    // THE TWO NUMBERS, and they are distinct rather than one of them being wrong.
    // §12 carries 32 `assertFn` of which 29 exclude the three lifecycle entries; the
    // block guards the SURFACE, so it has the size of the 32. Both are exported so a
    // consumer reads them rather than recounting, which is the defect §12 records
    // having paid for.
    try testing.expectEqual(@as(usize, 32), frozen_entry_count);
    try testing.expectEqual(@as(usize, 29), frozen_non_lifecycle_count);
    try testing.expectEqual(frozen_entry_count - 3, frozen_non_lifecycle_count);
}

test "the surface guard compares signatures and not merely names" {
    // §1's own `assertFn` says "full signature checking omitted for brevity — in
    // production, compare `@typeInfo` of the decl vs Expected". This is production,
    // and the difference is not academic: a guard checking `@hasDecl` alone passes an
    // implementation whose `raycastAll` returns `void`, which is exactly the class
    // the multi-result entries' error channel was added to close.
    //
    // The guard's own discrimination cannot be tested by instantiating it — a
    // mismatch is a COMPILE error, not a runtime one — so what is asserted here is
    // the shape of the comparison the guard performs, on the same three axes:
    // arity, parameter types, and the return type up to an inferred error set.
    const Expected = fn (*u8, api.BodyId, WorldVec3) void;
    const e = @typeInfo(Expected).@"fn";
    try testing.expectEqual(@as(usize, 3), e.params.len);
    try testing.expectEqual(WorldVec3, e.params[2].type.?);
    try testing.expectEqual(void, e.return_type.?);

    // The ONE deliberate tolerance, stated as a property rather than left implicit:
    // where the contract says `anyerror!T`, an inferred error set is accepted and its
    // PAYLOAD is what is compared. Zig gives an inferred set no nameable type, so
    // demanding `anyerror` literally would force every implementation to widen its
    // errors for the guard's benefit — a guard that changes the code it guards.
    const Contract = anyerror!u32;
    const Inferred = @typeInfo(@TypeOf(inferredExample)).@"fn".return_type.?;
    try testing.expect(Contract != Inferred);
    try testing.expectEqual(
        @typeInfo(Contract).error_union.payload,
        @typeInfo(Inferred).error_union.payload,
    );
}

fn inferredExample() !u32 {
    return error.Whatever;
}

test "step declares an error channel, and the three pose setters do not" {
    // The two halves of the allocator/fallibility contract of `engine-tier-interfaces.md`
    // §0, asserted against each other so neither can drift alone: `step` can allocate and
    // says so; the three pose setters cannot and say so. The `void` half is CONDITIONAL on
    // the broadphase moved-log uniqueness invariant — if that invariant falls, these
    // signatures are what must change, and this test is what makes that visible.
    const st = @typeInfo(Step).@"fn";
    try testing.expect(@typeInfo(st.return_type.?) == .error_union);
    try testing.expectEqual(void, @typeInfo(st.return_type.?).error_union.payload);
    try testing.expectEqual(f32, st.params[0].type.?);

    inline for (.{ SetBodyTransform, MoveKinematic, SetAngularVelocity }) |Entry| {
        const info = @typeInfo(Entry).@"fn";
        try testing.expectEqual(void, info.return_type.?);
        inline for (info.params) |param| {
            try testing.expect(param.type.? != std.mem.Allocator);
        }
    }
}

test "the three signatures are written at the world scalar, not at a literal f32" {
    // `engine-tier-interfaces.md` §1: the positions and poses of this section follow the
    // world scalar, and reading them as `f32` in every circumstance contradicts `ARCH-022`.
    // What is asserted is the LINK to the alias — that is what survives `large_world` — and
    // not the alias's current value, which `forge/api/precision.zig` pins on its own.
    const t = @typeInfo(SetBodyTransform).@"fn";
    try testing.expectEqual(WorldVec3, t.params[1].type.?);
    try testing.expectEqual(WorldQuat, t.params[2].type.?);

    const m = @typeInfo(MoveKinematic).@"fn";
    try testing.expectEqual(WorldVec3, m.params[1].type.?);
    try testing.expectEqual(WorldQuat, m.params[2].type.?);
    // `dt` is a DURATION: no length dimension, so it does not follow the world scalar and
    // stays `f32` under both settings. Asserted because the distinction is the one §1.11.8
    // says is the first cause of error on this subject.
    try testing.expectEqual(f32, m.params[3].type.?);

    const a = @typeInfo(SetAngularVelocity).@"fn";
    try testing.expectEqual(WorldVec3, a.params[1].type.?);
}

test "the header's claim and this test are one thing, checked against the file" {
    // **THE ORACLE FOR A DRIFT THIS FILE HAS ALREADY SEEN.** A test asserting a fact
    // ABOUT the file, while the file states the opposite in prose, is a guard that
    // cannot see the thing it guards — and inverting one half without the other is how
    // the two come apart inside a single commit.
    //
    // So the claim is confronted with the header's own bytes. An edit that declares the
    // file unfrozen, or that removes the frozen statement, reddens here.
    //
    // **EVERY NEEDLE OVER THIS CORPUS IS BUILT BY CONCATENATION, and that is not a
    // style choice.** This file embeds ITSELF, so a literal needle appears in the
    // searched corpus by virtue of being written here: a negative fires on its own text,
    // and — worse — a POSITIVE passes on its own text even when the header has lost the
    // claim entirely. A false alarm and a tautology from one cause. Concatenated at
    // comptime, neither string exists contiguously in the source, so the only matches
    // are the header's.
    const header = @embedFile("PhysicsModule.zig");
    const frozen_claim = "**THIS FILE IS " ++ "FROZEN.**";
    const stale_claim = "THIS FILE IS " ++ "NOT FROZEN";
    try testing.expect(std.mem.indexOf(u8, header, frozen_claim) != null);
    try testing.expect(std.mem.indexOf(u8, header, stale_claim) == null);
    // And the constant the header claims is really there — the two halves asserted
    // against each other, which is what "move together" means mechanically.
    try testing.expect(@hasDecl(@This(), "WELD_PHYSICS_PROTOCOL_VERSION"));
    try testing.expectEqual(@as(u32, 1), WELD_PHYSICS_PROTOCOL_VERSION);

    // NON-VACUITY, and its needle is CONCATENATED TOO — which is the point rather than
    // a repetition. A literal control over a self-embedded corpus is IN the corpus, so
    // it cannot fail. Every needle here carries that hazard, the controls included:
    // patching only the ones that carry the claim leaves the control as the one thing
    // that cannot fail honestly.
    const absent = "THIS FILE IS " ++ "MADE OF CHEESE";
    try testing.expect(std.mem.indexOf(u8, header, absent) == null);
    try testing.expect(std.mem.indexOf(u8, header, "the Tier 1 " ++ "physics interface") != null);

    // **THE HEADER'S NUMBER, confronted with the constant rather than left as prose.**
    // The two excluded values are the KNOWN wrong ones and not arbitrary: a header
    // carrying THIRTY `assertFn` of which twenty-seven are non-lifecycle holds the count
    // from before `getTriggerOverlaps` and `setJointMotor`, and a stale count is a claim
    // a reader acts on rather than a typo.
    //
    // THE CAPITALS ABOVE ARE LOAD-BEARING. The needle below is lower-case and the search
    // is case-sensitive, so lower-casing that phrase here makes this block match its own
    // text and the assertion fires on the comment that explains it.
    try testing.expect(std.mem.indexOf(u8, header, "thirty" ++ "-two") != null);
    try testing.expect(std.mem.indexOf(u8, header, "thirty " ++ "`assertFn`") == null);
    try testing.expect(std.mem.indexOf(u8, header, "thirty" ++ "-three") == null);
    try testing.expectEqual(@as(usize, 32), frozen_entry_count);
}

test "the guard block has the size it declares, and every entry it guards is delegated" {
    // **THE HOLE THIS CLOSES WAS MEASURED, not suspected.** Deleting one `assertFn`
    // line from the block left the tree green at 2029 of 2029: `frozen_entry_count`
    // declared a size and nothing ever put it in front of the block. Every other
    // assertion in this file and in `forge_module_test.zig` reads the CONSTANT or the
    // adapter's own declarations, both of which survive an entry silently leaving the
    // guard.
    const names = comptime guardedNames();
    try testing.expectEqual(frozen_entry_count, names.len);

    // NO DUPLICATE, which is the other way a count of 32 can be reached by 31 entries.
    inline for (names, 0..) |a, i| {
        inline for (names, 0..) |b, j| {
            if (i < j) try testing.expect(!std.mem.eql(u8, a, b));
        }
    }

    // AND WHAT IS GUARDED IS WHAT IS DELEGATED. The two lists have the same names by
    // intention and not by construction — the block is a comptime predicate and the
    // wrapper is a set of functions — so a `pub fn` removed from one or an `assertFn`
    // from the other would leave them disagreeing about what the surface is.
    const src = @embedFile("PhysicsModule.zig");
    inline for (names) |name| {
        const decl = "pub" ++ " fn " ++ name ++ "(";
        if (std.mem.indexOf(u8, src, decl) == null) std.debug.print("NOT DELEGATED: {s}\n", .{name});
        try testing.expect(std.mem.indexOf(u8, src, decl) != null);
    }

    // NON-VACUITY on the walk, and it is not the trivial one: the search really does
    // report an absence for a plausible name that is NOT an entry — `hasCapability` is
    // delegated but never guarded, so it must be absent from `names` while present in
    // the source. That is the exact asymmetry the header claims for it.
    comptime var saw_capability = false;
    inline for (names) |name| {
        if (comptime std.mem.eql(u8, name, "hasCapability")) saw_capability = true;
    }
    try testing.expect(!saw_capability);
    try testing.expect(std.mem.indexOf(u8, src, "pub" ++ " fn " ++ "hasCapability(") != null);
    try testing.expect(std.mem.indexOf(u8, src, "pub" ++ " fn " ++ "notAnEntry(") == null);
}
