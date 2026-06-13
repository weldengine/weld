//! M0.9 vertical slice — forward renderer (E4).
//!
//! Drives the public GAL end-to-end to render the live ECS scene: one shared
//! cube mesh instanced once per entity at the entity's `Position` (read from
//! the world each frame), shaded by an M0.6-cooked albedo texture uploaded to
//! the GPU via `copyBufferToTexture` (the primitive E4 implements), under a
//! perspective camera with depth testing.
//!
//! Three entry points share the `Renderer` (resources + pipeline + draw):
//!   - `runInteractive` — window + swapchain + present loop (hardware); pumps
//!     M0.3 input (SPACE toggles pause) into the sim each frame.
//!   - `runSmoke` — offscreen render of the final state → PPM capture, no
//!     window/swapchain (headless lavapipe in CI; validation layers active in
//!     Debug). "The frame composes without crash."
//!   - `composeNull` — builds the full pipeline + records a frame over the
//!     Null backend, exercising the whole path (incl. `copyBufferToTexture`)
//!     on every platform incl. macOS (the integration test's render facet).
//!
//! The renderer is generic over the GAL device type (`anytype`) so the same
//! code runs on the Vulkan and Null backends — handles are device-agnostic
//! `gal.types.*`.

const std = @import("std");
const builtin = @import("builtin");
const weld_render = @import("weld_render");
const weld_core = @import("weld_core");
const assets = @import("weld_asset_pipeline");
const sim = @import("sim.zig");
const m = @import("math.zig");

const gal = weld_render.gal;
const window_mod = weld_core.platform.window;
const World = weld_core.ecs.world.World;
const raw_state = weld_core.platform.input.raw_state;
const InputRawState = raw_state.InputRawState;

const log = std.log.scoped(.vertical_slice);

/// Fixed render target size (matches the triangle; depth target sized to it).
pub const render_width: u32 = 1280;
pub const render_height: u32 = 720;

const vert_spv: []const u8 = @embedFile("shaders/slice.vert.spv");
const frag_spv: []const u8 = @embedFile("shaders/slice.frag.spv");

/// Per-vertex cube attributes — matches `slice.vert.glsl` locations 0/1.
const Vertex = extern struct { pos: [3]f32, uv: [2]f32 };
/// Per-instance attribute — entity world offset, location 2.
const Instance = extern struct { offset: [3]f32 };

const cube_half: f32 = 0.4;

/// 24-vertex unit cube (4 per face so each face gets full `[0,1]²` UVs),
/// centered at the origin, half-extent `cube_half`.
const cube_vertices = blk: {
    const h = cube_half;
    break :blk [24]Vertex{
        // +X
        .{ .pos = .{ h, -h, -h }, .uv = .{ 0, 0 } }, .{ .pos = .{ h, h, -h }, .uv = .{ 1, 0 } },
        .{ .pos = .{ h, h, h }, .uv = .{ 1, 1 } },   .{ .pos = .{ h, -h, h }, .uv = .{ 0, 1 } },
        // -X
        .{ .pos = .{ -h, -h, h }, .uv = .{ 0, 0 } }, .{ .pos = .{ -h, h, h }, .uv = .{ 1, 0 } },
        .{ .pos = .{ -h, h, -h }, .uv = .{ 1, 1 } }, .{ .pos = .{ -h, -h, -h }, .uv = .{ 0, 1 } },
        // +Y
        .{ .pos = .{ -h, h, -h }, .uv = .{ 0, 0 } }, .{ .pos = .{ -h, h, h }, .uv = .{ 1, 0 } },
        .{ .pos = .{ h, h, h }, .uv = .{ 1, 1 } },   .{ .pos = .{ h, h, -h }, .uv = .{ 0, 1 } },
        // -Y
        .{ .pos = .{ -h, -h, h }, .uv = .{ 0, 0 } }, .{ .pos = .{ -h, -h, -h }, .uv = .{ 1, 0 } },
        .{ .pos = .{ h, -h, -h }, .uv = .{ 1, 1 } }, .{ .pos = .{ h, -h, h }, .uv = .{ 0, 1 } },
        // +Z
        .{ .pos = .{ -h, -h, h }, .uv = .{ 0, 0 } }, .{ .pos = .{ h, -h, h }, .uv = .{ 1, 0 } },
        .{ .pos = .{ h, h, h }, .uv = .{ 1, 1 } },   .{ .pos = .{ -h, h, h }, .uv = .{ 0, 1 } },
        // -Z
        .{ .pos = .{ h, -h, -h }, .uv = .{ 0, 0 } }, .{ .pos = .{ -h, -h, -h }, .uv = .{ 1, 0 } },
        .{ .pos = .{ -h, h, -h }, .uv = .{ 1, 1 } }, .{ .pos = .{ h, h, -h }, .uv = .{ 0, 1 } },
    };
};

