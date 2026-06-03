//! `foundation/simd` — public API of the batched-SIMD kernel module.
//!
//! Level-1 kernels (the default surface modules consume) take raw slices and
//! resolve their best variant at comptime via `dispatch`. M0.6 stands up the
//! infrastructure with one kernel — `adler32` — used by the Asset Pipeline
//! DEFLATE/zlib codec to verify the ADLER32 trailer.
//!
//! Boundary discipline (engine-simd.md §4): this module imports nothing but
//! `std`. Typed math objects are converted to raw slices at the call site,
//! never here.

const dispatch = @import("dispatch.zig");

/// ADLER32 checksum of `data` (the dispatched best variant for the target).
pub const adler32 = dispatch.adler32;

/// CPU capability bitflags + comptime detection.
pub const traits = @import("traits.zig");

/// Portable kernel variants (always present).
pub const portable = @import("portable.zig");

/// Comptime variant dispatch table.
pub const dispatch_table = dispatch;

/// Kernel internals — exposed so tests and benches can reach the scalar
/// reference alongside the vectorized path.
pub const kernels = struct {
    /// ADLER32 kernel (`reference` scalar oracle + `vectorized` `@Vector`).
    pub const adler32 = @import("kernels/adler32.zig");
};

// Pins so inline tests in the kernel + traits files are analysed when this
// module is built as a test target (engine-zig-conventions.md §13).
comptime {
    _ = traits;
    _ = portable;
    _ = dispatch;
    _ = kernels.adler32;
}
