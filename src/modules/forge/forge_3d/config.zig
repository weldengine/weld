//! `forge_3d/config.zig` — the solver scalar `Real` and its math aliases.
//!
//! `Real` is `f32` by default and `f64` under the `-Dphysics_f64=true` build
//! option (open worlds > 10 km from the origin, `engine-physics-forge.md`
//! §1.5). All `forge_3d` code is written against `Real` from day one; the f64
//! path is a compile-time flip, not a runtime option.

const math = @import("foundation").math;
const build_options = @import("build_options");
const api = @import("weld_forge");

/// The solver scalar type. `f32` by default; `f64` when built with
/// `-Dphysics_f64=true`.
pub const Real = if (build_options.physics_f64) f64 else f32;

/// 3-vector at solver precision.
pub const Vec3r = math.Vec(3, Real);
/// Quaternion at solver precision.
pub const Quatr = math.Quat(Real);
/// 3×3 matrix at solver precision.
pub const Mat3r = math.Mat3(Real);
/// Axis-aligned bounding box at solver precision.
pub const Aabbr = math.Aabb(Real);

/// **The one precision crossing of the module, instantiated at `Real`.** Every world ↔
/// solver conversion goes through here and nowhere else; the `no_precision_crossing` lint
/// rule is what makes that a check rather than a convention
/// (`engine-physics-queries.md` §1.11.8).
pub const cross = api.precision.Crossing(Real);
