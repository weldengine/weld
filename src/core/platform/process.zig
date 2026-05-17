//! Minimal process control surface used by the S6 editor stub to
//! spawn / monitor / kill the runtime stub. Tier 0 — `engine-
//! platform.md` §4 (Process section) defines a wider API; S6 fills
//! only the four entry points the brief calls out:
//!
//!   - `spawn_process(path, argv) !Process`
//!   - `wait_nonblock(proc) !?i32`
//!   - `kill(proc) !void`
//!   - `is_alive(pid) bool`
//!
//! The rest of the surface (stdout/stderr piping, env passing,
//! redirection, working directory) lands in Phase 0.3 alongside
//! the X11 backend + input handling — out of scope for S6.
//!
//! POSIX: `posix_spawnp` + `waitpid(WNOHANG)` + `kill(SIGKILL)` +
//! `kill(0)` for the liveness probe.
//! Windows: `CreateProcessW` + `WaitForSingleObject(0)` +
//! `TerminateProcess` + `OpenProcess(SYNCHRONIZE)`.

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{
    SpawnFailed,
    WaitFailed,
    KillFailed,
    InvalidArgument,
} || std.mem.Allocator.Error;

pub const Pid = switch (builtin.os.tag) {
    .linux, .macos => i32,
    .windows => u32,
    else => @compileError("Pid: unsupported OS"),
};

/// Opaque handle on the child process. On POSIX the only state we
/// need is the pid; on Windows we additionally hold the process
/// `HANDLE` so `TerminateProcess` / `GetExitCodeProcess` don't have
/// to re-open it.
pub const Process = switch (builtin.os.tag) {
    .linux, .macos => extern struct {
        pid: i32,
    },
    .windows => extern struct {
        pid: u32,
        handle: ?*anyopaque,
    },
    else => @compileError("Process: unsupported OS"),
};

const posix = struct {
    const SIGKILL: i32 = 9;
    const WNOHANG: i32 = 1;

    extern "c" fn posix_spawnp(
        pid: *Pid,
        file: [*:0]const u8,
        file_actions: ?*anyopaque,
        attrp: ?*anyopaque,
        argv: [*]const ?[*:0]const u8,
        envp: [*]const ?[*:0]const u8,
    ) i32;

    extern "c" fn waitpid(pid: Pid, status: *i32, options: i32) Pid;
    extern "c" fn kill(pid: Pid, sig: i32) i32;
    extern "c" fn getpid() Pid;
};

