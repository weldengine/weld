//! Weld editor stub — owns the listening socket + shm viewport,
//! spawns the runtime, drives the handshake, opens a 1280×720
//! Vulkan window, and presents the runtime-written mire each frame
//! via a fullscreen blit pipeline (cf. `src/editor/vk_blit.zig`).
//!
//! S6 lifecycle (per brief § Scope and § Comportement observable):
//!   1. Create the shm region (`/weld-shm-viewport-<pid>`).
//!   2. Open the Vulkan-capable window at the brief's resolution.
//!   3. Initialise the blit renderer (instance, device, swapchain,
//!      sampled image bound to the viewport, fullscreen pipeline).
//!   4. Listen on the IPC socket, spawn the runtime (unless
//!      `--no-spawn`), accept the connection.
//!   5. Exchange `ProtocolHello` / `ProtocolHelloAck`.
//!   6. Loop: poll window events, snapshot the runtime's published
//!      slot from shm, stage + blit, drain IPC, present.
//!   7. Send `Shutdown`, await `ShutdownAck`, exit.
//!
//! Argv:
//!   --runtime=<path>     path to the runtime binary
//!   --frames=<N>         render-loop frame budget (default: 3600 ≈ 60 s)
//!   --no-heartbeat       debug aid (no-op in S6 — runtime side
//!                        replies inline)
//!   --no-spawn           do not spawn the runtime; print argv and
//!                        wait for an external invocation. Used to
//!                        bisect spawn vs primitive issues.

const std = @import("std");
const builtin = @import("builtin");

const weld_core = @import("weld_core");
const ipc = weld_core.ipc;
const framing = ipc.framing;
const messages = ipc.messages;
const protocol = ipc.protocol;
const viewport = ipc.viewport;
const platform_process = weld_core.platform.process;
const window_mod = weld_core.platform.window;
const vk = weld_core.platform.vk;
const vk_blit = @import("vk_blit.zig");

const is_posix = builtin.os.tag == .linux or builtin.os.tag == .macos;

const Args = struct {
    runtime_path: []const u8 = "zig-out/bin/weld-runtime",
    frames: u64 = 3600,
    no_heartbeat: bool = false,
    no_spawn: bool = false,
};

fn parseArgs(gpa: std.mem.Allocator, init: std.process.Init.Minimal) !Args {
    var a = Args{};
    var it = std.process.Args.Iterator.init(init.args);
    defer it.deinit();
    _ = it.skip();
    while (it.next()) |s| {
        if (std.mem.startsWith(u8, s, "--runtime=")) {
            a.runtime_path = try gpa.dupe(u8, s["--runtime=".len..]);
        } else if (std.mem.startsWith(u8, s, "--frames=")) {
            a.frames = try std.fmt.parseInt(u64, s["--frames=".len..], 10);
        } else if (std.mem.eql(u8, s, "--no-heartbeat")) {
            a.no_heartbeat = true;
        } else if (std.mem.eql(u8, s, "--no-spawn")) {
            a.no_spawn = true;
        }
    }
    return a;
}

extern "c" fn getpid() i32;

const timespec_t = extern struct { tv_sec: i64, tv_nsec: i64 };
extern "c" fn nanosleep(req: *const timespec_t, rem: ?*timespec_t) c_int;

fn sleepMs(ms: u64) void {
    var ts = timespec_t{
        .tv_sec = @intCast(ms / 1_000),
        .tv_nsec = @intCast((ms % 1_000) * std.time.ns_per_ms),
    };
    _ = nanosleep(&ts, null);
}

