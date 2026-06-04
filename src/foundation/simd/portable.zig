//! Portable `@Vector` kernel variants — always present on every target, no
//! ISA-specific asm. `dispatch.zig` falls back here when no faster arch
//! variant exists for the build target (the only case in M0.6).

const adler32_kernel = @import("kernels/adler32.zig");
const paeth_kernel = @import("kernels/paeth.zig");

/// Portable ADLER32 (`@Vector`).
pub const adler32 = adler32_kernel.vectorized;

/// Portable PNG Paeth-filter decode (`@Vector`).
pub const paeth_filter_decode = paeth_kernel.vectorized;
