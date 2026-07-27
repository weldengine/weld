//! `forge_3d/pipeline/narrowphase/root.zig` — the narrowphase package facade.
//!
//! M1.1.3/E1 promoted the single-file `narrowphase.zig` to this package so the
//! GJK stack (`support.zig` + `gjk.zig`), EPA (`epa.zig`), and the contact
//! manifold (`manifold.zig`) live as sibling files without one 1300-line file.
//! This root re-exports every public name the old file exposed — unchanged — so
//! consumers change only their import path (`pipeline/narrowphase.zig` →
//! `pipeline/narrowphase/root.zig`).
//!
//! **Dependency discipline (brief Notes).** The whole package imports
//! `foundation` (math) ONLY — never `weld_forge`, never `body*.zig`, never
//! `config.zig`, never `broadphase.zig`. The scalar arrives as the comptime
//! parameter `T`; `forge_3d` instantiates it at `config.Real`.

const support = @import("support.zig");
const gjk_mod = @import("gjk.zig");
const epa_mod = @import("epa.zig");
const manifold = @import("manifold.zig");
const fast_paths = @import("fast_paths.zig");
const raycast_mod = @import("raycast.zig");
const shapecast_mod = @import("shapecast.zig");
const plane_mod = @import("plane.zig");

// --- Support layer (support.zig) ---

/// A convex support shape (core + inflation radius).
pub const SupportShape = support.SupportShape;
/// Shape-B-relative-to-A pose precompute (frame of A).
pub const RelativePose = support.RelativePose;
/// A support sample on the Minkowski difference (`w` + the two source supports).
pub const Vertex = support.Vertex;
/// A shape's supporting feature (vertex / segment / quad) in a direction.
pub const Face = support.Face;
/// A hit on one shape in that shape's local frame (distance + outward normal) — the
/// shared return type of the `raycast.zig` and `plane.zig` ray kernels.
pub const LocalHit = support.LocalHit;
/// One cast hit in the cast shape's frame — the shared return type of the
/// `shapecast.zig` and `plane.zig` cast kernels.
pub const CastHit = support.CastHit;
/// Support point of the Minkowski difference of two cores (`pub` for EPA/manifold).
pub const minkowskiSupport = support.minkowskiSupport;

// --- GJK layer (gjk.zig) ---

/// GJK simplex machinery (triplet vertex + Voronoi-region origin-closest solver).
pub const Simplex = gjk_mod.Simplex;
/// Three-regime GJK result (separated / shallow / deep).
pub const GjkResult = gjk_mod.GjkResult;
/// The GJK descent iteration ceiling (scalar-independent).
pub const max_gjk_iterations = gjk_mod.max_gjk_iterations;
/// Distance-based GJK between two support shapes at their world poses.
pub const gjk = gjk_mod.gjk;

// --- EPA (penetration axis + core depth, epa.zig) ---

/// EPA penetration result (world normal A→B, core depth, world closest points).
pub const EpaResult = epa_mod.EpaResult;
/// Optional per-call EPA diagnostics (exit kind, iterations, skips, fallback) —
/// a test/tooling seam, not part of the frozen `EpaResult` contract.
pub const EpaDiagnostics = epa_mod.EpaDiagnostics;
/// The EPA expansion iteration ceiling (scalar-independent).
pub const max_epa_iterations = epa_mod.max_epa_iterations;
/// EPA over a `.deep` GJK seed — penetration axis + core depth.
pub const epa = epa_mod.epa;

// --- Contact manifold (manifold.zig) ---

/// The contact manifold between two shapes (world normal + up to 4 points).
pub const ContactManifold = manifold.ContactManifold;
/// One contact point of a `ContactManifold`.
pub const ContactPoint = manifold.ContactPoint;
/// Full narrowphase (GJK → shallow/deep manifold) between two shapes; null when
/// separated. Order-independent (pose-canonicalized).
pub const collide = manifold.collide;
/// `collide` for a FIXED shape order (no pose canonicalization) — for callers
/// that own a stable external key (body ids) and need a frame-stable feature_id.
/// Dispatches the M1.1.4 analytic fast paths, falling through to
/// `collideOrderedGeneric`.
pub const collideOrdered = manifold.collideOrdered;
/// `collideOrdered` with the fast-path dispatcher bypassed — the generic GJK/EPA
/// manifold path. The differential oracle + bench baseline for the M1.1.4 fast
/// paths. (`generateManifold` stays package-internal — not re-exported here.)
pub const collideOrderedGeneric = manifold.collideOrderedGeneric;

// --- Fast paths (analytic per-pair seeds, fast_paths.zig) ---

/// The `(normal, closest points, base penetration)` seed a fast path supplies to
/// the shared manifold generator (the quantities the generic GJK/EPA block computes).
pub const ContactSeed = fast_paths.ContactSeed;
/// The three-state fast-path dispatcher result (not_handled / separated / contact).
pub const FastResult = fast_paths.FastResult;
/// Analytic per-pair narrowphase dispatcher (`.not_handled` until a kernel lands).
pub const fastSeed = fast_paths.fastSeed;

// --- Ray kernels (analytic ray↔core, raycast.zig) ---

/// Nearest ray↔shape intersection in the shape's local frame; `null` on a miss.
/// Precondition: `raySupportsShape` (no error channel since M1.1.11).
pub const rayShape = raycast_mod.rayShape;
/// Whether the ray kernels cover a support shape — `rayShape`'s precondition, exposed
/// so a caller can decide admissibility instead of relying on a debug assert.
pub const raySupportsShape = raycast_mod.raySupportsShape;
/// Whether a point lies in the solid shape, boundary included.
pub const containsPoint = raycast_mod.containsPoint;

// --- Shape-cast kernel (GJK ray march on the Minkowski difference, shapecast.zig) ---

/// Which row of `engine-physics-forge.md` §1.11.11's termination table ended a march.
pub const CastExit = shapecast_mod.CastExit;
/// Observability channel for the march (exit row, iterations, advances, restart).
pub const CastDiagnostics = shapecast_mod.CastDiagnostics;
/// Named, obligatory iteration ceiling; exhaustion returns a hit at the current
/// parameter (§1.11.11).
pub const max_shapecast_iterations = shapecast_mod.max_shapecast_iterations;
/// Cast a shape along a direction against another; `null` on a miss. No error
/// channel: a support map covers every bounded convex, so nothing is rejected.
pub const castShape = shapecast_mod.castShape;
/// `castShape` with the ceiling and the diagnostics exposed — the seam that makes the
/// normative fallback observable rather than merely documented.
pub const castShapeBounded = shapecast_mod.castShapeBounded;

// --- Half-space kernels (analytic, closed-form, plane.zig) ---

/// The half-space kernels, as a NAMESPACE rather than six flat re-exports
/// (`engine-physics-forge.md` §1.11.15). Deliberate: `containsPoint`, `rayShape` and
/// `castShape` all have a bounded-convex namesake in this package, and flattening
/// them here would either collide or force six invented names. `narrowphase.plane.rayShape`
/// says which category it serves, which is the whole point of the taxonomy.
pub const plane = plane_mod;

// Pins so every package sub-file is analysed when forge_3d is built as a test
// target (engine-zig-conventions.md §13 lazy-analysis guard).
comptime {
    _ = support;
    _ = gjk_mod;
    _ = epa_mod;
    _ = manifold;
    _ = fast_paths;
    _ = raycast_mod;
    _ = shapecast_mod;
    _ = plane_mod;
}
