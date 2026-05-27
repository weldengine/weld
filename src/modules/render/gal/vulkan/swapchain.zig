//! Swapchain Vulkan — Phase 0 / M0.4.
//!
//! Absorbe le rôle de `src/spike/vk_frame.zig` (suppression brief §Suppressions).
//! Crée la VkSwapchainKHR + les vues image associées, expose `acquireNextImage`
//! et `present` côté GAL.
//!
//! Phase 0 : 2 images (double buffer FIFO), format BGRA8_UNORM, présent mode
//! FIFO. Recréation à `OUT_OF_DATE_KHR` non automatique (le caller doit
//! détecter `error.SwapchainOutOfDate` et recréer manuellement). Phase 1+ :
//! transparent recreate côté GAL.
//!
//! La sélection de surface est faite via le `surface` du DeviceDescriptor —
//! Phase 0 attend que le caller (e.g., `examples/triangle/`) ait créé la
//! surface VK_KHR_xxx_surface en amont et l'ait passée au Device.

const std = @import("std");
const weld_core = @import("weld_core");
const vk = weld_core.platform.vk;
const types = @import("../types.zig");
const conv = @import("conv.zig");
const Device = @import("device.zig").Device;
const texture_mod = @import("texture.zig");

const log = std.log.scoped(.gal_vk_swap);

/// Slot interne d'une Swapchain — bundle VkSwapchainKHR + images + views.
/// Les images sont owned par la swapchain (pas par notre allocateur).
/// `view_handles` est pré-alloué à `create()` : un `TextureViewHandle` GAL
/// stable par image du swapchain. Le caller appelle
/// `Device.getSwapchainImageView(handle, image_index)` qui lit ce slot
/// sans alloc par frame.
pub const Entry = struct {
    vk_swapchain: vk.SwapchainKHR,
    surface: vk.SurfaceKHR,
    format: types.TextureFormat,
    extent: vk.Extent2D,
    images: []vk.Image,
    image_views: []vk.ImageView,
    view_handles: []types.TextureViewHandle,
    /// Image index courant (mis à jour par `acquireNextImage`).
    current_image: u32 = 0,

    pub fn destroy(self: *Entry, device: *vk.Device, allocator: std.mem.Allocator) void {
        for (self.image_views) |v| {
            if (v != .null) device.destroyImageView(v, null);
        }
        allocator.free(self.image_views);
        allocator.free(self.view_handles);
        allocator.free(self.images);
        if (self.vk_swapchain != .null) device.destroySwapchainKHR(self.vk_swapchain, null);
        self.* = undefined;
    }
};