const cube_indices = blk: {
    var idx: [36]u16 = undefined;
    var f: u16 = 0;
    while (f < 6) : (f += 1) {
        const base = f * 4;
        const o = f * 6;
        idx[o + 0] = base + 0;
        idx[o + 1] = base + 1;
        idx[o + 2] = base + 2;
        idx[o + 3] = base + 0;
        idx[o + 4] = base + 2;
        idx[o + 5] = base + 3;
    }
    break :blk idx;
};

/// A loaded albedo: owned RGBA8 bytes + square dimension.
const Albedo = struct {
    rgba: []u8,
    dim: u32,
    fn deinit(self: *Albedo, gpa: std.mem.Allocator) void {
        gpa.free(self.rgba);
    }
};

/// Load the M0.6-cooked `.texture.bin` via the async `Loader` and return an
/// owned RGBA8 copy + its (square) dimension. The slice's albedo is square by
/// construction, so the dimension derives from the payload length (the Loader
/// surfaces the payload + header but not the metadata bytes; a square asset
/// sidesteps needing the width/height fields).
fn loadAlbedo(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Albedo {
    var loader = assets.Loader.init(std.Io.Dir.cwd());
    defer loader.deinit(gpa);
    const handle = try loader.load(gpa, io, path);
    const payload = loader.get(handle) orelse return error.AssetUnavailable;
    const px = payload.len / 4;
    const dim: u32 = @intFromFloat(@sqrt(@as(f32, @floatFromInt(px))));
    if (dim == 0 or dim * dim * 4 != payload.len) return error.NonSquareTexture;
    return .{ .rgba = try gpa.dupe(u8, payload), .dim = dim };
}

/// GPU resources + pipeline for the slice. Generic over the GAL device type via
/// `anytype` on every method; only device-agnostic `gal.types.*` handles are
/// stored.
pub const Renderer = struct {
    vert_module: gal.types.ShaderModuleHandle,
    frag_module: gal.types.ShaderModuleHandle,
    bgl: gal.types.BindGroupLayoutHandle,
    pipeline: gal.types.RenderPipelineHandle,
    cube_vb: gal.types.BufferHandle,
    cube_ib: gal.types.BufferHandle,
    instance_vb: gal.types.BufferHandle,
    camera_ub: gal.types.BufferHandle,
    albedo_tex: gal.types.TextureHandle,
    albedo_view: gal.types.TextureViewHandle,
    sampler: gal.types.SamplerHandle,
    bind_group: gal.types.BindGroupHandle,
    depth_tex: gal.types.TextureHandle,
    depth_view: gal.types.TextureViewHandle,
    instance_count: u32,
    max_instances: u32,

    pub fn init(
        device: anytype,
        color_format: gal.types.TextureFormat,
        albedo_rgba: []const u8,
        albedo_dim: u32,
        max_instances: u32,
    ) !Renderer {
        const vsm = try device.createShaderModule(.{ .code = vert_spv, .label = "slice.vs" });
        errdefer device.destroyShaderModule(vsm);
        const fsm = try device.createShaderModule(.{ .code = frag_spv, .label = "slice.fs" });
        errdefer device.destroyShaderModule(fsm);

        const bgl = try device.createBindGroupLayout(.{ .entries = &.{
            .{ .binding = 0, .visibility = .{ .vertex = true }, .binding_type = .uniform_buffer },
            .{ .binding = 1, .visibility = .{ .fragment = true }, .binding_type = .sampled_texture },
            .{ .binding = 2, .visibility = .{ .fragment = true }, .binding_type = .sampler },
        } });
        errdefer device.destroyBindGroupLayout(bgl);

        const pipeline = try device.createRenderPipeline(.{
            .label = "slice.pso",
            .layout = &.{bgl},
            .vertex_module = vsm,
            .fragment_module = fsm,
            .color_targets = &.{.{ .format = color_format }},
            .vertex_buffers = &.{
                .{ .stride = @sizeOf(Vertex), .step_mode = .vertex, .attributes = &.{
                    .{ .location = 0, .format = .rgb32_sfloat, .offset = @offsetOf(Vertex, "pos") },
                    .{ .location = 1, .format = .rg32_sfloat, .offset = @offsetOf(Vertex, "uv") },
                } },
                .{ .stride = @sizeOf(Instance), .step_mode = .instance, .attributes = &.{
                    .{ .location = 2, .format = .rgb32_sfloat, .offset = @offsetOf(Instance, "offset") },
                } },
            },
            .primitive_topology = .triangle_list,
            .cull_mode = .none,
            .depth_format = .d32_sfloat,
            .depth_test_enabled = true,
            .depth_write_enabled = true,
            .depth_compare = .less,
        });
        errdefer device.destroyRenderPipeline(pipeline);

        // Cube vertex + index buffers (host-visible + map, like the triangle).
        const cube_vb = try device.createBuffer(.{
            .label = "slice.cube.vb",
            .size = @sizeOf(@TypeOf(cube_vertices)),
            .usage = .{ .vertex = true, .copy_dst = true },
            .host_visible = true,
        });
        errdefer device.destroyBuffer(cube_vb);
        {
            const mapped = try device.mapBuffer(cube_vb);
            @memcpy(mapped[0..@sizeOf(@TypeOf(cube_vertices))], std.mem.asBytes(&cube_vertices));
            device.unmapBuffer(cube_vb);
        }

        const cube_ib = try device.createBuffer(.{
            .label = "slice.cube.ib",
            .size = @sizeOf(@TypeOf(cube_indices)),
            .usage = .{ .index = true, .copy_dst = true },
            .host_visible = true,
        });
        errdefer device.destroyBuffer(cube_ib);
        {
            const mapped = try device.mapBuffer(cube_ib);
            @memcpy(mapped[0..@sizeOf(@TypeOf(cube_indices))], std.mem.asBytes(&cube_indices));
            device.unmapBuffer(cube_ib);
        }

        const instance_vb = try device.createBuffer(.{
            .label = "slice.instance.vb",
            .size = @as(u64, max_instances) * @sizeOf(Instance),
            .usage = .{ .vertex = true, .copy_dst = true },
            .host_visible = true,
        });
        errdefer device.destroyBuffer(instance_vb);

        const camera_ub = try device.createBuffer(.{
            .label = "slice.camera.ub",
            .size = 64, // one mat4 (std140)
            .usage = .{ .uniform = true, .copy_dst = true },
            .host_visible = true,
        });
        errdefer device.destroyBuffer(camera_ub);

        // Albedo texture + GPU upload via copyBufferToTexture (the E4 primitive).
        const albedo_tex = try device.createTexture(.{
            .label = "slice.albedo",
            .format = .rgba8_unorm,
            .width = albedo_dim,
            .height = albedo_dim,
            .usage = .{ .sampled = true, .copy_dst = true },
        });
        errdefer device.destroyTexture(albedo_tex);
        try uploadTexture(device, albedo_tex, albedo_rgba, albedo_dim);

        const albedo_view = try device.createTextureView(albedo_tex, .{ .label = "slice.albedo.view" });
        errdefer device.destroyTextureView(albedo_view);
        const sampler = try device.createSampler(.{ .mag_filter = .nearest, .min_filter = .nearest });
        errdefer device.destroySampler(sampler);

        const bind_group = try device.createBindGroup(.{
            .label = "slice.bg",
            .layout = bgl,
            .entries = &.{
                .{ .binding = 0, .resource = .{ .buffer = .{ .handle = camera_ub } } },
                .{ .binding = 1, .resource = .{ .texture_view = albedo_view } },
                .{ .binding = 2, .resource = .{ .sampler = sampler } },
            },
        });
        errdefer device.destroyBindGroup(bind_group);

        const depth_tex = try device.createTexture(.{
            .label = "slice.depth",
            .format = .d32_sfloat,
            .width = render_width,
            .height = render_height,
            .usage = .{ .depth_stencil_attachment = true },
        });
        errdefer device.destroyTexture(depth_tex);
        const depth_view = try device.createTextureView(depth_tex, .{ .label = "slice.depth.view" });
        errdefer device.destroyTextureView(depth_view);

        return .{
            .vert_module = vsm,
            .frag_module = fsm,
            .bgl = bgl,
            .pipeline = pipeline,
            .cube_vb = cube_vb,
            .cube_ib = cube_ib,
            .instance_vb = instance_vb,
            .camera_ub = camera_ub,
            .albedo_tex = albedo_tex,
            .albedo_view = albedo_view,
            .sampler = sampler,
            .bind_group = bind_group,
            .depth_tex = depth_tex,
            .depth_view = depth_view,
            .instance_count = 0,
            .max_instances = max_instances,
        };
    }

    pub fn deinit(self: *Renderer, device: anytype) void {
        device.destroyTextureView(self.depth_view);
        device.destroyTexture(self.depth_tex);
        device.destroyBindGroup(self.bind_group);
        device.destroySampler(self.sampler);
        device.destroyTextureView(self.albedo_view);
        device.destroyTexture(self.albedo_tex);
        device.destroyBuffer(self.camera_ub);
        device.destroyBuffer(self.instance_vb);
        device.destroyBuffer(self.cube_ib);
        device.destroyBuffer(self.cube_vb);
        device.destroyRenderPipeline(self.pipeline);
        device.destroyBindGroupLayout(self.bgl);
        device.destroyShaderModule(self.frag_module);
        device.destroyShaderModule(self.vert_module);
    }

    /// Pull every entity's live `Position` from the world and write it as a
    /// per-instance world offset (x, y, 0). Sets `instance_count`.
    pub fn setInstancesFromWorld(self: *Renderer, device: anytype, world: *World) !void {
        const mapped = try device.mapBuffer(self.instance_vb);
        // Capacity from the REAL mapped buffer (usize), clamped to it — no u32
        // multiply that could overflow, and never writes past the buffer.
        const capacity = mapped.len / @sizeOf(Instance);
        const n = @min(@as(usize, sim.entity_count), capacity);
        log.info("vertical-slice: instances n={d} entity_count={d} max={d} mapped_len={d} cap={d}", .{
            n, sim.entity_count, self.max_instances, mapped.len, capacity,
        });
        const slots = @as([*]Instance, @ptrCast(@alignCast(mapped.ptr)))[0..n];
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const p = sim.readPosition(world, @intCast(i));
            slots[i] = .{ .offset = .{ p[0], p[1], 0 } };
        }
        device.unmapBuffer(self.instance_vb);
        self.instance_count = @intCast(n);
    }

    /// Write the camera MVP into the uniform buffer.
    pub fn setCamera(self: *Renderer, device: anytype, aspect: f32) !void {
        const proj = m.perspective(std.math.pi / 4.0, aspect, 0.1, 200.0);
        const view = m.lookAt(.{ 0, 0, 36 }, .{ 0, 0, 0 }, .{ 0, 1, 0 });
        const mvp = m.mul(proj, view);
        const mapped = try device.mapBuffer(self.camera_ub);
        @memcpy(mapped[0..64], std.mem.asBytes(&mvp));
        device.unmapBuffer(self.camera_ub);
    }

    /// Record the scene draw into an already-begun render pass.
    pub fn record(self: *const Renderer, pass: anytype) void {
        pass.setPipeline(self.pipeline);
        pass.setBindGroup(0, self.bind_group);
        pass.setVertexBuffer(0, self.cube_vb, 0);
        pass.setVertexBuffer(1, self.instance_vb, 0);
        pass.setIndexBuffer(self.cube_ib, 0, .u16);
        pass.drawIndexed(cube_indices.len, self.instance_count, 0, 0, 0);
    }
};

