//! `forge_3d/rigid/root.zig` — facade for the rigid-body branch (Sequential
//! Impulses + NGS position solver; `engine-physics-forge.md` §1.2). M1.1.6 lands
//! the velocity-level contact constraint setup (combine rules, tangent basis,
//! `ContactConstraint`, build/prepare); the contact cache (E3) and velocity
//! solver (E4/E5) land here as additive sibling files, and the NGS position
//! solver (M1.1.7) + joints follow the same way.
//!
//! Re-exported at `Real` by `forge_3d/root.zig`. The comptime pin analyses the
//! package's inline tests when built as a test target (engine-zig-conventions.md
//! §13 lazy-analysis guard).

const contact_constraint = @import("contact_constraint.zig");
const contact_cache = @import("contact_cache.zig");
const velocity_solver = @import("velocity_solver.zig");

/// One manifold's velocity-solver contact constraint (≤ 4 inline points).
pub const ContactConstraint = contact_constraint.ContactConstraint;
/// One contact point's precomputed solver data.
pub const ConstraintPoint = contact_constraint.ConstraintPoint;
/// An orthonormal tangent basis for a contact normal.
pub const TangentBasis = contact_constraint.TangentBasis;

/// Combined pair friction: geometric mean √(a·b).
pub const combineFriction = contact_constraint.combineFriction;
/// Combined pair restitution: max(a, b).
pub const combineRestitution = contact_constraint.combineRestitution;
/// Trig-free deterministic orthonormal tangent basis for a unit normal.
pub const tangentBasis = contact_constraint.tangentBasis;
/// Build a deterministically-ordered constraint array from canonical pairs.
pub const build = contact_constraint.build;

/// The Sequential Impulses warm-start cache (double-buffered, sorted flat).
pub const ContactCache = contact_cache.ContactCache;
/// A warm-start cache key (pair + sub-shape + feature).
pub const CacheKey = contact_cache.CacheKey;
/// A warm-start cache value (accumulated normal + world tangent impulse).
pub const CacheValue = contact_cache.CacheValue;

/// Velocity-solver tuning (iteration count, restitution threshold).
pub const SolverConfig = velocity_solver.SolverConfig;

/// Warm-start constraints from the previous tick's cache (tangent reprojection).
pub const warmStart = velocity_solver.warmStart;
/// Harvest solved constraint impulses into the cache's current buffer.
pub const storeContacts = velocity_solver.storeContacts;
/// Solve the velocity constraints over an index range (M1.1.6 passes the full range).
pub const solveRange = velocity_solver.solveRange;

comptime {
    _ = contact_constraint;
    _ = contact_cache;
    _ = velocity_solver;
}
