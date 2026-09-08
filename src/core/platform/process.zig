//! FROZEN — see engine-phase-0-criteria.md C0.5
//!
//! No stdio piping, no redirection, no working directory: the child inherits the
//! parent's environment as-is and its output goes wherever the parent's goes.

const std = @import("std");
const builtin = @import("builtin");

/// Error set surfaced by `spawn` / `waitNonblock` / `kill`.
pub const Error = error{
    SpawnFailed,
    WaitFailed,
    KillFailed,
    InvalidArgument,
} || std.mem.Allocator.Error;

/// OS-native process id — SIGNED on POSIX, unsigned on Windows.
pub const Pid = switch (builtin.os.tag) {
    .linux, .macos => i32,
    .windows => u32,
    else => @compileError("Pid: unsupported OS"),
};

/// Child-process handle; the Windows arm also retains the OS `HANDLE`.
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
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
};

/// `cb` MUST be `@sizeOf(STARTUPINFOW)` or `CreateProcessW` refuses the call.
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

const PROCESS_INFORMATION = extern struct {
    hProcess: ?*anyopaque,
    hThread: ?*anyopaque,
    dwProcessId: u32,
    dwThreadId: u32,
};

// Linux/glibc exposes a real `environ` global; macOS hides it behind
// `_NSGetEnviron()` so two-level-namespace dyld can relocate it.
extern "c" fn _NSGetEnviron() *[*]const ?[*:0]const u8;
extern var environ: [*]const ?[*:0]const u8;

fn currentEnvp() [*]const ?[*:0]const u8 {
    return switch (builtin.os.tag) {
        .macos => _NSGetEnviron().*,
        .linux => environ,
        else => @compileError("currentEnvp: unsupported OS"),
    };
}

/// Quote one argument per the `CommandLineToArgvW` rules. Caller owns the slice.
/// The naive `"arg"` wrapping is WRONG for a trailing `\` run or an embedded `"`.
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
            // Doubled so the closing quote stays a delimiter, not an escaped literal.
            try out.appendNTimes(gpa, '\\', backslashes * 2);
            break;
        } else if (arg[i] == '"') {
            try out.appendNTimes(gpa, '\\', backslashes * 2 + 1);
            try out.append(gpa, '"');
            i += 1;
        } else {
            try out.appendNTimes(gpa, '\\', backslashes);
            try out.append(gpa, arg[i]);
            i += 1;
        }
    }
    try out.append(gpa, '"');
    return out.toOwnedSlice(gpa);
}

fn utf8ToUtf16Z(gpa: std.mem.Allocator, s: []const u8) error{ InvalidArgument, OutOfMemory }![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(gpa, s) catch |e| switch (e) {
        error.InvalidUtf8 => error.InvalidArgument,
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Spawn `path` with `argv`; the caller's environment is inherited as-is.
/// On POSIX the child stays a ZOMBIE until `waitNonblock` reaps it.
pub fn spawnProcess(
    gpa: std.mem.Allocator,
    path: []const u8,
    argv: []const []const u8,
) Error!Process {
    switch (builtin.os.tag) {
        .linux, .macos => {
            const path_z = try gpa.dupeZ(u8, path);
            defer gpa.free(path_z);

            // `argv` must already carry argv[0]; only the trailing null is added.
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
            // `lpApplicationName` pins the binary; argv[0] must still lead the command line.
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
            if (ok == 0) {
                // Without the last-error the caller sees only an opaque `SpawnFailed`.
                std.log.scoped(.process).err(
                    "CreateProcessW failed: path='{s}' GetLastError={d}",
                    .{ path, win.GetLastError() },
                );
                return error.SpawnFailed;
            }
            // Close the unused thread handle; the process handle is kept for wait/kill.
            if (pi.hThread) |h| _ = win.CloseHandle(h);
            return .{ .pid = pi.dwProcessId, .handle = pi.hProcess };
        },
        else => @compileError("spawnProcess: unsupported OS"),
    }
}

/// Poll without blocking: `null` while the child lives, else its exit code.
/// Reaps the POSIX zombie, without which `isAlive(pid)` keeps answering true.
pub fn waitNonblock(proc: *Process) Error!?i32 {
    switch (builtin.os.tag) {
        .linux, .macos => {
            var status: i32 = 0;
            const r = posix.waitpid(proc.pid, &status, posix.WNOHANG);
            if (r == 0) return null; // still alive
            if (r < 0) return error.WaitFailed;
            // `WEXITSTATUS` is exactly this shift and mask — not `status` itself.
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
        else => @compileError("waitNonblock: unsupported OS"),
    }
}

/// SIGKILL or `TerminateProcess`; does not wait — follow with `waitNonblock`.
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

/// True if `pid` exists AND we may signal it; a foreign-owned pid answers false.
pub fn isAlive(pid: Pid) bool {
    switch (builtin.os.tag) {
        .linux, .macos => return posix.kill(pid, 0) == 0,
        .windows => {
            const SYNCHRONIZE: u32 = 0x00100000;
            const h = win.OpenProcess(SYNCHRONIZE, 0, pid) orelse return false;
            _ = win.CloseHandle(h);
            return true;
        },
        else => @compileError("isAlive: unsupported OS"),
    }
}

// No inline test here: coverage lives in `tests/ipc/process.zig`.
