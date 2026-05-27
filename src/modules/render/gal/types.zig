//! GAL public types — Phase 0 / M0.4.
//!
//! Surface publique de la GPU Abstraction Layer (cf. `engine-render.md` §3).
//! Inspirée WebGPU / sysgpu Mach, adaptée Weld (right-handed Y-up, escape
//! hatches pré-câblés jour 1 pour `TimelineSemaphore`, `BarrierExplicit`,
//! `DescriptorIndexing`).
//!
//! **Règle d'isolation absolue (brief §Notes pièges connus)** : aucun type
//! Vulkan natif (`vk.VkBuffer`, etc.) ne doit apparaître ici. Les types
//! GAL sont opaques côté caller — chaque backend mappe vers ses types
//! natifs via son propre `conv.zig` (cf. `gal/vulkan/conv.zig`).
//!
//! Les handles GPU sont des structs `extern struct` avec un seul champ
//! `inner: u64` pour garantir un layout stable cross-backend et faciliter
//! la sérialisation future (asset pipeline cooké).

const std = @import("std");

// ============================================================================
// Identités & handles opaques
// ============================================================================

/// Handle opaque de Device. Chaque backend stocke son state dans son propre
/// type concret (`gal/vulkan/device.zig:Device`, `gal/null/device.zig:Device`).
/// Le caller ne voit qu'un pointeur opaque ; les méthodes vivent sur le type
/// concret du backend résolu à comptime via `gal.main.Device`.
pub const DeviceHandle = *opaque {};

/// Handle opaque de Queue (graphics, compute, transfer). Issued par `Device.getQueue`.
pub const QueueHandle = *opaque {};

/// Handle opaque de Buffer GPU.
pub const BufferHandle = extern struct {
    inner: u64 = 0,
    pub fn isValid(self: BufferHandle) bool {
        return self.inner != 0;
    }
};

/// Handle opaque de Texture GPU.
pub const TextureHandle = extern struct {
    inner: u64 = 0,
    pub fn isValid(self: TextureHandle) bool {
        return self.inner != 0;
    }
};

/// Handle opaque de TextureView (vue sur une Texture + format + range mip/array).
pub const TextureViewHandle = extern struct {
    inner: u64 = 0,
    pub fn isValid(self: TextureViewHandle) bool {
        return self.inner != 0;
    }
};

/// Handle opaque de Sampler (filtrage, wrapping, anisotropie).
pub const SamplerHandle = extern struct {
    inner: u64 = 0,
    pub fn isValid(self: SamplerHandle) bool {
        return self.inner != 0;
    }
};

/// Handle opaque de ShaderModule (SPIR-V chargé sur le device).
pub const ShaderModuleHandle = extern struct {
    inner: u64 = 0,
    pub fn isValid(self: ShaderModuleHandle) bool {
        return self.inner != 0;
    }
};

/// Handle opaque de BindGroupLayout.
pub const BindGroupLayoutHandle = extern struct {
    inner: u64 = 0,
    pub fn isValid(self: BindGroupLayoutHandle) bool {
        return self.inner != 0;
    }
};

/// Handle opaque de BindGroup (descriptor set bindé).
pub const BindGroupHandle = extern struct {
    inner: u64 = 0,
    pub fn isValid(self: BindGroupHandle) bool {
        return self.inner != 0;
    }
};

/// Handle opaque de RenderPipeline (PSO graphics).
pub const RenderPipelineHandle = extern struct {
    inner: u64 = 0,
    pub fn isValid(self: RenderPipelineHandle) bool {
        return self.inner != 0;
    }
};

/// Handle opaque de ComputePipeline (PSO compute).
pub const ComputePipelineHandle = extern struct {
    inner: u64 = 0,
    pub fn isValid(self: ComputePipelineHandle) bool {
        return self.inner != 0;
    }
};

/// Handle opaque de Fence (sync CPU↔GPU).
pub const FenceHandle = extern struct {
    inner: u64 = 0,
    pub fn isValid(self: FenceHandle) bool {
        return self.inner != 0;
    }
};

/// Handle opaque de Semaphore binaire (sync GPU↔GPU).
/// Pour timeline semaphores, voir `escape_hatches.TimelineSemaphoreHandle`.
pub const SemaphoreHandle = extern struct {
    inner: u64 = 0,
    pub fn isValid(self: SemaphoreHandle) bool {
        return self.inner != 0;
    }
};