/// One-shot staging upload of RGBA8 bytes into a texture via the GAL
/// `copyBufferToTexture` (the E4 primitive). The texture is left in
/// shader-read layout, ready to sample.
fn uploadTexture(device: anytype, tex: gal.types.TextureHandle, rgba: []const u8, dim: u32) !void {
    const staging = try device.createBuffer(.{
        .label = "slice.albedo.staging",
        .size = rgba.len,
        .usage = .{ .copy_src = true },
        .host_visible = true,
    });
    defer device.destroyBuffer(staging);
    {
        const mapped = try device.mapBuffer(staging);
        @memcpy(mapped[0..rgba.len], rgba);
        device.unmapBuffer(staging);
    }

    const enc = try device.createCommandEncoder("slice.albedo.upload");
    defer device.destroyCommandEncoder(enc);
    enc.copyBufferToTexture(
        .{ .buffer = staging, .bytes_per_row = dim * 4 },
        .{ .texture = tex },
        .{ .width = dim, .height = dim, .depth_or_array_layers = 1 },
    );
    enc.finish();

    const fence = try device.createFence(false);
    defer device.destroyFence(fence);
    try device.submit(enc, .{ .fence = fence });
    try device.waitFence(fence, std.math.maxInt(u64));
}

// ============================================================== entry points =

