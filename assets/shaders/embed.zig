//! Compile-time embedding of pre-compiled SPIR-V shaders. Routed
//! through this tiny module so `@embedFile` resolves inside the
//! `assets/shaders/` package — caller modules sit under `src/`,
//! which `@embedFile` cannot escape directly.

// The triangle — kept for the legacy `weld` binary.
pub const triangle_vert_spv: []const u8 = @embedFile("triangle.vert.spv");
pub const triangle_frag_spv: []const u8 = @embedFile("triangle.frag.spv");

// The viewport blit pipeline: a fullscreen triangle with no VBO, its positions
// derived from `gl_VertexIndex`, sampling the runtime-written shm framebuffer.
pub const viewport_blit_vert_spv: []const u8 = @embedFile("viewport_blit.vert.spv");
pub const viewport_blit_frag_spv: []const u8 = @embedFile("viewport_blit.frag.spv");
