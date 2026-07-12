//! Foundation — transversal sibling submodules consumed across the engine.
//!
//! Per `engine-spec.md` §3.5 and `engine-simd.md` §4, `math` and `simd` are
//! sibling submodules with no mutual dependency. M0.6 shipped `simd` (the
//! batched-kernel module); M1.1.0 adds `math` — its first consumer is Forge 3D.

/// General-purpose math types (Vec/Quat/Mat3/Aabb, generic over the scalar;
/// f32 aliases + generics). Operates one value at a time; imports no `simd`.
pub const math = @import("math/math.zig");

/// Batched-SIMD kernels (adler32 in M0.6; audio mix, skinning, … later).
pub const simd = @import("simd/simd.zig");

comptime {
    _ = math;
    _ = simd;
}
