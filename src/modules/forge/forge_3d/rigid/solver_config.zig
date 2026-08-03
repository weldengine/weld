//! `forge_3d/rigid/solver_config.zig` — the rigid contact solver's tuning, shared
//! by the two passes of the normative per-tick cycle (`engine-physics-forge.md`
//! §1.7): the Sequential Impulses VELOCITY pass (§1.7.1, `velocity_solver.zig`)
//! and the NGS POSITION pass (§1.7.2, `position_solver.zig`).
//!
//! One struct read by two solvers belongs in neither, so it lives here. It was
//! born in `velocity_solver.zig` at M1.1.6 — with `velocity_iterations` named
//! explicitly for the `position_iterations` sibling this file adds — and moved at
//! M1.1.7 when the position pass landed. Both solvers import it and
//! `rigid/root.zig` re-exports it from this owner, so call sites keep naming
//! `rigid.SolverConfig`; the velocity half is unchanged by the move.
//!
//! `penetration_slop` and `max_penetration_correction` are absolute lengths in
//! metres, and that is assumed: they are PHYSICAL tolerances of the internal unit
//! scale (`engine-units.md`), the same class as `restitution_threshold`. They
//! classify nothing and guard no numerical degeneracy — every other guard in the
//! rigid solver fires at true zero. They are deliberately not derived from a scale
//! (§1.7.2): a body-size-derived slop would make the resting overlap pair-dependent
//! (a small body resting on a big one would sink by the big one's slop — a
//! non-uniform rest offset in a stack), and a contact-coordinate-derived one would
//! make it depend on where in the world the contact is.
//!
//! **A THIRD member of that family lives elsewhere, and deliberately.**
//! `mesh.default_active_edge_cos_threshold` (M1.1.11.1, default `cos(5°)`) is a physical
//! parameter of exactly this class — it selects a modelling behaviour, not a numerical
//! tolerance, and the `k · floatEps(T) · coordScale` discipline does not apply to it. It
//! is NOT declared here because the mesh's active-edge flags are BAKED AT CREATION: a
//! field on this struct would be read long after the decision it governs had been taken,
//! and changing it at runtime would silently rebuild nothing. This cross-reference is
//! what keeps the family readable from one place; see that declaration for the rest.

const std = @import("std");
const config = @import("../config.zig");

const Real = config.Real;

