//! Module Render — Phase 0 / M0.4.
//!
//! Entrée publique du module Render (Tier 1). Re-expose les deux
//! sous-systèmes Phase 0 :
//! - `gal` — GPU Abstraction Layer (Device, Buffer, Texture, ...)
//! - `render_graph` — DAG déclaratif de passes + 3 passes Phase 0
//!
//! Phase 1+ : ajoute V-Buffer, Radiance GI, post-process, etc. La surface
//! publique reste stable — c'est le contrat figé jour 1 (brief
//! §Notes décision 1).

// Re-export du sous-module GAL.

/// Namespace GAL — types publics, interface comptime, backends Null + Vulkan,
/// barriers tracker, escape hatches.
pub const gal = @import("gal/main.zig");

// Re-export du sous-module render_graph.

/// Namespace render graph — DAG, Pass, et 3 passes Phase 0 (depth_prepass,
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

/// Namespace shader pipeline — compiler GLSL→SPIR-V (glslc CLI spawn),
/// cache disque hashé, hot-reload via filewatch.
pub const shader_pipeline = struct {
    pub const compiler = @import("shader_pipeline/compiler.zig");
    pub const cache = @import("shader_pipeline/cache.zig");
    pub const hot_reload = @import("shader_pipeline/hot_reload.zig");
};

// Pins pour l'analyse des inline tests (engine-zig-conventions.md §13).
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
}

// Anciens accès directs préservés pour rétrocompatibilité avec
// `tests/render/gal_null_smoke.zig` (qui importe `weld_render` et accède à
// `.types`, `.interface`, etc.). Ces re-exports sont les mêmes types que
// `gal.X`, juste un raccourci.

/// Re-export pratique des types GAL.
pub const types = gal.types;
/// Re-export pratique de l'interface GAL.
pub const interface = gal.interface;
/// Re-export pratique du tracker de barriers.
pub const barriers = gal.barriers;
/// Re-export pratique des escape hatches GAL.
pub const escape_hatches = gal.escape_hatches;
/// Re-export pratique du backend Null.
pub const null_backend = gal.null_backend;
/// Re-export pratique du backend Vulkan.
pub const vulkan_backend = gal.vulkan_backend;
