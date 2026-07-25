//! `forge_3d/rigid/root.zig` — facade for the rigid-body branch (Sequential
//! Impulses + NGS position solver; `engine-physics-forge.md` §1.2). M1.1.6 landed
//! the velocity half: contact constraint setup (combine rules, tangent basis,
//! `ContactConstraint`, build/prepare), the warm-start cache, and the velocity
//! solver. M1.1.7 adds the shared `solver_config.zig` and the NGS position pass;
//! joints follow the same additive-sibling way.
//!
//! Re-exported at `Real` by `forge_3d/root.zig`. The comptime pin analyses the
//! package's inline tests when built as a test target (engine-zig-conventions.md
//! §13 lazy-analysis guard).

const contact_constraint = @import("contact_constraint.zig");
const contact_cache = @import("contact_cache.zig");
const solver_config = @import("solver_config.zig");
const velocity_solver = @import("velocity_solver.zig");
const position_solver = @import("position_solver.zig");
const island_manager = @import("island_manager.zig");

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

/// Rigid contact-solver tuning, shared by the velocity and position passes
/// (iteration counts, restitution threshold, NGS slop/factor/clamp).
pub const SolverConfig = solver_config.SolverConfig;

/// Warm-start constraints from the previous tick's cache (tangent reprojection).
pub const warmStart = velocity_solver.warmStart;
/// Harvest solved constraint impulses into the cache's current buffer.
pub const storeContacts = velocity_solver.storeContacts;
/// Solve the velocity constraints over an index range (M1.1.6 passes the full range).
pub const solveRange = velocity_solver.solveRange;

/// Telemetry of one NGS position pass (iterations run, minimum separation seen).
pub const PositionSolveResult = position_solver.PositionSolveResult;
/// Resorb penetration over an index range by correcting poses (NGS, §1.7.2).
pub const solvePositionRange = position_solver.solvePositionRange;

/// Partitions the awake dynamic bodies into islands, gives each a contiguous
/// constraint range for the two range-shaped solver passes, and arbitrates
/// activation (step 5) and the sleep transition (step 11).
pub const IslandManager = island_manager.IslandManager;
/// One island: its constraint range, its member range, and its W3 flag.
pub const Island = island_manager.Island;

comptime {
    _ = contact_constraint;
    _ = contact_cache;
    _ = solver_config;
    _ = velocity_solver;
    _ = position_solver;
    _ = island_manager;
}
