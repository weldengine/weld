//! FROZEN — see engine-phase-0-criteria.md C0.5 (M0.9)
//!
//! GAL public types — Phase 0 / M0.4.
//!
//! Public surface of the GPU Abstraction Layer (cf. `engine-render.md` §3).
//! Inspired by WebGPU / Mach sysgpu, adapted for Weld (right-handed Y-up,
//! escape hatches pre-wired day 1 for `TimelineSemaphore`, `BarrierExplicit`,
//! `DescriptorIndexing`).
//!
//! **Absolute isolation rule (brief §Notes known pitfalls)**: no native
//! Vulkan type (`vk.VkBuffer`, etc.) must appear here. The GAL types are
//! opaque on the caller side — each backend maps to its native types via
//! its own `conv.zig` (cf. `gal/vulkan/conv.zig`).
//!
//! The GPU handles are `extern struct` structs with a single `inner: u64`
//! field to guarantee a stable cross-backend layout and to ease future
//! serialization (cooked asset pipeline).

const std = @import("std");

// ============================================================================
// Identities & opaque handles
// ============================================================================

/// Opaque Device handle. Each backend stores its state in its own concrete
/// type (`gal/vulkan/device.zig:Device`, `gal/null/device.zig:Device`).
/// The caller only sees an opaque pointer; the methods live on the backend's
/// concrete type, resolved at comptime via `gal.main.Device`.
pub const DeviceHandle = *opaque {};

/// Opaque Queue handle (graphics, compute, transfer). Issued by `Device.getQueue`.
pub const QueueHandle = *opaque {};

/// Opaque GPU Buffer handle.
pub const BufferHandle = extern struct {
    inner: u64 = 0,
    pub fn isValid(self: BufferHandle) bool {
        return self.inner != 0;
    }
};

/// Opaque GPU Texture handle.
pub const TextureHandle = extern struct {
    inner: u64 = 0,
    pub fn isValid(self: TextureHandle) bool {
        return self.inner != 0;
    }
};

/// Opaque TextureView handle (view over a Texture + format + mip/array range).
pub const TextureViewHandle = extern struct {
    inner: u64 = 0,
    pub fn isValid(self: TextureViewHandle) bool {
        return self.inner != 0;
    }
};

/// Opaque Sampler handle (filtering, wrapping, anisotropy).
pub const SamplerHandle = extern struct {
    inner: u64 = 0,
    pub fn isValid(self: SamplerHandle) bool {
        return self.inner != 0;
    }
};

/// Opaque ShaderModule handle (SPIR-V loaded on the device).
pub const ShaderModuleHandle = extern struct {
    inner: u64 = 0,
    pub fn isValid(self: ShaderModuleHandle) bool {
        return self.inner != 0;
    }
};

/// Opaque BindGroupLayout handle.
pub const BindGroupLayoutHandle = extern struct {
    inner: u64 = 0,
    pub fn isValid(self: BindGroupLayoutHandle) bool {
        return self.inner != 0;
    }
};

/// Opaque BindGroup handle (bound descriptor set).
pub const BindGroupHandle = extern struct {
    inner: u64 = 0,
    pub fn isValid(self: BindGroupHandle) bool {
        return self.inner != 0;
    }
};

/// Opaque RenderPipeline handle (graphics PSO).
pub const RenderPipelineHandle = extern struct {
    inner: u64 = 0,
    pub fn isValid(self: RenderPipelineHandle) bool {
        return self.inner != 0;
    }
};

/// Opaque ComputePipeline handle (compute PSO).
pub const ComputePipelineHandle = extern struct {
    inner: u64 = 0,
    pub fn isValid(self: ComputePipelineHandle) bool {
        return self.inner != 0;
    }
};

/// Opaque Fence handle (CPU↔GPU sync).
pub const FenceHandle = extern struct {
    inner: u64 = 0,
    pub fn isValid(self: FenceHandle) bool {
        return self.inner != 0;
    }
};

/// Opaque binary Semaphore handle (GPU↔GPU sync).
/// For timeline semaphores, see `escape_hatches.TimelineSemaphoreHandle`.
pub const SemaphoreHandle = extern struct {
    inner: u64 = 0,
    pub fn isValid(self: SemaphoreHandle) bool {
        return self.inner != 0;
    }
};