/// Handle opaque de Swapchain (chain de framebuffers présentables).
pub const SwapchainHandle = extern struct {
    inner: u64 = 0,
    pub fn isValid(self: SwapchainHandle) bool {
        return self.inner != 0;
    }
};

// ============================================================================
// Formats & enums
// ============================================================================

/// Formats Phase 0 (cf. brief §Scope GAL — formats limités). Phase 1+
/// étend la liste (BC compressed, ASTC, BC7, etc.).
pub const TextureFormat = enum(u32) {
    undef = 0,

    // 8-bit per channel UNORM
    r8_unorm,
    rg8_unorm,
    rgba8_unorm,
    rgba8_srgb,
    bgra8_unorm,
    bgra8_srgb,

    // Depth/stencil
    d32_sfloat,
    d24_unorm_s8_uint,

    // 16-bit / 32-bit float (Phase 0 minimum — HDR readback)
    r16_sfloat,
    rg16_sfloat,
    rgba16_sfloat,
    r32_sfloat,
    rg32_sfloat,
    rgba32_sfloat,
};

/// Type de queue. Phase 0 : Vulkan présente typiquement une queue unique
/// graphics+present sur les GPUs cible. Compute + transfer dédiés sont
/// query-able mais non requis.
pub const QueueType = enum(u8) {
    graphics,
    compute,
    transfer,
};

/// Mode de présentation swapchain. Phase 0 : `fifo` (vsync) garanti, autres
/// best-effort (négociation à l'init du swapchain).
pub const PresentMode = enum(u8) {
    fifo,
    fifo_relaxed,
    immediate,
    mailbox,
};

/// Topologie de primitive (triangle list par défaut Phase 0).
pub const PrimitiveTopology = enum(u8) {
    point_list,
    line_list,
    line_strip,
    triangle_list,
    triangle_strip,
};

/// Face culling. Right-handed Y-up + counter-clockwise winding = la
/// convention Weld (cohérent glTF). Phase 0 : `back` par défaut.
pub const CullMode = enum(u8) {
    none,
    front,
    back,
};

/// Comparaison de depth/stencil.
pub const CompareOp = enum(u8) {
    never,
    less,
    equal,
    less_or_equal,
    greater,
    not_equal,
    greater_or_equal,
    always,
};

/// Stage shader (utilisé pour les bind groups et les visibility masks).
pub const ShaderStage = packed struct(u32) {
    vertex: bool = false,
    fragment: bool = false,
    compute: bool = false,
    _padding: u29 = 0,

    pub const all_graphics: ShaderStage = .{ .vertex = true, .fragment = true };
    pub const all: ShaderStage = .{ .vertex = true, .fragment = true, .compute = true };
};

/// Usage flags pour Buffer.
pub const BufferUsage = packed struct(u32) {
    vertex: bool = false,
    index: bool = false,
    uniform: bool = false,
    storage: bool = false,
    indirect: bool = false,
    copy_src: bool = false,
    copy_dst: bool = false,
    _padding: u25 = 0,
};

/// Usage flags pour Texture.
pub const TextureUsage = packed struct(u32) {
    sampled: bool = false,
    storage: bool = false,
    color_attachment: bool = false,
    depth_stencil_attachment: bool = false,
    copy_src: bool = false,
    copy_dst: bool = false,
    transient: bool = false,
    _padding: u25 = 0,
};

/// Dimension de Texture.
pub const TextureDimension = enum(u8) {
    @"1d",
    @"2d",
    @"3d",
    cube,
};

/// Origine 3D pour les copies texture/buffer (WebGPU canonical).
pub const Origin3D = extern struct {
    x: u32 = 0,
    y: u32 = 0,
    z: u32 = 0,
};

/// Extent 3D pour les copies texture/buffer (WebGPU canonical). Le champ
/// `depth_or_array_layers` couvre les textures 3D (profondeur) comme les
/// 2D arrays (nombre de couches) selon la dimension de la texture cible.
pub const Extent3D = extern struct {
    width: u32,
    height: u32,
    depth_or_array_layers: u32 = 1,
};

/// Aspect d'une vue/copie de texture (color | depth | stencil | all).
/// Phase 0 : `color` suffit pour la capture PPM ; `depth` exposé pour le
/// depth prepass futur ; `stencil` non utilisé.
pub const TextureAspect = enum(u8) {
    all,
    color,
    depth,
    stencil,
};

