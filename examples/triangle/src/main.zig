//! Triangle example — Phase 0 / M0.4.
//!
//! Démonstration de la surface publique GAL via le sous-projet standalone.
//! Le ≤ 200 lignes du fichier est l'assertion architecturale brief §Notes
//! pièges connus : si plus que ça pour faire tourner un triangle, la surface
//! publique est mal pensée.
//!
//! Flags supportés (brief §Comportement observable) :
//! - `--smoke-test`                — non-interactif, exit après 1 frame
//! - `--capture-frame=N`           — capture frame N en PPM dans `out/`
//! - `--gpu-prefer=<discrete|integrated|index:N>` — sélection hardware
//! - `--vulkan-driver=<auto|hardware|software>`   — sélection driver
//!
//! Phase 0 : utilise le backend Null par défaut (CI headless). Le backend
//! Vulkan demande l'intégration window↔surface via le platform layer M0.3
//! (`platform.window.Window` → `vk.SurfaceKHR`) — wiring laissé à la suite
//! immédiate du milestone.

const std = @import("std");
const gal = @import("weld_render").gal;

const log = std.log.scoped(.triangle);

const Args = struct {
    smoke_test: bool = false,
    capture_frame: ?u32 = null,
    gpu_preference: gal.types.GpuPreference = .auto,
    vulkan_driver: gal.types.VulkanDriver = .auto,

    fn parse(allocator: std.mem.Allocator, raw: []const [:0]const u8) !Args {
        _ = allocator;
        var args: Args = .{};
        for (raw[1..]) |a| {
            if (std.mem.eql(u8, a, "--smoke-test")) {
                args.smoke_test = true;
            } else if (std.mem.startsWith(u8, a, "--capture-frame=")) {
                args.capture_frame = try std.fmt.parseInt(u32, a[16..], 10);
            } else if (std.mem.startsWith(u8, a, "--gpu-prefer=")) {
                const v = a[13..];
                if (std.mem.eql(u8, v, "discrete")) args.gpu_preference = .discrete else if (std.mem.eql(u8, v, "integrated")) args.gpu_preference = .integrated else if (std.mem.startsWith(u8, v, "index:")) {
                    args.gpu_preference = .{ .index = try std.fmt.parseInt(u32, v[6..], 10) };
                }
            } else if (std.mem.startsWith(u8, a, "--vulkan-driver=")) {
                const v = a[16..];
                if (std.mem.eql(u8, v, "hardware")) args.vulkan_driver = .hardware else if (std.mem.eql(u8, v, "software")) args.vulkan_driver = .software;
            }
        }
        return args;
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const raw_args = try init.minimal.args.toSlice(init.arena.allocator());
    const args = try Args.parse(allocator, raw_args);

    log.info("triangle example — smoke={any} capture={any} gpu={any} driver={any}", .{
        args.smoke_test, args.capture_frame, args.gpu_preference, args.vulkan_driver,
    });

    // Phase 0 scaffolding : utilise le backend Null par défaut. Le backend
    // Vulkan demande window+surface — la conversion `*platform.window.Window`
    // → `gal.types.SurfaceHandle` est la pièce manquante à câbler dans la
    // suite immédiate du milestone (cf. brief §Suppressions src/main.zig).
    try runWithNullBackend(allocator, args);
}

fn runWithNullBackend(allocator: std.mem.Allocator, args: Args) !void {
    var device = try gal.null_backend.Device.init(allocator, .{
        .label = "triangle",
        .gpu_preference = args.gpu_preference,
        .vulkan_driver = args.vulkan_driver,
    });
    defer device.deinit();

    // SPIR-V stub — Phase 0 scaffold, remplacé par
    // `assets/shaders/triangle.{vert,frag}.spv` quand le sous-projet aura
    // accès aux assets cookés.
    const spv: [16]u8 align(4) = [_]u8{ 0x03, 0x02, 0x23, 0x07 } ** 4;
    const vsm = try device.createShaderModule(.{ .code = &spv, .label = "tri.vs" });
    defer device.destroyShaderModule(vsm);
    const fsm = try device.createShaderModule(.{ .code = &spv, .label = "tri.fs" });
    defer device.destroyShaderModule(fsm);

    const layout = try device.createBindGroupLayout(.{ .entries = &.{} });
    defer device.destroyBindGroupLayout(layout);

    const pipeline = try device.createRenderPipeline(.{
        .label = "tri.pso",
        .layout = &.{layout},
        .vertex_module = vsm,
        .fragment_module = fsm,
        .color_targets = &.{.{ .format = .bgra8_unorm }},
        .depth_format = .d32_sfloat,
        .depth_test_enabled = true,
        .depth_write_enabled = true,
    });
    defer device.destroyRenderPipeline(pipeline);

    const swap = try device.createSwapchain(.{ .width = 1280, .height = 720 });
    defer device.destroySwapchain(swap);
    const image_ready = try device.createSemaphore();
    defer device.destroySemaphore(image_ready);
    const render_done = try device.createSemaphore();
    defer device.destroySemaphore(render_done);
    const in_flight = try device.createFence(false);
    defer device.destroyFence(in_flight);

    const max_frames: u32 = if (args.smoke_test) 1 else 1; // Phase 0 : 1 frame en attendant la window loop
    var frame: u32 = 0;
    while (frame < max_frames) : (frame += 1) {
        const image_index = try device.acquireNextImage(swap, image_ready, std.math.maxInt(u64));

        const enc = try device.createCommandEncoder("frame");
        defer device.destroyCommandEncoder(enc);

        // Render pass color-only stub. Le Null backend no-op tout, mais
        // le call site reflète ce que le backend Vulkan exécuterait.
        const color = try device.createTexture(.{
            .format = .bgra8_unorm,
            .width = 1280,
            .height = 720,
            .usage = .{ .color_attachment = true, .copy_src = true },
        });
        defer device.destroyTexture(color);
        const color_view = try device.createTextureView(color, .{});
        defer device.destroyTextureView(color_view);

        var pass = enc.beginRenderPass(.{
            .color_attachments = &.{.{
                .view = color_view,
                .load_op = .clear,
                .store_op = .store,
                .clear_color = .{ .r = 0.05, .g = 0.05, .b = 0.08, .a = 1.0 },
            }},
        });
        pass.setPipeline(pipeline);
        pass.setViewport(0, 0, 1280, 720, 0, 1);
        pass.setScissor(0, 0, 1280, 720);
        pass.draw(3, 1, 0, 0);
        pass.end();
        enc.finish();

        try device.present(swap, image_index, &.{render_done});
        try device.waitFence(in_flight, std.math.maxInt(u64));

        if (args.capture_frame) |target| if (frame == target) {
            log.info("capture stub — Phase 0 scaffold writes nothing (Vulkan path will route through capture pass + readback)", .{});
        };

        if (args.smoke_test) break;
    }

    log.info("triangle example completed {d} frame(s)", .{frame + 1});
}
