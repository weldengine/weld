//! POSIX backend for shared memory (Linux + macOS).
//!
//! `shm_open` returns a file descriptor that names a POSIX shm
//! object. `ftruncate` sets its size. `mmap` maps it into the
//! process address space. The fd can be closed once the mapping is
//! established — the kernel keeps the backing pages alive for as
//! long as any process holds a mapping.
//!
//! Creator (editor): `shm_open(name, O_CREAT | O_RDWR, 0600)` →
//!                   `ftruncate(fd, size)` → `mmap`.
//! Attacher (runtime): `shm_open(name, O_RDWR, 0)` → `mmap`.
//! Close (creator): `munmap` + `shm_unlink(name)`.
//! Close (attacher): `munmap` only.
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

pub const Backend = struct {
    name_z: [:0]u8,
    gpa: std.mem.Allocator,
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

        // The fd can be closed — the mapping holds the region alive.
        _ = sys.close(fd);

        const ptr: [*]align(std.heap.pageSize()) u8 = @ptrCast(@alignCast(raw.?));
        return Backend{
            .name_z = name_z,
            .gpa = gpa,
            .ptr = ptr,
            .size = size,
        };
    }

    pub fn open(name: []const u8, size: usize) Error!Backend {
        if (name.len > MAX_SHM_NAME_LEN) return error.NameTooLong;

        const gpa = std.heap.page_allocator;
        const name_z = try gpa.dupeZ(u8, name);
        errdefer gpa.free(name_z);

        // macOS requires a non-zero mode argument even when O_CREAT is
        // absent — supplying 0o600 matches what the creator used.
        const fd = sys.shm_open(name_z.ptr, O_RDWR, 0o600);
        if (fd < 0) return error.ShmOpenFailed;
        errdefer _ = sys.close(fd);

        const raw = sys.mmap(null, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        if (raw == null or @intFromPtr(raw.?) == MAP_FAILED_RAW) return error.ShmMapFailed;

        _ = sys.close(fd);

        const ptr: [*]align(std.heap.pageSize()) u8 = @ptrCast(@alignCast(raw.?));
        return Backend{
            .name_z = name_z,
            .gpa = gpa,
            .ptr = ptr,
            .size = size,
        };
    }

    pub fn close(self: *Backend, is_owner: bool) void {
        _ = sys.munmap(@ptrCast(self.ptr), self.size);
        if (is_owner) _ = sys.shm_unlink(self.name_z.ptr);
        self.gpa.free(self.name_z);
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
