//! `forge_3d` — the native Zig 3D physics solver (Tier 1, in-tree per
//! `ARCH-017`). M1.1.0 laid the foundations: the `Real` scalar, the
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
// M1.1.11.1 — the owned triangle-mesh payload a `.triangle_mesh` shape holds.
// Re-exported below; the comptime pin analyses its acceptance suite.
const mesh_mod = @import("mesh.zig");
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
// M1.1.6 — rigid-body branch (Sequential Impulses contact solver). Re-exported
// as the `rigid` namespace below; the comptime pin analyses its inline tests.
const rigid_mod = @import("rigid/root.zig");
// M1.1.8 — branch-neutral island partition core (union-find over opaque element
// indices). Scalar-free, so it is re-exported as a namespace rather than bound to
// `Real`; the comptime pin analyses its acceptance tests.
const island_mod = @import("pipeline/island.zig");
// M1.1.8 — sleep detection (displacement window sweep + eligibility + transition)
// over the `BodyManager` SoA store, at the same pipeline level as integration.
// Re-exported as the `sleep` namespace below; the comptime pin analyses its tests.
const sleep_mod = @import("pipeline/sleep.zig");
// M1.1.9 — `Real`-bound spatial queries (stateless orchestration over the
// broadphase ray traversal + the exact kernels). Re-exported as the `query`
// namespace below; the comptime pin analyses its acceptance tests.
const query_mod = @import("query/root.zig");
// M1.1.12 — the kinematic character controller's store. Re-exported below; the
// comptime pin analyses its acceptance suite.
const character_mod = @import("character.zig");

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
/// The narrowphase CATEGORY of a shape — bounded convex or half-space (M1.1.11,
/// `engine-physics-forge.md` §1.11.15). Scalar-free, so re-exported as-is.
pub const ShapeClass = shape.ShapeClass;
/// Generational store of collision shapes.
pub const ShapeStore = shape.ShapeStore;
/// The OWNED triangle-mesh data a `.triangle_mesh` shape holds — vertices and indices
/// at solver precision (M1.1.11.1, `engine-physics-forge.md` §1.11.17). The store owns
/// it: `createShape` copies the borrowed descriptor arrays, `destroyShape` releases.
pub const MeshData = mesh_mod.MeshData;
/// The five ways a triangle-mesh descriptor can be malformed, each refused by its own
/// typed error and never sanitised away.
pub const MeshError = mesh_mod.MeshError;

// --- Bodies ---

/// Derived inverse mass/inertia + damping/gravity for a body.
pub const MotionProperties = body.MotionProperties;
/// Per-body simulation flags.
pub const BodyFlags = body.BodyFlags;
/// One SoA body row.
pub const Body = body.Body;
/// SoA store of rigid bodies with generational handles.
pub const BodyManager = body_manager.BodyManager;

