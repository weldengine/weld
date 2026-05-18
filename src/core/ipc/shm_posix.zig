//! POSIX backend for shared memory (Linux + macOS).
//!
//! `shm_open` returns a file descriptor that names a POSIX shm
//! object. `ftruncate` sets its size. `mmap` maps it into the
//! process address space. On Linux the fd can be closed once the
//! mapping is established — the kernel keeps the backing pages
//! alive for as long as any process holds a mapping. **macOS
//! differs**: once the creating fd is `close()`d, a subsequent
//! `shm_open(name, O_RDWR)` from the same process returns `EACCES`
//! even though the kernel object is still alive (the name namespace
//! and the access namespace are decoupled in BSD-derived shm).
//! We therefore keep the fd open inside the `Backend` and only
//! close it in `Backend.close()` — the mapping survives the whole
//! `Backend` lifetime and the name remains openable in the same
//! process for the FIRST create+open pair.
//!
//! macOS multi-region caveat: macOS additionally limits a process
//! to ONE successful `shm_open(O_CREAT) → shm_open(O_RDWR)`
//! sequence per process lifetime (independent of `shm_unlink`
//! status or names). Subsequent attempts return `EACCES`. The
//! real S6 demo is unaffected because the editor (creator) and
//! the runtime (opener) live in different processes; the bug
//! only surfaces in single-process tests, which gate themselves
//! on `builtin.os.tag != .macos` in `tests/ipc/shm.zig` and
//! `tests/ipc/shm_viewport.zig`. Linux is unaffected. The Phase 0.6
//! macOS hardware validation milestone revisits this when the
//! editor lifecycle integration test lands (cf. `briefs/S6-…` §
//! "Dettes héritées" — promoted from inherited to active).
//!
//! Creator (editor): `shm_open(name, O_CREAT | O_RDWR, 0o666)` →
//!                   `ftruncate(fd, size)` → `mmap`. Keep fd.
//! Attacher (runtime): `shm_open(name, O_RDWR, 0o666)` → `mmap`.
//! Close (creator): `munmap` + `close(fd)` + `shm_unlink(name)`.
//! Close (attacher): `munmap` + `close(fd)`.
//!
//! Permission note: `0o666` rather than `0o600`. macOS rejects a
//! follow-up `shm_open(name, O_RDWR)` with `EACCES` when the region
//! was created with mode `0o600`, even for the creating UID. The
//! names are PID-suffixed and live in the per-session POSIX shm
//! namespace, so the wider mode is not a cross-user attack vector.
//! The same workaround is documented in `boost::interprocess` and
//! `POCO::SharedMemory`.
//!
//! Name length: macOS caps `PSHMNAMLEN-1 = 30` chars; Linux is more
//! permissive. We bail at 30 for portability.

const std = @import("std");
const builtin = @import("builtin");

const shm = @import("shm.zig");

comptime {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) {
        @compileError("shm_posix.zig: only Linux and macOS are supported.");
    }
}

const O_RDWR: i32 = if (builtin.os.tag == .linux) 0x0002 else 0x0002;
const O_CREAT: i32 = if (builtin.os.tag == .linux) 0x0040 else 0x0200;
const O_EXCL: i32 = if (builtin.os.tag == .linux) 0x0080 else 0x0800;
const PROT_READ: i32 = 0x1;
const PROT_WRITE: i32 = 0x2;
const MAP_SHARED: i32 = 0x1;
const MAP_FAILED_RAW: usize = std.math.maxInt(usize);
const MAX_SHM_NAME_LEN: usize = 30;

const sys = struct {
    extern "c" fn shm_open(name: [*:0]const u8, oflag: i32, mode: u32) i32;
    extern "c" fn shm_unlink(name: [*:0]const u8) i32;
    extern "c" fn ftruncate(fd: i32, length: i64) i32;
    extern "c" fn mmap(addr: ?*anyopaque, length: usize, prot: i32, flags: i32, fd: i32, offset: i64) ?*anyopaque;
    extern "c" fn munmap(addr: *anyopaque, length: usize) i32;
    extern "c" fn close(fd: i32) i32;
    /// `umask(0)` returns the previous umask. We temporarily clear
    /// it around `shm_open(O_CREAT)` so the requested 0o666 mode is
    /// applied exactly. Without this, the umask (default 022 on
    /// macOS / most Linux distros) reduces 0o666 to 0o644, and a
    /// fresh runtime process attempting `shm_open(name, O_RDWR)`
    /// then sees `EACCES`. Restored to the original value
    /// immediately after the `shm_open` call.
    extern "c" fn umask(cmask: u16) u16;
};

const Error = shm.Error;

