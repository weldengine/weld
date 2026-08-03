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

// Pins so the inline tests in every sub-file are analysed when this module is
// built as a test target (engine-zig-conventions.md §13).
comptime {
    _ = vec;
    _ = quat;
    _ = mat3;
    _ = aabb;
}
