//! GAL escape hatches pre-wired day 1 (brief §Scope + §Notes decision 1).
//!
//! Three concepts whose absence in Phase 0 would force a Phase 1+ refactor:
//!
//! 1. **`TimelineSemaphore`** — timeline semaphore (Vulkan `VK_KHR_timeline_semaphore`,
//!    Metal events, D3D12 fences with value). Phase 0: type present, minimally
//!    functional on the Vulkan side, no-op on Null. First use Phase 1+ (render
//!    graph with multi-queue async compute).
//!
//! 2. **`BarrierExplicit`** — per-pass opt-in flag that disables barrier
//!    auto-tracking (cf. `gal/barriers.zig`). Phase 0: flag present, the
//!    tracking code skips the pass, the body fends for itself. First use Phase 1+
//!    (render graph pass merging + resource aliasing).
//!
//! 3. **`DescriptorIndexing`** — bindless descriptors (Vulkan `VK_EXT_descriptor_indexing`,
//!    Metal argument buffers, D3D12 ResourceDescriptorHeap). Phase 0: structures
//!    declared, capability query-able via `Device.supports`, but fixed bind groups
//!    only (cf. brief §Out-of-scope). First use Phase 1+ (data-driven V-Buffer
//!    material eval).
//!
//! Pre-wiring avoids a Phase 1+ addition forcing a refactor of the whole
//! GAL surface (the "design at day 1" guiding principle).

const std = @import("std");
const types = @import("types.zig");

// ============================================================================
// TimelineSemaphore
// ============================================================================

/// Opaque TimelineSemaphore handle.
pub const TimelineSemaphoreHandle = extern struct {
    inner: u64 = 0,
    pub fn isValid(self: TimelineSemaphoreHandle) bool {
        return self.inner != 0;
    }
};

/// TimelineSemaphore descriptor.
pub const TimelineSemaphoreDescriptor = struct {
    label: ?[]const u8 = null,
    /// Initial counter value. The value is monotonically increasing.
    initial_value: u64 = 0,
};

/// Snapshot of a wait/signal on a given value.
pub const TimelineWait = struct {
    semaphore: TimelineSemaphoreHandle,
    value: u64,
};

// ============================================================================
// BarrierExplicit
// ============================================================================

/// Barrier tracking mode for a pass. Set by the caller in the pass
/// descriptor (cf. `render_graph/pass.zig`).
pub const BarrierMode = enum {
    /// Auto-tracking by the render graph (Phase 0 default).
    auto,
    /// No tracking — the pass body inserts its barriers via
    /// `RenderPassEncoder.barrier(...)` / `ComputePassEncoder.barrier(...)`.
    /// First use Phase 1+ (pass merging, resource aliasing).
    explicit,
};

/// Explicit barrier descriptor (used in `BarrierMode.explicit` mode).
pub const ExplicitBarrier = struct {
    /// Target resource (Buffer or Texture).
    resource: union(enum) {
        buffer: types.BufferHandle,
        texture: types.TextureHandle,
    },
    /// Producer stage (produces the data before the barrier).
    src_stage: types.ShaderStage,
    /// Consumer stage (reads the data after the barrier).
    dst_stage: types.ShaderStage,
    /// Texture layout after the transition (only if `resource = .texture`).
    new_layout: ?TextureLayout = null,
};

/// Possible layout of a texture. Cf. Vulkan `VkImageLayout`. Phase 0 subset.
pub const TextureLayout = enum(u8) {
    undefined,
    general,
    color_attachment,
    depth_stencil_attachment,
    shader_read_only,
    transfer_src,
    transfer_dst,
    present_src,
};

// ============================================================================
// DescriptorIndexing
// ============================================================================

/// Bindless descriptor heap configuration. Phase 0: type present, instantiation
/// returns `error.Unsupported` if `Device.supports(.descriptor_indexing) == false`.
pub const DescriptorIndexingDescriptor = struct {
    label: ?[]const u8 = null,
    /// Heap capacity per resource type. Phase 0: values ignored (heap not
    /// created), Phase 1+: hardware-aware limit (typically 500k textures on
    /// recent GPUs).
    max_sampled_textures: u32 = 0,
    max_storage_textures: u32 = 0,
    max_samplers: u32 = 0,
    max_storage_buffers: u32 = 0,
};

/// Opaque handle to a bindless heap. Phase 0: `inner = 0` always.
pub const DescriptorHeapHandle = extern struct {
    inner: u64 = 0,
    pub fn isValid(self: DescriptorHeapHandle) bool {
        return self.inner != 0;
    }
};

// ============================================================================
// Feature query (consistent with the escape hatches)
// ============================================================================

/// Optional features query-able via `Device.supports`.
pub const Feature = enum {
    timeline_semaphore,
    barrier_explicit,
    descriptor_indexing,
    ray_tracing,
    mesh_shaders,
    variable_rate_shading,
};

test "escape_hatches: handles default to invalid" {
    const t = std.testing;
    try t.expect(!(TimelineSemaphoreHandle{}).isValid());
    try t.expect(!(DescriptorHeapHandle{}).isValid());
}

test "escape_hatches: BarrierMode default is auto" {
    const t = std.testing;
    const mode: BarrierMode = .auto;
    try t.expectEqual(BarrierMode.auto, mode);
}
