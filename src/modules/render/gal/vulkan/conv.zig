//! Conversions GAL → Vulkan natif — Phase 0 / M0.4.
//!
//! Pattern sysgpu (`engine-mach-reference.md` §2) : un fichier dédié par
//! backend qui traduit les types publics GAL (`gal/types.zig`,
//! `gal/escape_hatches.zig`) vers les types Vulkan natifs du binding
//! `weld_core.platform.vk`.
//!
//! Aucun call site GAL ne référence directement un type `vk.*` —
//! tout passe par les helpers de ce fichier. Cette discipline est
//! enforcée par la règle linter brief §CI : pas d'accès `vk.device_dispatch`
//! hors du module `gal/vulkan/`.

const std = @import("std");
const weld_core = @import("weld_core");
const vk = weld_core.platform.vk;
const types = @import("../types.zig");
const escape = @import("../escape_hatches.zig");

/// Map GAL `TextureFormat` → Vulkan `Format`.
pub fn textureFormat(fmt: types.TextureFormat) vk.Format {
    return switch (fmt) {
        .undef => .undefined,
        .r8_unorm => .r8_unorm,
        .rg8_unorm => .r8g8_unorm,
        .rgba8_unorm => .r8g8b8a8_unorm,
        .rgba8_srgb => .r8g8b8a8_srgb,
        .bgra8_unorm => .b8g8r8a8_unorm,
        .bgra8_srgb => .b8g8r8a8_srgb,
        .d32_sfloat => .d32_sfloat,
        .d24_unorm_s8_uint => .d24_unorm_s8_uint,
        .r16_sfloat => .r16_sfloat,
        .rg16_sfloat => .r16g16_sfloat,
        .rgba16_sfloat => .r16g16b16a16_sfloat,
        .r32_sfloat => .r32_sfloat,
        .rg32_sfloat => .r32g32_sfloat,
        .rgba32_sfloat => .r32g32b32a32_sfloat,
    };
}

/// Map Vulkan `Format` → GAL `TextureFormat` (best-effort, retourne `.undef`
/// pour les formats non couverts par la sous-liste Phase 0).
pub fn textureFormatFromVk(fmt: vk.Format) types.TextureFormat {
    return switch (fmt) {
        .r8_unorm => .r8_unorm,
        .r8g8_unorm => .rg8_unorm,
        .r8g8b8a8_unorm => .rgba8_unorm,
        .r8g8b8a8_srgb => .rgba8_srgb,
        .b8g8r8a8_unorm => .bgra8_unorm,
        .b8g8r8a8_srgb => .bgra8_srgb,
        .d32_sfloat => .d32_sfloat,
        .d24_unorm_s8_uint => .d24_unorm_s8_uint,
        .r16_sfloat => .r16_sfloat,
        .r16g16_sfloat => .rg16_sfloat,
        .r16g16b16a16_sfloat => .rgba16_sfloat,
        .r32_sfloat => .r32_sfloat,
        .r32g32_sfloat => .rg32_sfloat,
        .r32g32b32a32_sfloat => .rgba32_sfloat,
        else => .undef,
    };
}

/// Map GAL `PresentMode` → Vulkan `PresentModeKHR`.
pub fn presentMode(mode: types.PresentMode) vk.PresentModeKHR {
    return switch (mode) {
        .fifo => .fifo,
        .fifo_relaxed => .fifo_relaxed,
        .immediate => .immediate,
        .mailbox => .mailbox,
    };
}

/// Map GAL `PrimitiveTopology` → Vulkan `PrimitiveTopology`.
pub fn primitiveTopology(topo: types.PrimitiveTopology) vk.PrimitiveTopology {
    return switch (topo) {
        .point_list => .point_list,
        .line_list => .line_list,
        .line_strip => .line_strip,
        .triangle_list => .triangle_list,
        .triangle_strip => .triangle_strip,
    };
}

/// Map GAL `CullMode` → Vulkan `CullModeFlags`.
pub fn cullMode(mode: types.CullMode) vk.CullModeFlags {
    return switch (mode) {
        .none => .empty,
        .front => .{ .front = true },
        .back => .{ .back = true },
    };
}

/// Map GAL `CompareOp` → Vulkan `CompareOp`.
pub fn compareOp(op: types.CompareOp) vk.CompareOp {
    return switch (op) {
        .never => .never,
        .less => .less,
        .equal => .equal,
        .less_or_equal => .less_or_equal,
        .greater => .greater,
        .not_equal => .not_equal,
        .greater_or_equal => .greater_or_equal,
        .always => .always,
    };
}

/// Map GAL `ShaderStage` → Vulkan `ShaderStageFlags`.
pub fn shaderStageFlags(stage: types.ShaderStage) vk.ShaderStageFlags {
    var out: vk.ShaderStageFlags = .empty;
    if (stage.vertex) out.vertex = true;
    if (stage.fragment) out.fragment = true;
    if (stage.compute) out.compute = true;
    return out;
}

/// Map GAL `BufferUsage` → Vulkan `BufferUsageFlags`.
pub fn bufferUsage(u: types.BufferUsage) vk.BufferUsageFlags {
    var out: vk.BufferUsageFlags = .empty;
    if (u.vertex) out.vertex_buffer = true;
    if (u.index) out.index_buffer = true;
    if (u.uniform) out.uniform_buffer = true;
    if (u.storage) out.storage_buffer = true;
    if (u.indirect) out.indirect_buffer = true;
    if (u.copy_src) out.transfer_src = true;
    if (u.copy_dst) out.transfer_dst = true;
    return out;
}

