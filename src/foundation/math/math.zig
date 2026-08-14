//! `foundation/math` — general-purpose math types for the whole engine.
//!
//! Vec / Quat / Mat3 / Aabb, each generic over the scalar (`f32` and `f64`
//! instantiable from day one). The plain-name generics (`Vec`, `Quat`,
//! `Mat3`, `Aabb`) are the constructors; `Vec2`/`Vec3`/`Vec4` and
//! `Quatf`/`Mat3f`/`Aabbf` are the f32 aliases (no f64 aliases — consumers
//! instantiate the generics). First consumer of `foundation/math/`: Forge 3D
//! (M1.1). This submodule never imports `foundation/simd/` (sister-module
//! rule, `engine-directory-structure.md` §620) — typed vectors cross to the
//! SIMD kernels via `asFloatSlice` at the call site.

const vec = @import("vec.zig");
const quat = @import("quat.zig");
const mat3 = @import("mat3.zig");
const aabb = @import("aabb.zig");
const trig = @import("trig.zig");

/// Generic vector constructor `Vec(N, T)`.
pub const Vec = vec.Vec;
/// f32 2-vector.
pub const Vec2 = vec.Vec2;
/// f32 3-vector.
pub const Vec3 = vec.Vec3;
/// f32 4-vector.
pub const Vec4 = vec.Vec4;
/// Reinterpret `[]const Vec3` as a flat `[]const f32` for the SIMD kernels.
pub const asFloatSlice = vec.asFloatSlice;
/// The DIRECTION of a triangle's area vector — NOT a flatness classifier. See `CrossOutcome` for
/// the asymmetry: `.degenerate` is a reliable flatness verdict, `.direction` is not a reliable
/// verdict of non-flatness. The classifier is `triangleIsFlat`.
pub const triangleCross = vec.triangleCross;
/// What `triangleCross` can conclude, and in which direction that conclusion is trustworthy.
pub const CrossOutcome = vec.CrossOutcome;
/// Whether a triangle is EXACTLY flat, decided in integer arithmetic. THE classifier: callers that
/// must not admit a flat triangle ask this, never `triangleCross`.
pub const triangleIsFlat = @import("exact.zig").triangleIsFlat;
/// A vector PARALLEL to the exact area vector of three points, or `null` when that vector is
/// EXACTLY zero — the exact tier `triangleIsFlat` is written on, exposed for callers that need the
/// DIRECTION together with that exact null.
///
/// Re-exported at M1.1.12 for its second consumer: the character controller's edge slide, whose
/// direction is `n₁ × n₂` and whose `null` must mean "the two normals are exactly parallel" and
/// nothing weaker. The tiered `triangleCross` cannot serve there — its `.direction` comes from the
/// first float tier that forms a non-zero vector, so on exactly parallel normals it returns a
/// rounding residue that reads as a valid crease. That is the very confusion §1.11.17 records as
/// having nearly shipped.
pub const triangleCrossDirection = @import("exact.zig").triangleCrossDirection;
/// The power-of-two exponent that reduces three points below unit magnitude.
pub const pow2ReductionExponent = vec.pow2ReductionExponent;

/// Generic quaternion constructor `Quat(T)`.
pub const Quat = quat.Quat;
/// f32 quaternion.
pub const Quatf = quat.Quatf;

/// Generic 3×3 matrix constructor `Mat3(T)`.
pub const Mat3 = mat3.Mat3;
/// f32 3×3 matrix.
pub const Mat3f = mat3.Mat3f;

/// Generic axis-aligned bounding box constructor `Aabb(T)`.
pub const Aabb = aabb.Aabb;
/// f32 axis-aligned bounding box.
pub const Aabbf = aabb.Aabbf;

/// DETERMINISTIC cosine — no libm call, fixed operation order (`ARCH-031`
/// rule 4). NOT a wrapper around `@cos`: `@cos` lowers to an external `cosf` /
/// `cos` on every target the engine ships, and two C libraries disagree by an
/// ULP. Domain-bounded by `max_argument`; see `trig.zig` for what that bound is
/// and why serving past it would mean writing a replacement libm.
pub const cos = trig.cos;
/// The largest argument magnitude `cos` accepts, in radians.
pub const max_trig_argument = trig.max_argument;

// Pins so the inline tests in every sub-file are analysed when this module is
// built as a test target (engine-zig-conventions.md §13).
comptime {
    _ = vec;
    _ = quat;
    _ = mat3;
    _ = aabb;
    _ = trig;
}