/// Source d'une copie texture → buffer (WebGPU canonical).
pub const ImageCopyTexture = struct {
    texture: TextureHandle,
    mip_level: u32 = 0,
    origin: Origin3D = .{},
    aspect: TextureAspect = .color,
};

/// Destination d'une copie texture → buffer (WebGPU canonical).
/// `bytes_per_row` doit être aligné selon les contraintes du backend
/// (Vulkan : 256 bytes typique). `rows_per_image` ne s'applique qu'aux
/// textures 3D / arrays ; ignoré pour les 2D simples.
pub const ImageCopyBuffer = struct {
    buffer: BufferHandle,
    offset: u64 = 0,
    bytes_per_row: u32,
    rows_per_image: u32 = 0,
};

/// Submit a CommandEncoder to a queue. WebGPU-aligned shape extended
/// with the explicit Vulkan-style sync triple — Phase 1+ the wait/signal
/// pair may move behind an automatic frame manager and this descriptor
/// will collapse to the WebGPU `submit(commandBuffers)` form.
pub const SubmitDescriptor = struct {
    /// Semaphore to wait on before the GPU starts executing the
    /// submitted command buffer (typically the `image_ready` from
    /// `acquireNextImage`).
    wait_semaphore: ?SemaphoreHandle = null,
    /// Semaphore to signal when the GPU finishes the submitted command
    /// buffer (typically the `render_done` passed to `present`).
    signal_semaphore: ?SemaphoreHandle = null,
    /// Fence signaled when the GPU finishes; pair with `waitFence` to
    /// gate CPU-side work that depends on the GPU completing.
    fence: ?FenceHandle = null,
};

/// Type de bind dans un BindGroupLayout.
pub const BindingType = enum(u8) {
    uniform_buffer,
    storage_buffer,
    sampled_texture,
    storage_texture,
    sampler,
};

/// Type d'attachement de pass.
pub const LoadOp = enum(u8) {
    load,
    clear,
    dont_care,
};

/// Stratégie de sauvegarde d'attachement en fin de pass.
pub const StoreOp = enum(u8) {
    store,
    dont_care,
};

// ============================================================================
// Descripteurs (par valeur, POD, passés à `Device.create*`)
// ============================================================================

/// Descripteur de Buffer.
pub const BufferDescriptor = struct {
    label: ?[]const u8 = null,
    size: u64,
    usage: BufferUsage,
    /// Si true, le buffer est CPU-visible (host-mappable). Phase 0 limité à
    /// staging + uniform — la majorité des Buffers GPU restent device-local.
    host_visible: bool = false,
};

/// Descripteur de Texture.
pub const TextureDescriptor = struct {
    label: ?[]const u8 = null,
    dimension: TextureDimension = .@"2d",
    format: TextureFormat,
    width: u32,
    height: u32,
    depth_or_array_layers: u32 = 1,
    mip_levels: u32 = 1,
    /// Phase 0 : `sample_count` > 1 retourne `error.Unsupported`
    /// (cf. brief §Out-of-scope MSAA).
    sample_count: u32 = 1,
    usage: TextureUsage,
};

/// Descripteur de TextureView (sous-vue d'une Texture).
pub const TextureViewDescriptor = struct {
    label: ?[]const u8 = null,
    format: ?TextureFormat = null,
    dimension: ?TextureDimension = null,
    base_mip: u32 = 0,
    mip_count: u32 = 1,
    base_layer: u32 = 0,
    layer_count: u32 = 1,
};

/// Descripteur de Sampler.
pub const SamplerDescriptor = struct {
    label: ?[]const u8 = null,
    mag_filter: enum { nearest, linear } = .linear,
    min_filter: enum { nearest, linear } = .linear,
    mipmap_filter: enum { nearest, linear } = .linear,
    address_mode_u: enum { repeat, clamp, mirror } = .repeat,
    address_mode_v: enum { repeat, clamp, mirror } = .repeat,
    address_mode_w: enum { repeat, clamp, mirror } = .repeat,
    anisotropy: u8 = 1,
};

/// Descripteur d'entrée de BindGroupLayout.
pub const BindGroupLayoutEntry = struct {
    binding: u32,
    visibility: ShaderStage,
    binding_type: BindingType,
};

/// Descripteur de BindGroupLayout.
pub const BindGroupLayoutDescriptor = struct {
    label: ?[]const u8 = null,
    entries: []const BindGroupLayoutEntry,
};