/// Rigid contact-solver tuning: the velocity pass (§1.7.1) then the position pass
/// (§1.7.2). Defaults are the spec's §1.7.2 table plus the M1.1.6 velocity half.
pub const SolverConfig = struct {
    // --- Velocity pass (Sequential Impulses, §1.7.1) ---

    /// Gauss-Seidel velocity iteration passes per tick. 0 is allowed — warm start
    /// only, no solve.
    ///
    /// 16, not the 8 of the Box2D tuning family: that number is 2D, where a contact
    /// patch is two points and a rotation is one scalar. A 3D face patch carries
    /// four points and a five-deep stack forty, and 8 is under-provisioned at that
    /// depth — measured at M1.1.7, a five-box stack never comes to rest at 8 and
    /// stops dead at 16. 16 is a measured FLOOR, not a first-principles result:
    /// there is no derivation of the required budget from chain depth, patch size or
    /// mass ratio, only the measurement that 16 puts this configuration inside the
    /// convergence basin.
    ///
    /// A claim written here at M1.1.7 — that Jolt uses no global constant and
    /// derives the budget per island, so a deep stack automatically gets more
    /// iterations — was READ ON THE SOURCE at M1.1.8 and is false in both halves
    /// (`engine-physics-forge.md` §1.8.2). Jolt does carry global defaults
    /// (`PhysicsSettings.h`: `mNumVelocitySteps = 10`, `mNumPositionSteps = 2`), and
    /// its per-island aggregation (`CalculateSolverSteps.h`) is a MAXIMUM over
    /// overrides supplied by the author on bodies and constraints, falling back on
    /// the global default when none is set. No heuristic of any kind reads the
    /// topology: under Jolt a deep stack receives exactly the global default.
    ///
    /// So this stays a global default and a floor. The velocity pass's EARLY-OUT
    /// (§1.8.2) is EXACT and free, but its yield is scene- AND precision-dependent,
    /// because the predicate is a true-zero test: it fires only once `Δλ` underflows
    /// to exactly zero, which happens sooner in coarser precision. Measured on a
    /// resting five-box stack (40 contact points), ceiling 16: 11 iterations at f32,
    /// all 16 at f64. The unambiguous saving is the position pass — 1 of 3 at rest at
    /// both precisions. So this field is NOT a ceiling that is generally left
    /// unreached; it remains a MEASURED floor, and raising it locally is what the
    /// additive per-body override channel is for (no Phase-1 consumer).
    velocity_iterations: u32 = 16,
    /// Restitution cutoff (m/s): a bounce is applied only when the pre-solve
    /// relative normal speed exceeds this — a PHYSICAL velocity constant (config
    /// field), not a geometric epsilon. Below it, low-speed contacts settle
    /// without jitter.
    restitution_threshold: Real = 1.0,

    // --- Position pass (NGS, §1.7.2) ---

    /// NGS position passes per tick. 0 is legal: no position correction at all
    /// (velocity-only behaviour, the M1.1.6 contract).
    position_iterations: u32 = 3,
    /// Stationary overlap allowed at rest (m). Its role is contact PERSISTENCE:
    /// a small steady overlap keeps the contact — and therefore its warm-start
    /// cache entry — alive instead of oscillating between contact and no contact.
    /// The 5 mm is the Box2D tuning family, not Jolt's 2 cm, which is coupled to
    /// its speculative-contact distance (a number without its reason until
    /// speculative contacts ship). It is independent of the iteration budget: the
    /// slop sets WHERE the position pass stops, not how fast either pass converges.
    penetration_slop: Real = 0.005,
    /// NGS under-relaxation: the fraction of the measured error a pass resorbs.
    /// NOT a Baumgarte velocity bias — the velocity pass carries none. Above 1 it
    /// over-relaxes and can diverge, hence the `[0, 1]` domain.
    position_correction_factor: Real = 0.2,
    /// Clamp on the penetration ERROR a single pass takes into account (m) — "never
    /// try to resorb more than this at once". It bounds the error going in, not the
    /// correction coming out (Jolt `mMaxPenetrationDistance` semantics).
    max_penetration_correction: Real = 0.2,
};

/// Debug-assert the position pass's config domain at its entry, mirroring the
/// velocity pass's `restitution_threshold` guard (M1.1.6): all three `Real` fields
/// finite, `penetration_slop >= 0`, `max_penetration_correction >= 0`, and
/// `position_correction_factor` in `[0, 1]` (a factor above 1 over-relaxes and can
/// diverge). `position_iterations` is a `u32`, so its domain holds by type — and
/// 0 is legal.
pub fn assertPositionDomain(cfg: SolverConfig) void {
    std.debug.assert(std.math.isFinite(cfg.penetration_slop) and cfg.penetration_slop >= 0);
    std.debug.assert(std.math.isFinite(cfg.max_penetration_correction) and cfg.max_penetration_correction >= 0);
    std.debug.assert(std.math.isFinite(cfg.position_correction_factor) and
        cfg.position_correction_factor >= 0 and cfg.position_correction_factor <= 1);
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;

test "solver config position defaults" {
    const cfg = SolverConfig{};
    try testing.expectEqual(@as(u32, 3), cfg.position_iterations);
    try testing.expectEqual(@as(Real, 0.005), cfg.penetration_slop);
    try testing.expectEqual(@as(Real, 0.2), cfg.position_correction_factor);
    try testing.expectEqual(@as(Real, 0.2), cfg.max_penetration_correction);
    // The velocity half: `restitution_threshold` carried over unchanged by the
    // relocation, `velocity_iterations` raised 8 → 16 at M1.1.7 (see its doc).
    try testing.expectEqual(@as(u32, 16), cfg.velocity_iterations);
    try testing.expectEqual(@as(Real, 1.0), cfg.restitution_threshold);
    // The defaults are inside the domain the position entry asserts.
    assertPositionDomain(cfg);
}
