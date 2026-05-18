//! S6 editor Vulkan blit renderer.
//!
//! Opens a window-sized swapchain and a fullscreen-quad pipeline that
//! samples the runtime-written viewport shm framebuffer (1280×720
//! RGBA8) onto the present surface. The pipeline is the brief's G6
//! deliverable — pattern lifted from `src/spike/vk_setup.zig` but
//! adapted to the editor's read-from-shm-and-blit flow rather than
//! the spike's vertex-buffer triangle. The two Vulkan setup files
//! deliberately duplicate boilerplate; the GAL refactor that
//! consolidates them lands in Phase 0.4 (cf. brief § Out-of-scope).
//!
//! Per-frame data flow:
//!   1. Editor reads `viewport.ShmViewport.readSlot()` to learn
//!      which slot the runtime just committed, plus the slot's RGBA
//!      bytes via `slotBytes`.
//!   2. Bytes are copied into a host-visible/coherent staging buffer
//!      (memcpy through the persistently-mapped pointer).
//!   3. Command buffer transitions the sampled image to
//!      TRANSFER_DST_OPTIMAL, issues `vkCmdCopyBufferToImage`,
//!      transitions to SHADER_READ_ONLY_OPTIMAL.
//!   4. Render pass begins on the acquired swapchain image; the
//!      blit pipeline is bound, the descriptor set holding the
//!      sampled image is bound, `vkCmdDraw(3, 1, 0, 0)` draws the
//!      fullscreen triangle, render pass ends, command buffer is
//!      submitted, image is presented.
//!
//! The whole sequence runs inside `drawFrame`; the editor main loop
//! is `while (!window.shouldClose() and frame < max) { drainIpc();
//! drawFrame(); }`.

const std = @import("std");
const builtin = @import("builtin");

const weld_core = @import("weld_core");
const vk = weld_core.platform.vk;
const window_mod = weld_core.platform.window;
const viewport_mod = weld_core.ipc.viewport;

const shaders = @import("shaders");
const blit_vert_spv = shaders.viewport_blit_vert_spv;
const blit_frag_spv = shaders.viewport_blit_frag_spv;

pub const max_frames_in_flight: u32 = 2;

pub const SetupError = error{
    LoaderUnavailable,
    InstanceUnavailable,
    NoCompatibleDevice,
    NoCompatibleQueueFamily,
    NoCompatibleSurfaceFormat,
    NoCompatibleCompositeAlpha,
    SurfaceCreateFailed,
    SwapchainCreateFailed,
    ShaderModuleCreateFailed,
    PipelineCreateFailed,
    DescriptorAllocFailed,
    MemoryMapFailed,
    UnsupportedHostPlatform,
} || vk.Error || std.mem.Allocator.Error;