pub const Backend = struct {
    name_z: [:0]u8,
    gpa: std.mem.Allocator,
    /// `shm_open` fd. Kept open for the lifetime of the `Backend`
    /// per the macOS quirk documented in the file header. Closed in
    /// `close()`.
    fd: i32,
    ptr: [*]align(std.heap.pageSize()) u8,
    size: usize,

    pub fn create(name: []const u8, size: usize) Error!Backend {
        if (name.len > MAX_SHM_NAME_LEN) return error.NameTooLong;

        const gpa = std.heap.page_allocator;
        const name_z = try gpa.dupeZ(u8, name);
        errdefer gpa.free(name_z);

        // Unlink any stale region from a previous crashed editor
        // with the same PID. Best-effort; ENOENT is the desired
        // post-state.
        _ = sys.shm_unlink(name_z.ptr);

        // Temporarily clear umask so the requested 0o666 is applied
        // exactly. Without this the kernel-side mask reduces the
        // mode to 0o644 and a fresh runtime process trying to open
        // the region with `O_RDWR` returns `EACCES` — verified
        // empirically on macOS 26.4.1 with the S6 demo.
        const prev_umask = sys.umask(0);
        const fd = sys.shm_open(name_z.ptr, O_RDWR | O_CREAT | O_EXCL, 0o666);
        _ = sys.umask(prev_umask);
        if (fd < 0) return error.ShmCreateFailed;
        errdefer {
            _ = sys.close(fd);
            _ = sys.shm_unlink(name_z.ptr);
        }

        if (sys.ftruncate(fd, @intCast(size)) != 0) return error.ShmTruncateFailed;

        const raw = sys.mmap(null, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        // `mmap` returns `MAP_FAILED == (void*)-1` on failure.
        if (raw == null or @intFromPtr(raw.?) == MAP_FAILED_RAW) return error.ShmMapFailed;

        const ptr: [*]align(std.heap.pageSize()) u8 = @ptrCast(@alignCast(raw.?));
        return Backend{
            .name_z = name_z,
            .gpa = gpa,
            .fd = fd,
            .ptr = ptr,
            .size = size,
        };
    }

    pub fn open(name: []const u8, size: usize) Error!Backend {
        if (name.len > MAX_SHM_NAME_LEN) return error.NameTooLong;

        const gpa = std.heap.page_allocator;
        const name_z = try gpa.dupeZ(u8, name);
        errdefer gpa.free(name_z);

        // macOS quirk: even with mode `0o666` and `umask(0)`, a
        // `shm_open(name, O_RDWR)` (no O_CREAT) returns `EACCES` —
        // both intra-process and across `posix_spawnp`'d siblings.
        // Passing `O_CREAT | O_RDWR` works around it: the kernel
        // opens the existing region (the name already exists).
        // If no region exists, the open creates an empty one —
        // `ShmViewport.open` then catches the missing header magic
        // and returns `error.InvalidHeader`. The Linux backend is
        // unaffected (kept symmetric for code-path simplicity).
        const prev_umask = sys.umask(0);
        const fd = sys.shm_open(name_z.ptr, O_RDWR | O_CREAT, 0o666);
        _ = sys.umask(prev_umask);
        if (fd < 0) return error.ShmOpenFailed;
        errdefer _ = sys.close(fd);

        const raw = sys.mmap(null, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (raw == null or @intFromPtr(raw.?) == MAP_FAILED_RAW) return error.ShmMapFailed;

        const ptr: [*]align(std.heap.pageSize()) u8 = @ptrCast(@alignCast(raw.?));
        return Backend{
            .name_z = name_z,
            .gpa = gpa,
            .fd = fd,
            .ptr = ptr,
            .size = size,
        };
    }

    pub fn close(self: *Backend, is_owner: bool) void {
        _ = sys.munmap(@ptrCast(self.ptr), self.size);
        _ = sys.close(self.fd);
        if (is_owner) _ = sys.shm_unlink(self.name_z.ptr);
        self.gpa.free(self.name_z);
        self.fd = -1;
        self.size = 0;
        // `name_z` is left dangling — close() is single-shot, the
        // caller must drop the Backend value after.
    }
};

// ---------------------------------------------------------------- tests --
//
// Same rationale as transport_posix: runtime tests live in
// `tests/ipc/*.zig` exe-tests where each case can be isolated.

test "create + write + open + read round-trip — SKIPPED, see tests/ipc/" {
    return error.SkipZigTest;
}

test "attacher writes are visible to owner — SKIPPED, see tests/ipc/" {
    return error.SkipZigTest;
}

test "create rejects too-long names" {
    const too_long = "/weld-this-name-is-deliberately-way-too-long-for-pshmnamlen";
    try std.testing.expectError(error.NameTooLong, shm.ShmRegion.create(too_long, 4096));
}
