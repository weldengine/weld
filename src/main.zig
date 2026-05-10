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
//! `--measure-frame-time[=N]` is wired here in step (f) — frame durations
//! are sampled with `std.time.Instant`, sorted, and the median / p95 / max
//! are reported to stdout. The smoke-test PPM capture, 5 s timeout, and
//! SIGINT handling land in step (g).

const std = @import("std");
const builtin = @import("builtin");

const weld_core = @import("weld_core");
const window_mod = weld_core.platform.window;
const vk = weld_core.platform.vk;

const cli = @import("spike/cli.zig");
const vk_setup = @import("spike/vk_setup.zig");
const vk_frame = @import("spike/vk_frame.zig");

const log = std.log.scoped(.s2);

const initial_width: u32 = 800;
const initial_height: u32 = 600;

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
        .width = initial_width,
        .height = initial_height,
    }) catch |err| {
        try stdout.print("window.create failed: {t}\n", .{err});
        return err;
    };
    defer window.destroy();

    // ---- Renderer ----
    var renderer = vk_setup.Renderer.init(gpa, &window, .{
        .width = initial_width,
        .height = initial_height,
    }, args) catch |err| {
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

    // ---- Frame-time sampling (optional) ----
    var timings: ?[]u64 = null;
    var timings_count: usize = 0;
    if (args.measure_frame_time) |n| {
        timings = try gpa.alloc(u64, n);
    }
    defer if (timings) |t| gpa.free(t);

    // ---- Render loop ----
    var should_close = false;
    var frames_presented: u32 = 0;
    while (!should_close) {
        // Drain pending window events.
        while (window.pollEvent()) |event| switch (event) {
            .close => {
                should_close = true;
                if (args.verbose) try stdout.print("[event] close\n", .{});
            },
            .resize => |sz| {
                renderer.last_known_size = .{ .width = sz.width, .height = sz.height };
                renderer.swapchain_dirty = true;
                if (args.verbose) try stdout.print("[event] resize {d}x{d}\n", .{ sz.width, sz.height });
            },
            .dpi_changed => |scale| {
                renderer.swapchain_dirty = true;
                if (args.verbose) try stdout.print("[event] dpi_changed {d:.2}\n", .{scale});
            },
        };

        if (renderer.swapchain_dirty) {
            renderer.recreateSwapchain() catch |err| {
                try stdout.print("recreateSwapchain failed: {t}\n", .{err});
                return err;
            };
        }

        const t0 = std.Io.Clock.now(.awake, init.io);
        const presented = vk_frame.drawFrame(&renderer) catch |err| {
            try stdout.print("drawFrame failed: {t}\n", .{err});
            return err;
        };
        if (presented) {
            if (timings) |buf| if (timings_count < buf.len) {
                const t1 = std.Io.Clock.now(.awake, init.io);
                const elapsed: i96 = t0.durationTo(t1).nanoseconds;
                buf[timings_count] = @intCast(@max(@as(i96, 0), elapsed));
                timings_count += 1;
            };
            frames_presented += 1;
        }

        // Smoke-test budget for step (f): render 10 frames then exit. The
        // PPM capture, 5 s wall-clock timeout, and SIGINT handling land
        // in step (g). For `--measure-frame-time` we run until the
        // sampling buffer is full instead.
        if (args.measure_frame_time) |n| {
            if (timings_count >= n) should_close = true;
        } else if (args.smoke_test and frames_presented >= 10) {
            should_close = true;
        }
    }

    if (args.verbose or args.smoke_test) {
        try stdout.print("frames presented: {d}\n", .{frames_presented});
    }

    if (timings) |buf| if (timings_count > 0) {
        const slice = buf[0..timings_count];
        std.mem.sort(u64, slice, {}, std.sort.asc(u64));
        const median = slice[slice.len / 2];
        const p95_idx = (slice.len * 95) / 100;
        const p95 = slice[@min(p95_idx, slice.len - 1)];
        const max = slice[slice.len - 1];
        try stdout.print(
            "frame-time-ms: median={d:.3} p95={d:.3} max={d:.3} over {d} frames\n",
            .{
                @as(f64, @floatFromInt(median)) / std.time.ns_per_ms,
                @as(f64, @floatFromInt(p95)) / std.time.ns_per_ms,
                @as(f64, @floatFromInt(max)) / std.time.ns_per_ms,
                slice.len,
            },
        );
    };
}