/// Interactive hardware path: window + swapchain + present loop, pumping M0.3
/// input (SPACE toggles pause) into the sim each frame.
pub fn runInteractive(gpa: std.mem.Allocator, io: std.Io, world: *World, asset_path: []const u8) !void {
    var albedo = try loadAlbedo(gpa, io, asset_path);
    defer albedo.deinit(gpa);

    var window = try window_mod.Window.create(gpa, .{
        .title = "Weld Vertical Slice (M0.9)",
        .width = render_width,
        .height = render_height,
    });
    defer window.destroy();

    var device = try gal.vulkan_backend.Device.init(gpa, .{
        .label = "vertical-slice",
        .enable_validation = builtin.mode == .Debug,
    });
    defer device.deinit();

    _ = try device.createSurfaceFromWindow(&window);
    const swap = try device.createSwapchain(.{
        .format = .bgra8_unorm,
        .width = render_width,
        .height = render_height,
        .present_mode = .fifo,
    });
    defer device.destroySwapchain(swap);

    var r = try Renderer.init(&device, .bgra8_unorm, albedo.rgba, albedo.dim, sim.entity_count);
    defer r.deinit(&device);

    const image_ready = try device.createSemaphore();
    defer device.destroySemaphore(image_ready);
    const render_done = try device.createSemaphore();
    defer device.destroySemaphore(render_done);
    const in_flight = try device.createFence(false);
    defer device.destroyFence(in_flight);

    var raw = InputRawState{};
    var control = sim.Control{};
    const aspect: f32 = @as(f32, render_width) / @as(f32, render_height);

    var frame: u32 = 0;
    var should_close = false;
    while (!should_close) : (frame += 1) {
        raw_state.beginFrame(&raw);
        while (window.pollEvent()) |evt| {
            switch (evt) {
                .close => should_close = true,
                else => {},
            }
            raw_state.applyEvent(&raw, evt); // M0.3 resource pipeline
            control.applyEvent(evt); // logical-key reaction (SPACE → pause)
        }
        if (should_close) break;

        control.stepIfRunning(world, gpa);

        try r.setInstancesFromWorld(&device, world);
        try r.setCamera(&device, aspect);

        if (frame > 0) {
            device.waitFence(in_flight, std.math.maxInt(u64)) catch {};
            device.resetFence(in_flight) catch {};
        }
        const image_index = device.acquireNextImage(swap, image_ready, std.math.maxInt(u64)) catch |e| switch (e) {
            error.SwapchainOutOfDate => continue,
            else => return e,
        };
        const color_view = device.getSwapchainImageView(swap, image_index);

        const enc = try device.createCommandEncoder("slice.frame");
        defer device.destroyCommandEncoder(enc);
        var pass = try enc.beginRenderPass(.{
            .label = "slice.frame",
            .color_attachments = &.{.{
                .view = color_view,
                .load_op = .clear,
                .store_op = .store,
                .clear_color = .{ .r = 0.02, .g = 0.02, .b = 0.05, .a = 1.0 },
            }},
            .depth_stencil_attachment = .{ .view = r.depth_view },
        });
        pass.setViewport(0, 0, @floatFromInt(render_width), @floatFromInt(render_height), 0, 1);
        pass.setScissor(0, 0, render_width, render_height);
        r.record(&pass);
        pass.end();
        enc.finish();

        try device.submit(enc, .{ .wait_semaphore = image_ready, .signal_semaphore = render_done, .fence = in_flight });
        device.present(swap, image_index, &.{render_done}) catch |e| switch (e) {
            error.SwapchainOutOfDate => {},
            else => return e,
        };
    }
    device.waitFence(in_flight, std.math.maxInt(u64)) catch {};
    log.info("vertical-slice: interactive exit after {d} frames", .{frame});
}