/// Opaque Swapchain handle (chain of presentable framebuffers).
pub const SwapchainHandle = extern struct {
    inner: u64 = 0,
    pub fn isValid(self: SwapchainHandle) bool {
        return self.inner != 0;
    }
};

// ============================================================================
// Formats & enums
// ============================================================================

/// Phase 0 formats (cf. brief §Scope GAL — limited formats). Phase 1+
/// extends the list (BC compressed, ASTC, BC7, etc.).
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
    rgb32_sfloat,
    rgba32_sfloat,
};

/// Queue type. Phase 0: Vulkan typically exposes a single graphics+present
/// queue on the target GPUs. Dedicated compute + transfer are query-able
/// but not required.
pub const QueueType = enum(u8) {
    graphics,
    compute,
    transfer,
};

/// Swapchain present mode. Phase 0: `fifo` (vsync) guaranteed, others
/// best-effort (negotiated at swapchain init).
pub const PresentMode = enum(u8) {
    fifo,
    fifo_relaxed,
    immediate,
    mailbox,
};

/// Primitive topology (triangle list by default in Phase 0).
pub const PrimitiveTopology = enum(u8) {
    point_list,
    line_list,
    line_strip,
    triangle_list,
    triangle_strip,
};

/// Face culling. Right-handed Y-up + counter-clockwise winding = the
/// Weld convention (consistent with glTF). Phase 0: `back` by default.
pub const CullMode = enum(u8) {
    none,
    front,
    back,
};

/// Depth/stencil comparison.
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

/// Shader stage (used for bind groups and visibility masks).
pub const ShaderStage = packed struct(u32) {
    vertex: bool = false,
    fragment: bool = false,
    compute: bool = false,
    _padding: u29 = 0,

    pub const all_graphics: ShaderStage = .{ .vertex = true, .fragment = true };
    pub const all: ShaderStage = .{ .vertex = true, .fragment = true, .compute = true };
};

/// Usage flags for Buffer.
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

/// Usage flags for Texture.
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

/// Texture dimension.
pub const TextureDimension = enum(u8) {
    @"1d",
    @"2d",
    @"3d",
    cube,
};

/// 3D origin for texture/buffer copies (WebGPU canonical).
pub const Origin3D = extern struct {
    x: u32 = 0,
    y: u32 = 0,
    z: u32 = 0,
};

/// 3D extent for texture/buffer copies (WebGPU canonical). The
/// `depth_or_array_layers` field covers 3D textures (depth) as well as
/// 2D arrays (layer count) depending on the target texture's dimension.
pub const Extent3D = extern struct {
    width: u32,
    height: u32,
    depth_or_array_layers: u32 = 1,
};

/// Aspect of a texture view/copy (color | depth | stencil | all).
/// Phase 0: `color` suffices for the PPM capture; `depth` exposed for the
/// future depth prepass; `stencil` unused.
pub const TextureAspect = enum(u8) {
    all,
    color,
    depth,
    stencil,
};

/// The texture endpoint of an image↔buffer copy (WebGPU canonical).
/// It is the SOURCE in `copyTextureToBuffer` and the DESTINATION in
/// `copyBufferToTexture` (the E4 reverse direction).
pub const ImageCopyTexture = struct {
    texture: TextureHandle,
    mip_level: u32 = 0,
    origin: Origin3D = .{},
    aspect: TextureAspect = .color,
};

/// The buffer endpoint of an image↔buffer copy (WebGPU canonical).
/// It is the DESTINATION in `copyTextureToBuffer` and the SOURCE in
/// `copyBufferToTexture` (the E4 reverse direction).
/// `bytes_per_row` must be aligned per the backend's constraints
/// (Vulkan: 256 bytes typical). `rows_per_image` only applies to
/// 3D / array textures; ignored for simple 2D ones.
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

/// Binding type in a BindGroupLayout.
pub const BindingType = enum(u8) {
    uniform_buffer,
    storage_buffer,
    sampled_texture,
    storage_texture,
    sampler,
};

/// Pass attachment load type.
pub const LoadOp = enum(u8) {
    load,
    clear,
    dont_care,
};

