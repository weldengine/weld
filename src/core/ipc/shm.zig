//! Shared-memory regions backing the viewport double-buffer.
//!
//! On POSIX the cross-process attach is `fromFd` over `SCM_RIGHTS`; `open` by name
//! is intra-process only and hits the BSD shm quirk across processes. On Windows
//! the attach IS by name. Region names are protocol — see `engine-ipc.md` §2.

const std = @import("std");
const builtin = @import("builtin");

const backend = switch (builtin.os.tag) {
    .linux, .macos => @import("shm_posix.zig"),
    .windows => @import("shm_windows.zig"),
    else => @compileError("Weld IPC shm: unsupported OS"),
};

const transport = @import("transport.zig");

/// OS-native region handle — the same alias `IpcSocket.sendWithHandles` takes.
pub const OsHandle = transport.OsHandle;

/// Error set for the shared-memory operations.
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
    /// `fromFd` on Windows: the attach there is by name, never by descriptor.
    Unimplemented,
} || std.mem.Allocator.Error;

/// One region; creator and attacher both hold an instance over the same pages.
pub const ShmRegion = struct {
    impl: backend.Backend,
    /// `page_size_min` and NOT `pageSize()`: a field's alignment must be
    /// comptime-known. And the MINIMUM, never `page_size_max` — on aarch64-linux
    /// that would claim align(65536) for memory `mmap` only guarantees to 4096.
    ptr: [*]align(std.heap.page_size_min) u8,
    /// Caller-requested length; Windows rounds the mapping up to its granularity.
    size: usize,
    /// Creator side only — the flag that makes `close` unlink the POSIX name.
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

    /// Intra-process attach by name; NOT the cross-process attach on POSIX.
    pub fn open(name: []const u8, size: usize) Error!ShmRegion {
        const impl = try backend.Backend.open(name, size);
        return .{
            .impl = impl,
            .ptr = impl.ptr,
            .size = size,
            .is_owner = false,
        };
    }

    /// POSIX runtime-side attach from an `SCM_RIGHTS` descriptor, which this region
    /// then OWNS and closes. Never the owner, so `close` does not unlink.
    pub fn fromFd(handle: OsHandle, size: usize) Error!ShmRegion {
        const impl = try backend.Backend.fromFd(handle, size);
        return .{
            .impl = impl,
            .ptr = impl.ptr,
            .size = size,
            .is_owner = false,
        };
    }

    /// The OS handle to forward through `IpcSocket.sendWithHandles`.
    pub fn fd(self: *const ShmRegion) OsHandle {
        return self.impl.handle();
    }

    /// Unmap, and unlink the name on the creator side. The kernel holds the pages
    /// while any process still maps them, so the close order does not matter.
    pub fn close(self: *ShmRegion) void {
        self.impl.close(self.is_owner);
        self.ptr = undefined;
        self.size = 0;
    }

    pub fn bytes(self: *const ShmRegion) []u8 {
        return self.ptr[0..self.size];
    }
};