/// Descripteur d'entrée de BindGroup.
pub const BindGroupEntry = struct {
    binding: u32,
    resource: union(enum) {
        buffer: struct { handle: BufferHandle, offset: u64 = 0, size: ?u64 = null },
        texture_view: TextureViewHandle,
        sampler: SamplerHandle,
    },
};

/// Descripteur de BindGroup.
pub const BindGroupDescriptor = struct {
    label: ?[]const u8 = null,
    layout: BindGroupLayoutHandle,
    entries: []const BindGroupEntry,
};

/// Descripteur de ShaderModule (SPIR-V uniquement Phase 0, cf. brief §Notes
/// décision 3 : pas de source HLSL/WGSL, pas de reflection runtime).
pub const ShaderModuleDescriptor = struct {
    label: ?[]const u8 = null,
    /// Bytes SPIR-V. Doit être aligné sur 4 octets.
    code: []const u8,
};

/// Layout d'un attribut de vertex.
pub const VertexAttribute = struct {
    location: u32,
    format: TextureFormat,
    offset: u32,
};

/// Layout d'un vertex buffer.
pub const VertexBufferLayout = struct {
    stride: u32,
    step_mode: enum { vertex, instance } = .vertex,
    attributes: []const VertexAttribute,
};

/// Descripteur de RenderPipeline (PSO graphics).
pub const RenderPipelineDescriptor = struct {
    label: ?[]const u8 = null,
    layout: []const BindGroupLayoutHandle = &.{},
    vertex_module: ShaderModuleHandle,
    vertex_entry_point: [:0]const u8 = "main",
    fragment_module: ?ShaderModuleHandle = null,
    fragment_entry_point: [:0]const u8 = "main",
    vertex_buffers: []const VertexBufferLayout = &.{},
    primitive_topology: PrimitiveTopology = .triangle_list,
    cull_mode: CullMode = .back,
    depth_format: ?TextureFormat = null,
    depth_test_enabled: bool = false,
    depth_write_enabled: bool = false,
    depth_compare: CompareOp = .less,
    color_targets: []const ColorTargetState = &.{},
    /// Phase 0 : > 1 retourne `error.Unsupported`.
    sample_count: u32 = 1,
};

/// État d'une cible color attachment (format + blend).
pub const ColorTargetState = struct {
    format: TextureFormat,
    blend: ?BlendState = null,
};

/// État de blending. Phase 0 : forward opaque uniquement (pas de blend),
/// préservé pour Phase 1 (transparents).
pub const BlendState = struct {
    color_op: enum { add, subtract, min, max } = .add,
    color_src: enum { zero, one, src_alpha, one_minus_src_alpha } = .one,
    color_dst: enum { zero, one, src_alpha, one_minus_src_alpha } = .zero,
    alpha_op: enum { add, subtract, min, max } = .add,
    alpha_src: enum { zero, one, src_alpha, one_minus_src_alpha } = .one,
    alpha_dst: enum { zero, one, src_alpha, one_minus_src_alpha } = .zero,
};

/// Descripteur de ComputePipeline.
pub const ComputePipelineDescriptor = struct {
    label: ?[]const u8 = null,
    layout: []const BindGroupLayoutHandle = &.{},
    module: ShaderModuleHandle,
    entry_point: [:0]const u8 = "main",
};

/// Descripteur de Swapchain.
pub const SwapchainDescriptor = struct {
    width: u32,
    height: u32,
    format: TextureFormat = .bgra8_unorm,
    present_mode: PresentMode = .fifo,
    /// Phase 0 : 2 (double-buffer) ou 3 (triple-buffer). Le backend choisit
    /// la valeur la plus proche supportée.
    min_image_count: u32 = 2,
};

// ============================================================================
// Attachements de render pass (passés à `CommandEncoder.beginRenderPass`)
// ============================================================================

/// Couleur de clear.
pub const ColorClear = extern struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 1,
};

/// Attachement color pour une render pass.
pub const ColorAttachment = struct {
    view: TextureViewHandle,
    /// Si présent, résoudre vers cette view en fin de pass (MSAA Phase 1+).
    resolve_view: ?TextureViewHandle = null,
    load_op: LoadOp = .clear,
    store_op: StoreOp = .store,
    clear_color: ColorClear = .{},
};

