//! `forge_3d/pipeline/integration.zig` — semi-implicit (symplectic) Euler
//! integration over the live `BodyManager` SoA store.
//!
//! One pure per-tick pass in ascending slot-index order (deterministic — no hash
//! container on the path, the `BodyManager` discipline; M1.1.14). The store does
//! not compact, so the pass walks `0..bodies.len` and filters liveness with
//! `IdAllocator.isAliveIndex`. This is FREE-FLIGHT integration: broadphase and
//! narrowphase exist but are NOT invoked here, and there is no contact response
//! (Sequential Impulses is M1.1.6) — a dynamic body under gravity follows an
//! unobstructed trajectory.
//!
//! Semi-implicit Euler: velocity is integrated first, position from the *new*
//! velocity. Gravity is applied as an ACCELERATION scaled by `gravity_factor`
//! (mass-independent — Galileo), never as a force. Damping is the Jolt
//! clamped-linear form `v *= max(0, 1 − d·dt)`; the clamp is physical (it
//! prevents a sign flip when `d·dt > 1`), not a geometric epsilon. The
//! `force`/`torque` accumulators are reset every fixed tick for ALL live bodies
//! (`engine-physics-forge.md` §2). `integrate` applies damping exactly once with
//! the `dt` it is given and has no opinion on substeps — call cadence is the
//! orchestrator's concern (M1.1.15).
//!
//! Angular integration mirrors the linear half: the torque is mapped through the
//! world-space inverse inertia `I_world_inv = R · I_local_inv · Rᵀ`, `ω` is
//! integrated then clamp-damped, and the orientation advances by the first-order
//! (linearized) rule `q ← normalize(q + ½·dt·(ω_quat ⊗ q))` with the world-space
//! `ω` on the LEFT. That form divides by no `|ω|`, so it is singularity-free at
//! `ω = 0` (no zero guard needed — the M1.1.4 threshold discipline is honoured).
//! The gyroscopic term `ω × (I·ω)` is dropped (Jolt/PhysX/Bevy default; its
//! explicit integration injects energy).

const config = @import("../config.zig");
const body_manager = @import("../body_manager.zig");

const Real = config.Real;
const Vec3r = config.Vec3r;
const Quatr = config.Quatr;
const Mat3r = config.Mat3r;
const BodyManager = body_manager.BodyManager;

/// Advance every live body one fixed tick of `dt` seconds under world-space
/// `gravity` (m/s²), in ascending slot-index order.
///
/// For each DYNAMIC body — linear: `a = gravity·gravity_factor + force·inv_mass`;
/// `v += a·dt`; `v *= max(0, 1 − linear_damping·dt)`; `x += v·dt` (position from
/// the new velocity). Angular: `α = (R·I_local_inv·Rᵀ)·torque`; `ω += α·dt`;
/// `ω *= max(0, 1 − angular_damping·dt)`; `q ← normalize(q + ½·dt·(ω_quat ⊗ q))`
/// with world-space `ω` on the left. Static and kinematic bodies are not moved
/// (kinematic position-from-velocity is a later additive concern). Every live
/// body then has its `force`/`torque` accumulators cleared for the next tick.
///
/// This is a pure function of the store and `(dt, gravity)`: no broadphase,
/// narrowphase, contacts, or sleeping. The gyroscopic term is dropped.
pub fn integrate(bm: *BodyManager, dt: Real, gravity: Vec3r) void {
    const positions = bm.bodies.items(.position);
    const rotations = bm.bodies.items(.rotation);
    const linear_velocities = bm.bodies.items(.linear_velocity);
    const angular_velocities = bm.bodies.items(.angular_velocity);
    const forces = bm.bodies.items(.force);
    const torques = bm.bodies.items(.torque);
    const motions = bm.bodies.items(.motion);
    const body_types = bm.bodies.items(.body_type);

    const n: u32 = @intCast(bm.bodies.len);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        // The store never compacts, so dead slots sit between live ones — skip
        // them (their stale data must not be integrated).
        if (!bm.alloc.isAliveIndex(i)) continue;

        if (body_types[i] == .dynamic) {
            const mp = motions[i];

            // --- Linear ---
            // Gravity as an acceleration (mass-independent), plus the accumulated
            // force divided by mass. Read `force` before the clear below.
            const accel = gravity.scale(mp.gravity_factor).add(forces[i].scale(mp.inv_mass));
            // Integrate velocity first (symplectic), then damp, then position.
            var v = linear_velocities[i].add(accel.scale(dt));
            const damp = @max(@as(Real, 0), 1 - mp.linear_damping * dt);
            v = v.scale(damp);
            linear_velocities[i] = v;
            positions[i] = positions[i].add(v.scale(dt));

            // --- Angular ---
            // World-space inverse inertia I_world_inv = R · I_local_inv · Rᵀ
            // (Rᵀ == R⁻¹ for an orthonormal rotation), then α = I_world_inv·τ.
            const r = Mat3r.fromQuat(rotations[i]);
            const i_world_inv = r.mul(mp.local_inv_inertia).mul(r.transpose());
            const alpha = i_world_inv.mulVec(torques[i]);
            var w = angular_velocities[i].add(alpha.scale(dt));
            const ang_damp = @max(@as(Real, 0), 1 - mp.angular_damping * dt);
            w = w.scale(ang_damp);
            angular_velocities[i] = w;
            // First-order orientation update: q ← normalize(q + ½·dt·(ω_quat ⊗ q)),
            // world-space ω on the LEFT. No |ω| division ⇒ singularity-free at ω = 0.
            const wa = w.toArray();
            const w_quat = Quatr{ .x = wa[0], .y = wa[1], .z = wa[2], .w = 0 };
            const dq = w_quat.mul(rotations[i]).scale(0.5 * dt);
            rotations[i] = rotations[i].add(dq).normalize();
        }

        // Reset the per-tick accumulators for every live body (§2), including
        // static/kinematic — the clear is uniform.
        forces[i] = Vec3r.zero;
        torques[i] = Vec3r.zero;
    }
}
