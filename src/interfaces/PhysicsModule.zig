//! `src/interfaces/PhysicsModule.zig` — the Tier 1 physics interface, and the first file of
//! `src/interfaces/`.
//!
//! **THIS FILE IS NOT FROZEN.** The freeze is M1.1.15.2 and it is what brings
//! `WELD_PHYSICS_PROTOCOL_VERSION`, the comptime surface guards, and the normative update of
//! `engine-tier-interfaces.md`. Until then this file may change freely, and the absence of
//! the protocol constant is asserted below so that nobody reads its silence as a freeze
//! already taken.
//!
//! **What it holds today, and why not more.** `engine-tier-interfaces.md` §1 declares the
//! interface as `pub fn PhysicsModule(comptime Impl: type) type` whose comptime block
//! `assertFn`s thirty-two entries. That block is not written here, for ONE measured reason —
//! and it carried a second until this milestone removed it:
//!
//!   - the assert block IS the surface guard, and surface guards are M1.1.15.2's by the
//!     milestone's own scope. A guard that checked three of the thirty-two entries would
//!     be worse than no guard, because an implementation missing the other twenty-nine
//!     would pass it — a check that under-checks reads as a check.
//!
//!     Thirty-two and not twenty-nine, and the two numbers are distinct rather than one of
//!     them being wrong: `engine-tier-interfaces.md` §12 disambiguates them — the surface
//!     carries **thirty-two** `assertFn`, of which **twenty-nine** exclude `init`, `deinit`
//!     and `step`. The assert block guards the surface, so it is the thirty-two that bound
//!     it; a guard built on twenty-nine would pass an implementation missing any of the
//!     three lifecycle entries, which is the very failure mode this paragraph names.
//!
//!     THE THREE NUMBERS MOVED TOGETHER AT M1.1.15.2 G5a, and they had already parted from
//!     their source: this header read 30 / 27 while §12 had carried 32 / 29 since
//!     2026-08-30 — `getTriggerOverlaps` entered at §12 version 0.12 and `setJointMotor` at
//!     0.14. Corrected here rather than left for G7's rewrite to carry, because a number
//!     that cites a document it no longer matches is the defect this file's own paragraph
//!     is about.
//!   - **the second reason is gone, and its removal is the point.** It read that the
//!     block's first entry is `init`, typed `fn (*core.ModuleContext) anyerror!Impl`, and
//!     that `ModuleContext` *"does not exist in this repository"* — a measurement that was
//!     exact when it was written and that **M1.1.15.1 gate A obsoleted by minting the type**
//!     (`src/core/module_context.zig`), the corpus having removed `asset_loader` from the
//!     context before that. It is deleted rather than softened: a text that asserts more
//!     than its oracle establishes is a defect, and this one asserted a measurement whose
//!     object is gone. What remains true, and sufficient, is the clause above — the block is
//!     absent because surface guards are M1.1.15.2's, never because the type was missing.
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
// Moved from `forge/api/types.zig`, which held them as a day-1 mirror while this file did
// not exist and which named this move as its destination.
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
//     `BodyInterface::MoveKinematic`. Its signature froze at M1.1.12; its body was a typed
//     stub until M1.1.15, deriving a velocity belonging to the tick cycle and the wake
//     composition, which arrive with `PhysicsWorld`. It is now realised
//     (`forge_3d/world.zig`): `ω = 2 · vec(q_target · conj(q_current)) / dt`, sign
//     normalised for the short path.
//
//   - `setAngularVelocity(id, ω)` closes a gap dating from M1.1.0: `PhysicsModule2D`
//     carries `setAngularVelocity2D` and the reference carries both, while 3D carried only
//     the linear setter — so `ω` was authorable by NO caller at all, and the rotational
//     term of `ground_velocity` had no source. `BodyManager` has had the column setter
//     since M1.1.8; what was missing is the interface entry.
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
// `step` is `anyerror!void` and NOT `void`, on eight allocation sites measured inside the
// cycle at M1.1.15.1 — pair generation, the retained candidate set, the constraint array,
// the island partition, the warm-start cache, the sensor pass and the two the substep loop
// reaches. The reservation seam of that milestone closed exactly one, step 10's proxy
// update; the other seven grow structures whose size follows the scene, and no up-front
// reservation bounds them without bounding the scene. A `void` signature would have only
// two exits, both refused: swallow the failure and return a tick whose result is wrong
// without saying so, or panic and turn memory pressure into a process abort.
//
// **THE FAILURE CONTRACT — the tick is NOT atomic and does not become atomic.** This is the
// half a signature cannot state, and neither `engine-tier-interfaces.md`,
// `engine-physics-solver.md` nor `engine-physics-forge.md` carried it before M1.1.15.1: an
// `error.OutOfMemory` out of `step` leaves the world **UNSPECIFIED but NOT CORRUPTED**. The
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

// --- THE FREEZE (M1.1.15.2 G7) -----------------------------------------------

/// **THE SURFACE IS FROZEN AT THIS VERSION.**
///
/// From here on, an entry may not be added, removed or re-typed without bumping
/// this constant — which is what makes a substitutable `physics_3d` backend
/// possible at all: a Tier 3 solver compiles against a surface, and a surface
/// that can move under it is not one.
///
/// The freeze had already moved twice before landing here (M1.1.15, then
/// M1.1.15.1), and it does not move a third time. Everything the freeze could
/// not wait for landed in the gates before it: the joint type family without
/// which three entries were unwritable, `getTriggerOverlaps`, the error channel
/// on `getBodyTransform`, and the two preconditions M1.1.15.1 closed —
/// `core.ModuleContext` and the `void`-vs-fallible arbitration on the pose
/// setters.
pub const WELD_PHYSICS_PROTOCOL_VERSION: u32 = 1;

/// The comptime surface guard: `PhysicsModule(Impl)` fails to compile unless
/// `Impl` presents all **thirty-two** entries with the exact declared signature.
///
/// **THIRTY-TWO AND NOT TWENTY-NINE, and confusing the two has already cost.**
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
    };
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
    // **THIS TEST WAS AN ATTESTATION OF ABSENCE UNTIL G7, and its going red is what
    // it existed for.** Until this gate it asserted `!@hasDecl(…,
    // "WELD_PHYSICS_PROTOCOL_VERSION")`, with the reason written on it: declaring the
    // constant early would make the surface irreversible a milestone ahead of the
    // decision to make it so. The freeze is that decision, so the claim inverts —
    // the test is CHANGED and not deleted, because a deleted attestation leaves no
    // record that the state it described was left deliberately.
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
    // the moved-log uniqueness invariant (M1.1.15.1) — if that invariant falls, these
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
