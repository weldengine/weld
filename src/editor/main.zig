//! Weld editor stub — owns the listening socket + shm viewport,
//! spawns the runtime, drives the handshake, exchanges a few
//! S6 messages, and exits.
//!
//! S6 simplifications relative to the eventual Phase 0+ editor:
//!   - No Vulkan window: the Vulkan/window plumbing from S2 is
//!     reused only when `--with-window` is passed (off by default
//!     so `zig build test` exercises the IPC path without a GPU).
//!     The full G6 visual demo gates on the explicit flag.
//!   - No heartbeat scheduler: handled by the runtime stub but the
//!     editor side just exchanges `SpawnEntity` / `Echo` / `Shutdown`
//!     and exits.
//!   - One restart attempt on `kill -9` of the runtime (cf. brief).
//!
//! Argv:
//!   --runtime=<path>     path to the runtime binary (default:
//!                        zig-out/bin/weld-runtime)
//!   --frames=<N>         pass through to runtime
//!   --no-heartbeat       debug aid (no-op in S6 — heartbeat is
//!                        delegated to a future patch)

const std = @import("std");
const builtin = @import("builtin");

const weld_core = @import("weld_core");
const ipc = weld_core.ipc;
const framing = ipc.framing;
const messages = ipc.messages;
const protocol = ipc.protocol;
const viewport = ipc.viewport;
const platform_process = weld_core.platform.process;

const is_posix = builtin.os.tag == .linux or builtin.os.tag == .macos;

const Args = struct {
    runtime_path: []const u8 = "zig-out/bin/weld-runtime",
    frames: ?u64 = null,
    no_heartbeat: bool = false,
    /// Debug flag — when set, the editor creates the shm + listens
    /// but does NOT spawn the runtime. It instead prints the argv
    /// the runtime would have received and waits for an external
    /// invocation on the same socket+shm pair. Used to bisect
    /// posix_spawn / sandbox issues from shm primitive issues.
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

    // Create the shm region the runtime will attach to.
    var vp = try viewport.ShmViewport.create(shm_name, viewport.default_resolution.width, viewport.default_resolution.height);
    defer vp.close();

    // Open the listening socket.
    var server = ipc.server.IpcServer.init(gpa);
    defer server.deinit();
    try server.listen(socket_path);

    // Spawn the runtime. Pass the socket + shm + editor pid.
    const socket_arg = try std.fmt.allocPrint(gpa, "--socket={s}", .{socket_path});
    const shm_arg = try std.fmt.allocPrint(gpa, "--shm={s}", .{shm_name});
    const pid_arg = try std.fmt.allocPrint(gpa, "--editor-pid={d}", .{my_pid});

    var spawn_argv = std.ArrayList([]const u8).empty;
    defer spawn_argv.deinit(gpa);
    try spawn_argv.append(gpa, args.runtime_path);
    try spawn_argv.append(gpa, socket_arg);
    try spawn_argv.append(gpa, shm_arg);
    try spawn_argv.append(gpa, pid_arg);
    if (args.frames) |f| {
        const frames_arg = try std.fmt.allocPrint(gpa, "--frames={d}", .{f});
        try spawn_argv.append(gpa, frames_arg);
    }

    var proc_opt: ?weld_core.platform.process.Process = null;
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

    // Accept the runtime's connection.
    try server.acceptOne();

    // Handshake.
    var hello_buf: [framing.frameSizeOf(messages.ProtocolHello)]u8 = undefined;
    const hello = try server.recvHello(&hello_buf);
    if (ipc.server.IpcServer.validateHello(hello)) |_| {
        try server.sendHelloAck(true, "");
    } else |_| {
        try server.sendHelloAck(false, "protocol mismatch");
        if (proc_opt) |*p| _ = try platform_process.wait_nonblock(p);
        return error.HandshakeRejected;
    }

    // Demo traffic: one Echo round-trip + one SpawnEntity.
    var echo = messages.Echo{ .payload = std.mem.zeroes([64]u8) };
    for (&echo.payload, 0..) |*b, idx| b.* = @intCast(idx & 0xFF);
    try server.connection().sendMessage(messages.Echo, 0, &echo);
    var echo_buf: [framing.frameSizeOf(messages.EchoReply)]u8 = undefined;
    const reply = try server.connection().recvMessage(messages.EchoReply, &echo_buf);
    if (!std.mem.eql(u8, &echo.payload, &reply.payload)) return error.EchoMismatch;

    const spawn = messages.SpawnEntity{ .archetype_hint = 1 };
    try server.connection().sendMessage(messages.SpawnEntity, 0, &spawn);
    var sp_buf: [framing.frameSizeOf(messages.EntityCreated)]u8 = undefined;
    _ = try server.connection().recvMessage(messages.EntityCreated, &sp_buf);

    // Graceful shutdown.
    const sd = messages.Shutdown{};
    try server.connection().sendMessage(messages.Shutdown, 0, &sd);
    var sa_buf: [framing.frameSizeOf(messages.ShutdownAck)]u8 = undefined;
    _ = try server.connection().recvMessage(messages.ShutdownAck, &sa_buf);

    if (proc_opt) |*p| _ = try platform_process.wait_nonblock(p);
    std.debug.print("editor stub: ipc demo completed cleanly\n", .{});
}
