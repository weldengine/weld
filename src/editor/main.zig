//! Weld editor stub — owns the listening socket + shm viewport,
//! spawns the runtime, drives the handshake, opens a 1280×720
//! Vulkan window, and presents the runtime-written mire each frame
//! via a fullscreen blit pipeline (cf. `src/editor/vk_blit.zig`).
//!
//! S6 lifecycle (per brief § Scope and § Observable behavior):
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
// M1.1.14 — the engine float environment (`ARCH-031` rule 5): the main thread
// is not born of a spawn, so it is installed here rather than by the job system.
const foundation = @import("foundation");
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
    /// Empty = auto-derive from the editor's own executable directory
    /// (`<exe-dir>/weld-runtime[.exe]`), set after parsing. `--runtime=`
    /// overrides it (e.g. tests passing an explicit path).
    runtime_path: []const u8 = "",
    frames: u64 = 3600,
    no_heartbeat: bool = false,
    no_spawn: bool = false,
};

fn parseArgs(gpa: std.mem.Allocator, init: std.process.Init.Minimal) !Args {
    var a = Args{};
    // `Iterator.init` is a `@compileError` on Windows (no POSIX argv) —
    // the allocator variant parses the wide command line. `init.args`
    // (Juicy Main) is preserved; `deinit` frees the Windows buffer.
    var it = try std.process.Args.Iterator.initAllocator(init.args, gpa);
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

pub fn main(init: std.process.Init) !void {
    // M1.1.14 — the main thread is not born of a spawn, so it does not pass
    // through the job system's worker entry and receives the engine float
    // environment here instead (`ARCH-031` rule 5, `engine-platform.md` §4).
    // First statement, before anything can compute.
    foundation.math.float_env.install();

    // Full Juicy Main (engine-zig-conventions §2 — `Init` for dev tools):
    // `init.arena` is process-lifetime + auto-cleaned; `init.io` drives
    // the executable-directory lookup used to resolve the runtime path.
    const gpa = init.arena.allocator();
    const io = init.io;

    const args = try parseArgs(gpa, init.minimal);

    // Resolve the runtime binary. Without `--runtime=`, derive it from
    // the editor's own executable directory + `weld-runtime[.exe]` —
    // robust against the CWD and OS-correct (CreateProcessW with
    // lpApplicationName needs the exact path, incl. the `.exe` suffix,
    // and does not search PATH).
    const runtime_path: []const u8 = if (args.runtime_path.len != 0)
        args.runtime_path
    else blk: {
        const dir = try std.process.executableDirPathAlloc(io, gpa);
        const exe_name = if (builtin.os.tag == .windows) "weld-runtime.exe" else "weld-runtime";
        break :blk try std.fs.path.join(gpa, &.{ dir, exe_name });
    };

    const my_pid = getpid();
    // OS-correct endpoints. Socket: `/tmp/weld-<pid>.sock` (POSIX Unix
    // socket) vs `\\.\pipe\weld-<pid>` (Windows named pipe), via
    // `transport.buildSocketPath`. Shm name: POSIX `/weld-shm-...` vs
    // Windows session-local `Local\weld-shm-...` (engine-ipc.md §2.2).
    var ep_name_buf: [64]u8 = undefined;
    const ep_name = try std.fmt.bufPrint(&ep_name_buf, "weld-{d}", .{my_pid});
    var sock_path_buf: [128]u8 = undefined;
    const socket_path: []const u8 = try ipc.transport.buildSocketPath(&sock_path_buf, ep_name);
    const shm_name = if (is_posix)
        try std.fmt.allocPrint(gpa, "/weld-shm-viewport-{d}", .{my_pid})
    else
        try std.fmt.allocPrint(gpa, "Local\\weld-shm-viewport-{d}", .{my_pid});

    // ---- Reap orphan sockets / shm regions from any previously
    // crashed editor (engine-ipc.md §2.4). Runs before we create our
    // own endpoints; only dead-PID orphans are removed, so a second
    // live editor is never disturbed. ----
    ipc.cleanup.reapOrphans();

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
    // Snapshot path for SaveProject persistence / replay reload (§7.1).
    // CWD-relative so it resolves identically in the spawned runtime
    // (which inherits this process's CWD) on both POSIX and Windows.
    const snapshot_arg = try std.fmt.allocPrint(gpa, "--snapshot=weld-snapshot-{d}.bin", .{my_pid});

    var spawn_argv = std.ArrayList([]const u8).empty;
    defer spawn_argv.deinit(gpa);
    try spawn_argv.append(gpa, runtime_path);
    try spawn_argv.append(gpa, socket_arg);
    try spawn_argv.append(gpa, shm_arg);
    try spawn_argv.append(gpa, pid_arg);
    const frames_arg = try std.fmt.allocPrint(gpa, "--frames={d}", .{args.frames});
    try spawn_argv.append(gpa, frames_arg);
    try spawn_argv.append(gpa, snapshot_arg);

    var proc_opt: ?platform_process.Process = null;
    if (args.no_spawn) {
        std.debug.print(
            "[editor] --no-spawn: launch the runtime manually with:\n  {s}",
            .{runtime_path},
        );
        for (spawn_argv.items[1..]) |a| std.debug.print(" {s}", .{a});
        std.debug.print("\n[editor] waiting for runtime to connect on {s} ...\n", .{socket_path});
    } else {
        proc_opt = try platform_process.spawnProcess(gpa, runtime_path, spawn_argv.items);
    }

    try server.acceptOne();

    // ---- Handshake ----
    var hello_buf: [framing.frameSizeOf(messages.ProtocolHello)]u8 = undefined;
    const hello = try server.recvHello(&hello_buf);
    if (ipc.server.IpcServer.validateHello(hello)) |_| {
        try server.sendHelloAck(true, "");
    } else |_| {
        try server.sendHelloAck(false, "protocol mismatch");
        if (proc_opt) |*p| _ = try platform_process.waitNonblock(p);
        return error.HandshakeRejected;
    }

    // ---- POSIX shm fd handoff (engine-ipc.md §4.8) ----
    // Hand the runtime the viewport region's fd via SCM_RIGHTS so it
    // maps the framebuffer with ShmRegion.fromFd — never cross-process
    // shm_open. The editor stays the region owner; its own mapping is
    // untouched by the transfer. Windows skips this: the runtime opens
    // the named mapping by name (§2.2), so there is no fd to pass.
    if (is_posix) {
        var handoff = messages.ShmRegionsHandoff{
            .region_count = 1,
            .regions = std.mem.zeroes([messages.MAX_SHM_REGIONS]messages.ShmRegionDesc),
        };
        messages.writeFixedString(&handoff.regions[0].logical_name, "viewport_framebuffer");
        handoff.regions[0].size = viewport.regionSize(
            viewport.default_resolution.width,
            viewport.default_resolution.height,
        );
        try server.connection().sendMessageWithHandles(
            messages.ShmRegionsHandoff,
            0,
            &handoff,
            &[_]ipc.transport.OsHandle{vp.fd()},
        );
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
        _ = try platform_process.waitNonblock(p);
    }
    std.debug.print("editor stub: ipc demo completed cleanly\n", .{});
}
