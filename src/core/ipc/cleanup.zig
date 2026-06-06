//! Startup orphan reaping for IPC endpoints (`engine-ipc.md` §2.4 +
//! §6.3). The editor owns its Unix socket file (`/tmp/weld-<pid>.sock`)
//! and its POSIX shm regions (`/weld-shm-<role>-<pid>`); a `kill -9`
//! of the editor leaves both behind, named with the dead editor's PID.
//! The next editor calls `reapOrphans` at startup to remove any such
//! orphan whose embedded PID is no longer alive (`process.is_alive`).
//!
//! Safety: an endpoint is removed **only** when its PID is dead, so a
//! second editor running concurrently (live PID) never has its
//! endpoints reaped. The reap is best-effort — every failure is
//! swallowed (it is startup hygiene, not a correctness gate).
//!
//! Implementation note: raw `opendir`/`readdir` via `extern "c"`,
//! consistent with the rest of the IPC module (`shm_posix.zig`,
//! `transport_posix.zig`) which binds libc directly to stay decoupled
//! from the evolving `std.fs` / `std.Io.Dir` signatures across Zig
//! 0.16 patches. Windows is a no-op: named pipes and named file
//! mappings are refcounted kernel objects that vanish with their last
//! handle, so there is nothing to unlink. shm orphan scanning uses the
//! Linux `/dev/shm` tmpfs listing (macOS POSIX shm objects are not
//! filesystem-visible, so only the socket reap runs there).

const std = @import("std");
const builtin = @import("builtin");

const process = @import("../platform/process.zig");

const is_linux = builtin.os.tag == .linux;
const is_posix = builtin.os.tag == .linux or builtin.os.tag == .macos;

// `struct dirent` layout. Linux glibc and macOS (arm64, 64-bit inode)
// differ in field order/width before `d_name`; only the `d_name`
// offset matters here (we read it as a NUL-terminated slice).
const dirent = if (is_linux) extern struct {
    d_ino: u64,
    d_off: i64,
    d_reclen: u16,
    d_type: u8,
    d_name: [256]u8,
} else extern struct {
    d_ino: u64,
    d_seekoff: u64,
    d_reclen: u16,
    d_namlen: u16,
    d_type: u8,
    d_name: [1024]u8,
};

const DIR = opaque {};

const sys = struct {
    extern "c" fn opendir(name: [*:0]const u8) ?*DIR;
    extern "c" fn readdir(dir: *DIR) ?*dirent;
    extern "c" fn closedir(dir: *DIR) c_int;
    extern "c" fn unlink(path: [*:0]const u8) c_int;
    extern "c" fn shm_unlink(name: [*:0]const u8) i32;
};

/// Removes orphan IPC endpoints left by crashed editors. Scans
/// `/tmp` for `weld-<pid>.sock` sockets (Linux + macOS) and, on Linux,
/// `/dev/shm` for `weld-shm-*-<pid>` regions, unlinking each whose
/// `<pid>` is no longer alive. Best-effort and side-effect-safe for a
/// concurrently-running editor (live PIDs are kept). No-op on Windows.
pub fn reapOrphans() void {
    if (comptime !is_posix) return;
    reapSocketOrphans();
    if (comptime is_linux) reapShmOrphans();
}

/// Parses the PID out of an editor socket name `weld-<pid>.sock`.
/// Returns `null` for any name that is not exactly that shape (so
/// test sockets like `weld-crashtest-<pid>.sock` are left untouched).
fn pidFromSocketName(name: []const u8) ?process.Pid {
    const prefix = "weld-";
    const suffix = ".sock";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    if (!std.mem.endsWith(u8, name, suffix)) return null;
    const mid = name[prefix.len .. name.len - suffix.len];
    if (mid.len == 0) return null;
    return std.fmt.parseInt(process.Pid, mid, 10) catch null;
}

/// Parses the trailing PID out of a shm region name
/// `weld-shm-<role>-<pid>`. Returns `null` when the name does not
/// start with `weld-shm-` or has no numeric trailing segment.
fn pidFromShmName(name: []const u8) ?process.Pid {
    const prefix = "weld-shm-";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    const last_dash = std.mem.lastIndexOfScalar(u8, name, '-') orelse return null;
    const pid_str = name[last_dash + 1 ..];
    if (pid_str.len == 0) return null;
    return std.fmt.parseInt(process.Pid, pid_str, 10) catch null;
}

fn reapSocketOrphans() void {
    const d = sys.opendir("/tmp") orelse return;
    defer _ = sys.closedir(d);
    while (sys.readdir(d)) |ent| {
        const name = std.mem.sliceTo(&ent.d_name, 0);
        const pid = pidFromSocketName(name) orelse continue;
        if (process.is_alive(pid)) continue;
        var buf: [320]u8 = undefined;
        const full = std.fmt.bufPrintZ(&buf, "/tmp/{s}", .{name}) catch continue;
        _ = sys.unlink(full.ptr);
    }
}

