//! `forge_3d/pipeline/sleep.zig` — sleep detection: the per-body window sweep, the
//! eligibility predicate, and the sleep transition itself.
//!
//! Sleeping and island partitioning are one model (`engine-physics-forge.md` §1.8):
//! the MEASURE is per body, the DECISION is per island. This file owns the measure
//! and the mechanism; the arbitration — an island sleeps only if EVERY member is
//! eligible — belongs to `rigid/island_manager.zig`. Like `integration.zig`, this
//! is a sweep over the `BodyManager` SoA store and sits at the same level: shared
//! pipeline, no `rigid/` type, no constraint.
//!
//! **The criterion is a displacement bound over a window, not an instantaneous
//! velocity.** Each body remembers the reference pose its window opened at; every
//! tick it measures how far it has moved from that reference, and the window either
//! advances or restarts:
//!
//! ```
//! Δq = q_current ⊗ conj(q_ref)
//! d  = |x_current − x_ref| + 2·sleep_radius·|vec(Δq)|
//! d > maxDisplacement() : reference ← current pose ; window ← 0
//! otherwise             : window += dt ; eligible once window >= time_before_sleep
//! ```
//!
//! The rotational term is the EXACT maximum displacement of a point at
//! `sleep_radius` from the centre, through the identity `2·sin(θ/2) = 2·|vec(Δq)|`
//! — so no trigonometry, as cross-platform determinism requires (§1.5). Their sum
//! is a triangle bound rather than the exact combined maximum: `d` OVER-estimates
//! the displacement of every material point of the body, which is conservative in
//! the right direction — it never makes sleeping easier than it should be.
//!
//! Two things the instantaneous-velocity criterion this replaces would get wrong,
//! and which the tests pin: it resets on a single noisy tick, and it never sleeps a
//! jittering body — which is one of the things sleeping exists to kill.
//!
//! Divergence from Jolt, assumed (§1.8.3): Jolt tracks three points (the centre of
//! mass and the centres of the two bounding-box faces furthest from it) and wraps
//! their trajectories in growing spheres — about a dozen accumulated scalars per
//! body and a sphere centre that drifts. A reference pose plus a radius carries the
//! same meaning ("the body's configuration has not changed by more than
//! `maxDisplacement()` during the window") with no accumulation, by bounding
//! instead of measuring a spread. One corollary of Jolt's choice disappears here: a
//! body spinning about the axis through its two test points moves neither of them
//! and can sleep under Jolt, whereas a radius bound sees every rotation.
//!
//! **The sleep masks slow drift, by construction.** A displacement bound lets a body
//! that creeps while staying under `maxDisplacement()` per window fall asleep: a
//! 5 mm/s drift is 2.5 mm over 0.5 s, far below 15 mm. The corollary is NORMATIVE —
//! every solver convergence measurement in this repository runs with
//! `allow_sleeping = false`.

const std = @import("std");
const api = @import("weld_forge");
const config = @import("../config.zig");
const body_manager = @import("../body_manager.zig");

const Real = config.Real;
const Vec3r = config.Vec3r;
const BodyManager = body_manager.BodyManager;
const BodyId = api.BodyId;

/// Sleep tuning. `point_velocity_threshold` and `time_before_sleep` are PHYSICAL
/// constants in the internal unit scale (m/s and s, `engine-units.md`), the same
/// class as `restitution_threshold` and `penetration_slop`: they classify no
/// numerical degeneracy and guard no zero. Every numerical guard on this path stays
/// at true zero.
pub const SleepConfig = struct {
    /// Global switch. `false` disables all sleeping and changes nothing else.
    allow_sleeping: bool = true,
    /// Admissible movement speed of a point of the body during the window (m/s).
    point_velocity_threshold: Real = 0.03,
    /// How long the body must stay under the bound before becoming eligible (s).
    time_before_sleep: Real = 0.5,

    /// The displacement tolerated over the whole window (m) —
    /// `point_velocity_threshold · time_before_sleep`, 15 mm at the defaults. Named
    /// rather than written as a literal anywhere: it is the derived quantity the
    /// criterion is actually expressed in.
    pub fn maxDisplacement(self: SleepConfig) Real {
        return self.point_velocity_threshold * self.time_before_sleep;
    }
};