/// Exact world AABB of a shape at a pose — the body-free form `BodyManager.bodyAabb` wraps.
/// Re-exported at `Real` for the mesh bench, which measures its O(V) pass against the
/// per-body cache that could replace it (M1.1.11.1).
pub const worldAabb = body_manager.worldAabb;

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
/// A world-space ray (origin + direction + the reciprocal form the slab test
/// wants) at solver precision — the input to both the broadphase ray traversal
/// and the exact kernels.
pub const Ray = broadphase.Ray(Real);

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
pub fn epa(shape_a: SupportShape, pos_a: Vec3r, rot_a: Quatr, relpose: RelativePose, shape_b: SupportShape, rot_b: Quatr, seed: GjkResult) EpaResult {
    return narrowphase.epa(Real, shape_a, pos_a, rot_a, relpose, shape_b, rot_b, seed, null);
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

// --- Half-space kernels (M1.1.11) ---

/// A solid half-space `{ x : n·x <= d }` at solver precision — the geometry a `.plane`
/// shape carries, and the input to every kernel of the `plane` namespace below.
pub const HalfSpace = narrowphase.plane.HalfSpace(Real);

/// The analytic half-space kernels (`engine-physics-forge.md` §1.11.15): separation
/// against a bounded convex, ray, shape cast, solid membership, closest point, and the
/// AABB corner predicate. Closed-form and iteration-free — a half-space has no support
/// map, so it traverses neither GJK, EPA nor the cast march. Scalar-generic, so
/// re-exported as a namespace; `BodyManager`'s five adapters bind it at `Real`.
pub const plane = narrowphase.plane;

// --- Ray kernels + queries ---

/// A ray hit on one shape in that shape's LOCAL frame (distance + outward
/// normal) at solver precision — what `BodyManager.raycastBody` returns.
pub const LocalHit = narrowphase.LocalHit(Real);

/// Nearest ray↔shape intersection in the shape's local frame, at solver
/// precision — the `Real`-bound kernel entry. `BodyManager.raycastBody` is the
/// `BodyId`-level adapter the query traversal drives.
pub fn rayShape(support_shape: SupportShape, origin: Vec3r, direction: Vec3r) ?LocalHit {
    return narrowphase.rayShape(Real, support_shape, origin, direction);
}

/// The analytic ray↔triangle kernel and the shared back-face predicate (M1.1.11.1,
/// `engine-physics-forge.md` §1.11.17): `rayTriangle`, `isBackFace`, and `localHit`, which
/// is where the back-face normal FLIP lives. Scalar-generic, so re-exported as a namespace;
/// `BodyManager.raycastBody`'s mesh arm binds it at `Real`.
///
/// Only the RAY gains a kernel. A triangle is a bounded convex, so GJK, EPA, the manifold
/// generator and the cast kernel serve a mesh through `SupportShape.Core.triangle`
/// unchanged — one variant against four reused families.
pub const triangle = narrowphase.triangle;

/// Whether the ray kernels cover `support_shape` — `rayShape`'s asserted
/// precondition at solver precision (M1.1.11). Every box the `ShapeStore` converts
/// carries `radius = 0`, so this is false only for a `SupportShape` a caller built by
/// hand.
pub fn raySupportsShape(support_shape: SupportShape) bool {
    return narrowphase.raySupportsShape(Real, support_shape);
}

/// Spatial queries at solver precision (`engine-physics-forge.md` §1.11): the
/// shared `Filter`, the `RayQuery`/`RayHit` types, and the three raycast entries
/// `raycast` / `raycastAny` / `raycastAll`. Stateless — each entry takes
/// `(bp, bm, store)`.
pub const query = query_mod;

// --- Character controller (M1.1.12) ---

/// Generational store of character controllers (`engine-physics-forge.md` §1.12). A
/// controller is VIRTUAL: it takes part in no solver pass, and its pose is written by
/// `moveCharacter` alone. Bound to `Real` through the module's own `config.zig`.
pub const CharacterStore = character_mod.CharacterStore;
/// One stored controller — authored parameters at solver precision, plus the capsule and
/// the optional presence the store owns the lifetime of. `position` is the capsule's BASE.
pub const Character = character_mod.Character;
/// Every way a `CharacterDescriptor` can be malformed, plus the stale handle — each its own
/// typed error, and never sanitised.
pub const CharacterError = character_mod.CharacterError;
/// The offset from a character's BASE to the CENTRE of its capsule — half the height along
/// `+Y`. Re-exported because it is THE one named place that offset exists, and a consumer
/// deriving it a second time is the defect the single definition prevents.
pub const baseToCentre = character_mod.baseToCentre;

// --- Islands (branch-neutral partition core) ---

/// The island partition core: a union-find over opaque element indices, shared by
/// both solver branches (`engine-physics-forge.md` §1.8.1). Scalar-free — the rigid
/// adapter that maps bodies and constraints onto it lives in `rigid/`.
pub const island = island_mod;

/// Sleep detection at solver precision (`engine-physics-forge.md` §1.8.3): the
/// `SleepConfig` tuning, the per-body displacement-window sweep, the eligibility
/// predicate, and the sleep transition. The per-island decision that consumes them
/// lives in `rigid/`.
pub const sleep = sleep_mod;

// --- Integration (semi-implicit Euler) ---

/// Advance every live body one fixed tick of `dt` under world-space `gravity`
/// (m/s²) with semi-implicit Euler + gravity·gravity_factor + clamped-linear
/// damping — the `Real`-bound entry. Free-flight only (no contacts); called by
/// the `step` orchestrator at M1.1.15.
pub fn integrate(bm: *BodyManager, dt: Real, gravity: Vec3r) void {
    return integration.integrate(bm, dt, gravity);
}

// --- Rigid solver (Sequential Impulses contact solver) ---

/// The rigid-body branch: contact constraint setup + material combine rules +
/// tangent basis (M1.1.6), with the contact cache + velocity solver as additive
/// siblings. Bound to `Real` through the package's `../config.zig` import.
pub const rigid = rigid_mod;

// Pins so the inline tests + the acceptance suite are analysed when this module
// is built as a test target (engine-zig-conventions.md §13).
comptime {
    _ = config;
    _ = shape;
    _ = mesh_mod;
    _ = body;
    _ = body_manager;
    _ = broadphase;
    _ = narrowphase;
    _ = integration;
    _ = rigid_mod;
    _ = island_mod;
    _ = sleep_mod;
    _ = query_mod;
    _ = character_mod;
    _ = @import("tests/body_manager_test.zig");
    _ = @import("tests/integration_test.zig");
    _ = @import("tests/broadphase_test.zig");
    _ = @import("tests/gjk_test.zig");
    _ = @import("tests/epa_test.zig");
    _ = @import("tests/manifold_test.zig");
    _ = @import("tests/fast_paths_test.zig");
    _ = @import("tests/epa_robustness_test.zig");
    _ = @import("tests/solver_test.zig");
    _ = @import("tests/position_solver_test.zig");
    _ = @import("tests/island_test.zig");
    _ = @import("tests/sleep_test.zig");
    _ = @import("tests/raycast_test.zig");
    _ = @import("tests/shapecast_test.zig");
    _ = @import("tests/overlap_test.zig");
    _ = @import("tests/plane_test.zig");
    _ = @import("tests/mesh_test.zig");
    _ = @import("tests/character_test.zig");
}
