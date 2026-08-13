//! `forge_3d/rigid/solver_config.zig` — the rigid contact solver's tuning, read by
//! the substepped solver of the normative per-tick cycle
//! (`engine-physics-solver.md` §1.7): the substep loop of step 6 (§1.7.1) and the
//! restitution pass of step 7 (§1.7.2).
//!
//! It was born in `velocity_solver.zig` at M1.1.6, moved here at M1.1.7 when a
//! second pass began reading it, and outlived both of those passes at M1.1.13.1.
//! The doc header cited `engine-physics-forge.md` §1.7 until then — stale since the
//! M1.1.12 file split moved §1.7 into `engine-physics-solver.md`.
//!
//! **What the port removed, and why none of it is deferred.** `velocity_iterations`
//! and `position_iterations` were budgets of a big-step model that no longer exists:
//! each substep runs exactly one biased sweep and one relax sweep, a cost fixed BY
//! CONSTRUCTION rather than by a predicate, so there is no budget left to spend.
//! `position_correction_factor` and `max_penetration_correction` were the NGS pass's
//! under-relaxation and its per-pass error clamp; position error is now corrected by
//! the velocity bias inside the loop, and its rate is bounded by
//! `contact_push_max_speed` instead. The 16-iteration floor M1.1.7 MEASURED goes with
//! them — the five-box stack that established it is the acceptance oracle of the port
//! and now comes to rest on `substep_count = 4`.
//!
//! **Threshold class.** `penetration_slop`, `restitution_threshold` and
//! `contact_push_max_speed` are PHYSICAL tolerances in the internal unit scale
//! (`engine-units.md`) — metres, m/s, m/s. They classify nothing and guard no
//! numerical degeneracy; every other guard in the rigid solver fires at true zero.
//! `contact_hertz` and `contact_damping_ratio` are authored parameters of the same
//! family: a stiffness and a damping ratio are meaningful to a designer, where an
//! iteration count encodes the solver's schema into the configuration
//! (`engine-physics-forge.md` §1.6, motive 4).
//!
//! `penetration_slop` is deliberately NOT derived from a scale (§1.7.1): a
//! body-size-derived slop would make the resting overlap pair-dependent (a small body
//! resting on a big one would sink by the big one's slop — a non-uniform rest offset
//! in a stack), and a contact-coordinate-derived one would make it depend on where in
//! the world the contact is.
//!
//! **A member of that family lives elsewhere, and deliberately.**
//! `mesh.default_active_edge_cos_threshold` (M1.1.11.1, default `cos(5°)`) selects a
//! modelling behaviour, not a numerical tolerance, so the `k · floatEps(T) ·
//! coordScale` discipline does not apply to it either. It is NOT declared here
//! because a mesh's active-edge flags are BAKED AT CREATION: a field on this struct
//! would be read long after the decision it governs had been taken.

const std = @import("std");
const config = @import("../config.zig");

const Real = config.Real;

/// Rigid contact-solver tuning for the substepped model (§1.7.1). Defaults are the
/// spec's §1.7.1 configuration table.
pub const SolverConfig = struct {
    /// Substeps per tick — the whole budget of the solver, and the only knob that
    /// buys convergence. `1` is legal and is the degenerate big-step A/B lever;
    /// `0` is illegal and asserts (`assertDomain`), a `u32` giving no other floor.
    ///
    /// 4 is the reference tuning. It is not a measured floor the way
    /// `velocity_iterations = 16` was: sub-sampling attacks the DISCRETISATION error
    /// (~h² per substep), which iterating cannot reduce at all, so the five-box stack
    /// that never came to rest at 8 iterations comes to rest here on four substeps
    /// (`engine-physics-forge.md` §1.6, motive 1).
    substep_count: u32 = 4,
    /// Contact-constraint stiffness (Hz). Clamped per tick to an eighth of the
    /// substep rate before use (`contact_constraint.effectiveContactHertz`): a
    /// constraint cannot be stiffer than the discretisation can resolve. At the
    /// defaults the clamp binds at equality and changes nothing.
    contact_hertz: Real = 30.0,
    /// Contact-constraint damping ratio (dimensionless). Well above critical: contact
    /// is a unilateral constraint, and an underdamped one visibly rings.
    contact_damping_ratio: Real = 10.0,
    /// Ceiling on the speed at which penetration is resorbed (m/s). Recovery is
    /// PACED — a deep overlap comes out over several ticks — rather than teleported
    /// the way the removed NGS pass resorbed it in one frame, which left pose and
    /// velocity inconsistent on the following tick (§1.7.2).
    contact_push_max_speed: Real = 3.0,
    /// Restitution cutoff (m/s): a bounce is applied only when the pre-solve relative
    /// normal speed reaches or exceeds this, approaching. Below it, low-speed contacts
    /// settle without jitter. Unchanged since M1.1.6.
    restitution_threshold: Real = 1.0,
    /// Stationary overlap allowed at rest (m). Its role is contact PERSISTENCE: a
    /// small steady overlap keeps the contact — and therefore its warm-start cache
    /// entry — alive instead of oscillating between contact and no contact. Consumed
    /// as the dead-zone offset of the biased solve's error term, `min(s + slop, 0)`.
    ///
    /// The 5 mm is the Box2D tuning family, not Jolt's 2 cm, which is coupled to its
    /// speculative-contact distance — a number without its reason until speculative
    /// contacts ship, at which point this offset goes to zero and the reference's own
    /// form is restored exactly.
    penetration_slop: Real = 0.005,
};

/// Debug-assert the solver config's domain at the entries that consume it. All five
/// `Real` fields finite; `contact_hertz` strictly positive (which is what makes the
/// reference's zero-hertz branch unreachable, so it is not ported); the other three
/// non-negative; `substep_count >= 1`, since zero substeps would advance no time at
/// all while reporting a completed tick.
pub fn assertDomain(cfg: SolverConfig) void {
    std.debug.assert(cfg.substep_count >= 1);
    std.debug.assert(std.math.isFinite(cfg.contact_hertz) and cfg.contact_hertz > 0);
    std.debug.assert(std.math.isFinite(cfg.contact_damping_ratio) and cfg.contact_damping_ratio >= 0);
    std.debug.assert(std.math.isFinite(cfg.contact_push_max_speed) and cfg.contact_push_max_speed >= 0);
    std.debug.assert(std.math.isFinite(cfg.restitution_threshold) and cfg.restitution_threshold >= 0);
    std.debug.assert(std.math.isFinite(cfg.penetration_slop) and cfg.penetration_slop >= 0);
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;

test "solver config defaults" {
    const cfg = SolverConfig{};
    try testing.expectEqual(@as(u32, 4), cfg.substep_count);
    try testing.expectEqual(@as(Real, 30.0), cfg.contact_hertz);
    try testing.expectEqual(@as(Real, 10.0), cfg.contact_damping_ratio);
    try testing.expectEqual(@as(Real, 3.0), cfg.contact_push_max_speed);
    try testing.expectEqual(@as(Real, 1.0), cfg.restitution_threshold);
    try testing.expectEqual(@as(Real, 0.005), cfg.penetration_slop);
    // The defaults are inside the domain the solver entries assert.
    assertDomain(cfg);
}

test "the degenerate big-step config is legal" {
    // `substep_count = 1` must pass the domain: it is the A/B lever, not an error.
    assertDomain(.{ .substep_count = 1 });
}