/// Map GAL `TextureUsage` → Vulkan `ImageUsageFlags`.
pub fn imageUsage(u: types.TextureUsage) vk.ImageUsageFlags {
    var out: vk.ImageUsageFlags = .empty;
    if (u.sampled) out.sampled = true;
    if (u.storage) out.storage = true;
    if (u.color_attachment) out.color_attachment = true;
    if (u.depth_stencil_attachment) out.depth_stencil_attachment = true;
    if (u.copy_src) out.transfer_src = true;
    if (u.copy_dst) out.transfer_dst = true;
    if (u.transient) out.transient_attachment = true;
    return out;
}

/// Map GAL `TextureDimension` → Vulkan `ImageType`.
pub fn imageType(dim: types.TextureDimension) vk.ImageType {
    return switch (dim) {
        .@"1d" => ._1d,
        .@"2d", .cube => ._2d,
        .@"3d" => ._3d,
    };
}

/// Map GAL `TextureDimension` → Vulkan `ImageViewType`.
pub fn imageViewType(dim: types.TextureDimension) vk.ImageViewType {
    return switch (dim) {
        .@"1d" => ._1d,
        .@"2d" => ._2d,
        .@"3d" => ._3d,
        .cube => .cube,
    };
}

/// Choisit l'aspect mask Vulkan en fonction du format (color vs depth/stencil).
pub fn imageAspect(fmt: types.TextureFormat) vk.ImageAspectFlags {
    return switch (fmt) {
        .d32_sfloat => .{ .depth = true },
        .d24_unorm_s8_uint => .{ .depth = true, .stencil = true },
        else => .{ .color = true },
    };
}

/// Map GAL `LoadOp` → Vulkan `AttachmentLoadOp`.
pub fn loadOp(op: types.LoadOp) vk.AttachmentLoadOp {
    return switch (op) {
        .load => .load,
        .clear => .clear,
        .dont_care => .dont_care,
    };
}

/// Map GAL `StoreOp` → Vulkan `AttachmentStoreOp`.
pub fn storeOp(op: types.StoreOp) vk.AttachmentStoreOp {
    return switch (op) {
        .store => .store,
        .dont_care => .dont_care,
    };
}

/// Map GAL `BindingType` → Vulkan `DescriptorType`.
pub fn descriptorType(t: types.BindingType) vk.DescriptorType {
    return switch (t) {
        .uniform_buffer => .uniform_buffer,
        .storage_buffer => .storage_buffer,
        .sampled_texture => .sampled_image,
        .storage_texture => .storage_image,
        .sampler => .sampler,
    };
}

/// Map GAL `TextureLayout` (escape hatches) → Vulkan `ImageLayout`.
pub fn imageLayout(layout: escape.TextureLayout) vk.ImageLayout {
    return switch (layout) {
        .undefined => .undefined,
        .general => .general,
        .color_attachment => .color_attachment_optimal,
        .depth_stencil_attachment => .depth_stencil_attachment_optimal,
        .shader_read_only => .shader_read_only_optimal,
        .transfer_src => .transfer_src_optimal,
        .transfer_dst => .transfer_dst_optimal,
        .present_src => .present_src_khr,
    };
}

/// Map Vulkan `Result` → GAL `Error`. Les codes hors set retournent
/// `error.BackendInternal`.
pub fn errorFromResult(r: vk.Result) types.Error {
    return switch (r) {
        .error_out_of_host_memory, .error_out_of_device_memory => error.OutOfMemory,
        .error_device_lost => error.DeviceLost,
        .error_surface_lost_khr => error.SurfaceLost,
        .error_out_of_date_khr => error.SwapchainOutOfDate,
        .error_initialization_failed => error.NotInitialized,
        .error_extension_not_present, .error_feature_not_present => error.Unsupported,
        else => error.BackendInternal,
    };
}

/// Pratique : wrap `vk.checkResult` en retournant un `types.Error` au lieu
/// du `vk.Error` natif. Les call sites GAL utilisent uniquement `types.Error`.
pub fn checkResult(r: vk.Result) types.Error!void {
    if (r == .success) return;
    return errorFromResult(r);
}

test "conv: textureFormat round-trip on Phase 0 formats" {
    const t = std.testing;
    inline for ([_]types.TextureFormat{
        .r8_unorm,    .rg8_unorm,     .rgba8_unorm,   .rgba8_srgb,
        .bgra8_unorm, .bgra8_srgb,    .d32_sfloat,    .d24_unorm_s8_uint,
        .r16_sfloat,  .rg16_sfloat,   .rgba16_sfloat, .r32_sfloat,
        .rg32_sfloat, .rgba32_sfloat,
    }) |fmt| {
        const native = textureFormat(fmt);
        const back = textureFormatFromVk(native);
        try t.expectEqual(fmt, back);
    }
}

test "conv: cullMode none → empty bitset" {
    const t = std.testing;
    const m = cullMode(.none);
    try t.expect(!m.front);
    try t.expect(!m.back);
}

test "conv: imageAspect depth format yields depth bit" {
    const t = std.testing;
    const a = imageAspect(.d32_sfloat);
    try t.expect(a.depth);
    try t.expect(!a.color);
}

test "conv: errorFromResult maps OOM" {
    const t = std.testing;
    try t.expectError(error.OutOfMemory, checkResult(.error_out_of_host_memory));
    try t.expectError(error.OutOfMemory, checkResult(.error_out_of_device_memory));
    try t.expectError(error.SwapchainOutOfDate, checkResult(.error_out_of_date_khr));
    try checkResult(.success); // pas d'erreur
}
