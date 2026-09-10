//! FROZEN — see `engine-phase-0-criteria.md` C0.5.
//!
//! GAL escape hatches pre-wired day 1.
//!
//! Three concepts pre-wired so that adding them later cannot force a refactor:
//!
//! 1. **`TimelineSemaphore`** — timeline semaphore (Vulkan `VK_KHR_timeline_semaphore`,
//!    Metal events, D3D12 fences with value). Type present, minimally
//!    functional on the Vulkan side, no-op on Null. No caller uses it yet; its
//!    first use is the render graph with multi-queue async compute.
//!
//! 2. **`BarrierExplicit`** — per-pass opt-in flag that disables barrier
//!    auto-tracking (cf. `gal/barriers.zig`). Flag present: the tracking code
//!    skips the pass and the body fends for itself. No caller uses it yet; its
//!    first use is render graph pass merging and resource aliasing.
//!
//! 3. **`DescriptorIndexing`** — bindless descriptors (Vulkan `VK_EXT_descriptor_indexing`,
//!    Metal argument buffers, D3D12 ResourceDescriptorHeap). Structures declared
//!    and the capability query-able via `Device.supports`, but fixed bind groups
//!    only. No caller uses it yet; its first use is data-driven V-Buffer material
//!    eval.
//!
//! Pre-wiring is what keeps a later addition from forcing a refactor of the
//! whole GAL surface — the "design at day 1" principle.

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
    /// Auto-tracking by the render graph (the default).
    auto,
    /// No tracking — the pass body inserts its barriers via
    /// `RenderPassEncoder.barrier(...)` / `ComputePassEncoder.barrier(...)`.
    /// No caller uses it yet; its first use is pass merging and resource
    /// aliasing.
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

/// Possible layout of a texture. Cf. Vulkan `VkImageLayout` — a subset.
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

/// Bindless descriptor heap configuration. Instantiation
/// returns `error.Unsupported` if `Device.supports(.descriptor_indexing) == false`.
pub const DescriptorIndexingDescriptor = struct {
    label: ?[]const u8 = null,
    /// Heap capacity per resource type.
    ///
    /// TODO(bindless heap creation): these values are IGNORED because the heap
    /// is never created, so a caller setting them gets nothing. What they should
    /// become is a hardware-aware limit, typically 500k textures on recent GPUs.
    max_sampled_textures: u32 = 0,
    max_storage_textures: u32 = 0,
    max_samplers: u32 = 0,
    max_storage_buffers: u32 = 0,
};

/// Opaque handle to a bindless heap. `inner = 0` always.
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
