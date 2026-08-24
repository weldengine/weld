//! `src/interfaces/PhysicsModule.zig` — the Tier 1 physics interface, and the first file of
//! `src/interfaces/`.
//!
//! **THIS FILE IS NOT FROZEN.** The freeze is M1.1.26 and it is what brings
//! `WELD_PHYSICS_PROTOCOL_VERSION`, the comptime surface guards, and the normative update of
//! `engine-tier-interfaces.md`. Until then this file may change freely, and the absence of
//! the protocol constant is asserted below so that nobody reads its silence as a freeze
//! already taken.
//!
//! **What it holds today, and why not more.** `engine-tier-interfaces.md` §1 declares the
//! interface as `pub fn PhysicsModule(comptime Impl: type) type` whose comptime block
//! `assertFn`s twenty-seven entries. That block is not written here, for two measured
//! reasons:
//!
//!   - the assert block IS the surface guard, and surface guards are M1.1.26's by the
//!     milestone's own scope. A guard that checked three of the twenty-seven entries would
//!     be worse than no guard, because an implementation missing the other twenty-four would
//!     pass it — a check that under-checks reads as a check.
//!   - the first entry of that block is `init`, typed `fn (*core.ModuleContext) anyerror!Impl`,
//!     and **`ModuleContext` does not exist in this repository**. Measured, not assumed: the
//!     name appears in three comments and in no declaration. Minting it here would be
//!     inventing a Tier 0 type that reaches the scheduler and the asset loader, which is a
//!     project and not a line.
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

// --- tests -------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

test "the interface is NOT frozen: no protocol version is declared here" {
    // An ATTESTATION OF ABSENCE, and the form matters. `WELD_PHYSICS_PROTOCOL_VERSION` is
    // what M1.1.26 adds when the surface freezes; declaring it early would make the surface
    // irreversible a milestone ahead of the decision to make it so. `@hasDecl` on this
    // file's own namespace is what states that, and it is a claim that can FAIL — adding
    // the constant turns this test red, which is exactly the alarm it exists to raise.
    try testing.expect(!@hasDecl(@This(), "WELD_PHYSICS_PROTOCOL_VERSION"));

    // NON-VACUITY: `@hasDecl` on this namespace does find what is really here, so the
    // expectation above is not the vacuous truth of a predicate that never finds anything.
    try testing.expect(@hasDecl(@This(), "SetBodyTransform"));
    try testing.expect(@hasDecl(@This(), "MoveKinematic"));
    try testing.expect(@hasDecl(@This(), "SetAngularVelocity"));
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
