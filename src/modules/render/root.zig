//! FROZEN — see engine-phase-0-criteria.md C0.5 (M0.9)
//!
//! Render module — Phase 0 / M0.4.
//!
//! Public entry point of the Render module (Tier 1). Re-exposes the two
//! Phase 0 subsystems:
//! - `gal` — GPU Abstraction Layer (Device, Buffer, Texture, ...)
//! - `render_graph` — declarative DAG of passes + 3 Phase 0 passes
//!
//! Phase 1+: adds V-Buffer, Radiance GI, post-process, etc. The public
//! surface stays stable — it is the contract frozen on day 1 (brief
//! §Notes decision 1).

/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.9)
/// Version of the frozen RenderModule (Tier-1, exercised) public surface
/// — the `gal` + `render_graph` + `shader_pipeline` + `instancing`
/// namespaces. The GAL cross-backend contract has its own finer-grained
/// `WELD_GAL_PROTOCOL_VERSION` (gal/root.zig). Bumped on any breaking
/// change — a tracked migration, not a freeze failure (the
/// `*_PROTOCOL_VERSION` rule, generalized from `WELD_IPC_PROTOCOL_VERSION`).
pub const WELD_RENDER_PROTOCOL_VERSION: u32 = 1;

// Re-export of the GAL submodule.

/// GAL namespace — public types, comptime interface, Null + Vulkan backends,
/// barriers tracker, escape hatches.
pub const gal = @import("gal/root.zig");

// Re-export of the render_graph submodule.

/// Render graph namespace — DAG, Pass, and 3 Phase 0 passes (depth_prepass,
/// forward, capture).
pub const render_graph = struct {
    pub const Graph = @import("render_graph/graph.zig").Graph;
    pub const PassIndex = @import("render_graph/graph.zig").PassIndex;
    pub const Error = @import("render_graph/graph.zig").Error;

    pub const pass = @import("render_graph/pass.zig");
    pub const passes = struct {
        pub const depth_prepass = @import("render_graph/passes/depth_prepass.zig");
        pub const forward = @import("render_graph/passes/forward.zig");
        pub const capture = @import("render_graph/passes/capture.zig");
    };
};

/// Shader pipeline namespace — GLSL→SPIR-V compiler (glslc CLI spawn),
/// hashed disk cache, hot-reload via filewatch.
pub const shader_pipeline = struct {
    pub const compiler = @import("shader_pipeline/compiler.zig");
    pub const cache = @import("shader_pipeline/cache.zig");
    pub const hot_reload = @import("shader_pipeline/hot_reload.zig");
};

/// Instancing batcher namespace — CPU-side ECS bucketing by
/// `(mesh_id, material_id)`, front-to-back sorting by centroid.
pub const instancing = struct {
    pub const batcher = @import("instancing/batcher.zig");
};

// Pins for the analysis of inline tests (engine-zig-conventions.md §13).
comptime {
    _ = gal;
    _ = render_graph.Graph;
    _ = render_graph.pass;
    _ = render_graph.passes.depth_prepass;
    _ = render_graph.passes.forward;
    _ = render_graph.passes.capture;
    _ = shader_pipeline.compiler;
    _ = shader_pipeline.cache;
    _ = shader_pipeline.hot_reload;
    _ = instancing.batcher;
}

// Former direct accesses preserved for backward compatibility with
// `tests/render/gal_null_smoke.zig` (which imports `weld_render` and accesses
// `.types`, `.interface`, etc.). These re-exports are the same types as
// `gal.X`, just a shortcut.

/// Convenience re-export of the GAL types.
pub const types = gal.types;
/// Convenience re-export of the GAL interface.
pub const interface = gal.interface;
/// Convenience re-export of the barriers tracker.
pub const barriers = gal.barriers;
/// Convenience re-export of the GAL escape hatches.
pub const escape_hatches = gal.escape_hatches;
/// Convenience re-export of the Null backend.
pub const null_backend = gal.null_backend;
/// Convenience re-export of the Vulkan backend.
pub const vulkan_backend = gal.vulkan_backend;
