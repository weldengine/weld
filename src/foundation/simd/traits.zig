//! Capability bitflags + comptime target detection for `foundation/simd`.
//!
//! M0.6 ships portable `@Vector` kernels only (no ISA-specific asm,
//! brief §Notes), so nothing dispatches on these flags yet. They exist to
//! stand up the dispatch infrastructure: `dispatch.zig` will branch on
//! `traits.current` once arch variants land in a later phase.

const std = @import("std");
const builtin = @import("builtin");

/// CPU SIMD capabilities resolved at build time from `builtin.cpu`.
pub const Capabilities = struct {
    /// x86_64 SSE4.1.
    has_sse4_1: bool = false,
    /// x86_64 AVX2.
    has_avx2: bool = false,
    /// x86_64 AVX-512 Foundation.
    has_avx512f: bool = false,
    /// x86_64 fused multiply-add.
    has_fma: bool = false,
    /// aarch64 Advanced SIMD (NEON).
    has_neon: bool = false,
    /// aarch64 SVE2.
    has_sve2: bool = false,
};

/// Resolve the target's SIMD capabilities from `builtin.cpu`. Evaluated at
/// comptime (it reads comptime-known CPU features); also callable in tests.
pub fn detect() Capabilities {
    var c = Capabilities{};
    const cpu = builtin.cpu;
    switch (cpu.arch) {
        .x86_64 => {
            c.has_sse4_1 = std.Target.x86.featureSetHas(cpu.features, .sse4_1);
            c.has_avx2 = std.Target.x86.featureSetHas(cpu.features, .avx2);
            c.has_avx512f = std.Target.x86.featureSetHas(cpu.features, .avx512f);
            c.has_fma = std.Target.x86.featureSetHas(cpu.features, .fma);
        },
        .aarch64, .aarch64_be => {
            c.has_neon = std.Target.aarch64.featureSetHas(cpu.features, .neon);
            c.has_sve2 = std.Target.aarch64.featureSetHas(cpu.features, .sve2);
        },
        else => {},
    }
    return c;
}

/// Capabilities of the current build target.
pub const current: Capabilities = detect();

test "capability detection is consistent with the build target" {
    try std.testing.expectEqual(detect(), current);
    // A64 mandates NEON, so it must be reported on every aarch64 build.
    switch (builtin.cpu.arch) {
        .aarch64, .aarch64_be => try std.testing.expect(current.has_neon),
        else => {},
    }
}
