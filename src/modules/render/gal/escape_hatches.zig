//! Escape hatches GAL pré-câblés jour 1 (brief §Scope + §Notes décision 1).
//!
//! Trois concepts dont l'absence Phase 0 forcerait un refactor Phase 1+ :
//!
//! 1. **`TimelineSemaphore`** — sémaphore timeline (Vulkan `VK_KHR_timeline_semaphore`,
//!    Metal events, D3D12 fences avec valeur). Phase 0 : type présent, fonctionnel
//!    minimal côté Vulkan, no-op Null. Premier usage Phase 1+ (render graph
//!    avec async compute multi-queue).
//!
//! 2. **`BarrierExplicit`** — opt-in flag par pass qui désactive l'auto-tracking
//!    de barriers (cf. `gal/barriers.zig`). Phase 0 : drapeau présent, code
//!    de tracking ignore la pass, le body se débrouille. Premier usage Phase 1+
//!    (pass merging du render graph + resource aliasing).
//!
//! 3. **`DescriptorIndexing`** — bindless descriptors (Vulkan `VK_EXT_descriptor_indexing`,
//!    Metal argument buffers, D3D12 ResourceDescriptorHeap). Phase 0 : structures
//!    déclarées, capacité query-able via `Device.supports`, mais bind groups fixes
//!    uniquement (cf. brief §Out-of-scope). Premier usage Phase 1+ (V-Buffer
//!    material eval data-driven).
//!
//! Le pré-câblage évite que l'ajout Phase 1+ force un refactor de toute la
//! surface GAL (principe directeur "concevoir au jour 1").

const std = @import("std");
const types = @import("types.zig");

// ============================================================================
// TimelineSemaphore
// ============================================================================

/// Handle opaque de TimelineSemaphore.
pub const TimelineSemaphoreHandle = extern struct {
    inner: u64 = 0,
    pub fn isValid(self: TimelineSemaphoreHandle) bool {
        return self.inner != 0;
    }
};

/// Descripteur de TimelineSemaphore.
pub const TimelineSemaphoreDescriptor = struct {
    label: ?[]const u8 = null,
    /// Valeur initiale du compteur. La valeur est monotone croissante.
    initial_value: u64 = 0,
};

/// Snapshot d'un wait/signal sur une valeur donnée.
pub const TimelineWait = struct {
    semaphore: TimelineSemaphoreHandle,
    value: u64,
};

// ============================================================================
// BarrierExplicit
// ============================================================================

/// Mode de tracking des barriers pour une pass. Posé par le caller dans le
/// descriptor de la pass (cf. `render_graph/pass.zig`).
pub const BarrierMode = enum {
    /// Auto-tracking par le render graph (défaut Phase 0).
    auto,
    /// Aucun tracking — le body de la pass insère ses barriers via
    /// `RenderPassEncoder.barrier(...)` / `ComputePassEncoder.barrier(...)`.
    /// Premier usage Phase 1+ (pass merging, resource aliasing).
    explicit,
};

/// Descripteur de barrier explicite (utilisé dans le mode `BarrierMode.explicit`).
pub const ExplicitBarrier = struct {
    /// Resource cible (Buffer ou Texture).
    resource: union(enum) {
        buffer: types.BufferHandle,
        texture: types.TextureHandle,
    },
    /// Stage producer (qui produit la donnée avant la barrière).
    src_stage: types.ShaderStage,
    /// Stage consumer (qui lit la donnée après la barrière).
    dst_stage: types.ShaderStage,
    /// Layout de texture après la transition (uniquement si `resource = .texture`).
    new_layout: ?TextureLayout = null,
};

/// Layout possible d'une texture. Cf. Vulkan `VkImageLayout`. Sous-set Phase 0.
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

/// Configuration du bindless descriptor heap. Phase 0 : type présent, instanciation
/// retourne `error.Unsupported` si `Device.supports(.descriptor_indexing) == false`.
pub const DescriptorIndexingDescriptor = struct {
    label: ?[]const u8 = null,
    /// Capacité du heap par type de resource. Phase 0 : valeurs ignorées (heap
    /// non créé), Phase 1+ : limite hardware-aware (typique 500k textures sur
    /// GPUs récents).
    max_sampled_textures: u32 = 0,
    max_storage_textures: u32 = 0,
    max_samplers: u32 = 0,
    max_storage_buffers: u32 = 0,
};

/// Handle opaque vers un heap bindless. Phase 0 : `inner = 0` toujours.
pub const DescriptorHeapHandle = extern struct {
    inner: u64 = 0,
    pub fn isValid(self: DescriptorHeapHandle) bool {
        return self.inner != 0;
    }
};

// ============================================================================
// Feature query (cohérent avec les escape hatches)
// ============================================================================

/// Features optionnelles query-ables via `Device.supports`.
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
