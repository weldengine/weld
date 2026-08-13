//! `forge_3d/pipeline/integration.zig` — semi-implicit (symplectic) Euler
//! integration over the live `BodyManager` SoA store, split into a velocity pass
//! and a position pass.
//!
//! `integrateVelocities` applies gravity + the force/torque accumulators + the
//! clamped damping (and clears the accumulators); `integratePositions` advances
//! position and orientation from the CURRENT velocity. `integrate` is their exact
//! composition.
//!
//! `integrateVelocities` is ITSELF a composition since M1.1.13.1 —
//! `integrateVelocitiesNoReset` then `resetForceAccumulators` — because a substepped
//! solver calls the velocity half once per substep and must not have the
//! accumulators consumed out from under it on the first one. The decomposition is
//! exact and the fused entries keep their behaviour bit-for-bit, so every M1.1.5 pin
//! reads the same values it did (the same move M1.1.5 made when it split `integrate`
//! itself; see `integrateVelocitiesNoReset` for the arithmetic that forces it). The split exists because the Sequential Impulses contact solver
//! (M1.1.6) must run BETWEEN the two — it corrects velocities after gravity but
//! before positions advance. Solving around the fused pass would leave the
//! per-tick `g·dt` residual advancing positions (a resting body would sink
//! ≈ g·dt² per tick). With no solve in between, the two halves reproduce the
//! fused pass bit-for-bit (pinned by `tests/integration_test.zig`).
//!
//! Each pass is one pure per-tick sweep in ascending slot-index order
//! (deterministic — no hash container on the path, the `BodyManager` discipline;
//! M1.1.14). The store does not compact, so each walks `0..bodies.len` and filters
//! liveness with `IdAllocator.isAliveIndex`. This is FREE-FLIGHT integration:
//! broadphase and narrowphase exist but are NOT invoked here, and contact response
//! is the solver's job (M1.1.6) — under gravity alone a dynamic body follows an
//! unobstructed trajectory.
//!
//! Semi-implicit Euler: velocity is integrated first, position from the *new*
//! velocity. Gravity is applied as an ACCELERATION scaled by `gravity_factor`
//! (mass-independent — Galileo), never as a force. Damping is the Jolt
//! clamped-linear form `v *= max(0, 1 − d·dt)`; the clamp is physical (it
//! prevents a sign flip when `d·dt > 1`), not a geometric epsilon. The
//! `force`/`torque` accumulators are reset every fixed tick for ALL live bodies
//! (`engine-physics-forge.md` §2) by the velocity pass. `integrateVelocities`
//! applies damping exactly once with the `dt` it is given and has no opinion on
//! substeps — call cadence is the orchestrator's concern (M1.1.15).
//!
//! Angular integration mirrors the linear half: the torque is mapped through the
//! world-space inverse inertia `I_world_inv = R · I_local_inv · Rᵀ`, `ω` is
//! integrated then clamp-damped (velocity pass), and the orientation advances by
//! the first-order (linearized) rule `q ← normalize(q + ½·dt·(ω_quat ⊗ q))` with
//! the world-space `ω` on the LEFT (position pass). That form divides by no `|ω|`,
//! so it is singularity-free at `ω = 0` (no zero guard needed — the M1.1.4
//! threshold discipline is honoured). The gyroscopic term `ω × (I·ω)` is dropped
//! (Jolt/PhysX/Bevy default; its explicit integration injects energy).

const config = @import("../config.zig");
const body_manager = @import("../body_manager.zig");

const Real = config.Real;
const Vec3r = config.Vec3r;
const Quatr = config.Quatr;
const Mat3r = config.Mat3r;
const BodyManager = body_manager.BodyManager;

