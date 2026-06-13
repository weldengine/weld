//! Editor viewport blit renderer — M0.9 / E6 (consolidated onto the GAL).
//!
//! Renders the runtime-written IPC viewport (a 1280×720 RGBA8 shm framebuffer)
//! onto the editor's swapchain via a fullscreen-triangle blit. As of E6 this
//! drives the **public GAL** (`gal.Device`) instead of raw Vulkan: the S6
//! hand-rolled instance/device/swapchain/descriptor/command plumbing
//! (`vk.device_dispatch.*`) is gone, replaced by GAL calls. The per-frame shm
//! upload uses `copyBufferToTexture` (the E4 primitive), whose internal
//! `undefined→transfer_dst→shader_read` barriers subsume the layout
//! transitions the raw path issued by hand.
//!
//! Two M0.5 sync bugs are resorbed by routing through the GAL:
//!   (a) colorspace — the GAL swapchain now selects a surface pair carrying
//!       the core `srgb_nonlinear` colorspace (`gal swapchain.zig` +
//!       `conv.colorSpace`), so it never emits an extended `*_EXT` colorspace
//!       without `VK_EXT_swapchain_colorspace`
//!       (VUID-VkSwapchainCreateInfoKHR-imageColorSpace-parameter). Validated
//!       absent on lavapipe.
//!   (b) present-semaphore reuse — `render_finished` is now **one semaphore
//!       per swapchain image**, indexed by the acquired `image_index`, so a
//!       binary semaphore is never re-signalled while a prior present on the
//!       same image is still pending (VUID-vkQueueSubmit-pSignalSemaphores-00067).
//!       NOT observable on lavapipe (software present is synchronous) — verified
//!       by construction; hardware-confirmed on the Fedora 44 + GTX 1660 Ti box.
//!
//! Per-frame flow (`drawFrame`): wait the frame's in-flight fence → acquire →
//! `copyBufferToTexture` the staged shm bytes into the sampled viewport texture
//! → render pass over the acquired swapchain image binding the texture+sampler
//! and drawing the fullscreen triangle → submit (signal the per-image
//! semaphore) → present (wait that semaphore). The editor main loop drains IPC
//! + calls `stageViewport` then `drawFrame` each frame.

const std = @import("std");
const builtin = @import("builtin");

const weld_core = @import("weld_core");
const weld_render = @import("weld_render");
const gal = weld_render.gal;
const window_mod = weld_core.platform.window;
const viewport_mod = weld_core.ipc.viewport;
// `vk` is imported ONLY for the `vk.Extent2D` POD (the public `last_known_size`
// field main.zig writes) — no `vk.device_dispatch.*`, so the
// `no_device_dispatch_outside_gal` rule holds.
const vk = weld_core.platform.vk;

const shaders = @import("shaders");
const blit_vert_spv = shaders.viewport_blit_vert_spv;
const blit_frag_spv = shaders.viewport_blit_frag_spv;

const log = std.log.scoped(.s6_editor);

/// Frames the editor can have in flight (acquire-side double buffering).
pub const max_frames_in_flight: u32 = 2;

/// Swapchain pixel format (the GAL pairs it with the core `srgb_nonlinear`
/// colorspace — see `gal/vulkan/swapchain.zig` colorspace selection).
const swapchain_format: gal.types.TextureFormat = .bgra8_unorm;

/// Error set surfaced by `Renderer.init` / `recreateSwapchain` / `drawFrame`.
/// Wraps the GAL error set (the raw `vk.Error` set is gone). main.zig only
/// `try`s these, so the concrete set may change without a main.zig edit.
pub const SetupError = gal.types.Error || std.mem.Allocator.Error || error{UnsupportedHostPlatform};