pub const Renderer = struct {
    gpa: std.mem.Allocator,

    instance: *vk.Instance,
    debug_messenger: ?vk.DebugUtilsMessengerEXT = null,
    physical_device: *vk.PhysicalDevice,
    device: *vk.Device,
    surface: vk.SurfaceKHR,
    queue: *vk.Queue,
    queue_family_index: u32,

    /// Most recent window-side surface size in physical pixels.
    /// Updated by the main loop from `Event.resize`; seeded at
    /// `init` from the window desc. Used as the swapchain extent
    /// fallback for Wayland's `(0xFFFFFFFF, …)` sentinel.
    last_known_size: vk.Extent2D,

    swapchain: vk.SwapchainKHR = .null,
    swapchain_format: vk.Format = .undefined,
    swapchain_extent: vk.Extent2D = .{ .width = 0, .height = 0 },
    swapchain_images: []vk.Image = &.{},
    swapchain_views: []vk.ImageView = &.{},
    framebuffers: []vk.Framebuffer = &.{},

    render_pass: vk.RenderPass = .null,
    descriptor_set_layout: vk.DescriptorSetLayout = .null,
    pipeline_layout: vk.PipelineLayout = .null,
    pipeline: vk.Pipeline = .null,
    vert_module: vk.ShaderModule = .null,
    frag_module: vk.ShaderModule = .null,

    /// 1280×720 RGBA8_UNORM sampled image — the runtime's mire
    /// lands here every frame before the blit pipeline reads it.
    viewport_image: vk.Image = .null,
    viewport_image_memory: vk.DeviceMemory = .null,
    viewport_image_view: vk.ImageView = .null,
    viewport_sampler: vk.Sampler = .null,
    /// Persistent host-visible staging buffer sized for the full
    /// 1280×720×4 framebuffer (≈ 3.5 MB).
    staging_buffer: vk.Buffer = .null,
    staging_memory: vk.DeviceMemory = .null,
    staging_mapped: ?[*]u8 = null,

    descriptor_pool: vk.DescriptorPool = .null,
    descriptor_set: vk.DescriptorSet = .null,

    command_pool: vk.CommandPool = .null,
    command_buffers: [max_frames_in_flight]*vk.CommandBuffer = undefined,
    image_available: [max_frames_in_flight]vk.Semaphore = .{ .null, .null },
    render_finished: [max_frames_in_flight]vk.Semaphore = .{ .null, .null },
    in_flight: [max_frames_in_flight]vk.Fence = .{ .null, .null },
    current_frame: u32 = 0,

    /// `true` until the first viewport upload — the image starts in
    /// `undefined` layout and the first command buffer transitions
    /// it to `transfer_dst_optimal` from there. Subsequent uploads
    /// transition from `shader_read_only_optimal`.
    image_undefined: bool = true,

    swapchain_dirty: bool = false,

    pub fn init(
        gpa: std.mem.Allocator,
        window: *window_mod.Window,
        initial_size: vk.Extent2D,
    ) SetupError!Renderer {
        try vk.loadLoader();

        var r: Renderer = .{
            .gpa = gpa,
            .instance = undefined,
            .physical_device = undefined,
            .device = undefined,
            .surface = .null,
            .queue = undefined,
            .queue_family_index = 0,
            .last_known_size = initial_size,
        };

        r.instance = try createInstance(gpa);
        errdefer r.instance.destroyInstance(null);
        try vk.loadInstance(r.instance);

        if (builtin.mode == .Debug) {
            r.debug_messenger = createDebugMessenger(r.instance) catch null;
        }
        errdefer if (r.debug_messenger) |m| {
            r.instance.destroyDebugUtilsMessengerEXT(m, null);
        };

        r.surface = try createSurface(r.instance, window);
        errdefer r.instance.destroySurfaceKHR(r.surface, null);

        try pickPhysicalDevice(&r, gpa);
        try createLogicalDevice(&r);
        errdefer r.device.destroyDevice(null);
        try vk.loadDevice(r.device);

        r.queue = r.device.getDeviceQueue(r.queue_family_index, 0);

        try createSwapchainAndViews(&r, gpa, .null);
        errdefer destroySwapchainResources(&r);

        try createRenderPass(&r);
        errdefer r.device.destroyRenderPass(r.render_pass, null);

        try createViewportImage(&r);
        errdefer destroyViewportImage(&r);

        try createSampler(&r);
        errdefer if (r.viewport_sampler != .null) r.device.destroySampler(r.viewport_sampler, null);

        try createStagingBuffer(&r);
        errdefer destroyStagingBuffer(&r);

        try createDescriptorResources(&r);
        errdefer destroyDescriptorResources(&r);

        try createBlitPipeline(&r);
        errdefer destroyPipelineResources(&r);

        try createFramebuffers(&r, gpa);
        try createSyncObjects(&r);

        return r;
    }

    pub fn deinit(self: *Renderer) void {
        self.device.waitIdle() catch {};

        for (0..max_frames_in_flight) |i| {
            if (self.in_flight[i] != .null) self.device.destroyFence(self.in_flight[i], null);
            if (self.image_available[i] != .null) self.device.destroySemaphore(self.image_available[i], null);
            if (self.render_finished[i] != .null) self.device.destroySemaphore(self.render_finished[i], null);
        }
        if (self.command_pool != .null) self.device.destroyCommandPool(self.command_pool, null);

        destroyPipelineResources(self);
        destroyDescriptorResources(self);
        destroyStagingBuffer(self);
        if (self.viewport_sampler != .null) self.device.destroySampler(self.viewport_sampler, null);
        destroyViewportImage(self);
        if (self.render_pass != .null) self.device.destroyRenderPass(self.render_pass, null);
        destroySwapchainResources(self);

        self.device.destroyDevice(null);
        if (self.debug_messenger) |m| self.instance.destroyDebugUtilsMessengerEXT(m, null);
        self.instance.destroySurfaceKHR(self.surface, null);
        self.instance.destroyInstance(null);
    }

    pub fn recreateSwapchain(self: *Renderer) SetupError!void {
        self.device.waitIdle() catch {};
        for (self.framebuffers) |fb| self.device.destroyFramebuffer(fb, null);
        self.gpa.free(self.framebuffers);
        self.framebuffers = &.{};
        for (self.swapchain_views) |v| self.device.destroyImageView(v, null);
        self.gpa.free(self.swapchain_views);
        self.swapchain_views = &.{};
        self.gpa.free(self.swapchain_images);
        self.swapchain_images = &.{};
        const old_swapchain = self.swapchain;
        try createSwapchainAndViews(self, self.gpa, old_swapchain);
        if (old_swapchain != .null) self.device.destroySwapchainKHR(old_swapchain, null);
        try createFramebuffers(self, self.gpa);
        self.swapchain_dirty = false;
    }

    /// Copy `slot_bytes` (1280×720×4 RGBA bytes from the shm
    /// viewport's published slot) into the staging buffer. Caller
    /// then issues `drawFrame` which flushes staging → image →
    /// sampler in one command-buffer recording.
    pub fn stageViewport(self: *Renderer, slot_bytes: []const u8) void {
        const dst = self.staging_mapped orelse return;
        const n = @min(slot_bytes.len, viewport_mod.default_resolution.width * viewport_mod.default_resolution.height * 4);
        @memcpy(dst[0..n], slot_bytes[0..n]);
    }
};

// ============================================================== helpers =