/// Attachment store strategy at end of pass.
pub const StoreOp = enum(u8) {
    store,
    dont_care,
};

// ============================================================================
// Descriptors (by value, POD, passed to `Device.create*`)
// ============================================================================

/// Buffer descriptor.
pub const BufferDescriptor = struct {
    label: ?[]const u8 = null,
    size: u64,
    usage: BufferUsage,
    /// If true, the buffer is CPU-visible (host-mappable). Phase 0 limited to
    /// staging + uniform — most GPU Buffers stay device-local.
    host_visible: bool = false,
};

/// Texture descriptor.
pub const TextureDescriptor = struct {
    label: ?[]const u8 = null,
    dimension: TextureDimension = .@"2d",
    format: TextureFormat,
    width: u32,
    height: u32,
    depth_or_array_layers: u32 = 1,
    mip_levels: u32 = 1,
    /// Phase 0: `sample_count` > 1 returns `error.Unsupported`
    /// (cf. brief §Out-of-scope MSAA).
    sample_count: u32 = 1,
    usage: TextureUsage,
};

/// TextureView descriptor (sub-view of a Texture).
pub const TextureViewDescriptor = struct {
    label: ?[]const u8 = null,
    format: ?TextureFormat = null,
    dimension: ?TextureDimension = null,
    base_mip: u32 = 0,
    mip_count: u32 = 1,
    base_layer: u32 = 0,
    layer_count: u32 = 1,
};

/// Sampler descriptor.
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

/// BindGroupLayout entry descriptor.
pub const BindGroupLayoutEntry = struct {
    binding: u32,
    visibility: ShaderStage,
    binding_type: BindingType,
};

/// BindGroupLayout descriptor.
pub const BindGroupLayoutDescriptor = struct {
    label: ?[]const u8 = null,
    entries: []const BindGroupLayoutEntry,
};

/// BindGroup entry descriptor.
pub const BindGroupEntry = struct {
    binding: u32,
    resource: union(enum) {
        buffer: struct { handle: BufferHandle, offset: u64 = 0, size: ?u64 = null },
        texture_view: TextureViewHandle,
        sampler: SamplerHandle,
    },
};

/// BindGroup descriptor.
pub const BindGroupDescriptor = struct {
    label: ?[]const u8 = null,
    layout: BindGroupLayoutHandle,
    entries: []const BindGroupEntry,
};

/// ShaderModule descriptor (SPIR-V only in Phase 0, cf. brief §Notes
/// decision 3: no HLSL/WGSL source, no runtime reflection).
pub const ShaderModuleDescriptor = struct {
    label: ?[]const u8 = null,
    /// SPIR-V bytes. Must be aligned to 4 bytes.
    code: []const u8,
};

/// Layout of a vertex attribute.
pub const VertexAttribute = struct {
    location: u32,
    format: TextureFormat,
    offset: u32,
};

/// Layout of a vertex buffer.
pub const VertexBufferLayout = struct {
    stride: u32,
    step_mode: enum { vertex, instance } = .vertex,
    attributes: []const VertexAttribute,
};

/// RenderPipeline descriptor (graphics PSO).
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
    /// Phase 0: > 1 returns `error.Unsupported`.
    sample_count: u32 = 1,
};

/// State of a color attachment target (format + blend).
pub const ColorTargetState = struct {
    format: TextureFormat,
    blend: ?BlendState = null,
};

/// Blending state. Phase 0: opaque forward only (no blend), preserved
/// for Phase 1 (transparents).
pub const BlendState = struct {
    color_op: enum { add, subtract, min, max } = .add,
    color_src: enum { zero, one, src_alpha, one_minus_src_alpha } = .one,
    color_dst: enum { zero, one, src_alpha, one_minus_src_alpha } = .zero,
    alpha_op: enum { add, subtract, min, max } = .add,
    alpha_src: enum { zero, one, src_alpha, one_minus_src_alpha } = .one,
    alpha_dst: enum { zero, one, src_alpha, one_minus_src_alpha } = .zero,
};

/// ComputePipeline descriptor.
pub const ComputePipelineDescriptor = struct {
    label: ?[]const u8 = null,
    layout: []const BindGroupLayoutHandle = &.{},
    module: ShaderModuleHandle,
    entry_point: [:0]const u8 = "main",
};