/// Crée la swapchain Vulkan sur la surface du Device. Échoue avec
/// `error.SurfaceLost` si le Device a été initialisé sans surface.
pub fn create(device: *Device, descriptor: types.SwapchainDescriptor) types.Error!types.SwapchainHandle {
    if (descriptor.width == 0 or descriptor.height == 0) return error.InvalidArgument;
    if (device.surface == .null) return error.SurfaceLost;

    const caps = device.physical_device.getPhysicalDeviceSurfaceCapabilitiesKHR(device.surface) catch return error.SurfaceLost;
    const formats = device.physical_device.getPhysicalDeviceSurfaceFormatsKHR(device.surface, device.allocator) catch return error.SurfaceLost;
    defer device.allocator.free(formats);

    // Sélection format préférable (request match si possible).
    var chosen: ?vk.SurfaceFormatKHR = null;
    const want = conv.textureFormat(descriptor.format);
    for (formats) |f| {
        if (f.format == want) {
            chosen = f;
            break;
        }
    }
    if (chosen == null) {
        // Fallback : premier BGRA8 disponible.
        for (formats) |f| {
            if (f.format == .b8g8r8a8_unorm) {
                chosen = f;
                break;
            }
        }
    }
    if (chosen == null and formats.len > 0) chosen = formats[0];
    const fmt = chosen orelse return error.Unsupported;

    var min_image_count = caps.min_image_count + 1;
    if (descriptor.min_image_count > min_image_count) min_image_count = descriptor.min_image_count;
    if (caps.max_image_count > 0 and min_image_count > caps.max_image_count) {
        min_image_count = caps.max_image_count;
    }

    const sentinel: u32 = 0xFFFFFFFF;
    const extent: vk.Extent2D = blk: {
        if (caps.current_extent.width != sentinel and caps.current_extent.height != sentinel) {
            break :blk caps.current_extent;
        }
        const w = std.math.clamp(descriptor.width, caps.min_image_extent.width, caps.max_image_extent.width);
        const h = std.math.clamp(descriptor.height, caps.min_image_extent.height, caps.max_image_extent.height);
        break :blk .{ .width = w, .height = h };
    };

    const composite_alpha = pickCompositeAlpha(caps.supported_composite_alpha) orelse return error.Unsupported;

    var image_usage: vk.ImageUsageFlags = .empty;
    image_usage.color_attachment = true;
    image_usage.transfer_src = true; // pour capture PPM (brief §Notes décision 6)

    const ci: vk.SwapchainCreateInfoKHR = .{
        .flags = .empty,
        .surface = device.surface,
        .min_image_count = min_image_count,
        .image_format = fmt.format,
        .image_color_space = fmt.color_space,
        .image_extent = extent,
        .image_array_layers = 1,
        .image_usage = image_usage,
        .image_sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
        .pre_transform = caps.current_transform,
        .composite_alpha = composite_alpha,
        .present_mode = conv.presentMode(descriptor.present_mode),
        .clipped = 1,
        .old_swapchain = .null,
    };
    const sc = device.vk_device.createSwapchainKHR(&ci, null) catch return error.BackendInternal;
    errdefer device.vk_device.destroySwapchainKHR(sc, null);

    const images = device.vk_device.getSwapchainImagesKHR(sc, device.allocator) catch return error.BackendInternal;
    errdefer device.allocator.free(images);

    const views = try device.allocator.alloc(vk.ImageView, images.len);
    errdefer device.allocator.free(views);
    for (images, 0..) |img, i| {
        const vci: vk.ImageViewCreateInfo = .{
            .flags = .empty,
            .image = img,
            .view_type = ._2d,
            .format = fmt.format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = .{ .color = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };
        views[i] = device.vk_device.createImageView(&vci, null) catch return error.BackendInternal;
    }

    // Pre-allocate one stable GAL TextureViewHandle per swapchain image.
    // Lookup in the device's texture_views registry happens via these
    // handles in `getImageView` — zero alloc per frame on the hot path.
    const view_handles = try device.allocator.alloc(types.TextureViewHandle, images.len);
    errdefer device.allocator.free(view_handles);
    var registered: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < registered) : (i += 1) _ = device.texture_views.remove(view_handles[i].inner);
    }
    for (views, 0..) |v, i| {
        view_handles[i] = try texture_mod.adoptSwapchainView(device, v);
        registered = i + 1;
    }

    const id = device.nextHandle();
    try device.swapchains.put(device.allocator, id, .{
        .vk_swapchain = sc,
        .surface = device.surface,
        .format = conv.textureFormatFromVk(fmt.format),
        .extent = extent,
        .images = images,
        .image_views = views,
        .view_handles = view_handles,
    });
    return .{ .inner = id };
}

/// Lookup the pre-allocated `TextureViewHandle` for an image of the
/// swapchain. `image_index` must come from `acquireNextImage` — out of
/// range is a caller bug, hence `unreachable` in debug.
pub fn getImageView(
    device: *Device,
    handle: types.SwapchainHandle,
    image_index: u32,
) types.TextureViewHandle {
    const entry = device.swapchains.get(handle.inner) orelse {
        log.debug("getImageView: unknown swapchain handle {x}", .{handle.inner});
        unreachable;
    };
    std.debug.assert(image_index < entry.view_handles.len);
    return entry.view_handles[image_index];
}