fn createInstance(gpa: std.mem.Allocator) !*vk.Instance {
    const layers_debug = [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"};
    var enabled_layers: []const [*:0]const u8 = &.{};
    if (builtin.mode == .Debug) {
        const available = vk.enumerateInstanceLayerProperties(gpa) catch &[_]vk.LayerProperties{};
        defer gpa.free(available);
        var has_validation = false;
        for (available) |lp| {
            if (std.mem.startsWith(u8, &lp.layer_name, "VK_LAYER_KHRONOS_validation")) {
                has_validation = true;
                break;
            }
        }
        if (has_validation) enabled_layers = layers_debug[0..];
    }

    var ext_buf: std.ArrayList([*:0]const u8) = .empty;
    defer ext_buf.deinit(gpa);
    try ext_buf.append(gpa, "VK_KHR_surface");
    switch (builtin.os.tag) {
        .linux => try ext_buf.append(gpa, "VK_KHR_wayland_surface"),
        .windows => try ext_buf.append(gpa, "VK_KHR_win32_surface"),
        .macos => return error.UnsupportedHostPlatform,
        else => return error.UnsupportedHostPlatform,
    }
    if (builtin.mode == .Debug) try ext_buf.append(gpa, "VK_EXT_debug_utils");

    const app_info: vk.ApplicationInfo = .{
        .p_application_name = "Weld Editor",
        .application_version = 1,
        .p_engine_name = "Weld",
        .engine_version = 1,
        .api_version = (@as(u32, 1) << 22) | (@as(u32, 3) << 12),
    };
    const ci: vk.InstanceCreateInfo = .{
        .flags = .empty,
        .p_application_info = &app_info,
        .enabled_layer_count = @intCast(enabled_layers.len),
        .pp_enabled_layer_names = if (enabled_layers.len > 0) enabled_layers.ptr else undefined,
        .enabled_extension_count = @intCast(ext_buf.items.len),
        .pp_enabled_extension_names = ext_buf.items.ptr,
    };
    return vk.createInstance(&ci, null);
}

fn debugCallback(
    severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    types: vk.DebugUtilsMessageTypeFlagsEXT,
    data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    user_data: ?*anyopaque,
) callconv(.c) vk.Bool32 {
    _ = severity;
    _ = types;
    _ = user_data;
    if (data) |d| {
        if (d.p_message) |msg| std.log.scoped(.s6_editor).warn("vk: {s}", .{msg});
    }
    return 0;
}

fn createDebugMessenger(instance: *vk.Instance) !vk.DebugUtilsMessengerEXT {
    const ci: vk.DebugUtilsMessengerCreateInfoEXT = .{
        .flags = .empty,
        .message_severity = .{ .warning = true, .@"error" = true },
        .message_type = .{ .general = true, .validation = true, .performance = true },
        .pfn_user_callback = @ptrCast(&debugCallback),
        .p_user_data = null,
    };
    return instance.createDebugUtilsMessengerEXT(&ci, null);
}

fn createSurface(instance: *vk.Instance, window: *window_mod.Window) !vk.SurfaceKHR {
    switch (builtin.os.tag) {
        .windows => {
            const handles = window.nativeHandles();
            const ci: vk.Win32SurfaceCreateInfoKHR = .{
                .flags = .empty,
                .hinstance = @ptrCast(handles.hinstance),
                .hwnd = @ptrCast(handles.hwnd),
            };
            return instance.createWin32SurfaceKHR(&ci, null);
        },
        .linux => {
            const handles = window.nativeHandles();
            const ci: vk.WaylandSurfaceCreateInfoKHR = .{
                .flags = .empty,
                .display = @ptrCast(handles.display),
                .surface = @ptrCast(handles.surface),
            };
            return instance.createWaylandSurfaceKHR(&ci, null);
        },
        else => return error.UnsupportedHostPlatform,
    }
}

fn pickPhysicalDevice(r: *Renderer, gpa: std.mem.Allocator) !void {
    const devices = try r.instance.enumeratePhysicalDevices(gpa);
    defer gpa.free(devices);
    if (devices.len == 0) return error.NoCompatibleDevice;

    // Prefer discrete > integrated > anything else. No CLI override
    // in the editor stub — the brief leaves device selection to the
    // editor itself (Phase 0.6 plumbs `--gpu-prefer`).
    var best: ?*vk.PhysicalDevice = null;
    var best_score: i32 = -1;
    for (devices) |pd| {
        const props = pd.getPhysicalDeviceProperties();
        const score: i32 = switch (@intFromEnum(props.device_type)) {
            2 => 100, // discrete
            1 => 50, // integrated
            else => 10,
        };
        if (score > best_score) {
            best = pd;
            best_score = score;
        }
    }
    r.physical_device = best orelse return error.NoCompatibleDevice;
    try findGraphicsQueueFamily(r, gpa);
}

fn findGraphicsQueueFamily(r: *Renderer, gpa: std.mem.Allocator) !void {
    const families = try r.physical_device.getPhysicalDeviceQueueFamilyProperties(gpa);
    defer gpa.free(families);
    for (families, 0..) |f, i| {
        const idx: u32 = @intCast(i);
        if (!f.queue_flags.graphics) continue;
        const presentable = try r.physical_device.getPhysicalDeviceSurfaceSupportKHR(idx, r.surface);
        if (presentable == 0) continue;
        r.queue_family_index = idx;
        return;
    }
    return error.NoCompatibleQueueFamily;
}

fn createLogicalDevice(r: *Renderer) !void {
    const priorities: [1]f32 = .{1.0};
    const queue_ci: vk.DeviceQueueCreateInfo = .{
        .flags = .empty,
        .queue_family_index = r.queue_family_index,
        .queue_count = 1,
        .p_queue_priorities = @ptrCast(&priorities),
    };
    const exts = [_][*:0]const u8{"VK_KHR_swapchain"};
    const features: vk.PhysicalDeviceFeatures = std.mem.zeroes(vk.PhysicalDeviceFeatures);
    const ci: vk.DeviceCreateInfo = .{
        .flags = .empty,
        .queue_create_info_count = 1,
        .p_queue_create_infos = &queue_ci,
        .enabled_layer_count = 0,
        .pp_enabled_layer_names = undefined,
        .enabled_extension_count = exts.len,
        .pp_enabled_extension_names = &exts,
        .p_enabled_features = &features,
    };
    r.device = try r.physical_device.createDevice(&ci, null);
}

fn createSwapchainAndViews(r: *Renderer, gpa: std.mem.Allocator, old_swapchain: vk.SwapchainKHR) !void {
    const caps = try r.physical_device.getPhysicalDeviceSurfaceCapabilitiesKHR(r.surface);
    const formats = try r.physical_device.getPhysicalDeviceSurfaceFormatsKHR(r.surface, gpa);
    defer gpa.free(formats);

    var chosen: ?vk.SurfaceFormatKHR = null;
    for (formats) |f| {
        if (f.format == .b8g8r8a8_unorm or f.format == .b8g8r8a8_srgb) {
            if (chosen == null or f.format == .b8g8r8a8_unorm) chosen = f;
        }
    }
    const fmt = chosen orelse return error.NoCompatibleSurfaceFormat;

    var min_image_count: u32 = caps.min_image_count + 1;
    if (caps.max_image_count > 0 and min_image_count > caps.max_image_count) {
        min_image_count = caps.max_image_count;
    }

    const sentinel: u32 = 0xFFFFFFFF;
    const extent: vk.Extent2D = blk: {
        if (caps.current_extent.width != sentinel and caps.current_extent.height != sentinel) {
            break :blk caps.current_extent;
        }
        const w = std.math.clamp(r.last_known_size.width, caps.min_image_extent.width, caps.max_image_extent.width);
        const h = std.math.clamp(r.last_known_size.height, caps.min_image_extent.height, caps.max_image_extent.height);
        break :blk .{ .width = w, .height = h };
    };
    r.swapchain_extent = extent;
    r.swapchain_format = fmt.format;

    const composite_alpha = pickCompositeAlpha(caps.supported_composite_alpha) orelse return error.NoCompatibleCompositeAlpha;
    const ci: vk.SwapchainCreateInfoKHR = .{
        .flags = .empty,
        .surface = r.surface,
        .min_image_count = min_image_count,
        .image_format = fmt.format,
        .image_color_space = fmt.color_space,
        .image_extent = extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment = true },
        .image_sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
        .pre_transform = caps.current_transform,
        .composite_alpha = composite_alpha,
        .present_mode = .fifo,
        .clipped = 1,
        .old_swapchain = old_swapchain,
    };
    r.swapchain = try r.device.createSwapchainKHR(&ci, null);

    const images = try r.device.getSwapchainImagesKHR(r.swapchain, gpa);
    r.swapchain_images = images;

    const views = try gpa.alloc(vk.ImageView, images.len);
    errdefer gpa.free(views);
    for (images, 0..) |img, i| {
        const view_ci: vk.ImageViewCreateInfo = .{
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
        views[i] = try r.device.createImageView(&view_ci, null);
    }
    r.swapchain_views = views;
}

fn pickCompositeAlpha(supported: vk.CompositeAlphaFlagsKHR) ?vk.CompositeAlphaFlagBitsKHR {
    if (supported.@"opaque") return .opaque_bit;
    if (supported.inherit) return .inherit_bit;
    if (supported.pre_multiplied) return .pre_multiplied_bit;
    if (supported.post_multiplied) return .post_multiplied_bit;
    return null;
}

fn destroySwapchainResources(r: *Renderer) void {
    for (r.framebuffers) |fb| r.device.destroyFramebuffer(fb, null);
    if (r.framebuffers.len != 0) r.gpa.free(r.framebuffers);
    r.framebuffers = &.{};
    for (r.swapchain_views) |v| r.device.destroyImageView(v, null);
    if (r.swapchain_views.len != 0) r.gpa.free(r.swapchain_views);
    r.swapchain_views = &.{};
    if (r.swapchain_images.len != 0) r.gpa.free(r.swapchain_images);
    r.swapchain_images = &.{};
    if (r.swapchain != .null) r.device.destroySwapchainKHR(r.swapchain, null);
    r.swapchain = .null;
}

fn createRenderPass(r: *Renderer) !void {
    const color_attachment: vk.AttachmentDescription = .{
        .flags = .empty,
        .format = r.swapchain_format,
        .samples = ._1_bit,
        .load_op = .clear,
        .store_op = .store,
        .stencil_load_op = .dont_care,
        .stencil_store_op = .dont_care,
        .initial_layout = .undefined,
        .final_layout = .present_src_khr,
    };
    const color_ref: vk.AttachmentReference = .{ .attachment = 0, .layout = .color_attachment_optimal };
    const subpass: vk.SubpassDescription = .{
        .flags = .empty,
        .pipeline_bind_point = .graphics,
        // Non-optional `*const T` fields can stay `undefined` when
        // their count is 0 — Vulkan never dereferences them. Optional
        // `?*const T` fields MUST be explicit `null` so the Zig
        // optional encodes a known nullptr value rather than stack
        // garbage; the NVIDIA driver dereferences
        // `p_resolve_attachments` before checking the colour count,
        // and any non-null garbage value SIGSEGVs inside
        // `libnvidia-eglcore.so` (verified on Fedora 41 + 595.71.05).
        .input_attachment_count = 0,
        .p_input_attachments = undefined,
        .color_attachment_count = 1,
        .p_color_attachments = @ptrCast(&color_ref),
        .p_resolve_attachments = null,
        .p_depth_stencil_attachment = null,
        .preserve_attachment_count = 0,
        .p_preserve_attachments = undefined,
    };
    const dep: vk.SubpassDependency = .{
        .src_subpass = vk.SUBPASS_EXTERNAL,
        .dst_subpass = 0,
        .src_stage_mask = .{ .color_attachment_output = true },
        .dst_stage_mask = .{ .color_attachment_output = true },
        .src_access_mask = .empty,
        .dst_access_mask = .{ .color_attachment_write = true },
        .dependency_flags = .empty,
    };
    const ci: vk.RenderPassCreateInfo = .{
        .flags = .empty,
        .attachment_count = 1,
        .p_attachments = @ptrCast(&color_attachment),
        .subpass_count = 1,
        .p_subpasses = @ptrCast(&subpass),
        .dependency_count = 1,
        .p_dependencies = @ptrCast(&dep),
    };
    r.render_pass = try r.device.createRenderPass(&ci, null);
}

fn createViewportImage(r: *Renderer) !void {
    const ci: vk.ImageCreateInfo = .{
        .flags = .empty,
        .image_type = ._2d,
        .format = .r8g8b8a8_unorm,
        .extent = .{
            .width = viewport_mod.default_resolution.width,
            .height = viewport_mod.default_resolution.height,
            .depth = 1,
        },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = ._1_bit,
        .tiling = .optimal,
        .usage = .{ .sampled = true, .transfer_dst = true },
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
        .initial_layout = .undefined,
    };
    r.viewport_image = try r.device.createImage(&ci, null);

    const reqs = r.device.getImageMemoryRequirements(r.viewport_image);
    const mem_props = r.physical_device.getPhysicalDeviceMemoryProperties();
    const ti = pickMemoryType(mem_props, reqs.memory_type_bits, .{ .device_local = true }) orelse return error.NoCompatibleDevice;
    const ai: vk.MemoryAllocateInfo = .{ .allocation_size = reqs.size, .memory_type_index = ti };
    r.viewport_image_memory = try r.device.allocateMemory(&ai, null);
    try r.device.bindImageMemory(r.viewport_image, r.viewport_image_memory, 0);

    const view_ci: vk.ImageViewCreateInfo = .{
        .flags = .empty,
        .image = r.viewport_image,
        .view_type = ._2d,
        .format = .r8g8b8a8_unorm,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = .{
            .aspect_mask = .{ .color = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };
    r.viewport_image_view = try r.device.createImageView(&view_ci, null);
}

fn destroyViewportImage(r: *Renderer) void {
    if (r.viewport_image_view != .null) r.device.destroyImageView(r.viewport_image_view, null);
    r.viewport_image_view = .null;
    if (r.viewport_image != .null) r.device.destroyImage(r.viewport_image, null);
    r.viewport_image = .null;
    if (r.viewport_image_memory != .null) r.device.freeMemory(r.viewport_image_memory, null);
    r.viewport_image_memory = .null;
}

fn createSampler(r: *Renderer) !void {
    const ci: vk.SamplerCreateInfo = .{
        .flags = .empty,
        .mag_filter = .linear,
        .min_filter = .linear,
        .mipmap_mode = .nearest,
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .address_mode_w = .clamp_to_edge,
        .mip_lod_bias = 0,
        .anisotropy_enable = 0,
        .max_anisotropy = 1,
        .compare_enable = 0,
        .compare_op = .never,
        .min_lod = 0,
        .max_lod = 0,
        .border_color = .float_opaque_black,
        .unnormalized_coordinates = 0,
    };
    r.viewport_sampler = try r.device.createSampler(&ci, null);
}

fn createStagingBuffer(r: *Renderer) !void {
    const w = viewport_mod.default_resolution.width;
    const h = viewport_mod.default_resolution.height;
    const size: vk.DeviceSize = @as(vk.DeviceSize, w) * h * 4;

    var usage: vk.BufferUsageFlags = .empty;
    usage.transfer_src = true;
    const bci: vk.BufferCreateInfo = .{
        .flags = .empty,
        .size = size,
        .usage = usage,
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
    };
    r.staging_buffer = try r.device.createBuffer(&bci, null);
    const reqs = r.device.getBufferMemoryRequirements(r.staging_buffer);
    const mem_props = r.physical_device.getPhysicalDeviceMemoryProperties();
    const ti = pickMemoryType(mem_props, reqs.memory_type_bits, .{ .host_visible = true, .host_coherent = true }) orelse return error.NoCompatibleDevice;
    const ai: vk.MemoryAllocateInfo = .{ .allocation_size = reqs.size, .memory_type_index = ti };
    r.staging_memory = try r.device.allocateMemory(&ai, null);
    try r.device.bindBufferMemory(r.staging_buffer, r.staging_memory, 0);

    const mapped = (try r.device.mapMemory(r.staging_memory, 0, size, .empty)) orelse return error.MemoryMapFailed;
    r.staging_mapped = @ptrCast(mapped);
}

fn destroyStagingBuffer(r: *Renderer) void {
    if (r.staging_memory != .null) {
        r.device.unmapMemory(r.staging_memory);
        r.staging_mapped = null;
    }
    if (r.staging_buffer != .null) r.device.destroyBuffer(r.staging_buffer, null);
    r.staging_buffer = .null;
    if (r.staging_memory != .null) r.device.freeMemory(r.staging_memory, null);
    r.staging_memory = .null;
}

fn createDescriptorResources(r: *Renderer) !void {
    const binding: vk.DescriptorSetLayoutBinding = .{
        .binding = 0,
        .descriptor_type = .combined_image_sampler,
        .descriptor_count = 1,
        .stage_flags = .{ .fragment = true },
        .p_immutable_samplers = null,
    };
    const layout_ci: vk.DescriptorSetLayoutCreateInfo = .{
        .flags = .empty,
        .binding_count = 1,
        .p_bindings = @ptrCast(&binding),
    };
    r.descriptor_set_layout = try r.device.createDescriptorSetLayout(&layout_ci, null);

    const pool_size: vk.DescriptorPoolSize = .{
        .type = .combined_image_sampler,
        .descriptor_count = 1,
    };
    const pool_ci: vk.DescriptorPoolCreateInfo = .{
        .flags = .empty,
        .max_sets = 1,
        .pool_size_count = 1,
        .p_pool_sizes = @ptrCast(&pool_size),
    };
    r.descriptor_pool = try r.device.createDescriptorPool(&pool_ci, null);

    const alloc_ci: vk.DescriptorSetAllocateInfo = .{
        .descriptor_pool = r.descriptor_pool,
        .descriptor_set_count = 1,
        .p_set_layouts = @ptrCast(&r.descriptor_set_layout),
    };
    var sets: [1]vk.DescriptorSet = .{.null};
    try r.device.allocateDescriptorSets(&alloc_ci, &sets);
    r.descriptor_set = sets[0];

    const image_info: vk.DescriptorImageInfo = .{
        .sampler = r.viewport_sampler,
        .image_view = r.viewport_image_view,
        .image_layout = .shader_read_only_optimal,
    };
    const write: vk.WriteDescriptorSet = .{
        .dst_set = r.descriptor_set,
        .dst_binding = 0,
        .dst_array_element = 0,
        .descriptor_count = 1,
        .descriptor_type = .combined_image_sampler,
        .p_image_info = @ptrCast(&image_info),
        .p_buffer_info = undefined,
        .p_texel_buffer_view = undefined,
    };
    r.device.updateDescriptorSets(&.{write}, &.{});
}

fn destroyDescriptorResources(r: *Renderer) void {
    if (r.descriptor_pool != .null) r.device.destroyDescriptorPool(r.descriptor_pool, null);
    r.descriptor_pool = .null;
    if (r.descriptor_set_layout != .null) r.device.destroyDescriptorSetLayout(r.descriptor_set_layout, null);
    r.descriptor_set_layout = .null;
}

fn createBlitPipeline(r: *Renderer) !void {
    if (blit_vert_spv.len < 16 or blit_frag_spv.len < 16) return error.ShaderModuleCreateFailed;

    const vci: vk.ShaderModuleCreateInfo = .{
        .flags = .empty,
        .code_size = blit_vert_spv.len,
        .p_code = @ptrCast(@alignCast(blit_vert_spv.ptr)),
    };
    r.vert_module = try r.device.createShaderModule(&vci, null);
    const fci: vk.ShaderModuleCreateInfo = .{
        .flags = .empty,
        .code_size = blit_frag_spv.len,
        .p_code = @ptrCast(@alignCast(blit_frag_spv.ptr)),
    };
    r.frag_module = try r.device.createShaderModule(&fci, null);

    const stages = [_]vk.PipelineShaderStageCreateInfo{
        .{
            .flags = .empty,
            .stage = .vertex_bit,
            .module = r.vert_module,
            .p_name = "main",
            .p_specialization_info = null,
        },
        .{
            .flags = .empty,
            .stage = .fragment_bit,
            .module = r.frag_module,
            .p_name = "main",
            .p_specialization_info = null,
        },
    };

    // No vertex input — the vertex shader builds the fullscreen
    // triangle from `gl_VertexIndex`.
    const vi: vk.PipelineVertexInputStateCreateInfo = .{
        .flags = .empty,
        .vertex_binding_description_count = 0,
        .p_vertex_binding_descriptions = undefined,
        .vertex_attribute_description_count = 0,
        .p_vertex_attribute_descriptions = undefined,
    };
    const ia: vk.PipelineInputAssemblyStateCreateInfo = .{
        .flags = .empty,
        .topology = .triangle_list,
        .primitive_restart_enable = 0,
    };
    const viewport: vk.Viewport = .{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(r.swapchain_extent.width),
        .height = @floatFromInt(r.swapchain_extent.height),
        .min_depth = 0,
        .max_depth = 1,
    };
    const scissor: vk.Rect2D = .{ .offset = .{ .x = 0, .y = 0 }, .extent = r.swapchain_extent };
    const vp: vk.PipelineViewportStateCreateInfo = .{
        .flags = .empty,
        .viewport_count = 1,
        .p_viewports = @ptrCast(&viewport),
        .scissor_count = 1,
        .p_scissors = @ptrCast(&scissor),
    };
    const dyn = [_]vk.DynamicState{ .viewport, .scissor };
    const dyn_state: vk.PipelineDynamicStateCreateInfo = .{
        .flags = .empty,
        .dynamic_state_count = dyn.len,
        .p_dynamic_states = @ptrCast(&dyn),
    };
    const rs: vk.PipelineRasterizationStateCreateInfo = .{
        .flags = .empty,
        .depth_clamp_enable = 0,
        .rasterizer_discard_enable = 0,
        .polygon_mode = .fill,
        .cull_mode = .empty,
        .front_face = .counter_clockwise,
        .depth_bias_enable = 0,
        .depth_bias_constant_factor = 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
        .line_width = 1.0,
    };
    const ms: vk.PipelineMultisampleStateCreateInfo = .{
        .flags = .empty,
        .rasterization_samples = ._1_bit,
        .sample_shading_enable = 0,
        .min_sample_shading = 0,
        .p_sample_mask = null,
        .alpha_to_coverage_enable = 0,
        .alpha_to_one_enable = 0,
    };
    const blend_attachment: vk.PipelineColorBlendAttachmentState = .{
        .blend_enable = 0,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
        .color_write_mask = .{ .r = true, .g = true, .b = true, .a = true },
    };
    const cb: vk.PipelineColorBlendStateCreateInfo = .{
        .flags = .empty,
        .logic_op_enable = 0,
        .logic_op = .copy,
        .attachment_count = 1,
        .p_attachments = @ptrCast(&blend_attachment),
        .blend_constants = .{ 0, 0, 0, 0 },
    };
    const layout_ci: vk.PipelineLayoutCreateInfo = .{
        .flags = .empty,
        .set_layout_count = 1,
        .p_set_layouts = @ptrCast(&r.descriptor_set_layout),
        .push_constant_range_count = 0,
        .p_push_constant_ranges = undefined,
    };
    r.pipeline_layout = try r.device.createPipelineLayout(&layout_ci, null);

    const pipe_ci = [_]vk.GraphicsPipelineCreateInfo{
        .{
            .flags = .empty,
            .stage_count = stages.len,
            .p_stages = @ptrCast(&stages),
            .p_vertex_input_state = &vi,
            .p_input_assembly_state = &ia,
            .p_tessellation_state = null,
            .p_viewport_state = &vp,
            .p_rasterization_state = &rs,
            .p_multisample_state = &ms,
            .p_depth_stencil_state = null,
            .p_color_blend_state = &cb,
            .p_dynamic_state = &dyn_state,
            .layout = r.pipeline_layout,
            .render_pass = r.render_pass,
            .subpass = 0,
            .base_pipeline_handle = .null,
            .base_pipeline_index = -1,
        },
    };
    var pipes: [1]vk.Pipeline = .{.null};
    try r.device.createGraphicsPipelines(.null, &pipe_ci, null, &pipes);
    r.pipeline = pipes[0];
}

fn destroyPipelineResources(r: *Renderer) void {
    if (r.pipeline != .null) r.device.destroyPipeline(r.pipeline, null);
    r.pipeline = .null;
    if (r.pipeline_layout != .null) r.device.destroyPipelineLayout(r.pipeline_layout, null);
    r.pipeline_layout = .null;
    if (r.frag_module != .null) r.device.destroyShaderModule(r.frag_module, null);
    r.frag_module = .null;
    if (r.vert_module != .null) r.device.destroyShaderModule(r.vert_module, null);
    r.vert_module = .null;
}

fn createFramebuffers(r: *Renderer, gpa: std.mem.Allocator) !void {
    const fbs = try gpa.alloc(vk.Framebuffer, r.swapchain_views.len);
    errdefer gpa.free(fbs);
    for (r.swapchain_views, 0..) |v, i| {
        const ci: vk.FramebufferCreateInfo = .{
            .flags = .empty,
            .render_pass = r.render_pass,
            .attachment_count = 1,
            .p_attachments = @ptrCast(&v),
            .width = r.swapchain_extent.width,
            .height = r.swapchain_extent.height,
            .layers = 1,
        };
        fbs[i] = try r.device.createFramebuffer(&ci, null);
    }
    r.framebuffers = fbs;
}

fn createSyncObjects(r: *Renderer) !void {
    const pool_ci: vk.CommandPoolCreateInfo = .{
        .flags = .{ .reset_command_buffer = true },
        .queue_family_index = r.queue_family_index,
    };
    r.command_pool = try r.device.createCommandPool(&pool_ci, null);

    const alloc_ci: vk.CommandBufferAllocateInfo = .{
        .command_pool = r.command_pool,
        .level = .primary,
        .command_buffer_count = max_frames_in_flight,
    };
    try r.device.allocateCommandBuffers(&alloc_ci, &r.command_buffers);

    const sem_ci: vk.SemaphoreCreateInfo = .{ .flags = .empty };
    const fence_ci: vk.FenceCreateInfo = .{ .flags = .{ .signaled = true } };
    for (0..max_frames_in_flight) |i| {
        r.image_available[i] = try r.device.createSemaphore(&sem_ci, null);
        r.render_finished[i] = try r.device.createSemaphore(&sem_ci, null);
        r.in_flight[i] = try r.device.createFence(&fence_ci, null);
    }
}

fn pickMemoryType(props: vk.PhysicalDeviceMemoryProperties, type_bits: u32, want: vk.MemoryPropertyFlags) ?u32 {
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

/// One swapchain frame. Records the staging→image copy + layout
/// transitions + render pass + blit draw. Returns `false` if the
/// swapchain went out-of-date and a recreate is needed.
pub fn drawFrame(r: *Renderer) vk.Error!bool {
    const cur = r.current_frame;
    try r.device.waitForFences(&.{r.in_flight[cur]}, 1, std.math.maxInt(u64));

    // Use the raw dispatch for `vkAcquireNextImageKHR` so we can
    // see `suboptimal_khr` and `error_out_of_date_khr` directly
    // — the wrapped Device method folds suboptimal into success.
    var img_index: u32 = 0;
    const acquire_result = vk.device_dispatch.vkAcquireNextImageKHR(
        r.device,
        r.swapchain,
        std.math.maxInt(u64),
        r.image_available[cur],
        .null,
        &img_index,
    );
    switch (acquire_result) {
        .success => {},
        .suboptimal_khr => r.swapchain_dirty = true,
        .error_out_of_date_khr => {
            r.swapchain_dirty = true;
            return false;
        },
        else => try vk.checkResult(acquire_result),
    }

    try r.device.resetFences(&.{r.in_flight[cur]});

    const cb = r.command_buffers[cur];
    try cb.resetCommandBuffer(.empty);
    const begin: vk.CommandBufferBeginInfo = .{ .flags = .empty, .p_inheritance_info = null };
    try cb.beginCommandBuffer(&begin);

    // Transition viewport image to TRANSFER_DST_OPTIMAL.
    const src_layout: vk.ImageLayout = if (r.image_undefined) .undefined else .shader_read_only_optimal;
    const src_access: vk.AccessFlags = if (r.image_undefined) .empty else .{ .shader_read = true };
    const src_stage: vk.PipelineStageFlags = if (r.image_undefined) .{ .top_of_pipe = true } else .{ .fragment_shader = true };
    const to_dst: vk.ImageMemoryBarrier = .{
        .src_access_mask = src_access,
        .dst_access_mask = .{ .transfer_write = true },
        .old_layout = src_layout,
        .new_layout = .transfer_dst_optimal,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = r.viewport_image,
        .subresource_range = .{
            .aspect_mask = .{ .color = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };
    cb.cmdPipelineBarrier(
        src_stage,
        .{ .transfer = true },
        .empty,
        &.{},
        &.{},
        &.{to_dst},
    );

    // Copy staging buffer → viewport image.
    const copy: vk.BufferImageCopy = .{
        .buffer_offset = 0,
        .buffer_row_length = 0,
        .buffer_image_height = 0,
        .image_subresource = .{
            .aspect_mask = .{ .color = true },
            .mip_level = 0,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .image_offset = .{ .x = 0, .y = 0, .z = 0 },
        .image_extent = .{
            .width = viewport_mod.default_resolution.width,
            .height = viewport_mod.default_resolution.height,
            .depth = 1,
        },
    };
    cb.cmdCopyBufferToImage(
        r.staging_buffer,
        r.viewport_image,
        .transfer_dst_optimal,
        &.{copy},
    );

    // Transition viewport image to SHADER_READ_ONLY_OPTIMAL.
    const to_shader: vk.ImageMemoryBarrier = .{
        .src_access_mask = .{ .transfer_write = true },
        .dst_access_mask = .{ .shader_read = true },
        .old_layout = .transfer_dst_optimal,
        .new_layout = .shader_read_only_optimal,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = r.viewport_image,
        .subresource_range = .{
            .aspect_mask = .{ .color = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };
    cb.cmdPipelineBarrier(
        .{ .transfer = true },
        .{ .fragment_shader = true },
        .empty,
        &.{},
        &.{},
        &.{to_shader},
    );
    r.image_undefined = false;

    // Render pass.
    const clear: vk.ClearValue = .{ .color = .{ .float32 = .{ 0, 0, 0, 1 } } };
    const rp_begin: vk.RenderPassBeginInfo = .{
        .render_pass = r.render_pass,
        .framebuffer = r.framebuffers[img_index],
        .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = r.swapchain_extent },
        .clear_value_count = 1,
        .p_clear_values = @ptrCast(&clear),
    };
    cb.cmdBeginRenderPass(&rp_begin, .@"inline");
    cb.cmdBindPipeline(.graphics, r.pipeline);
    const vp_dyn: vk.Viewport = .{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(r.swapchain_extent.width),
        .height = @floatFromInt(r.swapchain_extent.height),
        .min_depth = 0,
        .max_depth = 1,
    };
    cb.cmdSetViewport(0, &.{vp_dyn});
    const sc_dyn: vk.Rect2D = .{ .offset = .{ .x = 0, .y = 0 }, .extent = r.swapchain_extent };
    cb.cmdSetScissor(0, &.{sc_dyn});
    cb.cmdBindDescriptorSets(
        .graphics,
        r.pipeline_layout,
        0,
        &.{r.descriptor_set},
        &.{},
    );
    cb.cmdDraw(3, 1, 0, 0);
    cb.cmdEndRenderPass();

    try cb.endCommandBuffer();

    const wait_stages = [_]vk.PipelineStageFlags{.{ .color_attachment_output = true }};
    const submit: vk.SubmitInfo = .{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @ptrCast(&r.image_available[cur]),
        .p_wait_dst_stage_mask = @ptrCast(&wait_stages),
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&r.command_buffers[cur]),
        .signal_semaphore_count = 1,
        .p_signal_semaphores = @ptrCast(&r.render_finished[cur]),
    };
    try r.queue.submit(&.{submit}, r.in_flight[cur]);

    var per_swapchain_result: vk.Result = .success;
    const present: vk.PresentInfoKHR = .{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @ptrCast(&r.render_finished[cur]),
        .swapchain_count = 1,
        .p_swapchains = @ptrCast(&r.swapchain),
        .p_image_indices = @ptrCast(&img_index),
        .p_results = @ptrCast(&per_swapchain_result),
    };
    const present_call = vk.device_dispatch.vkQueuePresentKHR(r.queue, &present);
    switch (present_call) {
        .success => {},
        .suboptimal_khr => r.swapchain_dirty = true,
        .error_out_of_date_khr => {
            r.swapchain_dirty = true;
            return false;
        },
        else => try vk.checkResult(present_call),
    }

    r.current_frame = (cur + 1) % max_frames_in_flight;
    return true;
}