pub fn main(init: std.process.Init.Minimal) !void {
    if (!is_posix) {
        std.debug.print("editor stub: Windows path not implemented in S6 (cf. brief)\n", .{});
        return error.Unimplemented;
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const args = try parseArgs(gpa, init);

    const my_pid = getpid();
    const socket_path = try std.fmt.allocPrint(gpa, "/tmp/weld-{d}.sock", .{my_pid});
    const shm_name = try std.fmt.allocPrint(gpa, "/weld-shm-viewport-{d}", .{my_pid});

    // ---- shm region (created before everything else; runtime
    // attaches to it once spawned) ----
    var vp = try viewport.ShmViewport.create(
        shm_name,
        viewport.default_resolution.width,
        viewport.default_resolution.height,
    );
    defer vp.close();

    // ---- Window (S2 platform layer) ----
    var window = try window_mod.Window.create(gpa, .{
        .title = "Weld Editor — S6 viewport blit",
        .width = viewport.default_resolution.width,
        .height = viewport.default_resolution.height,
    });
    defer window.destroy();

    // ---- Vulkan blit renderer ----
    var renderer = try vk_blit.Renderer.init(gpa, &window, .{
        .width = viewport.default_resolution.width,
        .height = viewport.default_resolution.height,
    });
    defer renderer.deinit();

    // ---- IPC listen socket ----
    var server = ipc.server.IpcServer.init(gpa);
    defer server.deinit();
    try server.listen(socket_path);

    // ---- Spawn (or wait for) the runtime ----
    const socket_arg = try std.fmt.allocPrint(gpa, "--socket={s}", .{socket_path});
    const shm_arg = try std.fmt.allocPrint(gpa, "--shm={s}", .{shm_name});
    const pid_arg = try std.fmt.allocPrint(gpa, "--editor-pid={d}", .{my_pid});

    var spawn_argv = std.ArrayList([]const u8).empty;
    defer spawn_argv.deinit(gpa);
    try spawn_argv.append(gpa, args.runtime_path);
    try spawn_argv.append(gpa, socket_arg);
    try spawn_argv.append(gpa, shm_arg);
    try spawn_argv.append(gpa, pid_arg);
    const frames_arg = try std.fmt.allocPrint(gpa, "--frames={d}", .{args.frames});
    try spawn_argv.append(gpa, frames_arg);

    var proc_opt: ?platform_process.Process = null;
    if (args.no_spawn) {
        std.debug.print(
            "[editor] --no-spawn: launch the runtime manually with:\n  {s}",
            .{args.runtime_path},
        );
        for (spawn_argv.items[1..]) |a| std.debug.print(" {s}", .{a});
        std.debug.print("\n[editor] waiting for runtime to connect on {s} ...\n", .{socket_path});
    } else {
        proc_opt = try platform_process.spawn_process(gpa, args.runtime_path, spawn_argv.items);
    }

    try server.acceptOne();

    // ---- Handshake ----
    var hello_buf: [framing.frameSizeOf(messages.ProtocolHello)]u8 = undefined;
    const hello = try server.recvHello(&hello_buf);
    if (ipc.server.IpcServer.validateHello(hello)) |_| {
        try server.sendHelloAck(true, "");
    } else |_| {
        try server.sendHelloAck(false, "protocol mismatch");
        if (proc_opt) |*p| _ = try platform_process.wait_nonblock(p);
        return error.HandshakeRejected;
    }

    // ---- Render loop ----
    var frame: u64 = 0;
    var should_close = false;
    var last_frame_id: u64 = 0;
    while (frame < args.frames and !should_close) {
        while (window.pollEvent()) |event| switch (event) {
            .close => should_close = true,
            .resize => |sz| {
                renderer.last_known_size = .{ .width = sz.width, .height = sz.height };
                renderer.swapchain_dirty = true;
            },
            .dpi_changed => renderer.swapchain_dirty = true,
            // M0.3 — new Event variants ignored by the S6 editor stub.
            else => {},
        };
        if (should_close) break;

        if (renderer.swapchain_dirty) try renderer.recreateSwapchain();

        // Snapshot the runtime's latest committed slot. The mire
        // is published with `.release` so this `acquire`-paired
        // read pairs with it.
        const slot = vp.readSlot();
        const frame_id = vp.frameId();
        if (frame_id != last_frame_id) {
            renderer.stageViewport(vp.slotBytes(slot));
            last_frame_id = frame_id;
        }

        _ = try vk_blit.drawFrame(&renderer);

        sleepMs(16); // soft cap at ~60 Hz; window vsync owns the real cadence
        frame += 1;
    }

    // ---- Graceful shutdown ----
    const sd = messages.Shutdown{};
    server.connection().sendMessage(messages.Shutdown, 0, &sd) catch {};
    var sa_buf: [framing.frameSizeOf(messages.ShutdownAck)]u8 = undefined;
    _ = server.connection().recvMessage(messages.ShutdownAck, &sa_buf) catch {};

    if (proc_opt) |*p| {
        // Give the runtime a beat to flush its exit path before
        // we reap.
        sleepMs(20);
        _ = try platform_process.wait_nonblock(p);
    }
    std.debug.print("editor stub: ipc demo completed cleanly\n", .{});
}