/// Editor blit renderer — owns the GAL device + the blit resources. Internal
/// fields are GAL handles (the raw `vk.*` objects are gone); only the public
/// surface main.zig depends on (`last_known_size`, `swapchain_dirty`, the
/// pub fns) is preserved.
pub const Renderer = struct {
    gpa: std.mem.Allocator,
    device: gal.vulkan_backend.Device,
    swapchain: gal.types.SwapchainHandle,

    vert_module: gal.types.ShaderModuleHandle,
    frag_module: gal.types.ShaderModuleHandle,
    bgl: gal.types.BindGroupLayoutHandle,
    pipeline: gal.types.RenderPipelineHandle,

    /// 1280×720 RGBA8 sampled texture — the runtime's published slot is
    /// uploaded here each frame, then sampled by the blit.
    viewport_tex: gal.types.TextureHandle,
    viewport_view: gal.types.TextureViewHandle,
    sampler: gal.types.SamplerHandle,
    bind_group: gal.types.BindGroupHandle,

    /// Host-visible staging buffer sized for the full viewport, persistently
    /// mapped (`stageViewport` memcpys into it without error).
    staging: gal.types.BufferHandle,
    staging_mapped: []u8,

    image_available: [max_frames_in_flight]gal.types.SemaphoreHandle,
    in_flight: [max_frames_in_flight]gal.types.FenceHandle,
    /// One present-completion semaphore PER swapchain image (bug (b) fix),
    /// indexed by the acquired `image_index`.
    render_finished: []gal.types.SemaphoreHandle,
    current_frame: u32 = 0,

    /// Most recent window-side size (physical px); written by main.zig on
    /// resize, seeded at init. Used as the swapchain extent on recreate + the
    /// blit viewport/scissor.
    last_known_size: vk.Extent2D,
    swapchain_dirty: bool = false,

    pub fn init(
        gpa: std.mem.Allocator,
        window: *window_mod.Window,
        initial_size: vk.Extent2D,
    ) SetupError!Renderer {
        var device = try gal.vulkan_backend.Device.init(gpa, .{
            .label = "weld-editor",
            .enable_validation = builtin.mode == .Debug,
        });
        errdefer device.deinit();

        _ = try device.createSurfaceFromWindow(window);

        const swapchain = try device.createSwapchain(.{
            .format = swapchain_format,
            .width = initial_size.width,
            .height = initial_size.height,
            .present_mode = .fifo,
        });
        errdefer device.destroySwapchain(swapchain);

        const vsm = try device.createShaderModule(.{ .code = blit_vert_spv, .label = "blit.vs" });
        errdefer device.destroyShaderModule(vsm);
        const fsm = try device.createShaderModule(.{ .code = blit_frag_spv, .label = "blit.fs" });
        errdefer device.destroyShaderModule(fsm);

        const bgl = try device.createBindGroupLayout(.{ .entries = &.{
            .{ .binding = 0, .visibility = .{ .fragment = true }, .binding_type = .sampled_texture },
            .{ .binding = 1, .visibility = .{ .fragment = true }, .binding_type = .sampler },
        } });
        errdefer device.destroyBindGroupLayout(bgl);

        const pipeline = try device.createRenderPipeline(.{
            .label = "blit.pso",
            .layout = &.{bgl},
            .vertex_module = vsm,
            .fragment_module = fsm,
            // Fullscreen triangle generated from gl_VertexIndex — no VBO.
            .vertex_buffers = &.{},
            .color_targets = &.{.{ .format = swapchain_format }},
            .cull_mode = .none,
        });
        errdefer device.destroyRenderPipeline(pipeline);

        const w = viewport_mod.default_resolution.width;
        const h = viewport_mod.default_resolution.height;

        const viewport_tex = try device.createTexture(.{
            .label = "viewport.tex",
            .format = .rgba8_unorm,
            .width = w,
            .height = h,
            .usage = .{ .sampled = true, .copy_dst = true },
        });
        errdefer device.destroyTexture(viewport_tex);
        const viewport_view = try device.createTextureView(viewport_tex, .{ .label = "viewport.view" });
        errdefer device.destroyTextureView(viewport_view);
        const sampler = try device.createSampler(.{ .mag_filter = .linear, .min_filter = .linear });
        errdefer device.destroySampler(sampler);

        const bind_group = try device.createBindGroup(.{
            .label = "blit.bg",
            .layout = bgl,
            .entries = &.{
                .{ .binding = 0, .resource = .{ .texture_view = viewport_view } },
                .{ .binding = 1, .resource = .{ .sampler = sampler } },
            },
        });
        errdefer device.destroyBindGroup(bind_group);

        const staging_size: u64 = @as(u64, w) * h * 4;
        const staging = try device.createBuffer(.{
            .label = "viewport.staging",
            .size = staging_size,
            .usage = .{ .copy_src = true },
            .host_visible = true,
        });
        errdefer device.destroyBuffer(staging);
        const staging_mapped = try device.mapBuffer(staging);

        var image_available: [max_frames_in_flight]gal.types.SemaphoreHandle = undefined;
        var in_flight: [max_frames_in_flight]gal.types.FenceHandle = undefined;
        var sem_made: usize = 0;
        errdefer for (image_available[0..sem_made]) |s| device.destroySemaphore(s);
        var fence_made: usize = 0;
        errdefer for (in_flight[0..fence_made]) |f| device.destroyFence(f);
        for (0..max_frames_in_flight) |i| {
            image_available[i] = try device.createSemaphore();
            sem_made = i + 1;
        }
        for (0..max_frames_in_flight) |i| {
            in_flight[i] = try device.createFence(true); // signaled: first wait passes
            fence_made = i + 1;
        }

        const render_finished = try makePresentSemaphores(&device, gpa, swapchain);
        errdefer destroyPresentSemaphores(&device, gpa, render_finished);

        return .{
            .gpa = gpa,
            .device = device,
            .swapchain = swapchain,
            .vert_module = vsm,
            .frag_module = fsm,
            .bgl = bgl,
            .pipeline = pipeline,
            .viewport_tex = viewport_tex,
            .viewport_view = viewport_view,
            .sampler = sampler,
            .bind_group = bind_group,
            .staging = staging,
            .staging_mapped = staging_mapped,
            .image_available = image_available,
            .in_flight = in_flight,
            .render_finished = render_finished,
            .last_known_size = initial_size,
        };
    }

    pub fn deinit(self: *Renderer) void {
        // Drain in-flight GPU work before tearing resources down.
        for (self.in_flight) |f| self.device.waitFence(f, std.math.maxInt(u64)) catch {};

        destroyPresentSemaphores(&self.device, self.gpa, self.render_finished);
        for (self.image_available) |s| self.device.destroySemaphore(s);
        for (self.in_flight) |f| self.device.destroyFence(f);
        self.device.unmapBuffer(self.staging);
        self.device.destroyBuffer(self.staging);
        self.device.destroyBindGroup(self.bind_group);
        self.device.destroySampler(self.sampler);
        self.device.destroyTextureView(self.viewport_view);
        self.device.destroyTexture(self.viewport_tex);
        self.device.destroyRenderPipeline(self.pipeline);
        self.device.destroyBindGroupLayout(self.bgl);
        self.device.destroyShaderModule(self.frag_module);
        self.device.destroyShaderModule(self.vert_module);
        self.device.destroySwapchain(self.swapchain);
        self.device.deinit();
    }

    /// Recreate the swapchain (+ its per-image present semaphores) at
    /// `last_known_size`. The format-stable blit pipeline + viewport resources
    /// are untouched.
    pub fn recreateSwapchain(self: *Renderer) SetupError!void {
        for (self.in_flight) |f| self.device.waitFence(f, std.math.maxInt(u64)) catch {};

        destroyPresentSemaphores(&self.device, self.gpa, self.render_finished);
        self.device.destroySwapchain(self.swapchain);

        self.swapchain = try self.device.createSwapchain(.{
            .format = swapchain_format,
            .width = self.last_known_size.width,
            .height = self.last_known_size.height,
            .present_mode = .fifo,
        });
        self.render_finished = try makePresentSemaphores(&self.device, self.gpa, self.swapchain);
        self.current_frame = 0;
        self.swapchain_dirty = false;
    }

    /// Copy `slot_bytes` (the runtime's published viewport slot) into the
    /// persistently-mapped staging buffer. `drawFrame` then uploads it.
    pub fn stageViewport(self: *Renderer, slot_bytes: []const u8) void {
        const n = @min(slot_bytes.len, self.staging_mapped.len);
        @memcpy(self.staging_mapped[0..n], slot_bytes[0..n]);
    }
};

