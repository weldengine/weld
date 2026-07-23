//! `forge_3d` — the native Zig 3D physics solver (Tier 1, in-tree per
//! `engine-spec.md` §3.5). M1.1.0 laid the foundations: the `Real` scalar, the
//! `ShapeStore`, per-body `MotionProperties` with analytic inertia, and the SoA
//! `BodyManager`. M1.1.1 added the shared `pipeline/broadphase.zig` (a dynamic
//! multi-layer AABB tree — BVH); M1.1.2 added `pipeline/narrowphase/`
//! (distance-based GJK convex detection), promoted to a package at M1.1.3 with
//! EPA + contact manifold as sibling files. All re-exported here at `Real`. No
//! stepping, island manager, scheduler, or `PhysicsModule` instantiation yet —
//! those are later M1.1 sub-milestones. Depends only on `foundation/math` and
//! `src/modules/forge/api/` (core entity/component types reach here through
//! `api/`).

const config = @import("config.zig");
const shape = @import("shape.zig");
const body = @import("body.zig");
const body_manager = @import("body_manager.zig");
const broadphase = @import("pipeline/broadphase.zig");
// M1.1.2/3 — narrowphase package (GJK convex detection; EPA + manifold M1.1.3).
// Re-exported at `Real` below; the comptime pin analyses its acceptance tests
// (engine-zig-conventions.md §13 lazy-analysis guard — an unreferenced module's
// tests are silently skipped).
const narrowphase = @import("pipeline/narrowphase/root.zig");
// M1.1.5 — semi-implicit Euler integration over the `BodyManager` SoA store.
// Re-exported at `Real` below; the comptime pin analyses its acceptance tests.
const integration = @import("pipeline/integration.zig");

// --- Solver scalar + math aliases ---

/// Solver scalar (`f32`, or `f64` under `-Dphysics_f64=true`).
pub const Real = config.Real;
/// 3-vector at solver precision.
pub const Vec3r = config.Vec3r;
/// Quaternion at solver precision.
pub const Quatr = config.Quatr;
/// 3×3 matrix at solver precision.
pub const Mat3r = config.Mat3r;
/// Axis-aligned bounding box at solver precision.
pub const Aabbr = config.Aabbr;

// --- Shapes ---

/// Immutable per-shape data (geometry + local AABB + unit-mass inertia).
pub const Shape = shape.Shape;
/// Generational store of collision shapes.
pub const ShapeStore = shape.ShapeStore;

// --- Bodies ---

/// Derived inverse mass/inertia + damping/gravity for a body.
pub const MotionProperties = body.MotionProperties;
/// Per-body simulation flags.
pub const BodyFlags = body.BodyFlags;
/// One SoA body row.
pub const Body = body.Body;
/// SoA store of rigid bodies with generational handles.
pub const BodyManager = body_manager.BodyManager;

// --- Pipeline (shared by both solver branches) ---

/// Dynamic AABB tree (BVH) at solver precision.
pub const Bvh = broadphase.Bvh(Real);
/// Multi-layer broadphase (one `Bvh` per layer + candidate-pair generation) at
/// solver precision.
pub const Broadphase = broadphase.Broadphase(Real);
/// The broad collision layers (scalar-independent).
pub const BroadphaseLayer = broadphase.BroadphaseLayer;
/// Broadphase tuning at solver precision.
pub const BroadphaseConfig = broadphase.BroadphaseConfig(Real);

// --- Narrowphase (GJK convex detection) ---

/// A convex support shape (core + inflation radius) at solver precision.
pub const SupportShape = narrowphase.SupportShape(Real);
/// Shape-B-relative-to-A pose precompute at solver precision.
pub const RelativePose = narrowphase.RelativePose(Real);
/// GJK simplex machinery (triplet vertex + Voronoi solver) at solver precision.
pub const Simplex = narrowphase.Simplex(Real);
/// Three-regime GJK result (separated / shallow / deep) at solver precision.
pub const GjkResult = narrowphase.GjkResult(Real);
/// The GJK descent iteration ceiling (scalar-independent).
pub const max_gjk_iterations = narrowphase.max_gjk_iterations;

/// Distance-based GJK between two support shapes at their world poses — the
/// `Real`-bound narrowphase entry. `BodyManager.gjkPair` is the `BodyId`-level
/// adapter used by the broadphase→narrowphase flow.
pub fn gjk(shape_a: SupportShape, pos_a: Vec3r, rot_a: Quatr, shape_b: SupportShape, pos_b: Vec3r, rot_b: Quatr) GjkResult {
    return narrowphase.gjk(Real, shape_a, pos_a, rot_a, shape_b, pos_b, rot_b);
}

