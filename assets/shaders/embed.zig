//! Compile-time embedding of the S2 spike's pre-compiled SPIR-V shaders.
//! Routed through this tiny module so `@embedFile` resolves inside the
//! `assets/shaders/` package — the spike's executable module sits under
//! `src/`, which `@embedFile` cannot escape directly.

pub const triangle_vert_spv: []const u8 = @embedFile("triangle.vert.spv");
pub const triangle_frag_spv: []const u8 = @embedFile("triangle.frag.spv");
