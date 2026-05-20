//! Shared-memory region interface used to back the viewport
//! framebuffer + the `ShmViewport` double-buffer (`viewport.zig`).
//! Comptime-dispatched between `shm_posix.zig` (POSIX `shm_open` +
//! `mmap`) and `shm_windows.zig` (`CreateFileMapping` +
//! `MapViewOfFile`).
//!
//! Lifetime: the editor side calls `create(name, size)` to allocate
//! the region and `close()` to release it (POSIX also `shm_unlink`s
//! the name). The runtime side calls `open(name)` to attach to an
//! existing region and `close()` to detach (no `shm_unlink` on the
//! attached side).
//!
//! Naming convention per `engine-ipc.md` §2:
//!   - POSIX  : `/weld-shm-<role>-<editor-pid>`
//!   - Windows: `Local\weld-shm-<role>-<editor-pid>` (session-local)
//!
//! `ptr` is always page-aligned (POSIX `mmap` guarantees it; Windows
//! `MapViewOfFile` returns alignments at least `dwAllocationGranularity`
//! which is 64 KB on the targets Weld supports).

const std = @import("std");
const builtin = @import("builtin");

const backend = switch (builtin.os.tag) {
    .linux, .macos => @import("shm_posix.zig"),
    .windows => @import("shm_windows.zig"),
    else => @compileError("Weld IPC shm: unsupported OS"),
};

/// Error set for shared-memory segment operations (create, open,
/// resize, unlink). Backends translate native errors into this set.
pub const Error = error{
    NameTooLong,
    InvalidName,
    PermissionDenied,
    AlreadyExists,
    NotFound,
    OutOfHostMemory,
    ShmCreateFailed,
    ShmTruncateFailed,
    ShmMapFailed,
    ShmOpenFailed,
} || std.mem.Allocator.Error;

/// One shared-memory region. Both the creator (editor) and the
/// attacher (runtime) hold an instance pointing at the same backing
/// memory.
pub const ShmRegion = struct {
    impl: backend.Backend,
    /// Page-aligned mapping pointer. Same address space-wise on the
    /// creator side; the attacher gets a fresh virtual address but
    /// the same physical pages.
    ptr: [*]align(std.heap.pageSize()) u8,
    /// Bytes mapped. POSIX `ftruncate`s to exactly this size; Windows
    /// rounds up to allocation granularity but `size` reports the
    /// caller-requested length.
    size: usize,
    /// `true` on the creator side. Drives whether `close()` calls
    /// `shm_unlink` (POSIX) or just `UnmapViewOfFile + CloseHandle`
    /// (Windows treats the kernel object as refcounted).
    is_owner: bool,

    /// Editor side. Creates and mmap-s a fresh region.
    pub fn create(name: []const u8, size: usize) Error!ShmRegion {
        const impl = try backend.Backend.create(name, size);
        return .{
            .impl = impl,
            .ptr = impl.ptr,
            .size = size,
            .is_owner = true,
        };
    }

    /// Runtime side. Attaches to an already-created region.
    pub fn open(name: []const u8, size: usize) Error!ShmRegion {
        const impl = try backend.Backend.open(name, size);
        return .{
            .impl = impl,
            .ptr = impl.ptr,
            .size = size,
            .is_owner = false,
        };
    }

    /// Unmap + (creator only) unlink the underlying name. The
    /// kernel keeps the backing pages alive while any process still
    /// has the region mapped, so the close order between creator
    /// and attacher is irrelevant.
    pub fn close(self: *ShmRegion) void {
        self.impl.close(self.is_owner);
        self.ptr = undefined;
        self.size = 0;
    }

    /// Convenience accessor returning the mapping as a byte slice.
    pub fn bytes(self: *const ShmRegion) []u8 {
        return self.ptr[0..self.size];
    }
};
