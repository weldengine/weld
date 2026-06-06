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
//! "Inherited debts" — promoted from inherited to active).
//!
//! Creator (editor): `shm_open(name, O_CREAT | O_RDWR, 0o600)` →
//!                   `ftruncate(fd, size)` → `mmap`. Keep fd.
//! Attacher (runtime): `shm_open(name, O_RDWR | O_CREAT, 0o600)` →
//!                     `mmap`.
//! Close (creator): `munmap` + `close(fd)` + `shm_unlink(name)`.
//! Close (attacher): `munmap` + `close(fd)`.
//!
//! Permission note: mode `0o600` (`rw-------`). Owner-only access
//! is the tight permission that matches the editor↔runtime
//! parent-child spawn relationship — both processes run under the
//! same UID. We do **not** call `umask(0)` around `shm_open`:
//! `0o600 & ~umask = 0o600` regardless of the caller's umask
//! because the masked-out bits (group/other) are already zero in
//! the requested mode. This avoids a process-global `umask`
//! mutation that would race with other threads in the engine.
//!
//! `Backend.open` passes `O_CREAT | O_RDWR` rather than `O_RDWR`
//! alone — that combination works around a macOS BSD shm quirk
//! where the no-`O_CREAT` form returns `EACCES` for a
//! `posix_spawnp`-spawned sibling of the creator, even when both
//! processes share the same UID. The kernel returns the existing
//! region if `name` is present; if absent (a spurious orphan run),
//! the create path produces an empty region that
//! `ShmViewport.open` rejects via `error.InvalidHeader`. Linux
//! tolerates pure `O_RDWR` but we keep the platform-symmetric
//! code path.
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
};

const Error = shm.Error;

/// POSIX `shm_open` + `mmap` backend for the IPC viewport shared
/// memory segment. Embedded inside `shm.Segment.impl` on Linux/macOS.
pub const Backend = struct {
    /// `null` for a `fromFd` attach (the received fd has no name in
    /// this process — cross-process attach is by fd, not by name,
    /// per `engine-ipc.md` §4.8). Non-null for `create`/`open`.
    name_z: ?[:0]u8 = null,
    gpa: std.mem.Allocator,
    /// `shm_open` fd (create/open) or the fd received via SCM_RIGHTS
    /// (`fromFd`). Kept open for the lifetime of the `Backend` per the
    /// macOS quirk documented in the file header. Closed in `close()`.
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

        const fd = sys.shm_open(name_z.ptr, O_RDWR | O_CREAT | O_EXCL, 0o600);
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

        // `O_CREAT | O_RDWR` — see file header for the macOS BSD
        // shm quirk. Mode `0o600` is honored as-is (no umask hack
        // needed: 0o600 has no group/other bits for umask to mask).
        const fd = sys.shm_open(name_z.ptr, O_RDWR | O_CREAT, 0o600);
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

    /// Attach to a shm region from a file descriptor received over the
    /// IPC socket via `SCM_RIGHTS` (`IpcSocket.recvWithHandles`). This
    /// is the **primary cross-process attach** on POSIX
    /// (`engine-ipc.md` §4.8): no `shm_open`, no name. The fd ownership
    /// transfers to the `Backend` and is closed in `close()`. The
    /// region is never the owner (the editor that created it via
    /// `create` keeps ownership), so `close()` never `shm_unlink`s.
    pub fn fromFd(fd: i32, size: usize) Error!Backend {
        const raw = sys.mmap(null, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (raw == null or @intFromPtr(raw.?) == MAP_FAILED_RAW) return error.ShmMapFailed;

        const ptr: [*]align(std.heap.pageSize()) u8 = @ptrCast(@alignCast(raw.?));
        return Backend{
            .name_z = null,
            .gpa = std.heap.page_allocator,
            .fd = fd,
            .ptr = ptr,
            .size = size,
        };
    }

    /// The backing fd, to transmit to the runtime via
    /// `IpcSocket.sendWithHandles` (`engine-ipc.md` §4.8). Named
    /// `handle` rather than `fd` to avoid shadowing the `fd` field.
    pub fn handle(self: *const Backend) i32 {
        return self.fd;
    }

    pub fn close(self: *Backend, is_owner: bool) void {
        _ = sys.munmap(@ptrCast(self.ptr), self.size);
        _ = sys.close(self.fd);
        if (self.name_z) |nz| {
            if (is_owner) _ = sys.shm_unlink(nz.ptr);
            self.gpa.free(nz);
        }
        self.fd = -1;
        self.size = 0;
        self.name_z = null;
    }
};

// Runtime tests live in `tests/ipc/shm.zig` (negative cases) and
// `tests/ipc/shm_cases/*.zig` (one exe per `create + open` case to
// avoid the macOS BSD shm intra-process quirk).

test "create rejects too-long names" {
    const too_long = "/weld-this-name-is-deliberately-way-too-long-for-pshmnamlen";
    try std.testing.expectError(error.NameTooLong, shm.ShmRegion.create(too_long, 4096));
}