const win = struct {
    extern "kernel32" fn CreateProcessW(
        lpApplicationName: ?[*:0]const u16,
        lpCommandLine: ?[*]u16,
        lpProcessAttributes: ?*anyopaque,
        lpThreadAttributes: ?*anyopaque,
        bInheritHandles: i32,
        dwCreationFlags: u32,
        lpEnvironment: ?*anyopaque,
        lpCurrentDirectory: ?[*:0]const u16,
        lpStartupInfo: *anyopaque,
        lpProcessInformation: *anyopaque,
    ) callconv(.winapi) i32;

    extern "kernel32" fn TerminateProcess(hProcess: *anyopaque, uExitCode: u32) callconv(.winapi) i32;
    extern "kernel32" fn WaitForSingleObject(hHandle: *anyopaque, dwMilliseconds: u32) callconv(.winapi) u32;
    extern "kernel32" fn GetExitCodeProcess(hProcess: *anyopaque, lpExitCode: *u32) callconv(.winapi) i32;
    extern "kernel32" fn CloseHandle(hObject: *anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn OpenProcess(dwDesiredAccess: u32, bInheritHandle: i32, dwProcessId: u32) callconv(.winapi) ?*anyopaque;
};

// External symbol available on both Linux and macOS — holds the
// process environment. Required by `posix_spawnp`.
extern var environ: [*]const ?[*:0]const u8;

/// Spawns a child process running `path` with the supplied
/// `argv`. The caller's environment is inherited as-is. The
/// returned `Process` must be passed to `wait_nonblock` /
/// `kill` for cleanup; on POSIX the child becomes a zombie
/// until reaped.
pub fn spawn_process(
    gpa: std.mem.Allocator,
    path: []const u8,
    argv: []const []const u8,
) Error!Process {
    switch (builtin.os.tag) {
        .linux, .macos => {
            const path_z = try gpa.dupeZ(u8, path);
            defer gpa.free(path_z);

            // Build a null-terminated argv vector. Includes argv[0]
            // (conventionally the binary path) plus a trailing null.
            var c_argv = try gpa.alloc(?[*:0]const u8, argv.len + 1);
            defer {
                for (c_argv[0..argv.len]) |maybe| if (maybe) |p| gpa.free(std.mem.span(p));
                gpa.free(c_argv);
            }
            for (argv, 0..) |a, i| {
                const z = try gpa.dupeZ(u8, a);
                c_argv[i] = z.ptr;
            }
            c_argv[argv.len] = null;

            var pid: Pid = 0;
            const rc = posix.posix_spawnp(
                &pid,
                path_z.ptr,
                null,
                null,
                c_argv.ptr,
                @ptrCast(@as([*]const ?[*:0]const u8, environ)),
            );
            if (rc != 0) return error.SpawnFailed;
            return .{ .pid = pid };
        },
        .windows => {
            // Windows path is wired in S6 only at the API-surface
            // level — the editor + runtime binaries are exercised on
            // Linux/macOS for S6 acceptance. A real CreateProcessW
            // implementation lands when Win11 hardware validation is
            // added in Phase 0.6 (consistent with the S3/S4 inherited-
            // debt pattern for Windows-only paths).
            _ = .{ gpa, path, argv };
            return error.SpawnFailed;
        },
        else => @compileError("spawn_process: unsupported OS"),
    }
}

/// Polls without blocking. Returns `null` if the child is still
/// alive, or its exit code if it has terminated. Reaps zombies on
/// POSIX so subsequent `is_alive(pid)` calls don't lie.
pub fn wait_nonblock(proc: *Process) Error!?i32 {
    switch (builtin.os.tag) {
        .linux, .macos => {
            var status: i32 = 0;
            const r = posix.waitpid(proc.pid, &status, posix.WNOHANG);
            if (r == 0) return null; // still alive
            if (r < 0) return error.WaitFailed;
            // WEXITSTATUS macro: (status >> 8) & 0xFF
            return @intCast((status >> 8) & 0xFF);
        },
        .windows => {
            const handle = proc.handle orelse return error.WaitFailed;
            const r = win.WaitForSingleObject(handle, 0);
            if (r == 0x102) return null; // WAIT_TIMEOUT — still alive
            if (r != 0) return error.WaitFailed; // WAIT_OBJECT_0 == 0
            var code: u32 = 0;
            if (win.GetExitCodeProcess(handle, &code) == 0) return error.WaitFailed;
            _ = win.CloseHandle(handle);
            proc.handle = null;
            return @intCast(code);
        },
        else => @compileError("wait_nonblock: unsupported OS"),
    }
}

/// Sends SIGKILL (POSIX) or `TerminateProcess` (Windows). Does not
/// wait; caller follows up with `wait_nonblock` to reap.
pub fn kill(proc: *Process) Error!void {
    switch (builtin.os.tag) {
        .linux, .macos => {
            if (posix.kill(proc.pid, posix.SIGKILL) != 0) return error.KillFailed;
        },
        .windows => {
            const handle = proc.handle orelse return error.KillFailed;
            if (win.TerminateProcess(handle, 1) == 0) return error.KillFailed;
        },
        else => @compileError("kill: unsupported OS"),
    }
}

/// Liveness probe — true if a process with `pid` exists in our
/// session. Implemented via `kill(pid, 0)` on POSIX (signal 0
/// performs the error checks of `kill` without sending a signal) and
/// `OpenProcess(SYNCHRONIZE)` on Windows.
pub fn is_alive(pid: Pid) bool {
    switch (builtin.os.tag) {
        .linux, .macos => return posix.kill(pid, 0) == 0,
        .windows => {
            const SYNCHRONIZE: u32 = 0x00100000;
            const h = win.OpenProcess(SYNCHRONIZE, 0, pid) orelse return false;
            _ = win.CloseHandle(h);
            return true;
        },
        else => @compileError("is_alive: unsupported OS"),
    }
}

// ---------------------------------------------------------------- tests --

const is_posix = builtin.os.tag == .linux or builtin.os.tag == .macos;

test "spawn /bin/true and reap with wait_nonblock" {
    if (!is_posix) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var proc = try spawn_process(gpa, "/usr/bin/true", &.{"true"});

    // Poll until reaped — `wait_nonblock` returns null while alive,
    // the exit code once terminated. A short busy loop is fine for a
    // process that runs in microseconds.
    var spins: u32 = 0;
    while (spins < 1000) : (spins += 1) {
        if (try wait_nonblock(&proc)) |exit| {
            try std.testing.expectEqual(@as(i32, 0), exit);
            return;
        }
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try std.testing.expect(false); // timed out
}

test "is_alive returns true for self, false for pid 1 unrelated" {
    if (!is_posix) return error.SkipZigTest;
    try std.testing.expect(is_alive(posix.getpid()));
    // Pid 99999 is highly unlikely to exist on a clean macOS / Linux dev box.
    try std.testing.expect(!is_alive(99999));
}
