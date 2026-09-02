//! `forge/api/precision.zig` — the forge module's SINGLE precision boundary.
//!
//! **Three distinct scalars meet in this engine, and confusing them is the first cause of
//! error on this subject** (`engine-physics-queries.md` §1.11.8):
//!
//!   - the **world** scalar governs world-space positions — the ECS `Transform`,
//!     `BodyDescriptor.position`, the pose the interface returns, the geometric inputs and
//!     outputs of the queries. It is settled by `large_world` in `weld.toml`, read at
//!     `comptime` and never at runtime (`ARCH-022`, whose conformity test states that large
//!     worlds cannot be toggled without recompiling).
//!   - the **solver** scalar governs internal accumulation — traversal, kernels, selection,
//!     integration, constraints. It is settled by `-Dphysics_f64`.
//!   - the **render** scalar is fixed `f32`, always camera-relative, and never appears here.
//!
//! The two flags COMPOSE, and not symmetrically: `large_world = true` implies the solver
//! scalar in `f64`, since a surface more precise than the solver serving it would return
//! low-order digits that mean nothing. The converse — `-Dphysics_f64` alone — stays
//! legitimate and distinct: it buys internal accumulation precision under an `f32` world
//! surface, and it is NOT a large-world mode.
//!
//! **What the repository actually carries, measured and not supposed.** `large_world` does
//! not exist here: only `-Dphysics_f64` is wired, and it switches `forge_3d` alone. So this
//! file's `WorldReal` is `f32` today, and the whole point of naming it is that a literal
//! `f32` at a crossing site would have to be found again, one site at a time, the day the
//! flag lands. The surface ADMITS the mode without delivering it.
//!
//! **Why the boundary is a single point.** Before this file the repository carried four
//! private helpers of identical semantics under two names — `widen` in `mesh.zig`,
//! `convVec3` in `body_manager.zig` and again in `character.zig`, `convQuat` in
//! `body_manager.zig`. Two writings of one conversion are two things that can diverge, and
//! these already had: `character.zig`'s carried an `if (Real == f32) return v;` short
//! circuit the other two did not, so one of the three took a different path at the default
//! precision. That is the failure mode a single point removes by construction.
//!
//! **Why it lives in `api/` and not in `src/interfaces/`.** §1.11.8 places the boundary at
//! the interface tier, "the only place that knows both scalars". `src/interfaces/` wraps an
//! implementation, so `forge_3d` cannot import it without inverting the dependency — and
//! `forge_3d` is exactly where three of the four helpers lived. `api/` is the module's
//! public surface, the mirror of `engine-tier-interfaces.md` §1, and it is imported by
//! `forge_3d`, by the ECS sync seam and by the interface tier alike. It is the only place
//! all three can reach.
//!
//! **One point, four faces, and the reading is deliberate.** A vector and a quaternion
//! cannot share a signature, and hiding both behind an `anytype` facade would erase the
//! very types the boundary exists to name. What "single point" buys is that there is ONE
//! place to edit and ONE place to audit — which the `no_precision_crossing` lint rule turns
//! from an intention into a check.

const math = @import("foundation").math;

/// **The world scalar.** `f32` today, `f64` under `large_world` (`ARCH-022`), and this
/// declaration is the one place that changes when the flag lands. Any site that means "a
/// world-space coordinate" spells it `WorldReal` and never `f32`.
pub const WorldReal = f32;

/// A world-space 3-vector — the type of `BodyDescriptor.position` and of the ECS
/// `Transform`'s position once it is out of its raw array form.
pub const WorldVec3 = math.Vec(3, WorldReal);

/// A world-space rotation.
pub const WorldQuat = math.Quat(WorldReal);

/// **THE ETCH SCALAR.** Etch's `float` is `f64` (`etch-grammar.md` §2.2), and it
/// is a THIRD scalar next to the world's and the solver's — a script writes a
/// literal, not a build configuration, so it cannot follow either.
///
/// The two crossings below are named here for the same reason every other one is:
/// this file is the ONE place that knows more than one scalar, and a `@floatCast`
/// spelled at a service entry would be a second boundary. `no_precision_crossing`
/// is what enforces that, and it is what sent these here — the first version of
/// the physics service spelled its own casts and the guard refused them.
pub const EtchReal = f64;

/// An Etch `float` arriving at the world. Narrowing when the world is `f32`, exact
/// when it is `f64`.
pub fn etchToWorld(v: EtchReal) WorldReal {
    return @floatCast(v);
}

/// A world value leaving for Etch. Widening at `f32`, exact at `f64`, and never
/// lossy in either direction.
pub fn worldToEtch(v: WorldReal) EtchReal {
    return @floatCast(v);
}

/// An Etch `float` triple arriving at the world.
pub fn etchVec3ToWorld(x: EtchReal, y: EtchReal, z: EtchReal) WorldVec3 {
    return WorldVec3.fromArray(.{ etchToWorld(x), etchToWorld(y), etchToWorld(z) });
}

