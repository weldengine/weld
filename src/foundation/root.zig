//! Foundation — transversal sibling submodules consumed across the engine.
//!
//! Per `engine-spec.md` §3.5 and `engine-simd.md` §4, `math` and `simd` are
//! sibling submodules with no mutual dependency. M0.6 ships `simd` (the
//! batched-kernel module); `math` is added when its first consumer lands.

/// Batched-SIMD kernels (adler32 in M0.6; audio mix, skinning, … later).
pub const simd = @import("simd/simd.zig");

comptime {
    _ = simd;
}
