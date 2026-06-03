//! Comptime variant dispatch. Each kernel resolves to the best
//! implementation available for the build target, decided at comptime so
//! the call site (`simd.adler32(data)`) carries no runtime branch.
//!
//! M0.6 ships portable `@Vector` kernels only, so every kernel resolves to
//! its portable variant. Arch variants (`arch_x86_64/`, `arch_aarch64/`)
//! slot into the `select*` functions below behind `traits.current` checks
//! in a later phase without touching any call site.

const portable = @import("portable.zig");

/// ADLER32 entry point selected for the build target.
pub const adler32 = selectAdler32();

fn selectAdler32() fn (data: []const u8) u32 {
    // No ISA-specific variants in M0.6 (brief §Notes — `@Vector` only).
    // Future shape:
    //   if (traits.current.has_avx2) return @import("arch_x86_64/avx2.zig").adler32;
    //   if (traits.current.has_neon) return @import("arch_aarch64/neon.zig").adler32;
    return portable.adler32;
}

/// PNG Paeth-filter decode entry point selected for the build target.
pub const paeth_filter_decode = selectPaeth();

fn selectPaeth() fn (prev: []const u8, curr: []u8, bpp: u8) void {
    // Portable-only in M0.6; arch variants slot in here later.
    return portable.paeth_filter_decode;
}