/// A world-space rotation.
/// **The precision boundary, instantiated at a solver scalar.** `forge_3d/root.zig` holds
/// the single instantiation as `cross`; nothing else should instantiate it, since a second
/// instantiation is a second place to look when the world scalar moves.
///
/// The conversions are element-wise and carry no logic: widening is exact, narrowing rounds
/// once and at this site only. Neither direction short-circuits when the two scalars
/// coincide — the round trip through the component array is then the identity on the same
/// type, and a comptime special case would be a second code path for no gain, which is the
/// divergence this file exists to end.
pub fn Crossing(comptime Solver: type) type {
    return struct {
        /// 3-vector at the solver scalar.
        pub const SolverVec3 = math.Vec(3, Solver);
        /// Rotation at the solver scalar.
        pub const SolverQuat = math.Quat(Solver);

        /// World → solver. Exact: the solver scalar is never narrower than the world one
        /// (`large_world` implies `-Dphysics_f64`, §1.11.8).
        pub fn vec3ToSolver(v: WorldVec3) SolverVec3 {
            const a = v.toArray();
            return SolverVec3.fromArray(.{ a[0], a[1], a[2] });
        }

        /// World → solver, rotation. Component-wise, so a unit quaternion stays unit to
        /// within the widening's exactness — which is nothing, widening being exact.
        pub fn quatToSolver(q: WorldQuat) SolverQuat {
            const a = q.toArray();
            return SolverQuat.fromArray(.{ a[0], a[1], a[2], a[3] });
        }

        /// Solver → world. This is the ONLY rounding in the module's public direction, and
        /// the reason the lint rule flags `@floatCast` everywhere else: a narrowing spelled
        /// somewhere else is a rounding nobody counted.
        pub fn vec3ToWorld(v: SolverVec3) WorldVec3 {
            const a = v.toArray();
            return WorldVec3.fromArray(.{ @floatCast(a[0]), @floatCast(a[1]), @floatCast(a[2]) });
        }

        /// Solver → world, SCALAR. The vector and rotation helpers above cover the aggregates;
        /// this covers the lone lengths that travel beside them — a hit distance, a
        /// separation. Added at M1.1.15.1, when `Forge3DModule` became the first caller to
        /// wrap the eight query entries and found that every one of them returns a `distance`
        /// the aggregates do not carry.
        ///
        /// It exists so that those narrowings are AT the boundary rather than spelled at the
        /// adapter, which is what `no_precision_crossing` enforces over
        /// `src/modules/forge/` and `src/interfaces/`. A `@floatCast` written in the adapter
        /// instead would be a rounding nobody counted, in the exact place §1.11.8 says the
        /// boundary is.
        pub fn realToWorld(v: Solver) WorldReal {
            return @floatCast(v);
        }

        /// Solver → world, rotation. A narrowed unit quaternion is unit only to the world
        /// scalar's resolution; every consumer that inverts by conjugation re-normalises on
        /// the way back in, which `vec3ToSolver`'s exactness then preserves.
        pub fn quatToWorld(q: SolverQuat) WorldQuat {
            const a = q.toArray();
            return WorldQuat.fromArray(.{ @floatCast(a[0]), @floatCast(a[1]), @floatCast(a[2]), @floatCast(a[3]) });
        }
    };
}

// --- tests -------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

test "the world scalar is f32 in this build, and moving it is a deliberate act" {
    // A PIN, not a tautology. M1.1.15 states that the world scalar stays `f32` and that
    // `large_world` is a project of its own; this is what makes flipping it break a test
    // that names the decision, instead of sliding through as an edit to one alias.
    try testing.expectEqual(f32, WorldReal);

    // Nothing else is asserted here on purpose. `WorldVec3 = math.Vec(3, WorldReal)` is true
    // BY DEFINITION, so a test comparing the two cannot fail, and a guard that cannot fail
    // is not a guard — this repository has removed one for that exact reason. What actually
    // holds the "no literal `f32` at a crossing" property is the `no_precision_crossing`
    // lint rule and the `f64` build, not an assertion in this file.
}

test "widening is exact and narrowing is the only rounding" {
    const wide = Crossing(f64);

    // Widening: every f32 is an f64 exactly, so the round trip is the identity ON THE BITS
    // and not merely close. A tolerance here would hide a lost component.
    const v = WorldVec3.fromArray(.{ 1.0 / 3.0, -7.25e12, 5.9604645e-8 });
    const back = wide.vec3ToWorld(wide.vec3ToSolver(v));
    try testing.expectEqual(v.toArray(), back.toArray());

    const q = WorldQuat.fromArray(.{ 0.5, -0.5, 0.5, 0.5 });
    const qback = wide.quatToWorld(wide.quatToSolver(q));
    try testing.expectEqual(q.toArray(), qback.toArray());

    // Narrowing: a value that needs more than 24 bits of mantissa MUST lose something, or
    // the test above proves nothing about direction. The two f64 neighbours below collapse
    // onto the same f32, which is exactly what "the only rounding" means.
    const a = wide.vec3ToWorld(wide.SolverVec3.fromArray(.{ 1.0000000000000002, 0, 0 }));
    const b = wide.vec3ToWorld(wide.SolverVec3.fromArray(.{ 1.0, 0, 0 }));
    try testing.expectEqual(a.toArray()[0], b.toArray()[0]);
    try testing.expectEqual(@as(WorldReal, 1.0), a.toArray()[0]);
}

test "at a coinciding scalar the crossing is the identity, with no second code path" {
    // The helper this file replaced carried an `if (Real == f32) return v;` short circuit in
    // one of its three copies. Removing it must not change the answer — measured here rather
    // than argued, on the value a short circuit would have returned untouched.
    const same = Crossing(WorldReal);
    const v = WorldVec3.fromArray(.{ -0.0, 3.4028235e38, 1.1754944e-38 });
    try testing.expectEqual(v.toArray(), same.vec3ToSolver(v).toArray());
    try testing.expectEqual(v.toArray(), same.vec3ToWorld(same.vec3ToSolver(v)).toArray());

    const q = WorldQuat.fromArray(.{ 0, 0, 0, 1 });
    try testing.expectEqual(q.toArray(), same.quatToWorld(same.quatToSolver(q)).toArray());
}