/// Integrate velocities one fixed tick of `dt` seconds under world-space
/// `gravity` (m/s²), in ascending slot-index order, then clear the per-tick
/// force/torque accumulators for every live body.
///
/// SLEEPING bodies are skipped (`engine-physics-forge.md` §1.8.6) — but only for
/// the integration itself: the accumulator reset stays uniform over all live
/// bodies, sleepers included, so a force applied to a sleeper (which wakes it) is
/// never left to fire twice.
///
/// For each DYNAMIC body — linear: `a = gravity·gravity_factor + force·inv_mass`;
/// `v += a·dt`; `v *= max(0, 1 − linear_damping·dt)`. Angular:
/// `α = (R·I_local_inv·Rᵀ)·torque`; `ω += α·dt`;
/// `ω *= max(0, 1 − angular_damping·dt)`. Static and kinematic bodies keep their
/// velocity. Positions and orientations are NOT touched — `integratePositions`
/// advances them (in the full pipeline, after the contact solver has run).
pub fn integrateVelocities(bm: *BodyManager, dt: Real, gravity: Vec3r) void {
    integrateVelocitiesNoReset(bm, dt, gravity);
    resetForceAccumulators(bm);
}

/// `integrateVelocities` WITHOUT the accumulator reset — the form the substepped
/// solver calls once per substep (`engine-physics-solver.md` §1.7, step 6).
///
/// **The split is a correctness requirement of substepping, not a refactor.** The
/// fused form CONSUMES the accumulators: it reads `force`/`torque`, applies them,
/// and clears them. Called `n` times with `h = dt/n` it would therefore apply an
/// accumulated force on the FIRST substep only and deliver `F/m·h` over the tick —
/// a quarter of `F/m·dt` at the default four substeps. That is not a reading in
/// need of a probe: `tests/integration_test.zig` already pins the consumption in so
/// many words, "second tick with no re-apply: no force contribution".
///
/// Gravity and damping, by contrast, want the per-substep call and get it: gravity
/// accumulates to `g·dt` over the `n` slices, exactly as §1.7 step 3 requires of any
/// constant force, and damping becomes `(1 − d·h)^n` — substep-count-sensitive,
/// which M1.1.5 recorded as the orchestrator's decision and §1.7 step 6 now takes.
///
/// The reset therefore runs ONCE, after the LAST substep (`resetForceAccumulators`),
/// never before the first: clearing an accumulator before anything consumes it
/// delivers `F/m·0`, which is a worse defect than the `1/n` it would be trying to
/// fix. Step 3 of the cycle owns no code at all — the accumulators are constant for
/// the whole of `step()`, so they ARE the tick's accelerations, and reading them per
/// substep needs neither a capture nor a scratch column.
pub fn integrateVelocitiesNoReset(bm: *BodyManager, dt: Real, gravity: Vec3r) void {
    const rotations = bm.bodies.items(.rotation);
    const linear_velocities = bm.bodies.items(.linear_velocity);
    const angular_velocities = bm.bodies.items(.angular_velocity);
    const forces = bm.bodies.items(.force);
    const torques = bm.bodies.items(.torque);
    const motions = bm.bodies.items(.motion);
    const body_types = bm.bodies.items(.body_type);
    const flags = bm.bodies.items(.flags);

    const n: u32 = @intCast(bm.bodies.len);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        // The store never compacts, so dead slots sit between live ones — skip
        // them (their stale data must not be integrated).
        if (!bm.alloc.isAliveIndex(i)) continue;

        // A sleeper is not simulated (§1.8.6).
        if (body_types[i] != .dynamic or flags[i].sleeping) continue;
        const mp = motions[i];

        // --- Linear ---
        // Gravity as an acceleration (mass-independent), plus the accumulated
        // force divided by mass.
        const accel = gravity.scale(mp.gravity_factor).add(forces[i].scale(mp.inv_mass));
        const v = linear_velocities[i].add(accel.scale(dt));
        const damp = @max(@as(Real, 0), 1 - mp.linear_damping * dt);
        linear_velocities[i] = v.scale(damp);

        // --- Angular ---
        // World-space inverse inertia I_world_inv = R · I_local_inv · Rᵀ
        // (Rᵀ == R⁻¹ for an orthonormal rotation), then α = I_world_inv·τ.
        const r = Mat3r.fromQuat(rotations[i]);
        const i_world_inv = r.mul(mp.local_inv_inertia).mul(r.transpose());
        const alpha = i_world_inv.mulVec(torques[i]);
        const w = angular_velocities[i].add(alpha.scale(dt));
        const ang_damp = @max(@as(Real, 0), 1 - mp.angular_damping * dt);
        angular_velocities[i] = w.scale(ang_damp);
    }
}