// --- Narrowphase (EPA penetration + contact manifold) ---

/// EPA penetration result (world normal A→B, core depth, world closest points)
/// at solver precision.
pub const EpaResult = narrowphase.EpaResult(Real);
/// The EPA expansion iteration ceiling (scalar-independent).
pub const max_epa_iterations = narrowphase.max_epa_iterations;
/// The contact manifold between two shapes (world normal + up to 4 points) at
/// solver precision.
pub const ContactManifold = narrowphase.ContactManifold(Real);
/// One contact point of a `ContactManifold` at solver precision.
pub const ContactPoint = narrowphase.ContactPoint(Real);

/// EPA over a `.deep` GJK seed — penetration axis + core depth. The `Real`-bound
/// entry; `collide` runs it internally on the deep path.
pub fn epa(shape_a: SupportShape, pos_a: Vec3r, rot_a: Quatr, relpose: RelativePose, shape_b: SupportShape, seed: GjkResult) EpaResult {
    return narrowphase.epa(Real, shape_a, pos_a, rot_a, relpose, shape_b, seed);
}

/// Full narrowphase (GJK → shallow/deep contact manifold) between two support
/// shapes at their world poses — the `Real`-bound entry; null when separated.
/// `BodyManager.collidePair` is the `BodyId`-level adapter for the
/// broadphase→narrowphase flow. Order-independent.
pub fn collide(shape_a: SupportShape, pos_a: Vec3r, rot_a: Quatr, shape_b: SupportShape, pos_b: Vec3r, rot_b: Quatr) ?ContactManifold {
    return narrowphase.collide(Real, shape_a, pos_a, rot_a, shape_b, pos_b, rot_b);
}

/// `collide` for a FIXED shape order (no pose canonicalization) at solver
/// precision — the `BodyId`-ordered path `BodyManager.collidePair` drives so the
/// `feature_id` reference/incident ownership stays frame-stable. Dispatches the
/// M1.1.4 analytic fast paths, falling through to `collideOrderedGeneric`.
pub fn collideOrdered(shape_a: SupportShape, pos_a: Vec3r, rot_a: Quatr, shape_b: SupportShape, pos_b: Vec3r, rot_b: Quatr) ?ContactManifold {
    return narrowphase.collideOrdered(Real, shape_a, pos_a, rot_a, shape_b, pos_b, rot_b);
}

/// `collideOrdered` with the fast-path dispatcher bypassed (the generic GJK/EPA
/// oracle) at solver precision — the differential oracle + bench baseline for the
/// M1.1.4 fast paths.
pub fn collideOrderedGeneric(shape_a: SupportShape, pos_a: Vec3r, rot_a: Quatr, shape_b: SupportShape, pos_b: Vec3r, rot_b: Quatr) ?ContactManifold {
    return narrowphase.collideOrderedGeneric(Real, shape_a, pos_a, rot_a, shape_b, pos_b, rot_b);
}

/// The `(normal, closest points, base penetration)` fast-path seed at solver precision.
pub const ContactSeed = narrowphase.ContactSeed(Real);

// --- Integration (semi-implicit Euler) ---

/// Advance every live body one fixed tick of `dt` under world-space `gravity`
/// (m/s²) with semi-implicit Euler + gravity·gravity_factor + clamped-linear
/// damping — the `Real`-bound entry. Free-flight only (no contacts); called by
/// the `step` orchestrator at M1.1.15.
pub fn integrate(bm: *BodyManager, dt: Real, gravity: Vec3r) void {
    return integration.integrate(bm, dt, gravity);
}

// Pins so the inline tests + the acceptance suite are analysed when this module
// is built as a test target (engine-zig-conventions.md §13).
comptime {
    _ = config;
    _ = shape;
    _ = body;
    _ = body_manager;
    _ = broadphase;
    _ = narrowphase;
    _ = integration;
    _ = @import("tests/body_manager_test.zig");
    _ = @import("tests/integration_test.zig");
    _ = @import("tests/broadphase_test.zig");
    _ = @import("tests/gjk_test.zig");
    _ = @import("tests/epa_test.zig");
    _ = @import("tests/manifold_test.zig");
    _ = @import("tests/fast_paths_test.zig");
}
