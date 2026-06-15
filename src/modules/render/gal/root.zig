//! FROZEN — see engine-phase-0-criteria.md C0.5 (M0.9)
//!
//! GPU Abstraction Layer (GAL) — public entry point of the Render module, Phase 0 / M0.4.
//!
//! Surface inspired by WebGPU (cf. `engine-render.md` §3) with escape hatches
//! pre-wired day 1 for `TimelineSemaphore`, `BarrierExplicit`,
//! `DescriptorIndexing` (cf. `escape_hatches.zig`).
//!
//! **Comptime backend selection via `BackendChoice`.** Phase 0 exposes
//! `Null` (headless CI) and `Vulkan` (coming later in M0.4). Phase 2
//! adds `Metal` + `D3D12`, Phase 3 `WebGPU`. The public surface stays
//! identical cross-backend — only the concrete type behind `Device` changes.
//!
//! Usage pattern:
//!
//! ```zig
//! const gal = @import("gal");
//! var device = try gal.Device(.null_backend).init(allocator, .{ .label = "test" });
//! defer device.deinit();
//! ```
//!
//! The `Device(choice)` wrapper checks the contract at comptime via
//! `interface.checkBackend(Backend)`. No dynamic dispatch.

const std = @import("std");

/// Public GAL types (handles, formats, descriptors).
pub const types = @import("types.zig");
/// Escape hatches pre-wired day 1 (`TimelineSemaphore`, `BarrierExplicit`,
/// `DescriptorIndexing`, `Feature` query).
pub const escape_hatches = @import("escape_hatches.zig");
/// Comptime check of the backend contract (cf. `checkBackend`).
pub const interface = @import("interface.zig");
/// Barrier auto-tracking between render graph passes.
pub const barriers = @import("barriers.zig");
/// Null backend — no-op, used in headless CI and for API discipline.
pub const null_backend = @import("null/device.zig");
/// Vulkan backend — Phase 0+ implementation (cf. brief §Scope).
pub const vulkan_backend = @import("vulkan/device.zig");
/// Frame-capture helper (texture → PPM readback), M0.5 item 2. Backend-
/// agnostic; each backend `Device` also exposes it as a `captureFrameToPPM`
/// method (cf. `gal/capture.zig`).
pub const capture = @import("capture.zig");

/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.9)
/// Version of the frozen GAL cross-backend contract — the comptime
/// `interface.required_methods` + `checkBackend`, the opaque handle +
/// descriptor + `Error` types, and the colorspace/copy/subpass touch-points.
/// Bumped on any breaking change to the backend-facing contract — a tracked
/// migration, not a freeze failure (the `*_PROTOCOL_VERSION` rule).
pub const WELD_GAL_PROTOCOL_VERSION: u32 = 1;

// Caller-friendly re-exports (avoids the `gal.types.*` nesting).

/// Convenience re-export: Device init descriptor.
pub const DeviceDescriptor = types.DeviceDescriptor;
/// Convenience re-export: Buffer descriptor.
pub const BufferDescriptor = types.BufferDescriptor;
/// Convenience re-export: Texture descriptor.
pub const TextureDescriptor = types.TextureDescriptor;
/// Convenience re-export: TextureView descriptor.
pub const TextureViewDescriptor = types.TextureViewDescriptor;
/// Convenience re-export: Sampler descriptor.
pub const SamplerDescriptor = types.SamplerDescriptor;
/// Convenience re-export: ShaderModule descriptor (SPIR-V).
pub const ShaderModuleDescriptor = types.ShaderModuleDescriptor;
/// Convenience re-export: BindGroupLayout descriptor.
pub const BindGroupLayoutDescriptor = types.BindGroupLayoutDescriptor;
/// Convenience re-export: BindGroup descriptor.
pub const BindGroupDescriptor = types.BindGroupDescriptor;
/// Convenience re-export: RenderPipeline descriptor (graphics PSO).
pub const RenderPipelineDescriptor = types.RenderPipelineDescriptor;
/// Convenience re-export: ComputePipeline descriptor.
pub const ComputePipelineDescriptor = types.ComputePipelineDescriptor;
/// Convenience re-export: Swapchain descriptor.
pub const SwapchainDescriptor = types.SwapchainDescriptor;
/// Convenience re-export: Render pass descriptor (passed to `beginRenderPass`).
pub const RenderPassDescriptor = types.RenderPassDescriptor;
/// Convenience re-export: Compute pass descriptor.
pub const ComputePassDescriptor = types.ComputePassDescriptor;
/// Convenience re-export: unified cross-backend GAL error set.
pub const Error = types.Error;
/// Convenience re-export: enumeration of optional query-able features.
pub const Feature = escape_hatches.Feature;

/// Backend choice resolved at compile time. Phase 0 explicitly supports
/// `null_backend`. `vulkan` comes later in M0.4. The other entries are
/// declared day 1 to freeze the surface but return `@compileError` until
/// their Phase 2-3 delivery.
pub const BackendChoice = enum {
    null_backend,
    vulkan,
    metal,
    d3d12,
    webgpu,
};

/// Comptime wrapper that resolves `BackendChoice` to the concrete type.
pub fn Device(comptime choice: BackendChoice) type {
    return switch (choice) {
        .null_backend => null_backend.Device,
        .vulkan => vulkan_backend.Device,
        .metal => @compileError("Metal backend is Phase 2+ (declared day 1, not implemented in M0.4)"),
        .d3d12 => @compileError("D3D12 backend is Phase 2+ (declared day 1, not implemented in M0.4)"),
        .webgpu => @compileError("WebGPU backend is Phase 3+ (declared day 1, not implemented in M0.4)"),
    };
}

/// Default selection based on `builtin.os.tag`. Phase 0: `null_backend`
/// since Vulkan is not yet wired in the M0.4 scaffolding. Updated to
/// `.vulkan` once the Vulkan backend is delivered in the immediate
/// follow-up of the milestone.
pub fn defaultBackend() BackendChoice {
    return .null_backend;
}

// ============================================================================
// Comptime sanity — Null backend satisfies the interface
// ============================================================================

comptime {
    interface.checkBackend(null_backend.Device);
    interface.checkBackend(vulkan_backend.Device);
}

test "main: BackendChoice exposes all 5 entries" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 5), @typeInfo(BackendChoice).@"enum".fields.len);
}

test "main: Device(.null_backend) resolves to null device type" {
    const D = Device(.null_backend);
    try std.testing.expectEqual(null_backend.Device, D);
}
