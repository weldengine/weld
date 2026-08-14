//! Foundation — transversal sibling submodules consumed across the engine.
//!
//! Per `engine-simd.md` § "Relation avec `foundation/math/`", `math` and `simd`
//! are sibling submodules with no mutual dependency. M0.6 shipped `simd` (the
//! batched-kernel module); M1.1.0 adds `math` — its first consumer is Forge 3D.

/// General-purpose math types (Vec/Quat/Mat3/Aabb, generic over the scalar;
/// f32 aliases + generics). Operates one value at a time; imports no `simd`.
pub const math = @import("math/math.zig");

/// Batched-SIMD kernels (adler32 in M0.6; audio mix, skinning, … later).
pub const simd = @import("simd/simd.zig");

/// The floating-point EXECUTION state (`ARCH-031` rule 5) — rounding mode and
/// denormal handling of the calling thread. Installed by the platform layer at
/// thread creation, ASSERTED by every module whose output is compared.
///
/// It sits in `foundation` rather than under `core/platform/` because the two
/// halves have different owners and only one mechanism: the module that has to
/// assert is `forge_3d`, which may not import `weld_core` (a C1.1 exit metric).
/// `core/platform/float_env.zig` is the platform layer's facade over this file
/// and holds no second copy of the register layout. Added M1.1.14.
pub const float_env = @import("float_env.zig");

comptime {
    _ = math;
    _ = simd;
    _ = float_env;
}