/// Debug-assert the sleep config's domain at the entry of each pass, mirroring the
/// solver's `assertPositionDomain` (M1.1.7): both `Real` fields finite and `>= 0`.
/// `allow_sleeping` is a `bool`, so its domain holds by type.
pub fn assertDomain(cfg: SleepConfig) void {
    std.debug.assert(std.math.isFinite(cfg.point_velocity_threshold) and cfg.point_velocity_threshold >= 0);
    std.debug.assert(std.math.isFinite(cfg.time_before_sleep) and cfg.time_before_sleep >= 0);
}

/// Advance every awake dynamic body's sleep window by `dt`, in ascending slot-index
/// order (deterministic — the `BodyManager` sweep discipline, M1.1.14).
///
/// This is step 11 of the normative per-tick cycle (§1.7) and runs on the
/// POST-SOLVE state. Static and kinematic bodies are skipped: they never join an
/// island (§1.8.1), so their window would never be read. A sleeping body is skipped
/// too — its state is frozen (§1.8.6).
pub fn updateWindows(bm: *BodyManager, dt: Real, cfg: SleepConfig) void {
    assertDomain(cfg);

    const positions = bm.bodies.items(.position);
    const rotations = bm.bodies.items(.rotation);
    const ref_positions = bm.bodies.items(.sleep_ref_position);
    const ref_rotations = bm.bodies.items(.sleep_ref_rotation);
    const sleep_times = bm.bodies.items(.sleep_time);
    const radii = bm.bodies.items(.sleep_radius);
    const body_types = bm.bodies.items(.body_type);
    const flags = bm.bodies.items(.flags);

    const n: u32 = @intCast(bm.bodies.len);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (!bm.alloc.isAliveIndex(i)) continue;
        if (body_types[i] != .dynamic) continue;
        if (flags[i].sleeping) continue;

        // How far the body has moved since its window opened. The rotational term
        // is the exact displacement of a point at `sleep_radius` from the centre,
        // via `2·sin(θ/2) = 2·|vec(Δq)|` — no trigonometry, no `|Δθ|` division, so
        // it is regular at zero rotation and needs no guard.
        const delta_position = positions[i].sub(ref_positions[i]).length();
        const delta_rotation = rotations[i].mul(ref_rotations[i].conjugate()).toArray();
        const sin_half_angle = @sqrt(delta_rotation[0] * delta_rotation[0] +
            delta_rotation[1] * delta_rotation[1] +
            delta_rotation[2] * delta_rotation[2]);
        const displacement = delta_position + 2 * radii[i] * sin_half_angle;

        if (displacement > cfg.maxDisplacement()) {
            ref_positions[i] = positions[i];
            ref_rotations[i] = rotations[i];
            sleep_times[i] = 0;
        } else {
            // Saturate at the threshold: the window's whole meaning is "has it been
            // still long enough", so growing it without bound past that point would
            // only accumulate float error in a value nothing reads beyond the
            // comparison and the debug overlay (§1.8.9).
            sleep_times[i] = @min(cfg.time_before_sleep, sleep_times[i] + dt);
        }
    }
}

/// Whether `id` may fall asleep right now: sleeping is globally enabled, the body
/// allows it, and its window is full. False on a stale/invalid handle.
///
/// This is the PER-BODY half of the decision. An island sleeps only when this holds
/// for every one of its members (§1.8.3) — that reduction is the island manager's.
pub fn isEligible(bm: *const BodyManager, id: BodyId, cfg: SleepConfig) bool {
    if (!cfg.allow_sleeping) return false;
    const idx = bm.alloc.validate(id) orelse return false;
    if (!bm.bodies.items(.flags)[idx].can_sleep) return false;
    return bm.bodies.items(.sleep_time)[idx] >= cfg.time_before_sleep;
}

/// Put `id` to sleep: raise the flag and zero BOTH velocities exactly. No-op on a
/// stale/invalid handle.
///
/// The MECHANISM only — it asks no question and checks no eligibility. Whether a
/// body should sleep is an island decision taken at step 11 of the cycle and
/// nowhere else (§1.8.3); this is what that decision calls once taken.
///
/// The discarded velocity residue is bounded by the sleep criterion itself. Zeroing
/// it is an assumed physical approximation, and it is what guarantees that a woken
/// body does not resume with a stale velocity.
pub fn putToSleep(bm: *BodyManager, id: BodyId) void {
    const idx = bm.alloc.validate(id) orelse return;
    bm.bodies.items(.flags)[idx].sleeping = true;
    bm.bodies.items(.linear_velocity)[idx] = Vec3r.zero;
    bm.bodies.items(.angular_velocity)[idx] = Vec3r.zero;
}