/// Swapchain descriptor.
pub const SwapchainDescriptor = struct {
    width: u32,
    height: u32,
    format: TextureFormat = .bgra8_unorm,
    present_mode: PresentMode = .fifo,
    /// Phase 0: 2 (double-buffer) or 3 (triple-buffer). The backend picks
    /// the closest supported value.
    min_image_count: u32 = 2,
};

// ============================================================================
// Render pass attachments (passed to `CommandEncoder.beginRenderPass`)
// ============================================================================

/// Clear color.
pub const ColorClear = extern struct {
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 1,
};

/// Final layout expected for an attachment at the end of the render pass.
/// The backend transitions the image to this layout automatically (as an
/// implicit barrier at the end of the subpass). The caller chooses based on
/// the downstream usage: `.present` for a swapchain image to present,
/// `.transfer_src` for a texture about to be copied to a buffer (PPM
/// capture, blit), `.shader_read` for a texture read by a shader (input
/// of a following pass), `.color_attachment` to stay rebindable as a
/// color attachment of a downstream pass.
pub const AttachmentFinalLayout = enum(u8) {
    present,
    transfer_src,
    shader_read,
    color_attachment,
};

/// Color attachment for a render pass.
pub const ColorAttachment = struct {
    view: TextureViewHandle,
    /// If present, resolve to this view at end of pass (MSAA Phase 1+).
    resolve_view: ?TextureViewHandle = null,
    load_op: LoadOp = .clear,
    store_op: StoreOp = .store,
    clear_color: ColorClear = .{},
    final_layout: AttachmentFinalLayout = .present,
};

/// Depth/stencil attachment for a render pass.
pub const DepthStencilAttachment = struct {
    view: TextureViewHandle,
    depth_load_op: LoadOp = .clear,
    depth_store_op: StoreOp = .store,
    depth_clear: f32 = 1.0,
    stencil_load_op: LoadOp = .dont_care,
    stencil_store_op: StoreOp = .dont_care,
    stencil_clear: u32 = 0,
};

/// Render pass descriptor (begun via `CommandEncoder.beginRenderPass`).
pub const RenderPassDescriptor = struct {
    label: ?[]const u8 = null,
    color_attachments: []const ColorAttachment = &.{},
    depth_stencil_attachment: ?DepthStencilAttachment = null,
};

/// Compute pass descriptor.
pub const ComputePassDescriptor = struct {
    label: ?[]const u8 = null,
};

// ============================================================================
// Device selection (consistent with --gpu-prefer / --vulkan-driver, brief §Scope)
// ============================================================================

/// Hardware selection preference. Preserves the S2 semantics.
pub const GpuPreference = union(enum) {
    auto,
    discrete,
    integrated,
    index: u32,
};

/// Vulkan implementation selector (new in M0.4, cf. brief §Notes decision 11).
/// Orthogonal to `GpuPreference`.
pub const VulkanDriver = enum {
    /// Enumerates all devices and applies `--gpu-prefer`.
    auto,
    /// Filters out `CPU` devices before applying `--gpu-prefer`.
    hardware,
    /// Forces lavapipe or equivalent, ignores `--gpu-prefer`.
    software,
};

/// Device init descriptor.
pub const DeviceDescriptor = struct {
    label: ?[]const u8 = null,
    gpu_preference: GpuPreference = .auto,
    vulkan_driver: VulkanDriver = .auto,
    /// Enables validation layers (Vulkan) or the equivalent on other backends.
    enable_validation: bool = false,
    /// OS surface (window handle) to attach the device to. `null` =
    /// headless / offscreen (Null backend, CI runtime-smoke-test without a window).
    surface: ?SurfaceHandle = null,
};

/// Opaque surface handle (created from a `*platform.window.Window`
/// — the conversion lives on the backend side, not exposed here).
pub const SurfaceHandle = extern struct {
    inner: u64 = 0,
    pub fn isValid(self: SurfaceHandle) bool {
        return self.inner != 0;
    }
};

// ============================================================================
// Unified errors
// ============================================================================

/// GAL error set. Each backend maps its native codes to this set
/// (cf. `gal/vulkan/conv.zig`). The call sites consume this error set
/// uniformly.
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
