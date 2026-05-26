//! GPU Abstraction Layer (GAL) — entrée publique du module Render Phase 0 / M0.4.
//!
//! Surface inspirée WebGPU (cf. `engine-render.md` §3) avec escape hatches
//! pré-câblés jour 1 pour `TimelineSemaphore`, `BarrierExplicit`,
//! `DescriptorIndexing` (cf. `escape_hatches.zig`).
//!
//! **Sélection backend par comptime selon `BackendChoice`.** Phase 0 expose
//! `Null` (CI headless) et `Vulkan` (à venir dans la suite de M0.4). Phase 2
//! ajoute `Metal` + `D3D12`, Phase 3 `WebGPU`. La surface publique reste
//! identique cross-backend — seul le type concret derrière `Device` change.
//!
//! Pattern d'utilisation :
//!
//! ```zig
//! const gal = @import("gal");
//! var device = try gal.Device(.null_backend).init(allocator, .{ .label = "test" });
//! defer device.deinit();
//! ```
//!
//! Le wrapper `Device(choice)` vérifie le contrat au comptime via
//! `interface.checkBackend(Backend)`. Aucun dispatch dynamique.

const std = @import("std");

/// Types publics GAL (handles, formats, descripteurs).
pub const types = @import("types.zig");
/// Escape hatches pré-câblés jour 1 (`TimelineSemaphore`, `BarrierExplicit`,
/// `DescriptorIndexing`, `Feature` query).
pub const escape_hatches = @import("escape_hatches.zig");
/// Vérification comptime du contrat backend (cf. `checkBackend`).
pub const interface = @import("interface.zig");
/// Auto-tracking de barriers entre passes du render graph.
pub const barriers = @import("barriers.zig");
/// Backend Null — no-op, utilisé en CI headless et pour la discipline d'API.
pub const null_backend = @import("null/device.zig");

// Re-exports lisibles côté caller (évite l'imbrication `gal.types.*`).

/// Re-export pratique : descripteur d'init de Device.
pub const DeviceDescriptor = types.DeviceDescriptor;
/// Re-export pratique : descripteur de Buffer.
pub const BufferDescriptor = types.BufferDescriptor;
/// Re-export pratique : descripteur de Texture.
pub const TextureDescriptor = types.TextureDescriptor;
/// Re-export pratique : descripteur de TextureView.
pub const TextureViewDescriptor = types.TextureViewDescriptor;
/// Re-export pratique : descripteur de Sampler.
pub const SamplerDescriptor = types.SamplerDescriptor;
/// Re-export pratique : descripteur de ShaderModule (SPIR-V).
pub const ShaderModuleDescriptor = types.ShaderModuleDescriptor;
/// Re-export pratique : descripteur de BindGroupLayout.
pub const BindGroupLayoutDescriptor = types.BindGroupLayoutDescriptor;
/// Re-export pratique : descripteur de BindGroup.
pub const BindGroupDescriptor = types.BindGroupDescriptor;
/// Re-export pratique : descripteur de RenderPipeline (PSO graphics).
pub const RenderPipelineDescriptor = types.RenderPipelineDescriptor;
/// Re-export pratique : descripteur de ComputePipeline.
pub const ComputePipelineDescriptor = types.ComputePipelineDescriptor;
/// Re-export pratique : descripteur de Swapchain.
pub const SwapchainDescriptor = types.SwapchainDescriptor;
/// Re-export pratique : descripteur de Render pass (passé à `beginRenderPass`).
pub const RenderPassDescriptor = types.RenderPassDescriptor;
/// Re-export pratique : descripteur de Compute pass.
pub const ComputePassDescriptor = types.ComputePassDescriptor;
/// Re-export pratique : set d'erreurs GAL unifié cross-backend.
pub const Error = types.Error;
/// Re-export pratique : énumération des features optionnelles query-ables.
pub const Feature = escape_hatches.Feature;

/// Choix de backend résolu à la compilation. Phase 0 supporte explicitement
/// `null_backend`. `vulkan` arrive dans la suite de M0.4. Les autres entrées
/// sont déclarées jour 1 pour figer la surface mais retournent
/// `@compileError` jusqu'à leur livraison Phase 2-3.
pub const BackendChoice = enum {
    null_backend,
    vulkan,
    metal,
    d3d12,
    webgpu,
};

/// Wrapper comptime qui résout `BackendChoice` vers le type concret.
pub fn Device(comptime choice: BackendChoice) type {
    return switch (choice) {
        .null_backend => null_backend.Device,
        .vulkan => @compileError("Vulkan backend not yet wired in M0.4 scaffolding — see brief §Scope (suite immediate)"),
        .metal => @compileError("Metal backend is Phase 2+ (declared day 1, not implemented in M0.4)"),
        .d3d12 => @compileError("D3D12 backend is Phase 2+ (declared day 1, not implemented in M0.4)"),
        .webgpu => @compileError("WebGPU backend is Phase 3+ (declared day 1, not implemented in M0.4)"),
    };
}

/// Sélection par défaut basée sur `builtin.os.tag`. Phase 0 : `null_backend`
/// puisque Vulkan n'est pas encore wiré dans M0.4 scaffolding. Mis à jour
/// vers `.vulkan` une fois le backend Vulkan livré dans la suite immédiate
/// du milestone.
pub fn defaultBackend() BackendChoice {
    return .null_backend;
}

// ============================================================================
// Sanity comptime — Null backend satisfait l'interface
// ============================================================================

comptime {
    interface.checkBackend(null_backend.Device);
}

test "main: BackendChoice exposes all 5 entries" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 5), @typeInfo(BackendChoice).@"enum".fields.len);
}

test "main: Device(.null_backend) resolves to null device type" {
    const D = Device(.null_backend);
    try std.testing.expectEqual(null_backend.Device, D);
}