fn reapShmOrphans() void {
    const d = sys.opendir("/dev/shm") orelse return;
    defer _ = sys.closedir(d);
    while (sys.readdir(d)) |ent| {
        const name = std.mem.sliceTo(&ent.d_name, 0);
        const pid = pidFromShmName(name) orelse continue;
        if (process.is_alive(pid)) continue;
        // `shm_unlink` takes the name as passed to `shm_open` (leading
        // slash), which maps to `/dev/shm/<name>` on Linux.
        var buf: [320]u8 = undefined;
        const shm_name = std.fmt.bufPrintZ(&buf, "/{s}", .{name}) catch continue;
        _ = sys.shm_unlink(shm_name.ptr);
    }
}

// ---------------------------------------------------------------- tests --

extern "c" fn getpid() process.Pid;
extern "c" fn creat(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;

test "pidFromSocketName parses weld-<pid>.sock only" {
    try std.testing.expectEqual(@as(?process.Pid, 1234), pidFromSocketName("weld-1234.sock"));
    try std.testing.expectEqual(@as(?process.Pid, null), pidFromSocketName("weld-crashtest-1234.sock"));
    try std.testing.expectEqual(@as(?process.Pid, null), pidFromSocketName("weld-.sock"));
    try std.testing.expectEqual(@as(?process.Pid, null), pidFromSocketName("other-1234.sock"));
    try std.testing.expectEqual(@as(?process.Pid, null), pidFromSocketName("weld-1234.txt"));
}

test "pidFromShmName parses the trailing pid of weld-shm-<role>-<pid>" {
    try std.testing.expectEqual(@as(?process.Pid, 77), pidFromShmName("weld-shm-viewport-77"));
    try std.testing.expectEqual(@as(?process.Pid, 5), pidFromShmName("weld-shm-overlays-5"));
    try std.testing.expectEqual(@as(?process.Pid, null), pidFromShmName("weld-viewport-9"));
    try std.testing.expectEqual(@as(?process.Pid, null), pidFromShmName("weld-shm-noprefixmatch"));
}

test "reapOrphans removes a dead-pid socket and keeps a live-pid one" {
    if (comptime !is_posix) return error.SkipZigTest;

    // A PID far above any real one — `kill(pid, 0)` returns ESRCH, so
    // `is_alive` is false. Deterministic on Linux + macOS.
    const dead_pid: process.Pid = 0x7FFF_FFFF;
    const my_pid = getpid();
    try std.testing.expect(!process.is_alive(dead_pid));
    try std.testing.expect(process.is_alive(my_pid));

    var dead_buf: [64]u8 = undefined;
    var live_buf: [64]u8 = undefined;
    const dead_path = try std.fmt.bufPrintZ(&dead_buf, "/tmp/weld-{d}.sock", .{dead_pid});
    const live_path = try std.fmt.bufPrintZ(&live_buf, "/tmp/weld-{d}.sock", .{my_pid});

    _ = sys.unlink(dead_path.ptr);
    _ = sys.unlink(live_path.ptr);
    const fd_dead = creat(dead_path.ptr, 0o600);
    try std.testing.expect(fd_dead >= 0);
    _ = close(fd_dead);
    const fd_live = creat(live_path.ptr, 0o600);
    try std.testing.expect(fd_live >= 0);
    _ = close(fd_live);
    defer _ = sys.unlink(live_path.ptr);
    defer _ = sys.unlink(dead_path.ptr);

    reapOrphans();

    // The dead-pid orphan is gone; the live-pid endpoint survives.
    try std.testing.expect(access(dead_path.ptr, 0) != 0);
    try std.testing.expect(access(live_path.ptr, 0) == 0);
}

test "reapOrphans removes a dead-pid shm region on Linux" {
    if (comptime !is_linux) return error.SkipZigTest;

    const dead_pid: process.Pid = 0x7FFF_FFFF;
    var name_buf: [64]u8 = undefined;
    const shm_name = try std.fmt.bufPrintZ(&name_buf, "/weld-shm-reaptest-{d}", .{dead_pid});
    const O_RDWR: i32 = 0x0002;
    const O_CREAT: i32 = 0x0040;
    const shm = struct {
        extern "c" fn shm_open(name: [*:0]const u8, oflag: i32, mode: u32) i32;
    };
    _ = sys.shm_unlink(shm_name.ptr); // clear a prior run's leftover
    const fd = shm.shm_open(shm_name.ptr, O_RDWR | O_CREAT, 0o600);
    try std.testing.expect(fd >= 0);
    _ = close(fd);
    defer _ = sys.shm_unlink(shm_name.ptr); // belt-and-suspenders

    // `/dev/shm/weld-shm-reaptest-<dead>` now exists.
    var path_buf: [64]u8 = undefined;
    const dev_path = try std.fmt.bufPrintZ(&path_buf, "/dev/shm/weld-shm-reaptest-{d}", .{dead_pid});
    try std.testing.expect(access(dev_path.ptr, 0) == 0);

    reapOrphans();

    try std.testing.expect(access(dev_path.ptr, 0) != 0);
}
