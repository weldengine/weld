//! Vulkan setup for the S2 spike triangle. Throwaway with the rest of
//! `src/spike/`. Refactored in Phase 0.4 once the GAL is designed.
//!
//! `Renderer.init` walks the canonical Vulkan boot sequence — instance
//! creation, optional debug-utils + validation layer hookup, surface
//! creation via the OS-specific extension, physical-device selection
//! using `scoring.scoreDevice` (with `--gpu-prefer` override), logical
//! device + single graphics/present queue, swapchain in FIFO mode with
//! 2 images, render pass + graphics pipeline + framebuffers, vertex
//! buffer (device-local, populated via a staging buffer), command pool +
//! per-frame command buffers, and the per-frame semaphores + fences.
//!
//! Per-frame logic lives in `vk_frame.zig`.

const std = @import("std");
const builtin = @import("builtin");
const weld_core = @import("weld_core");
const vk = weld_core.platform.vk;
const window_mod = weld_core.platform.window;
const cli = @import("cli.zig");
const scoring = @import("scoring.zig");

/// Vsync-on path; both PCs in the validation matrix support FIFO.
const present_mode_preference: vk.PresentModeKHR = .fifo;

/// 2 frames in flight per the brief. Bigger numbers reduce CPU stalling
/// at the cost of input latency; 2 is the sweet spot for the spike.
pub const max_frames_in_flight: u32 = 2;

/// Vertex layout for the triangle. `extern struct` so the C ABI matches
/// what the vertex input descriptor declares.
pub const Vertex = extern struct {
    pos: [2]f32,
    color: [3]f32,
};

const triangle = [_]Vertex{
    .{ .pos = .{ 0.0, -0.5 }, .color = .{ 1.0, 0.0, 0.0 } }, // top — red
    .{ .pos = .{ 0.5, 0.5 }, .color = .{ 0.0, 1.0, 0.0 } }, // bottom-right — green
    .{ .pos = .{ -0.5, 0.5 }, .color = .{ 0.0, 0.0, 1.0 } }, // bottom-left — blue
};

const shaders = @import("shaders");
const triangle_vert_spv = shaders.triangle_vert_spv;
const triangle_frag_spv = shaders.triangle_frag_spv;