fn makePresentSemaphores(
    device: *gal.vulkan_backend.Device,
    gpa: std.mem.Allocator,
    swapchain: gal.types.SwapchainHandle,
) SetupError![]gal.types.SemaphoreHandle {
    const count = device.getSwapchainImageCount(swapchain);
    const sems = try gpa.alloc(gal.types.SemaphoreHandle, count);
    errdefer gpa.free(sems);
    var made: usize = 0;
    errdefer for (sems[0..made]) |s| device.destroySemaphore(s);
    for (0..count) |i| {
        sems[i] = try device.createSemaphore();
        made = i + 1;
    }
    return sems;
}

fn destroyPresentSemaphores(
    device: *gal.vulkan_backend.Device,
    gpa: std.mem.Allocator,
    sems: []gal.types.SemaphoreHandle,
) void {
    for (sems) |s| device.destroySemaphore(s);
    gpa.free(sems);
}

/// Record + submit + present one blit frame. Returns `false` (and sets
/// `swapchain_dirty`) when the swapchain is out-of-date and the caller must
/// recreate it. Free fn (`*Renderer` first arg) to preserve the S6 call site.
pub fn drawFrame(r: *Renderer) SetupError!bool {
    const dev = &r.device;
    const cur = r.current_frame;

    dev.waitFence(r.in_flight[cur], std.math.maxInt(u64)) catch {};

    const image_index = dev.acquireNextImage(r.swapchain, r.image_available[cur], std.math.maxInt(u64)) catch |e| switch (e) {
        error.SwapchainOutOfDate => {
            r.swapchain_dirty = true;
            return false;
        },
        else => return e,
    };
    dev.resetFence(r.in_flight[cur]) catch {};

    const color_view = dev.getSwapchainImageView(r.swapchain, image_index);
    const w = viewport_mod.default_resolution.width;
    const h = viewport_mod.default_resolution.height;

    const enc = try dev.createCommandEncoder("editor.blit");
    defer dev.destroyCommandEncoder(enc);

    // Upload the staged shm bytes into the sampled texture. copyBufferToTexture
    // emits the undefined→transfer_dst→shader_read transitions internally.
    enc.copyBufferToTexture(
        .{ .buffer = r.staging, .bytes_per_row = w * 4 },
        .{ .texture = r.viewport_tex },
        .{ .width = w, .height = h, .depth_or_array_layers = 1 },
    );

    var pass = try enc.beginRenderPass(.{
        .label = "editor.blit",
        .color_attachments = &.{.{
            .view = color_view,
            .load_op = .clear,
            .store_op = .store,
            .clear_color = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
        }},
    });
    pass.setViewport(0, 0, @floatFromInt(r.last_known_size.width), @floatFromInt(r.last_known_size.height), 0, 1);
    pass.setScissor(0, 0, r.last_known_size.width, r.last_known_size.height);
    pass.setPipeline(r.pipeline);
    pass.setBindGroup(0, r.bind_group);
    pass.draw(3, 1, 0, 0);
    pass.end();
    enc.finish();

    try dev.submit(enc, .{
        .wait_semaphore = r.image_available[cur],
        .signal_semaphore = r.render_finished[image_index], // per-image (bug (b))
        .fence = r.in_flight[cur],
    });
    dev.present(r.swapchain, image_index, &.{r.render_finished[image_index]}) catch |e| switch (e) {
        error.SwapchainOutOfDate => {
            r.swapchain_dirty = true;
            return false;
        },
        else => return e,
    };

    r.current_frame = (cur + 1) % max_frames_in_flight;
    return true;
}