/// Clear the per-tick force and torque accumulators, UNIFORMLY over every live body
/// (`engine-physics-forge.md` §2) — static and kinematic included, sleepers
/// included. Dead slots are left exactly as they are: the store does not compact,
/// and a freed slot's stale columns are nobody's business until it is reused.
///
/// Runs ONCE per tick, at the END of step 6 (after the last substep, before the
/// restitution pass), which is the only placement that both consumes the
/// accumulators `substep_count` times and leaves nothing behind for the next tick.
pub fn resetForceAccumulators(bm: *BodyManager) void {
    const forces = bm.bodies.items(.force);
    const torques = bm.bodies.items(.torque);

    const n: u32 = @intCast(bm.bodies.len);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (!bm.alloc.isAliveIndex(i)) continue;
        forces[i] = Vec3r.zero;
        torques[i] = Vec3r.zero;
    }
}

/// Advance every live DYNAMIC body's position and orientation one fixed tick of
/// `dt` seconds from its CURRENT velocity, in ascending slot-index order. Call
/// this AFTER `integrateVelocities` (in the full pipeline, after the contact
/// solver has corrected velocities).
///
/// Linear: `x += linear_velocity·dt`. Angular (first-order, world-space `ω` on
/// the left): `q ← normalize(q + ½·dt·(ω_quat ⊗ q))`. Static and kinematic bodies
/// are not moved (kinematic position-from-velocity is a later additive concern).
pub fn integratePositions(bm: *BodyManager, dt: Real) void {
    const positions = bm.bodies.items(.position);
    const rotations = bm.bodies.items(.rotation);
    const linear_velocities = bm.bodies.items(.linear_velocity);
    const angular_velocities = bm.bodies.items(.angular_velocity);
    const body_types = bm.bodies.items(.body_type);
    const flags = bm.bodies.items(.flags);

    const n: u32 = @intCast(bm.bodies.len);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (!bm.alloc.isAliveIndex(i)) continue;
        if (body_types[i] != .dynamic) continue;
        if (flags[i].sleeping) continue; // a sleeper's pose is frozen (§1.8.6)

        // Position from the current (post-solve) velocity.
        positions[i] = positions[i].add(linear_velocities[i].scale(dt));

        // First-order orientation update: q ← normalize(q + ½·dt·(ω_quat ⊗ q)),
        // world-space ω on the LEFT. No |ω| division ⇒ singularity-free at ω = 0.
        const wa = angular_velocities[i].toArray();
        const w_quat = Quatr{ .x = wa[0], .y = wa[1], .z = wa[2], .w = 0 };
        const dq = w_quat.mul(rotations[i]).scale(0.5 * dt);
        rotations[i] = rotations[i].add(dq).normalize();
    }
}

/// Advance every live body one fixed tick of `dt` seconds under world-space
/// `gravity` (m/s²): the exact composition of `integrateVelocities` then
/// `integratePositions`, with no contact solve between (free flight). Existing
/// M1.1.5 call sites and tests use this fused form unchanged; the full pipeline
/// (M1.1.15) calls the two halves directly with the solver in between.
pub fn integrate(bm: *BodyManager, dt: Real, gravity: Vec3r) void {
    integrateVelocities(bm, dt, gravity);
    integratePositions(bm, dt);
}