/// Headless offscreen smoke: advance the sim `ticks` times, render the final
/// state once into an offscreen RGBA8 target, and capture it to `capture_path`.
/// No window/swapchain. Validation layers active in Debug. "Frame composes
/// without crash" — the CI lavapipe acceptance; visual correctness is
/// hardware-validated.
pub fn runSmoke(gpa: std.mem.Allocator, io: std.Io, world: *World, asset_path: []const u8, ticks: u32, capture_path: []const u8) !void {
    var albedo = try loadAlbedo(gpa, io, asset_path);
    defer albedo.deinit(gpa);

    var device = try gal.vulkan_backend.Device.init(gpa, .{
        .label = "vertical-slice-smoke",
        .enable_validation = builtin.mode == .Debug,
    });
    defer device.deinit();

    var r = try Renderer.init(&device, .rgba8_unorm, albedo.rgba, albedo.dim, sim.entity_count);
    defer r.deinit(&device);

    var t: u32 = 0;
    while (t < ticks) : (t += 1) sim.step(world, gpa);

    try r.setInstancesFromWorld(&device, world);
    try r.setCamera(&device, @as(f32, render_width) / @as(f32, render_height));

    const color = try device.createTexture(.{
        .label = "slice.smoke.color",
        .format = .rgba8_unorm,
        .width = render_width,
        .height = render_height,
        .usage = .{ .color_attachment = true, .copy_src = true },
    });
    defer device.destroyTexture(color);
    const color_view = try device.createTextureView(color, .{ .label = "slice.smoke.color.view" });
    defer device.destroyTextureView(color_view);

    const enc = try device.createCommandEncoder("slice.smoke");
    defer device.destroyCommandEncoder(enc);
    var pass = try enc.beginRenderPass(.{
        .label = "slice.smoke",
        .color_attachments = &.{.{
            .view = color_view,
            .load_op = .clear,
            .store_op = .store,
            .clear_color = .{ .r = 0.02, .g = 0.02, .b = 0.05, .a = 1.0 },
            .final_layout = .transfer_src,
        }},
        .depth_stencil_attachment = .{ .view = r.depth_view },
    });
    pass.setViewport(0, 0, @floatFromInt(render_width), @floatFromInt(render_height), 0, 1);
    pass.setScissor(0, 0, render_width, render_height);
    r.record(&pass);
    pass.end();
    enc.finish();

    const fence = try device.createFence(false);
    defer device.destroyFence(fence);
    try device.submit(enc, .{ .fence = fence });
    try device.waitFence(fence, std.math.maxInt(u64));

    try device.captureFrameToPPM(gpa, io, color, render_width, render_height, capture_path);
    log.info("vertical-slice: smoke frame captured -> {s} ({d} entities)", .{ capture_path, r.instance_count });
}

// NOTE on cross-platform render coverage: the renderer fills its vertex/index/
// instance/uniform buffers via `mapBuffer`, which the Null backend leaves
// `Unsupported` (it was built for the buffer-less triangle). No slice-render
// path can therefore RUN on the Null backend, so there is no headless
// `zig build test` render assertion on macOS. Coverage instead is: the render
// code (incl. the `copyBufferToTexture` upload call in `uploadTexture`) is
// COMPILE-checked on every platform (the slice module builds in CI on all
// targets); the forward path is RUN on Linux lavapipe (the CI smoke,
// `--smoke-test`, validation layers active in Debug); and visual correctness is
// hardware-validated.