/// Attachement depth/stencil pour une render pass.
pub const DepthStencilAttachment = struct {
    view: TextureViewHandle,
    depth_load_op: LoadOp = .clear,
    depth_store_op: StoreOp = .store,
    depth_clear: f32 = 1.0,
    stencil_load_op: LoadOp = .dont_care,
    stencil_store_op: StoreOp = .dont_care,
    stencil_clear: u32 = 0,
};

/// Descripteur de render pass (commencée via `CommandEncoder.beginRenderPass`).
pub const RenderPassDescriptor = struct {
    label: ?[]const u8 = null,
    color_attachments: []const ColorAttachment = &.{},
    depth_stencil_attachment: ?DepthStencilAttachment = null,
};

/// Descripteur de compute pass.
pub const ComputePassDescriptor = struct {
    label: ?[]const u8 = null,
};

// ============================================================================
// Sélection de device (cohérent --gpu-prefer / --vulkan-driver, brief §Scope)
// ============================================================================

/// Préférence de sélection hardware. Préserve la sémantique S2.
pub const GpuPreference = union(enum) {
    auto,
    discrete,
    integrated,
    index: u32,
};

/// Sélecteur d'implémentation Vulkan (nouveau M0.4, cf. brief §Notes décision 11).
/// Orthogonal à `GpuPreference`.
pub const VulkanDriver = enum {
    /// Énumère tous les devices et applique `--gpu-prefer`.
    auto,
    /// Filtre les devices `CPU` avant d'appliquer `--gpu-prefer`.
    hardware,
    /// Force lavapipe ou équivalent, ignore `--gpu-prefer`.
    software,
};

/// Descripteur d'init de Device.
pub const DeviceDescriptor = struct {
    label: ?[]const u8 = null,
    gpu_preference: GpuPreference = .auto,
    vulkan_driver: VulkanDriver = .auto,
    /// Active les validation layers (Vulkan) ou équivalent côté autres backends.
    enable_validation: bool = false,
    /// Surface OS (handle window) à laquelle attacher le device. `null` =
    /// headless / offscreen (Null backend, CI runtime-smoke-test sans window).
    surface: ?SurfaceHandle = null,
};

/// Handle opaque de surface (créé depuis une `*platform.window.Window`
/// — la conversion vit côté backend, pas exposée ici).
pub const SurfaceHandle = extern struct {
    inner: u64 = 0,
    pub fn isValid(self: SurfaceHandle) bool {
        return self.inner != 0;
    }
};

// ============================================================================
// Erreurs unifiées
// ============================================================================

/// Set d'erreurs GAL. Chaque backend mappe ses codes natifs vers ce set
/// (cf. `gal/vulkan/conv.zig`). Les call sites consomment cet error set
/// uniformément.
pub const Error = error{
    OutOfMemory,
    DeviceLost,
    SurfaceLost,
    InvalidArgument,
    Unsupported,
    NotInitialized,
    SwapchainOutOfDate,
    ShaderCompilationFailed,
    PipelineCreationFailed,
    AcquireImageFailed,
    PresentFailed,
    BackendInternal,
};

test "types: handles default to invalid" {
    const t = std.testing;
    try t.expect(!(BufferHandle{}).isValid());
    try t.expect(!(TextureHandle{}).isValid());
    try t.expect(!(SamplerHandle{}).isValid());
    try t.expect(!(BindGroupHandle{}).isValid());
    try t.expect(!(RenderPipelineHandle{}).isValid());
    try t.expect(!(FenceHandle{}).isValid());
    try t.expect(!(SemaphoreHandle{}).isValid());
    try t.expect(!(SwapchainHandle{}).isValid());
}

test "types: handles with inner != 0 are valid" {
    const t = std.testing;
    try t.expect((BufferHandle{ .inner = 42 }).isValid());
    try t.expect((TextureHandle{ .inner = 1 }).isValid());
}

test "types: ShaderStage masks compose" {
    const t = std.testing;
    const all = ShaderStage.all;
    try t.expect(all.vertex);
    try t.expect(all.fragment);
    try t.expect(all.compute);

    const gfx = ShaderStage.all_graphics;
    try t.expect(gfx.vertex);
    try t.expect(gfx.fragment);
    try t.expect(!gfx.compute);
}

test "types: BufferUsage / TextureUsage POD layout" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 4), @sizeOf(BufferUsage));
    try t.expectEqual(@as(usize, 4), @sizeOf(TextureUsage));
}
