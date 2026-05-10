//! S2 spike binary entry point. Throwaway with the rest of `src/spike/`;
//! Phase 0.4 refactors this into the GAL.
//!
//! Drives the loop:
//!   * parse CLI flags (`cli.zig`)
//!   * open a `Window` via the platform layer
//!   * stand up a Vulkan triangle renderer (`vk_setup.zig`)
//!   * pump events, draw frames (`vk_frame.zig`)
//!   * tear everything down on close
//!
//! The smoke-test (PPM capture) and frame-time measurement modes wire in
//! during step (g); for step (f) the binary just opens the window and
//! renders the triangle until the user closes it.

const std = @import("std");
const builtin = @import("builtin");

const weld_core = @import("weld_core");
const window_mod = weld_core.platform.window;

const cli = @import("spike/cli.zig");
const vk_setup = @import("spike/vk_setup.zig");
const vk_frame = @import("spike/vk_frame.zig");

const log = std.log.scoped(.s2);

pub fn main(init: std.process.Init) !void {
    var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_alloc.deinit();
    const gpa = debug_alloc.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    // ---- CLI ----
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    const args_slice = if (argv.len > 1) argv[1..] else argv[0..0];
    const args = cli.parse(args_slice) catch |err| {
        try stdout.print("CLI parse error: {t}\n", .{err});
        return err;
    };

    if (args.verbose or args.smoke_test) {
        try stdout.print(
            "Weld S2 spike — mode={s}{s}\n",
            .{
                if (args.smoke_test) "smoke-test" else "interactive",
                if (args.measure_frame_time) |n| blk: {
                    var buf: [64]u8 = undefined;
                    break :blk std.fmt.bufPrint(&buf, " measure={d}", .{n}) catch "";
                } else "",
            },
        );
    }

    // ---- Window ----
    var window = window_mod.Window.create(gpa, .{
        .title = "Weld S2",
        .width = 800,
        .height = 600,
    }) catch |err| {
        try stdout.print("window.create failed: {t}\n", .{err});
        // Match the brief's exit codes: smoke-test returns 1 on hard failure.
        return err;
    };
    defer window.destroy();

    // ---- Renderer ----
    var renderer = vk_setup.Renderer.init(gpa, &window, args) catch |err| {
        try stdout.print("renderer.init failed: {t}\n", .{err});
        return err;
    };
    defer renderer.deinit();

    if (args.verbose or args.smoke_test) {
        const name = std.mem.sliceTo(&renderer.physical_device_name, 0);
        try stdout.print("Selected GPU: {s}\n", .{name});
        try stdout.print(
            "Swapchain: {d}x{d}, format={t}\n",
            .{ renderer.swapchain_extent.width, renderer.swapchain_extent.height, renderer.swapchain_format },
        );
    }

    // ---- Render loop ----
    var should_close = false;
    var frames_presented: u32 = 0;
    while (!should_close) {
        // Drain pending window events.
        while (window.pollEvent()) |event| switch (event) {
            .close => {
                should_close = true;
                if (args.verbose) try stdout.print("event: close\n", .{});
            },
            .resize => |sz| {
                renderer.swapchain_dirty = true;
                if (args.verbose) try stdout.print("event: resize {d}x{d}\n", .{ sz.width, sz.height });
            },
            .dpi_changed => |scale| {
                renderer.swapchain_dirty = true;
                if (args.verbose) try stdout.print("event: dpi_changed {d:.2}\n", .{scale});
            },
        };

        if (renderer.swapchain_dirty) {
            renderer.recreateSwapchain(&window) catch |err| {
                try stdout.print("recreateSwapchain failed: {t}\n", .{err});
                return err;
            };
        }

        const presented = vk_frame.drawFrame(&renderer) catch |err| {
            try stdout.print("drawFrame failed: {t}\n", .{err});
            return err;
        };
        if (presented) frames_presented += 1;

        // Smoke-test budget — render 10 frames then exit. Capture wiring
        // lands in step (g). For now, just exits cleanly so step (f) is
        // visibly green on the validation matrix.
        if (args.smoke_test and frames_presented >= 10) should_close = true;
    }

    if (args.verbose or args.smoke_test) {
        try stdout.print("frames presented: {d}\n", .{frames_presented});
    }
}