pub const SetupError = error{
    LoaderUnavailable,
    InstanceUnavailable,
    NoCompatibleDevice,
    NoCompatibleQueueFamily,
    NoCompatibleSurfaceFormat,
    SurfaceCreateFailed,
    SwapchainCreateFailed,
    ShaderModuleCreateFailed,
    PipelineCreateFailed,
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

    physical_device_name: [256]u8 = undefined,

    swapchain: vk.SwapchainKHR = .null,
    swapchain_format: vk.Format = .undefined,
    swapchain_extent: vk.Extent2D = .{ .width = 0, .height = 0 },
    swapchain_images: []vk.Image = &.{},
    swapchain_views: []vk.ImageView = &.{},
    framebuffers: []vk.Framebuffer = &.{},

    render_pass: vk.RenderPass = .null,
    pipeline_layout: vk.PipelineLayout = .null,
    pipeline: vk.Pipeline = .null,
    vert_module: vk.ShaderModule = .null,
    frag_module: vk.ShaderModule = .null,

    vertex_buffer: vk.Buffer = .null,
    vertex_memory: vk.DeviceMemory = .null,

    command_pool: vk.CommandPool = .null,
    command_buffers: [max_frames_in_flight]*vk.CommandBuffer = undefined,
    image_available: [max_frames_in_flight]vk.Semaphore = .{ .null, .null },
    render_finished: [max_frames_in_flight]vk.Semaphore = .{ .null, .null },
    in_flight: [max_frames_in_flight]vk.Fence = .{ .null, .null },
    current_frame: u32 = 0,

    /// Tracks the largest VkResult deviation from `.success` returned by
    /// `acquireNextImageKHR` or `queuePresentKHR`. The render loop reads
    /// it to decide when to recreate the swapchain.
    swapchain_dirty: bool = false,

    pub fn init(
        gpa: std.mem.Allocator,
        window: *window_mod.Window,
        args: cli.Args,
    ) SetupError!Renderer {
        try vk.loadLoader();
        // After loadLoader returns, base dispatch is populated. Now create
        // the instance, then load instance-level functions, then create
        // the device + load device-level functions.

        var r: Renderer = .{
            .gpa = gpa,
            .instance = undefined,
            .physical_device = undefined,
            .device = undefined,
            .surface = .null,
            .queue = undefined,
            .queue_family_index = 0,
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

        try pickPhysicalDevice(&r, gpa, args);

        try createLogicalDevice(&r, gpa);
        errdefer r.device.destroyDevice(null);
        try vk.loadDevice(r.device);

        r.queue = r.device.getDeviceQueue(r.queue_family_index, 0);

        try createSwapchainAndViews(&r, gpa, window);
        errdefer destroySwapchainResources(&r);

        try createRenderPass(&r);
        errdefer r.device.destroyRenderPass(r.render_pass, null);

        try createGraphicsPipeline(&r);
        errdefer destroyPipelineResources(&r);

        try createFramebuffers(&r, gpa);

        try createVertexBuffer(&r);
        errdefer {
            r.device.destroyBuffer(r.vertex_buffer, null);
            r.device.freeMemory(r.vertex_memory, null);
        }

        try createSyncObjects(&r);

        return r;
    }

    pub fn deinit(self: *Renderer) void {
        // Wait for all GPU work before tearing down.
        self.device.waitIdle() catch {};

        for (0..max_frames_in_flight) |i| {
            if (self.in_flight[i] != .null) self.device.destroyFence(self.in_flight[i], null);
            if (self.image_available[i] != .null) self.device.destroySemaphore(self.image_available[i], null);
            if (self.render_finished[i] != .null) self.device.destroySemaphore(self.render_finished[i], null);
        }
        if (self.command_pool != .null) self.device.destroyCommandPool(self.command_pool, null);

        if (self.vertex_buffer != .null) self.device.destroyBuffer(self.vertex_buffer, null);
        if (self.vertex_memory != .null) self.device.freeMemory(self.vertex_memory, null);

        destroyPipelineResources(self);
        if (self.render_pass != .null) self.device.destroyRenderPass(self.render_pass, null);

        destroySwapchainResources(self);

        self.device.destroyDevice(null);
        if (self.debug_messenger) |m| self.instance.destroyDebugUtilsMessengerEXT(m, null);
        self.instance.destroySurfaceKHR(self.surface, null);
        self.instance.destroyInstance(null);
    }

    pub fn recreateSwapchain(self: *Renderer, window: *window_mod.Window) SetupError!void {
        self.device.waitIdle() catch {};
        // Tear down the old swapchain-dependent resources.
        for (self.framebuffers) |fb| self.device.destroyFramebuffer(fb, null);
        self.gpa.free(self.framebuffers);
        self.framebuffers = &.{};
        for (self.swapchain_views) |v| self.device.destroyImageView(v, null);
        self.gpa.free(self.swapchain_views);
        self.swapchain_views = &.{};
        self.gpa.free(self.swapchain_images);
        self.swapchain_images = &.{};
        const old_swapchain = self.swapchain;

        try createSwapchainAndViews(self, self.gpa, window);
        if (old_swapchain != .null) self.device.destroySwapchainKHR(old_swapchain, null);
        try createFramebuffers(self, self.gpa);
        self.swapchain_dirty = false;
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
        if (has_validation) {
            enabled_layers = layers_debug[0..];
        } else {
            std.log.scoped(.s2).warn("VK_LAYER_KHRONOS_validation not installed; continuing without validation", .{});
        }
    }

    var ext_buf: std.ArrayList([*:0]const u8) = .empty;
    defer ext_buf.deinit(gpa);
    try ext_buf.append(gpa, "VK_KHR_surface");
    switch (builtin.os.tag) {
        .linux => try ext_buf.append(gpa, "VK_KHR_wayland_surface"),
        .windows => try ext_buf.append(gpa, "VK_KHR_win32_surface"),
        else => return error.UnsupportedHostPlatform,
    }
    if (builtin.mode == .Debug) try ext_buf.append(gpa, "VK_EXT_debug_utils");

    const app_info: vk.ApplicationInfo = .{
        .p_application_name = "Weld S2",
        .application_version = 1,
        .p_engine_name = "Weld",
        .engine_version = 1,
        .api_version = (@as(u32, 1) << 22) | (@as(u32, 3) << 12), // Vulkan 1.3
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
        if (d.p_message) |msg| {
            std.log.scoped(.s2).warn("vk: {s}", .{msg});
        }
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

fn pickPhysicalDevice(r: *Renderer, gpa: std.mem.Allocator, args: cli.Args) !void {
    const devices = try r.instance.enumeratePhysicalDevices(gpa);
    defer gpa.free(devices);
    if (devices.len == 0) return error.NoCompatibleDevice;

    // Direct index override.
    if (args.gpu_prefer) |hint| switch (hint) {
        .index => |i| {
            if (i >= devices.len) return error.NoCompatibleDevice;
            r.physical_device = devices[i];
            try recordDeviceName(r);
            try findGraphicsQueueFamily(r, gpa);
            return;
        },
        else => {},
    };

    var best: ?*vk.PhysicalDevice = null;
    var best_score: i32 = -1;
    for (devices) |pd| {
        const props = pd.getPhysicalDeviceProperties();
        const dt: scoring.DeviceType = switch (@intFromEnum(props.device_type)) {
            0 => .other,
            1 => .integrated_gpu,
            2 => .discrete_gpu,
            3 => .virtual_gpu,
            4 => .cpu,
            else => .other,
        };
        const s = scoring.scoreDevice(.{ .device_type = dt }, args.gpu_prefer);
        if (s > best_score) {
            best = pd;
            best_score = s;
        }
    }
    r.physical_device = best orelse return error.NoCompatibleDevice;
    try recordDeviceName(r);
    try findGraphicsQueueFamily(r, gpa);
}

fn recordDeviceName(r: *Renderer) !void {
    const props = r.physical_device.getPhysicalDeviceProperties();
    @memcpy(&r.physical_device_name, &props.device_name);
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

fn createLogicalDevice(r: *Renderer, gpa: std.mem.Allocator) !void {
    _ = gpa;
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

fn createSwapchainAndViews(r: *Renderer, gpa: std.mem.Allocator, window: *window_mod.Window) !void {
    _ = window;
    const caps = try r.physical_device.getPhysicalDeviceSurfaceCapabilitiesKHR(r.surface);
    const formats = try r.physical_device.getPhysicalDeviceSurfaceFormatsKHR(r.surface, gpa);
    defer gpa.free(formats);

    // Pick a B8G8R8A8 (UNORM preferred, _SRGB acceptable) format.
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

    const extent = caps.current_extent;
    r.swapchain_extent = extent;
    r.swapchain_format = fmt.format;

    var image_usage: vk.ImageUsageFlags = .empty;
    image_usage.color_attachment = true;
    image_usage.transfer_src = true;

    const ci: vk.SwapchainCreateInfoKHR = .{
        .flags = .empty,
        .surface = r.surface,
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
        .composite_alpha = .opaque_bit,
        .present_mode = present_mode_preference,
        .clipped = 1,
        .old_swapchain = .null,
    };
    r.swapchain = try r.device.createSwapchainKHR(&ci, null);

    r.swapchain_images = try r.device.getSwapchainImagesKHR(r.swapchain, gpa);

    const views = try gpa.alloc(vk.ImageView, r.swapchain_images.len);
    errdefer gpa.free(views);
    for (r.swapchain_images, 0..) |img, i| {
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

fn destroySwapchainResources(r: *Renderer) void {
    for (r.framebuffers) |fb| if (fb != .null) r.device.destroyFramebuffer(fb, null);
    if (r.framebuffers.len > 0) r.gpa.free(r.framebuffers);
    r.framebuffers = &.{};
    for (r.swapchain_views) |v| if (v != .null) r.device.destroyImageView(v, null);
    if (r.swapchain_views.len > 0) r.gpa.free(r.swapchain_views);
    r.swapchain_views = &.{};
    if (r.swapchain_images.len > 0) r.gpa.free(r.swapchain_images);
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
    const color_ref: vk.AttachmentReference = .{
        .attachment = 0,
        .layout = .color_attachment_optimal,
    };
    const subpass: vk.SubpassDescription = .{
        .flags = .empty,
        .pipeline_bind_point = .graphics,
        .input_attachment_count = 0,
        .p_input_attachments = undefined,
        .color_attachment_count = 1,
        .p_color_attachments = &color_ref,
        .p_resolve_attachments = null,
        .p_depth_stencil_attachment = null,
        .preserve_attachment_count = 0,
        .p_preserve_attachments = undefined,
    };
    const dep: vk.SubpassDependency = .{
        .src_subpass = ~@as(u32, 0), // VK_SUBPASS_EXTERNAL
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

fn createGraphicsPipeline(r: *Renderer) !void {
    if (triangle_vert_spv.len < 16 or triangle_frag_spv.len < 16) {
        return error.ShaderModuleCreateFailed;
    }

    const vert_ci: vk.ShaderModuleCreateInfo = .{
        .flags = .empty,
        .code_size = triangle_vert_spv.len,
        .p_code = @ptrCast(@alignCast(triangle_vert_spv.ptr)),
    };
    r.vert_module = try r.device.createShaderModule(&vert_ci, null);
    const frag_ci: vk.ShaderModuleCreateInfo = .{
        .flags = .empty,
        .code_size = triangle_frag_spv.len,
        .p_code = @ptrCast(@alignCast(triangle_frag_spv.ptr)),
    };
    r.frag_module = try r.device.createShaderModule(&frag_ci, null);

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

    const binding: vk.VertexInputBindingDescription = .{
        .binding = 0,
        .stride = @sizeOf(Vertex),
        .input_rate = .vertex,
    };
    const attrs = [_]vk.VertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = .r32g32_sfloat, .offset = @offsetOf(Vertex, "pos") },
        .{ .location = 1, .binding = 0, .format = .r32g32b32_sfloat, .offset = @offsetOf(Vertex, "color") },
    };
    const vi: vk.PipelineVertexInputStateCreateInfo = .{
        .flags = .empty,
        .vertex_binding_description_count = 1,
        .p_vertex_binding_descriptions = @ptrCast(&binding),
        .vertex_attribute_description_count = attrs.len,
        .p_vertex_attribute_descriptions = @ptrCast(&attrs),
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
    const scissor: vk.Rect2D = .{
        .offset = .{ .x = 0, .y = 0 },
        .extent = r.swapchain_extent,
    };
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
        .front_face = .clockwise,
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
        .set_layout_count = 0,
        .p_set_layouts = undefined,
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
    var pipelines: [1]vk.Pipeline = .{.null};
    try r.device.createGraphicsPipelines(.null, &pipe_ci, null, &pipelines);
    r.pipeline = pipelines[0];
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

fn createVertexBuffer(r: *Renderer) !void {
    const size: vk.DeviceSize = @sizeOf(@TypeOf(triangle));

    // Staging buffer (host-visible, used to upload to device-local).
    var staging_usage: vk.BufferUsageFlags = .empty;
    staging_usage.transfer_src = true;
    const staging_buf = try createRawBuffer(r, size, staging_usage);
    defer r.device.destroyBuffer(staging_buf.buf, null);
    const staging_mem = try allocateBufferMemory(r, staging_buf, .{ .host_visible = true, .host_coherent = true });
    defer r.device.freeMemory(staging_mem, null);
    try r.device.bindBufferMemory(staging_buf.buf, staging_mem, 0);

    const data_ptr = (try r.device.mapMemory(staging_mem, 0, size, .empty)) orelse return error.MemoryMapFailed;
    @memcpy(@as([*]u8, @ptrCast(data_ptr))[0..size], std.mem.asBytes(&triangle));
    r.device.unmapMemory(staging_mem);

    // Device-local buffer (vertex buffer).
    var dev_usage: vk.BufferUsageFlags = .empty;
    dev_usage.transfer_dst = true;
    dev_usage.vertex_buffer = true;
    const vb = try createRawBuffer(r, size, dev_usage);
    errdefer r.device.destroyBuffer(vb.buf, null);
    const vb_mem = try allocateBufferMemory(r, vb, .{ .device_local = true });
    errdefer r.device.freeMemory(vb_mem, null);
    try r.device.bindBufferMemory(vb.buf, vb_mem, 0);

    r.vertex_buffer = vb.buf;
    r.vertex_memory = vb_mem;

    // Copy staging → device-local via a one-shot command buffer.
    const pool_ci: vk.CommandPoolCreateInfo = .{
        .flags = .{ .transient = true },
        .queue_family_index = r.queue_family_index,
    };
    const oneshot_pool = try r.device.createCommandPool(&pool_ci, null);
    defer r.device.destroyCommandPool(oneshot_pool, null);

    const alloc_ci: vk.CommandBufferAllocateInfo = .{
        .command_pool = oneshot_pool,
        .level = .primary,
        .command_buffer_count = 1,
    };
    var bufs: [1]*vk.CommandBuffer = undefined;
    try r.device.allocateCommandBuffers(&alloc_ci, &bufs);
    const cb = bufs[0];

    const begin_ci: vk.CommandBufferBeginInfo = .{
        .flags = .{ .one_time_submit = true },
        .p_inheritance_info = null,
    };
    try cb.beginCommandBuffer(&begin_ci);
    const region: vk.BufferCopy = .{ .src_offset = 0, .dst_offset = 0, .size = size };
    cb.cmdCopyBuffer(staging_buf.buf, vb.buf, &.{region});
    try cb.endCommandBuffer();

    const submit: vk.SubmitInfo = .{
        .wait_semaphore_count = 0,
        .p_wait_semaphores = undefined,
        .p_wait_dst_stage_mask = undefined,
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&bufs),
        .signal_semaphore_count = 0,
        .p_signal_semaphores = undefined,
    };
    try r.queue.submit(&.{submit}, .null);
    try r.queue.waitIdle();
}

const RawBuffer = struct {
    buf: vk.Buffer,
    requirements: vk.MemoryRequirements,
};

fn createRawBuffer(r: *Renderer, size: vk.DeviceSize, usage: vk.BufferUsageFlags) !RawBuffer {
    const ci: vk.BufferCreateInfo = .{
        .flags = .empty,
        .size = size,
        .usage = usage,
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = undefined,
    };
    const buf = try r.device.createBuffer(&ci, null);
    const reqs = r.device.getBufferMemoryRequirements(buf);
    return .{ .buf = buf, .requirements = reqs };
}

fn allocateBufferMemory(r: *Renderer, raw: RawBuffer, props: vk.MemoryPropertyFlags) !vk.DeviceMemory {
    const mem_props = r.physical_device.getPhysicalDeviceMemoryProperties();
    const type_index = pickMemoryType(mem_props, raw.requirements.memory_type_bits, props) orelse return error.NoCompatibleDevice;
    const ai: vk.MemoryAllocateInfo = .{
        .allocation_size = raw.requirements.size,
        .memory_type_index = type_index,
    };
    return r.device.allocateMemory(&ai, null);
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