/// Libère la swapchain + ses vues + le tableau d'images. No-op si invalide.
/// Retire d'abord les `view_handles` du registry `texture_views` du device
/// avant que la swapchain ne libère les `vk.ImageView` sous-jacents — sans
/// ça, les entrées deviendraient zombies (handles pointant vers des views
/// freed). À `device.deinit` cet effet est neutre puisque le registry est
/// drainé avant les swapchains ; le code reste correct dans les deux flots.
pub fn destroy(device: *Device, handle: types.SwapchainHandle) void {
    if (handle.inner == 0) return;
    if (device.swapchains.fetchRemove(handle.inner)) |kv| {
        var entry = kv.value;
        for (entry.view_handles) |vh| _ = device.texture_views.remove(vh.inner);
        entry.destroy(device.vk_device, device.allocator);
    }
}

/// Acquiert le prochain image index de la swapchain. `signal_semaphore`
/// est signalé quand l'image est disponible côté GPU. Retourne
/// `error.SwapchainOutOfDate` si le caller doit recréer la swapchain.
pub fn acquireNextImage(
    device: *Device,
    handle: types.SwapchainHandle,
    signal_semaphore: ?types.SemaphoreHandle,
    timeout_ns: u64,
) types.Error!u32 {
    if (handle.inner == 0) return error.InvalidArgument;
    const entry = device.swapchains.getPtr(handle.inner) orelse return error.InvalidArgument;
    var image_index: u32 = 0;
    const sem: vk.Semaphore = if (signal_semaphore) |s| @enumFromInt(s.inner) else .null;
    const result = vk.device_dispatch.vkAcquireNextImageKHR(
        device.vk_device,
        entry.vk_swapchain,
        timeout_ns,
        sem,
        .null,
        &image_index,
    );
    switch (result) {
        .success, .suboptimal_khr => {
            entry.current_image = image_index;
            return image_index;
        },
        .error_out_of_date_khr => return error.SwapchainOutOfDate,
        else => return conv.errorFromResult(result),
    }
}

/// Présente l'image `image_index`. Attend les semaphores `wait_semaphores`
/// avant la présentation effective.
pub fn present(
    device: *Device,
    handle: types.SwapchainHandle,
    image_index: u32,
    wait_semaphores: []const types.SemaphoreHandle,
) types.Error!void {
    if (handle.inner == 0) return error.InvalidArgument;
    const entry = device.swapchains.get(handle.inner) orelse return error.InvalidArgument;

    var wait_vk: std.ArrayList(vk.Semaphore) = .empty;
    defer wait_vk.deinit(device.allocator);
    try wait_vk.ensureTotalCapacity(device.allocator, wait_semaphores.len);
    for (wait_semaphores) |s| {
        try wait_vk.append(device.allocator, @enumFromInt(s.inner));
    }

    const sc = entry.vk_swapchain;
    const info: vk.PresentInfoKHR = .{
        .wait_semaphore_count = @intCast(wait_vk.items.len),
        .p_wait_semaphores = if (wait_vk.items.len > 0) @ptrCast(wait_vk.items.ptr) else undefined,
        .swapchain_count = 1,
        .p_swapchains = @ptrCast(&sc),
        .p_image_indices = @ptrCast(&image_index),
        .p_results = null,
    };
    const result = vk.device_dispatch.vkQueuePresentKHR(device.vk_queue, &info);
    switch (result) {
        .success, .suboptimal_khr => {},
        .error_out_of_date_khr => return error.SwapchainOutOfDate,
        else => return conv.errorFromResult(result),
    }
}

fn pickCompositeAlpha(supported: vk.CompositeAlphaFlagsKHR) ?vk.CompositeAlphaFlagBitsKHR {
    if (supported.@"opaque") return .opaque_bit;
    if (supported.inherit) return .inherit_bit;
    if (supported.pre_multiplied) return .pre_multiplied_bit;
    if (supported.post_multiplied) return .post_multiplied_bit;
    return null;
}
