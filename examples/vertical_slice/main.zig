//! M0.9 vertical slice — host entry (E4).
//!
//! Boots the ECS world + cooked Etch gameplay (sim.zig), then dispatches on
//! platform + flags:
//!   - default (Vulkan-capable + window): `render.runInteractive` — windowed
//!     forward render of the live scene, M0.3 input (SPACE toggles pause)
//!     driving the sim.
//!   - `--smoke-test`: `render.runSmoke` — headless offscreen render of the
//!     final state → PPM capture (CI lavapipe; "the frame composes").
//!   - `--headless` (or no Vulkan window backend, e.g. macOS Phase 0): pure
//!     60 Hz sim loop, prints the E3 OK line. No GPU.
//!
//! `sim` + `render` are re-exported so the integration test (which imports this
//! module as `slice`) reaches the pure helpers and `render.composeNull`.

const std = @import("std");
const builtin = @import("builtin");
const weld_core = @import("weld_core");

pub const sim = @import("sim.zig");
pub const render = @import("render.zig");

const World = weld_core.ecs.world.World;
const log = std.log.scoped(.vertical_slice);

/// Where the cook step installs the runtime `.texture.bin` (see build.zig).
const default_asset = "zig-out/vertical-slice-assets/slice_albedo.texture.bin";
const default_capture = "out/vertical_slice.ppm";

fn supportsVulkanWindow() bool {
    return switch (builtin.os.tag) {
        .windows, .linux => true,
        else => false,
    };
}

const Mode = enum { auto, headless, smoke };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var mode: Mode = .auto;
    var ticks: u32 = sim.default_ticks;
    var asset_path: []const u8 = default_asset;
    var capture_path: []const u8 = default_capture;
    var ai: usize = 1;
    while (ai < args.len) : (ai += 1) {
        const a = args[ai];
        if (std.mem.eql(u8, a, "--headless")) {
            mode = .headless;
        } else if (std.mem.eql(u8, a, "--smoke-test")) {
            mode = .smoke;
        } else if (std.mem.eql(u8, a, "--ticks") and ai + 1 < args.len) {
            ticks = std.fmt.parseInt(u32, args[ai + 1], 10) catch sim.default_ticks;
            ai += 1;
        } else if (std.mem.eql(u8, a, "--asset") and ai + 1 < args.len) {
            asset_path = args[ai + 1];
            ai += 1;
        } else if (std.mem.eql(u8, a, "--capture") and ai + 1 < args.len) {
            capture_path = args[ai + 1];
            ai += 1;
        }
    }

    var world = World.init();
    defer world.deinit(gpa);
    try sim.bootAndSpawn(&world, gpa);

    switch (mode) {
        .smoke => {
            if (supportsVulkanWindow()) {
                render.runSmoke(gpa, io, &world, asset_path, ticks, capture_path) catch |e| {
                    log.warn("smoke render failed ({t}); falling back to headless sim", .{e});
                    try runHeadless(&world, gpa, io, ticks);
                };
            } else {
                try runHeadless(&world, gpa, io, ticks);
            }
        },
        .headless => try runHeadless(&world, gpa, io, ticks),
        .auto => {
            if (supportsVulkanWindow()) {
                render.runInteractive(gpa, io, &world, asset_path) catch |e| {
                    log.warn("interactive render failed ({t}); falling back to headless sim", .{e});
                    try runHeadless(&world, gpa, io, ticks);
                };
            } else {
                try runHeadless(&world, gpa, io, ticks);
            }
        },
    }
}

/// Pure 60 Hz simulation loop (no GPU) — the E3 behaviour, used on macOS dev
/// and as the render fallback.
fn runHeadless(world: *World, gpa: std.mem.Allocator, io: std.Io, ticks: u32) !void {
    var t: u32 = 0;
    while (t < ticks) : (t += 1) sim.step(world, gpa);

    var out_buf: [256]u8 = undefined;
    var out_w = std.Io.File.stdout().writer(io, &out_buf);
    const out = &out_w.interface;
    try out.print(
        "vertical-slice headless OK | entities={d} ticks={d} dt={d:.5}\n",
        .{ sim.entity_count, ticks, sim.fixed_dt },
    );
    try out.flush();
}
