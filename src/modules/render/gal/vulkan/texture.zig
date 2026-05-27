//! Texture + TextureView Vulkan — Phase 0 / M0.4.
//!
//! Comme pour Buffer, on bundle Image + DeviceMemory dans un `TextureEntry`.
//! Les TextureViews ont leur propre registry parce qu'on doit pouvoir les
//! détruire sans toucher la texture parente, et inversement on doit gérer
//! la cascade (détruire toutes les views d'une texture quand elle disparaît).
//!
//! Formats Phase 0 limités (cf. brief §Scope) : R8G8B8A8_UNORM, B8G8R8A8_UNORM
//! (swapchain), D32_SFLOAT. `sample_count > 1` retourne `Unsupported`.

const std = @import("std");
const weld_core = @import("weld_core");
const vk = weld_core.platform.vk;
const types = @import("../types.zig");
const conv = @import("conv.zig");
const Device = @import("device.zig").Device;

/// Slot interne d'une Texture — bundle `vk.Image` + `vk.DeviceMemory` +
/// métadonnées descripteur. Indexé par u64 monotone dans `device.textures`.
pub const TextureEntry = struct {
    vk_image: vk.Image,
    vk_memory: vk.DeviceMemory,
    format: types.TextureFormat,
    width: u32,
    height: u32,
    depth_or_array_layers: u32,
    mip_levels: u32,
    dimension: types.TextureDimension,
    /// `true` si l'image est gérée par la swapchain Vulkan (pas allouée
    /// par nous) — on n'appelle alors ni `destroyImage` ni `freeMemory`.
    swapchain_owned: bool = false,

    pub fn destroy(self: *TextureEntry, device: *vk.Device) void {
        if (!self.swapchain_owned) {
            if (self.vk_image != .null) device.destroyImage(self.vk_image, null);
            if (self.vk_memory != .null) device.freeMemory(self.vk_memory, null);
        }
        self.* = undefined;
    }
};

/// Slot interne d'une TextureView — wrap `vk.ImageView`. Indexé séparément
/// de `TextureEntry` parce qu'une view a son propre lifecycle.
/// Si `swapchain_owned = true`, le destroy du registry skip le
/// `destroyImageView` natif : la swapchain Vulkan détient la view et la
/// libère elle-même dans `swap.Entry.destroy`.
pub const ViewEntry = struct {
    vk_view: vk.ImageView,
    swapchain_owned: bool = false,

    pub fn destroy(self: *ViewEntry, device: *vk.Device) void {
        if (!self.swapchain_owned and self.vk_view != .null) {
            device.destroyImageView(self.vk_view, null);
        }
        self.* = undefined;
    }
};

/// Alloue une `vk.Image` + DeviceMemory device-local, enregistre dans
/// le registry. Phase 0 : `sample_count > 1` → `error.Unsupported`.
pub fn createTexture(device: *Device, descriptor: types.TextureDescriptor) types.Error!types.TextureHandle {
    if (descriptor.width == 0 or descriptor.height == 0) return error.InvalidArgument;
    if (descriptor.sample_count > 1) return error.Unsupported;

    const ci: vk.ImageCreateInfo = .{
        .flags = .empty,
        .image_type = conv.imageType(descriptor.dimension),
        .format = conv.textureFormat(descriptor.format),
        .extent = .{
            .width = descriptor.width,
            .height = descriptor.height,
            .depth = if (descriptor.dimension == .@"3d") descriptor.depth_or_array_layers else 1,
        },
        .mip_levels = descriptor.mip_levels,
        .array_layers = if (descriptor.dimension == .@"3d") 1 else descriptor.depth_or_array_layers,
        .samples = ._1_bit,
        .tiling = .optimal,
        .usage = conv.imageUsage(descriptor.usage),
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
        .initial_layout = .undefined,
    };
    const img = device.vk_device.createImage(&ci, null) catch return error.BackendInternal;
    errdefer device.vk_device.destroyImage(img, null);

    const reqs = device.vk_device.getImageMemoryRequirements(img);
    const mem_props = device.physical_device.getPhysicalDeviceMemoryProperties();
    const want: vk.MemoryPropertyFlags = .{ .device_local = true };
    const type_index = pickMemoryType(mem_props, reqs.memory_type_bits, want) orelse return error.Unsupported;

    const ai: vk.MemoryAllocateInfo = .{
        .allocation_size = reqs.size,
        .memory_type_index = type_index,
    };
    const mem = device.vk_device.allocateMemory(&ai, null) catch return error.OutOfMemory;
    errdefer device.vk_device.freeMemory(mem, null);

    device.vk_device.bindImageMemory(img, mem, 0) catch return error.BackendInternal;

    const id = device.nextHandle();
    try device.textures.put(device.allocator, id, .{
        .vk_image = img,
        .vk_memory = mem,
        .format = descriptor.format,
        .width = descriptor.width,
        .height = descriptor.height,
        .depth_or_array_layers = descriptor.depth_or_array_layers,
        .mip_levels = descriptor.mip_levels,
        .dimension = descriptor.dimension,
    });
    return .{ .inner = id };
}

