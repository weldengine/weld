//! POSIX backend for shared memory (Linux + macOS).
//!
//! THE FD STAYS OPEN inside the `Backend` until `close`. Closing it after `mmap` is
//! correct on Linux and makes a later `shm_open` of the same name return `EACCES` on
//! macOS, where the name and access namespaces are decoupled.
//!
//! `open` passes `O_CREAT | O_RDWR`, never `O_RDWR` alone, against the same quirk
//! for a `posix_spawnp`-ed sibling; a spurious create yields an empty region that
//! `ShmViewport.open` then refuses as `error.InvalidHeader`.
//!
//! NO `umask(0)` around `shm_open`: `0o600 & ~umask` is `0o600` whatever the umask,
//! and mutating a process-global would race the engine's other threads.
//!
//! macOS allows ONE create-then-open sequence per process, which is why the
//! single-process tests gate themselves off it. Names cap at 30 chars.

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

/// `shm_open` + `mmap` backend, embedded in `shm.ShmRegion.impl`.
pub const Backend = struct {
    /// `null` for a `fromFd` attach: that fd has no name in this process.
    name_z: ?[:0]u8 = null,
    gpa: std.mem.Allocator,
    /// Kept open for the whole `Backend` lifetime — see the header.
    fd: i32,
    ptr: [*]align(std.heap.page_size_min) u8,
    size: usize,

    pub fn create(name: []const u8, size: usize) Error!Backend {
        if (name.len > MAX_SHM_NAME_LEN) return error.NameTooLong;

        const gpa = std.heap.page_allocator;
        const name_z = try gpa.dupeZ(u8, name);
        errdefer gpa.free(name_z);

        // Best-effort unlink of a stale region from a crashed editor; ENOENT is fine.
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

        const ptr: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(raw.?));
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

        // `O_CREAT` is load-bearing here — see the header.
        const fd = sys.shm_open(name_z.ptr, O_RDWR | O_CREAT, 0o600);
        if (fd < 0) return error.ShmOpenFailed;
        errdefer _ = sys.close(fd);

        const raw = sys.mmap(null, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (raw == null or @intFromPtr(raw.?) == MAP_FAILED_RAW) return error.ShmMapFailed;

        const ptr: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(raw.?));
        return Backend{
            .name_z = name_z,
            .gpa = gpa,
            .fd = fd,
            .ptr = ptr,
            .size = size,
        };
    }

    /// POSIX cross-process attach: no `shm_open`, no name. The fd ownership TRANSFERS
    /// here and `close` releases it, but never `shm_unlink`s — the creator owns that.
    pub fn fromFd(fd: i32, size: usize) Error!Backend {
        const raw = sys.mmap(null, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (raw == null or @intFromPtr(raw.?) == MAP_FAILED_RAW) return error.ShmMapFailed;

        const ptr: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(raw.?));
        return Backend{
            .name_z = null,
            .gpa = std.heap.page_allocator,
            .fd = fd,
            .ptr = ptr,
            .size = size,
        };
    }

    /// The backing fd; named `handle` so it does not shadow the `fd` field.
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

// One exe per `create + open` case in `tests/ipc/shm_cases/` — the macOS quirk.

test "create rejects too-long names" {
    const too_long = "/weld-this-name-is-deliberately-way-too-long-for-pshmnamlen";
    try std.testing.expectError(error.NameTooLong, shm.ShmRegion.create(too_long, 4096));
}
