//! `forge_3d/rigid/root.zig` — facade for the rigid-body branch (TGS Soft
//! substepping; `engine-physics-forge.md` §1.2). It carries the contact constraint
//! setup (combine rules, tangent basis, soft coefficients, `ContactConstraint`,
//! build/prepare), the warm-start cache, the shared `solver_config.zig`, the
//! substepped solver and the island manager. The M1.1.6 velocity pass and the M1.1.7
//! NGS position pass were merged into `solver.zig` at M1.1.13.1 and their files are
//! gone; joints follow the same additive-sibling way.
//!
//! Re-exported at `Real` by `forge_3d/root.zig`. The comptime pin analyses the
//! package's inline tests when built as a test target (engine-zig-conventions.md
//! §13 lazy-analysis guard).

const contact_constraint = @import("contact_constraint.zig");
const contact_cache = @import("contact_cache.zig");
const solver_config = @import("solver_config.zig");
const solver = @import("solver.zig");
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
/// The TOTAL orders the two constraint sorts run on — `(pair_key, subshape_id)` here and
/// `(rank, pair_key, subshape_id)` for the island permutation. `pub` since the M1.1.11.1 closure:
/// with several constraints per pair, totality is the property that keeps the ordering from
/// resting on `std.sort.block`'s tie-handling, and totality is a claim about the COMPARATOR that
/// only a caller of it can check (closure finding F4).
pub const lessByConstraintKey = contact_constraint.lessByConstraintKey;
/// The island permutation's total order, `(rank, pair_key, subshape_id)`.
pub const lessByCompositeKey = island_manager.lessByCompositeKey;
/// One constraint's island sort key plus where it currently sits.
pub const ConstraintKey = island_manager.ConstraintKey;
/// A warm-start cache key (pair + sub-shape + feature).
pub const CacheKey = contact_cache.CacheKey;
/// A warm-start cache value (accumulated normal + world tangent impulse).
pub const CacheValue = contact_cache.CacheValue;

/// Rigid contact-solver tuning (substep count, contact stiffness and damping,
/// recovery cap, restitution threshold, slop).
pub const SolverConfig = solver_config.SolverConfig;
/// Debug-assert the solver config's domain.
pub const assertSolverDomain = solver_config.assertDomain;

/// The three mass-independent soft-constraint coefficients.
pub const Softness = contact_constraint.Softness;
/// The tick's two coefficient triples (ordinary and static-stiffened).
pub const SoftnessPair = contact_constraint.SoftnessPair;
/// What `build` needs beyond the geometry: the softness pair and the warm-start source.
pub const PrepareContext = contact_constraint.PrepareContext;
/// The `b2MakeSoft` closed form for `(hertz, damping ratio, substep length)`.
pub const makeSoft = contact_constraint.makeSoft;
/// The authored stiffness clamped to an eighth of the substep rate.
pub const effectiveContactHertz = contact_constraint.effectiveContactHertz;
/// Whether a pair takes the stiffened static coefficients (either endpoint static).
pub const usesStaticSoftness = contact_constraint.usesStaticSoftness;

/// Derive the tick's two coefficient triples from the config and the timestep.
pub const makeSoftnessPair = solver.makeSoftnessPair;
/// Build a `PrepareContext` for one tick.
pub const prepareContext = solver.prepareContext;
/// Inject the CURRENT accumulated impulses — once per substep, after integration.
pub const applyWarmStartRange = solver.applyWarmStartRange;
/// The biased sweep over an index range — one call per island range per substep.
pub const solveRange = solver.solveRange;
/// `solveRange` returning its telemetry (the §1.8.2 sibling entry).
pub const solveRangeReport = solver.solveRangeReport;
/// The relax sweep over an index range: normal points unbiased, then friction.
pub const relaxRange = solver.relaxRange;
/// The restitution pass over an index range — step 7, once after the substep loop.
pub const applyRestitutionRange = solver.applyRestitutionRange;
/// Steps 6 and 7: the substep loop, the accumulator reset, and restitution.
pub const solveTick = solver.solveTick;
/// Harvest solved constraint impulses into the cache's current buffer.
pub const storeContacts = solver.storeContacts;
/// Telemetry of one solver tick (substeps, sweeps, minimum separation).
pub const SolverStats = solver.SolverStats;
/// Telemetry of one biased sweep over one island range.
pub const RangeStats = solver.RangeStats;

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
    _ = solver;
    _ = island_manager;
}
