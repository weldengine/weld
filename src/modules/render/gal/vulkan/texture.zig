//! Texture + TextureView Vulkan — Phase 0 / M0.4.
//!
//! As with Buffer, we bundle Image + DeviceMemory in a `TextureEntry`.
//! TextureViews have their own registry because we must be able to destroy
//! them without touching the parent texture, and conversely we must handle
//! the cascade (destroy all of a texture's views when it disappears).
//!
//! Phase 0 limited formats (cf. brief §Scope): R8G8B8A8_UNORM, B8G8R8A8_UNORM
//! (swapchain), D32_SFLOAT. `sample_count > 1` returns `Unsupported`.

const std = @import("std");
const weld_core = @import("weld_core");
const vk = weld_core.platform.vk;
const types = @import("../types.zig");
const conv = @import("conv.zig");
const Device = @import("device.zig").Device;

/// Internal slot of a Texture — bundles `vk.Image` + `vk.DeviceMemory` +
/// descriptor metadata. Indexed by a monotonic u64 in `device.textures`.
pub const TextureEntry = struct {
    vk_image: vk.Image,
    vk_memory: vk.DeviceMemory,
    format: types.TextureFormat,
    width: u32,
    height: u32,
    depth_or_array_layers: u32,
    mip_levels: u32,
    dimension: types.TextureDimension,
    /// `true` if the image is managed by the Vulkan swapchain (not allocated
    /// by us) — we then call neither `destroyImage` nor `freeMemory`.
    swapchain_owned: bool = false,

    pub fn destroy(self: *TextureEntry, device: *vk.Device) void {
        if (!self.swapchain_owned) {
            if (self.vk_image != .null) device.destroyImage(self.vk_image, null);
            if (self.vk_memory != .null) device.freeMemory(self.vk_memory, null);
        }
        self.* = undefined;
    }
};

/// Internal slot of a TextureView — wraps `vk.ImageView`. Indexed separately
/// from `TextureEntry` because a view has its own lifecycle.
/// If `swapchain_owned = true`, the registry destroy skips the native
/// `destroyImageView`: the Vulkan swapchain owns the view and frees it
/// itself in `swap.Entry.destroy`.
///
/// `width` / `height` are populated at view creation time from the source
/// `TextureEntry` (or from the swapchain extent for swapchain-owned views).
/// They feed `render_pass.zig:begin` which needs the framebuffer dimensions
/// — without these fields the framebuffer is created with width=0 height=0
/// and the render pass executes on a zero-sized surface (black frame).
/// S2 reference: `/tmp/s2-ref/src/spike/vk_setup.zig:createFramebuffers`
/// uses `r.swapchain_extent.{width,height}` directly; the GAL needs the
/// per-view copy because views are independent of any single source.
pub const ViewEntry = struct {
    vk_view: vk.ImageView,
    width: u32,
    height: u32,
    /// Texture format the view exposes. Inherited from the source
    /// `TextureEntry` at view creation (or from the swapchain-negotiated
    /// format for swapchain-owned views). Read by `render_pass.zig` to
    /// build the attachment description — without the per-view copy the
    /// render pass would hardcode BGRA8_UNORM and mismatch RGBA8_UNORM
    /// offscreen captures.
    format: types.TextureFormat,
    swapchain_owned: bool = false,

    pub fn destroy(self: *ViewEntry, device: *vk.Device) void {
        if (!self.swapchain_owned and self.vk_view != .null) {
            device.destroyImageView(self.vk_view, null);
        }
        self.* = undefined;
    }
};

/// Allocates a device-local `vk.Image` + DeviceMemory, registers it in
/// the registry. Phase 0: `sample_count > 1` → `error.Unsupported`.
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

/// Frees a Texture + its memory. No-op if handle invalid or
/// `swapchain_owned` (the swapchain handles freeing itself).
pub fn destroyTexture(device: *Device, handle: types.TextureHandle) void {
    if (handle.inner == 0) return;
    if (device.textures.fetchRemove(handle.inner)) |kv| {
        var entry = kv.value;
        entry.destroy(device.vk_device);
    }
}

/// Creates a `vk.ImageView` on the parent texture. Format inherited if
/// not specified, dimension likewise.
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
    try device.texture_views.put(device.allocator, id, .{
        .vk_view = view,
        .width = tex.width,
        .height = tex.height,
        .format = format,
    });
    return .{ .inner = id };
}

/// Frees a `vk.ImageView`. No-op if handle invalid.
pub fn destroyView(device: *Device, handle: types.TextureViewHandle) void {
    if (handle.inner == 0) return;
    if (device.texture_views.fetchRemove(handle.inner)) |kv| {
        var entry = kv.value;
        entry.destroy(device.vk_device);
    }
}

/// Registers a swapchain-owned `vk.ImageView` in the registry and
/// returns the stable GAL `TextureViewHandle`. The view is destroyed by
/// `swap.Entry.destroy` (the registry skips via `swapchain_owned`).
/// `width` / `height` / `format` are the swapchain extent + negotiated
/// format — required by the framebuffer + render pass attachment
/// creation downstream (Bugs 1 & 2 fixes — without the per-view metadata
/// the render pass would hardcode dimensions to (0, 0) and the format
/// to BGRA8_UNORM, mismatching swapchain-negotiated SRGB variants and
/// any offscreen RGBA8_UNORM captures).
pub fn adoptSwapchainView(
    device: *Device,
    view: vk.ImageView,
    width: u32,
    height: u32,
    format: types.TextureFormat,
) types.Error!types.TextureViewHandle {
    const id = device.nextHandle();
    try device.texture_views.put(device.allocator, id, .{
        .vk_view = view,
        .width = width,
        .height = height,
        .format = format,
        .swapchain_owned = true,
    });
    return .{ .inner = id };
}

/// Internal helper — for swapchain.zig which adopts the `vk.Image`s from
/// `getSwapchainImagesKHR` (memory management delegated to the swapchain).
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

/// Helper — retrieves the native image of a handle (used by command_encoder).
pub fn lookupImage(device: *Device, handle: types.TextureHandle) ?vk.Image {
    if (handle.inner == 0) return null;
    return if (device.textures.get(handle.inner)) |e| e.vk_image else null;
}

/// Lookup of a `vk.ImageView` from a GAL handle.
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