/// Libère une Texture + sa memory. No-op si handle invalide ou
/// `swapchain_owned` (la swapchain gère elle-même la libération).
pub fn destroyTexture(device: *Device, handle: types.TextureHandle) void {
    if (handle.inner == 0) return;
    if (device.textures.fetchRemove(handle.inner)) |kv| {
        var entry = kv.value;
        entry.destroy(device.vk_device);
    }
}

/// Crée une `vk.ImageView` sur la texture parente. Format hérité si
/// non spécifié, dimension idem.
pub fn createView(
    device: *Device,
    parent: types.TextureHandle,
    descriptor: types.TextureViewDescriptor,
) types.Error!types.TextureViewHandle {
    if (parent.inner == 0) return error.InvalidArgument;
    const tex = device.textures.get(parent.inner) orelse return error.InvalidArgument;

    const format = if (descriptor.format) |f| f else tex.format;
    const dim = if (descriptor.dimension) |d| d else tex.dimension;
    const ci: vk.ImageViewCreateInfo = .{
        .flags = .empty,
        .image = tex.vk_image,
        .view_type = conv.imageViewType(dim),
        .format = conv.textureFormat(format),
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = .{
            .aspect_mask = conv.imageAspect(format),
            .base_mip_level = descriptor.base_mip,
            .level_count = descriptor.mip_count,
            .base_array_layer = descriptor.base_layer,
            .layer_count = descriptor.layer_count,
        },
    };
    const view = device.vk_device.createImageView(&ci, null) catch return error.BackendInternal;
    const id = device.nextHandle();
    try device.texture_views.put(device.allocator, id, .{ .vk_view = view });
    return .{ .inner = id };
}

/// Libère une `vk.ImageView`. No-op si handle invalide.
pub fn destroyView(device: *Device, handle: types.TextureViewHandle) void {
    if (handle.inner == 0) return;
    if (device.texture_views.fetchRemove(handle.inner)) |kv| {
        var entry = kv.value;
        entry.destroy(device.vk_device);
    }
}

/// Enregistre une `vk.ImageView` swapchain-owned dans le registry et
/// retourne le `TextureViewHandle` GAL stable. La view est détruite par
/// `swap.Entry.destroy` (le registry skip via `swapchain_owned`).
pub fn adoptSwapchainView(
    device: *Device,
    view: vk.ImageView,
) types.Error!types.TextureViewHandle {
    const id = device.nextHandle();
    try device.texture_views.put(device.allocator, id, .{
        .vk_view = view,
        .swapchain_owned = true,
    });
    return .{ .inner = id };
}

/// Helper interne — pour swapchain.zig qui adopte les `vk.Image` issues
/// de `getSwapchainImagesKHR` (gestion mémoire déléguée à la swapchain).
pub fn adoptSwapchainImage(
    device: *Device,
    img: vk.Image,
    format: types.TextureFormat,
    width: u32,
    height: u32,
) types.Error!types.TextureHandle {
    const id = device.nextHandle();
    try device.textures.put(device.allocator, id, .{
        .vk_image = img,
        .vk_memory = .null,
        .format = format,
        .width = width,
        .height = height,
        .depth_or_array_layers = 1,
        .mip_levels = 1,
        .dimension = .@"2d",
        .swapchain_owned = true,
    });
    return .{ .inner = id };
}

/// Helper — récupère l'image native d'un handle (utilisé par command_encoder).
pub fn lookupImage(device: *Device, handle: types.TextureHandle) ?vk.Image {
    if (handle.inner == 0) return null;
    return if (device.textures.get(handle.inner)) |e| e.vk_image else null;
}

/// Lookup d'une `vk.ImageView` à partir d'un handle GAL.
pub fn lookupView(device: *Device, handle: types.TextureViewHandle) ?vk.ImageView {
    if (handle.inner == 0) return null;
    return if (device.texture_views.get(handle.inner)) |e| e.vk_view else null;
}

fn pickMemoryType(
    props: vk.PhysicalDeviceMemoryProperties,
    type_bits: u32,
    want: vk.MemoryPropertyFlags,
) ?u32 {
    var i: u32 = 0;
    while (i < props.memory_type_count) : (i += 1) {
        const candidate = props.memory_types[i];
        const want_bits: u32 = @bitCast(want);
        const have_bits: u32 = @bitCast(candidate.property_flags);
        if ((type_bits & (@as(u32, 1) << @intCast(i))) != 0 and (have_bits & want_bits) == want_bits) {
            return i;
        }
    }
    return null;
}
