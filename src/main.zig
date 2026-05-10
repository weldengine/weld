//! S2 spike binary entry point. Throwaway with the rest of `src/spike/`;
//! Phase 0.4 refactors this into the GAL.
//!
//! Drives the loop:
//!   * parse CLI flags (`cli.zig`)
//!   * open a `Window` via the platform layer
//!   * stand up a Vulkan triangle renderer (`vk_setup.zig`)
//!   * pump events, draw frames (`vk_frame.zig`)
//!   * capture a PPM in smoke-test mode (`ppm.zig`)
//!   * tear everything down on close
//!
//! `--measure-frame-time[=N]` (step f) samples `std.Io.Clock.now(.awake, io)`
//! around each `drawFrame` and reports median / p95 / max.
//!
//! Step (g) adds: PPM capture of the last presented swapchain image to
//! `zig-out/smoke/<os>-<gpu>.ppm`, a 5 s wall-clock budget for smoke-test
//! mode, and SIGINT / CTRL_C_EVENT handling. Exit codes:
//!   * 0  — clean exit (interactive close, frame budget reached, capture OK)
//!   * 1  — timeout, capture failure, or any other initialisation error
//!   * 130 — SIGINT / CTRL_C_EVENT received

const std = @import("std");
const builtin = @import("builtin");

const weld_core = @import("weld_core");
const window_mod = weld_core.platform.window;
const vk = weld_core.platform.vk;

const cli = @import("spike/cli.zig");
const vk_setup = @import("spike/vk_setup.zig");
const vk_frame = @import("spike/vk_frame.zig");
const ppm = @import("spike/ppm.zig");

const log = std.log.scoped(.s2);

const initial_width: u32 = 800;
const initial_height: u32 = 600;
const smoke_test_timeout_ns: u64 = 5 * std.time.ns_per_s;
const smoke_test_target_frames: u32 = 10;

/// Set asynchronously by the SIGINT / CTRL_C_EVENT handler. The handler
/// only writes this atomic — every other side-effect (logging, teardown)
/// happens from the main thread when the loop observes the flag.
var interrupted: std.atomic.Value(bool) = .init(false);

fn handlePosixSigint(_: std.posix.SIG) callconv(.c) void {
    interrupted.store(true, .monotonic);
}

fn handleWindowsCtrl(_: u32) callconv(.winapi) i32 {
    interrupted.store(true, .monotonic);
    return 1; // TRUE — we consumed the event
}

extern "kernel32" fn SetConsoleCtrlHandler(
    HandlerRoutine: ?*const fn (u32) callconv(.winapi) i32,
    Add: i32,
) callconv(.winapi) i32;

fn installInterruptHandlers() void {
    if (builtin.os.tag == .windows) {
        _ = SetConsoleCtrlHandler(&handleWindowsCtrl, 1);
        return;
    }
    const sa: std.posix.Sigaction = .{
        .handler = .{ .handler = &handlePosixSigint },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &sa, null);
}

pub fn main(init: std.process.Init) !u8 {
    var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_alloc.deinit();
    const gpa = debug_alloc.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    installInterruptHandlers();

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
    var exit_code: u8 = 0;
    const wall_start = std.Io.Clock.now(.awake, init.io);
    while (!should_close) {
        if (interrupted.load(.monotonic)) {
            try stdout.print("[interrupt] SIGINT received — clean teardown\n", .{});
            exit_code = 130;
            break;
        }

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

        // Termination conditions. For `--measure-frame-time` we run until
        // the sampling buffer is full. `--smoke-test` exits after
        // `smoke_test_target_frames` are presented OR the 5 s wall-clock
        // budget is exhausted (exit code 1 in that case).
        if (args.measure_frame_time) |n| {
            if (timings_count >= n) should_close = true;
        } else if (args.smoke_test and frames_presented >= smoke_test_target_frames) {
            should_close = true;
        }

        if (args.smoke_test) {
            const now = std.Io.Clock.now(.awake, init.io);
            const elapsed_ns: i96 = wall_start.durationTo(now).nanoseconds;
            if (elapsed_ns > @as(i96, smoke_test_timeout_ns) and frames_presented < smoke_test_target_frames) {
                try stdout.print(
                    "[timeout] smoke-test wall-clock exceeded 5s ({d} frames presented)\n",
                    .{frames_presented},
                );
                exit_code = 1;
                break;
            }
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

    // ---- Smoke-test PPM capture ----
    // Captured only on a successful smoke-test run (full frame budget,
    // no SIGINT, no timeout). The brief specifies
    // `zig-out/smoke/<os>-<gpu_name>.ppm`.
    if (args.smoke_test and exit_code == 0 and frames_presented >= smoke_test_target_frames) {
        const out_dir_rel = "zig-out/smoke";
        const cwd = std.Io.Dir.cwd();
        cwd.createDirPath(init.io, out_dir_rel) catch |err| {
            try stdout.print("createDirPath({s}) failed: {t}\n", .{ out_dir_rel, err });
            return 1;
        };
        const gpu_name = std.mem.sliceTo(&renderer.physical_device_name, 0);
        const file_name = try ppmFileName(gpa, gpu_name);
        defer gpa.free(file_name);
        const full_path = try std.fs.path.join(gpa, &.{ out_dir_rel, file_name });
        defer gpa.free(full_path);
        ppm.capture(&renderer, gpa, init.io, cwd, full_path) catch |err| {
            try stdout.print("PPM capture failed: {t}\n", .{err});
            return 1;
        };
        if (args.verbose or args.smoke_test) {
            try stdout.print("wrote {s}\n", .{full_path});
        }
    }

    return exit_code;
}

/// Build a filesystem-friendly `<os>-<gpu>.ppm` leaf name. The sanitiser
/// keeps `[a-z0-9-]`, lowercases, and folds any other byte to `_`. The
/// upstream device name may contain spaces, parens, or vendor suffixes —
/// none of which should leak into a file path.
fn ppmFileName(gpa: std.mem.Allocator, gpu_name: []const u8) ![]u8 {
    const os_tag = @tagName(builtin.os.tag);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, os_tag);
    try buf.append(gpa, '-');
    var prev_underscore = false;
    for (gpu_name) |b| {
        const c: u8 = switch (b) {
            'A'...'Z' => b + 32,
            'a'...'z', '0'...'9', '-' => b,
            else => '_',
        };
        if (c == '_') {
            if (prev_underscore) continue;
            prev_underscore = true;
        } else {
            prev_underscore = false;
        }
        try buf.append(gpa, c);
    }
    // Trim any trailing underscore for tidier names.
    while (buf.items.len > 0 and buf.items[buf.items.len - 1] == '_') {
        _ = buf.pop();
    }
    try buf.appendSlice(gpa, ".ppm");
    return buf.toOwnedSlice(gpa);
}
