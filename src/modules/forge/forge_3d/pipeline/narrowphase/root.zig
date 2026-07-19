//! `forge_3d/pipeline/narrowphase/root.zig` — the narrowphase package façade.
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
const manifold = @import("manifold.zig");

// --- Support layer (support.zig) ---

/// A convex support shape (core + inflation radius).
pub const SupportShape = support.SupportShape;
/// Shape-B-relative-to-A pose precompute (frame of A).
pub const RelativePose = support.RelativePose;
/// A support sample on the Minkowski difference (`w` + the two source supports).
pub const Vertex = support.Vertex;
/// A shape's supporting feature (vertex / segment / quad) in a direction.
pub const Face = support.Face;
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

// --- Contact manifold (manifold.zig) ---

/// The contact manifold between two shapes (world normal + up to 4 points).
pub const ContactManifold = manifold.ContactManifold;
/// One contact point of a `ContactManifold`.
pub const ContactPoint = manifold.ContactPoint;

// Pins so every package sub-file is analysed when forge_3d is built as a test
// target (engine-zig-conventions.md §13 lazy-analysis guard).
comptime {
    _ = support;
    _ = gjk_mod;
    _ = manifold;
}
