//! Swapchain Vulkan — Phase 0 / M0.4.
//!
//! Absorbs the role of `src/spike/vk_frame.zig` (removed, brief §Removals).
//! Creates the VkSwapchainKHR + the associated image views, exposes
//! `acquireNextImage` and `present` on the GAL side.
//!
//! Phase 0: 2 images (double buffer FIFO), BGRA8_UNORM format, FIFO present
//! mode. Recreation on `OUT_OF_DATE_KHR` is not automatic (the caller must
//! detect `error.SwapchainOutOfDate` and recreate manually). Phase 1+:
//! transparent recreate on the GAL side.
//!
//! Surface selection is done via the `surface` of the DeviceDescriptor —
//! Phase 0 expects the caller (e.g., `examples/triangle/`) to have created the
//! VK_KHR_xxx_surface upstream and passed it to the Device.

const std = @import("std");
const weld_core = @import("weld_core");
const vk = weld_core.platform.vk;
const types = @import("../types.zig");
const conv = @import("conv.zig");
const Device = @import("device.zig").Device;
const texture_mod = @import("texture.zig");

const log = std.log.scoped(.gal_vk_swap);

/// Internal slot of a Swapchain — bundles VkSwapchainKHR + images + views.
/// The images are owned by the swapchain (not by our allocator).
/// `view_handles` is pre-allocated at `create()`: one stable GAL
/// `TextureViewHandle` per swapchain image. The caller calls
/// `Device.getSwapchainImageView(handle, image_index)` which reads this slot
/// without per-frame alloc.
pub const Entry = struct {
    vk_swapchain: vk.SwapchainKHR,
    surface: vk.SurfaceKHR,
    format: types.TextureFormat,
    extent: vk.Extent2D,
    images: []vk.Image,
    image_views: []vk.ImageView,
    view_handles: []types.TextureViewHandle,
    /// Current image index (updated by `acquireNextImage`).
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

/// Creates the Vulkan swapchain on the Device's surface. Fails with
/// `error.SurfaceLost` if the Device was initialized without a surface.
pub fn create(device: *Device, descriptor: types.SwapchainDescriptor) types.Error!types.SwapchainHandle {
    if (descriptor.width == 0 or descriptor.height == 0) return error.InvalidArgument;
    if (device.surface == .null) return error.SurfaceLost;

    const caps = device.physical_device.getPhysicalDeviceSurfaceCapabilitiesKHR(device.surface) catch return error.SurfaceLost;
    const formats = device.physical_device.getPhysicalDeviceSurfaceFormatsKHR(device.surface, device.allocator) catch return error.SurfaceLost;
    defer device.allocator.free(formats);

    // Format + colorspace selection. The GAL always presents in the core
    // `srgb_nonlinear` colorspace (`conv.colorSpace`) — never the surface's
    // first-reported colorspace, which on some drivers (e.g. lavapipe) is an
    // extended `*_EXT` value that trips
    // VUID-VkSwapchainCreateInfoKHR-imageColorSpace-parameter without
    // `VK_EXT_swapchain_colorspace`. So pick a SURFACE PAIR carrying that
    // colorspace, preferring the requested pixel format, then BGRA8_UNORM,
    // then any `srgb_nonlinear` pair. A last resort (no `srgb_nonlinear` pair
    // at all — the spec effectively precludes this) forces the colorspace on
    // the first reported format.
    const present_cs = conv.colorSpace();
    const want = conv.textureFormat(descriptor.format);
    var chosen_format: ?vk.Format = null;
    for (formats) |f| {
        if (f.color_space != present_cs) continue;
        if (f.format == want) {
            chosen_format = want;
            break;
        }
        if (chosen_format == null and f.format == .b8g8r8a8_unorm) chosen_format = f.format;
    }
    if (chosen_format == null) {
        for (formats) |f| {
            if (f.color_space == present_cs) {
                chosen_format = f.format;
                break;
            }
        }
    }
    if (chosen_format == null and formats.len > 0) chosen_format = formats[0].format;
    const fmt_format = chosen_format orelse return error.Unsupported;

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
    image_usage.transfer_src = true; // for PPM capture (brief §Notes decision 6)

    const ci: vk.SwapchainCreateInfoKHR = .{
        .flags = .empty,
        .surface = device.surface,
        .min_image_count = min_image_count,
        .image_format = fmt_format,
        .image_color_space = present_cs,
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
            .format = fmt_format,
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
    const swap_format = conv.textureFormatFromVk(fmt_format);
    for (views, 0..) |v, i| {
        view_handles[i] = try texture_mod.adoptSwapchainView(device, v, extent.width, extent.height, swap_format);
        registered = i + 1;
    }

    const id = device.nextHandle();
    try device.swapchains.put(device.allocator, id, .{
        .vk_swapchain = sc,
        .surface = device.surface,
        .format = conv.textureFormatFromVk(fmt_format),
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

/// Number of images in the swapchain (the driver may give more than the
/// requested `min_image_count`). Lets a caller size per-image resources —
/// e.g. one present-completion semaphore per image, indexed by the
/// `acquireNextImage` result, which avoids re-signalling a binary semaphore
/// still pending on a prior present (VUID-vkQueueSubmit-pSignalSemaphores-00067).
pub fn getImageCount(device: *Device, handle: types.SwapchainHandle) u32 {
    const entry = device.swapchains.get(handle.inner) orelse {
        log.debug("getImageCount: unknown swapchain handle {x}", .{handle.inner});
        unreachable;
    };
    return @intCast(entry.view_handles.len);
}

/// Frees the swapchain + its views + the image array. No-op if invalid.
/// First removes the `view_handles` from the device's `texture_views`
/// registry before the swapchain frees the underlying `vk.ImageView` — without
/// that, the entries would become zombies (handles pointing to freed views).
/// At `device.deinit` this effect is neutral since the registry is drained
/// before the swapchains; the code stays correct in both flows.
pub fn destroy(device: *Device, handle: types.SwapchainHandle) void {
    if (handle.inner == 0) return;
    if (device.swapchains.fetchRemove(handle.inner)) |kv| {
        var entry = kv.value;
        for (entry.view_handles) |vh| _ = device.texture_views.remove(vh.inner);
        entry.destroy(device.vk_device, device.allocator);
    }
}

/// Acquires the swapchain's next image index. `signal_semaphore` is
/// signaled when the image is available on the GPU side. Returns
/// `error.SwapchainOutOfDate` if the caller must recreate the swapchain.
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

/// Presents image `image_index`. Waits on the `wait_semaphores` semaphores
/// before the actual presentation.
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
