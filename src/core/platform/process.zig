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

/// Error set surfaced by `spawn` / `wait_nonblock` / `kill`.
pub const Error = error{
    SpawnFailed,
    WaitFailed,
    KillFailed,
    InvalidArgument,
} || std.mem.Allocator.Error;

/// OS-native process identifier — signed on POSIX, unsigned on
/// Windows. Used by `spawn` / `wait_nonblock` / `kill` to track a
/// child runtime process.
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

/// `STARTUPINFOW` — `cb` must be `@sizeOf(STARTUPINFOW)`; the rest is
/// zeroed for a plain console-less spawn (we inherit nothing and pipe
/// nothing — stdio piping is Phase 0.3 per the file header).
const STARTUPINFOW = extern struct {
    cb: u32,
    lpReserved: ?[*:0]u16,
    lpDesktop: ?[*:0]u16,
    lpTitle: ?[*:0]u16,
    dwX: u32,
    dwY: u32,
    dwXSize: u32,
    dwYSize: u32,
    dwXCountChars: u32,
    dwYCountChars: u32,
    dwFillAttribute: u32,
    dwFlags: u32,
    wShowWindow: u16,
    cbReserved2: u16,
    lpReserved2: ?[*]u8,
    hStdInput: ?*anyopaque,
    hStdOutput: ?*anyopaque,
    hStdError: ?*anyopaque,
};

/// `PROCESS_INFORMATION` — filled by `CreateProcessW` with the child's
/// process + primary-thread handles and ids.
const PROCESS_INFORMATION = extern struct {
    hProcess: ?*anyopaque,
    hThread: ?*anyopaque,
    dwProcessId: u32,
    dwThreadId: u32,
};

// `posix_spawnp` needs the parent process's `envp` pointer. The
// underlying symbol is OS-specific: Linux/glibc exposes a real
// `environ` global; macOS hides it behind `_NSGetEnviron()` to
// allow the two-level namespace dyld to relocate it.
extern "c" fn _NSGetEnviron() *[*]const ?[*:0]const u8;
extern var environ: [*]const ?[*:0]const u8;

fn currentEnvp() [*]const ?[*:0]const u8 {
    return switch (builtin.os.tag) {
        .macos => _NSGetEnviron().*,
        .linux => environ,
        else => @compileError("currentEnvp: unsupported OS"),
    };
}

/// Quotes a single argument for a Windows command line per the MSVCRT /
/// `CommandLineToArgvW` rules, so the spawned process reconstructs
/// `argv[i]` byte-for-byte — including the tricky cases the naive
/// `"arg"` wrapping gets wrong (a path ending in one or more `\`, or an
/// argument containing `"`). Caller owns the returned slice.
///
/// Operates on UTF-8: every metacharacter (` `, `\t`, `\n`, vertical
/// tab, `"`, `\`) is ASCII and UTF-8 is ASCII-transparent, so byte-wise
/// quoting matches the wide-char algorithm `CreateProcessW` will parse.
///
/// Algorithm (Daniel Colascione's `ArgvQuote`): emit the argument
/// verbatim when it is non-empty and contains no whitespace or `"`;
/// otherwise wrap in `"` and, scanning runs of backslashes, double them
/// before a `"` (literal or the closing one) and leave them as-is
/// elsewhere.
pub fn quoteArg(gpa: std.mem.Allocator, arg: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    if (arg.len != 0 and std.mem.indexOfAny(u8, arg, " \t\n\x0B\"") == null) {
        try out.appendSlice(gpa, arg);
        return out.toOwnedSlice(gpa);
    }

    try out.append(gpa, '"');
    var i: usize = 0;
    while (i < arg.len) {
        var backslashes: usize = 0;
        while (i < arg.len and arg[i] == '\\') : (i += 1) backslashes += 1;
        if (i == arg.len) {
            // Trailing backslashes precede the closing quote — double them
            // so the quote stays a delimiter, not an escaped literal.
            try out.appendNTimes(gpa, '\\', backslashes * 2);
            break;
        } else if (arg[i] == '"') {
            // Escape the run of backslashes AND the embedded quote.
            try out.appendNTimes(gpa, '\\', backslashes * 2 + 1);
            try out.append(gpa, '"');
            i += 1;
        } else {
            // Backslashes are literal away from a quote.
            try out.appendNTimes(gpa, '\\', backslashes);
            try out.append(gpa, arg[i]);
            i += 1;
        }
    }
    try out.append(gpa, '"');
    return out.toOwnedSlice(gpa);
}

/// UTF-8 → NUL-terminated UTF-16LE for the Win32 wide APIs, remapping a
/// non-UTF-8 input to `error.InvalidArgument` (it is invalid caller
/// input, not an engine fault) so the process `Error` set stays free of
/// a Unicode member. Caller owns the returned slice.
fn utf8ToUtf16Z(gpa: std.mem.Allocator, s: []const u8) error{ InvalidArgument, OutOfMemory }![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(gpa, s) catch |e| switch (e) {
        error.InvalidUtf8 => error.InvalidArgument,
        error.OutOfMemory => error.OutOfMemory,
    };
}

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
                currentEnvp(),
            );
            if (rc != 0) return error.SpawnFailed;
            return .{ .pid = pid };
        },
        .windows => {
            // Build a UTF-8 command line (each arg quoted), convert to
            // UTF-16, and spawn via CreateProcessW. `lpApplicationName`
            // pins the binary; argv[0] stays in the command line by
            // convention. M0.7 / E3 — wires the Windows editor path.
            var cmd: std.ArrayList(u8) = .empty;
            defer cmd.deinit(gpa);
            for (argv, 0..) |a, i| {
                if (i != 0) try cmd.append(gpa, ' ');
                const quoted = try quoteArg(gpa, a);
                defer gpa.free(quoted);
                try cmd.appendSlice(gpa, quoted);
            }
            const cmd_w = try utf8ToUtf16Z(gpa, cmd.items);
            defer gpa.free(cmd_w);
            const path_w = try utf8ToUtf16Z(gpa, path);
            defer gpa.free(path_w);

            var si: STARTUPINFOW = std.mem.zeroes(STARTUPINFOW);
            si.cb = @sizeOf(STARTUPINFOW);
            var pi: PROCESS_INFORMATION = std.mem.zeroes(PROCESS_INFORMATION);

            const ok = win.CreateProcessW(
                path_w.ptr,
                cmd_w.ptr,
                null,
                null,
                0, // bInheritHandles = FALSE
                0, // dwCreationFlags
                null,
                null,
                @ptrCast(&si),
                @ptrCast(&pi),
            );
            if (ok == 0) return error.SpawnFailed;
            // The primary-thread handle is unused; close it now. The
            // process handle is retained for `wait_nonblock` / `kill`.
            if (pi.hThread) |h| _ = win.CloseHandle(h);
            return .{ .pid = pi.dwProcessId, .handle = pi.hProcess };
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

// Runtime tests live in `tests/ipc/process.zig` — see that file
// for spawn + reap + is_alive + kill coverage.
