//! Viewport framebuffer: the runtime writes, the editor reads, through the same
//! pages with no lock.
//!
//! The ONLY synchronisation is the `last_complete` pair — the writer stores it with
//! `.release` AFTER its pixel writes, the reader loads it with `.acquire` before
//! touching them. `writer_slot` and `reader_slot` synchronise NOTHING. Two slots,
//! and the writer renders into the one `last_complete` does not name.

const std = @import("std");

const shm = @import("shm.zig");

/// Pixel format negotiated at handshake; one value today, `u32`-wide for later.
pub const PixelFormat = enum(u32) {
    rgba8_unorm = 0,
};

/// Pixel-grid dimensions of a viewport frame in shared memory.
pub const Resolution = struct {
    width: u32,
    height: u32,
};

/// THE single source of truth, so editor and runtime size their staging alike.
pub const default_resolution: Resolution = .{ .width = 1280, .height = 720 };

/// Slots in the rotating buffer.
pub const slot_count: u32 = 2;

/// Distinct from the framing magic, so a confused mmap is not read as a frame.
pub const HEADER_MAGIC: u32 = 0x57565057; // 'WVPW' (Weld Viewport, Phase Weld)

/// Bumped on any layout change to the header or the slot indexing.
pub const HEADER_VERSION: u16 = 1;

/// Header offset; the slot pixel blocks follow immediately, 4-byte aligned.
pub const header_size: usize = 128;

/// Header at offset 0 of the region — exactly 128 bytes, pinned just below.
pub const Header = extern struct {
    magic: u32, // +4 = 4
    version: u16, // +2 = 6
    _pad0: u16 = 0, // +2 = 8
    width: u32, // +4 = 12
    height: u32, // +4 = 16
    /// PixelFormat as u32 — extern struct can't embed Zig enums.
    format: u32, // +4 = 20
    slot_count: u32, // +4 = 24
    writer_slot: u32, // +4 = 28
    reader_slot: u32, // +4 = 32
    /// Typed `u32` for `extern struct`; the atomic ops go through the field address.
    last_complete: u32, // +4 = 36
    _pad1: u32 = 0, // +4 = 40 (pad before u64-aligned frame_id)
    /// Monotonic frame counter — a cached compare tells the reader nothing is new.
    frame_id: u64, // +8 = 48
    _reserved: [80]u8 = std.mem.zeroes([80]u8), // +80 = 128
};

comptime {
    if (@sizeOf(Header) != 128) {
        @compileError(std.fmt.comptimePrint(
            "Header must be exactly 128 bytes, got {d}",
            .{@sizeOf(Header)},
        ));
    }
}

/// Total bytes for `(width × height)` RGBA8 pixels across `slot_count` slots.
pub fn regionSize(width: u32, height: u32) usize {
    const slot_bytes: usize = @as(usize, width) * @as(usize, height) * 4;
    return header_size + slot_bytes * slot_count;
}

/// `InvalidHeader` is a region that was never created as a viewport.
pub const Error = error{
    InvalidHeader,
} || shm.Error;

/// A `ShmRegion` configured as a double-buffered viewport.
pub const ShmViewport = struct {
    region: shm.ShmRegion,
    width: u32,
    height: u32,

    /// Editor side. Creates the shm region, writes the header.
    pub fn create(name: []const u8, width: u32, height: u32) Error!ShmViewport {
        const size = regionSize(width, height);
        var region = try shm.ShmRegion.create(name, size);
        errdefer region.close();

        const hdr: *Header = @ptrCast(@alignCast(region.ptr));
        hdr.* = Header{
            .magic = HEADER_MAGIC,
            .version = HEADER_VERSION,
            .width = width,
            .height = height,
            .format = @intFromEnum(PixelFormat.rgba8_unorm),
            .slot_count = slot_count,
            .writer_slot = 0,
            .reader_slot = 0,
            .last_complete = 0,
            .frame_id = 0,
        };
        // Zero both slots: `mmap` can briefly surface pages of a crashed editor.
        const slot_bytes: usize = @as(usize, width) * @as(usize, height) * 4;
        @memset(region.ptr[header_size .. header_size + slot_bytes * slot_count], 0);

        return .{ .region = region, .width = width, .height = height };
    }

    /// Attach by name — Windows, or an intra-process re-attach; NOT POSIX's path.
    pub fn open(name: []const u8, width: u32, height: u32) Error!ShmViewport {
        const size = regionSize(width, height);
        var region = try shm.ShmRegion.open(name, size);
        errdefer region.close();
        try validateHeader(&region, width, height);
        return .{ .region = region, .width = width, .height = height };
    }

    /// POSIX runtime-side attach from an `SCM_RIGHTS` descriptor, header validated.
    pub fn fromFd(handle: shm.OsHandle, width: u32, height: u32) Error!ShmViewport {
        const size = regionSize(width, height);
        var region = try shm.ShmRegion.fromFd(handle, size);
        errdefer region.close();
        try validateHeader(&region, width, height);
        return .{ .region = region, .width = width, .height = height };
    }

    /// The backing fd, for the editor to forward through `sendWithHandles`.
    pub fn fd(self: *const ShmViewport) shm.OsHandle {
        return self.region.fd();
    }

    /// Shared by `open` and `fromFd`.
    fn validateHeader(region: *const shm.ShmRegion, width: u32, height: u32) Error!void {
        const hdr: *Header = @ptrCast(@alignCast(region.ptr));
        if (hdr.magic != HEADER_MAGIC) return error.InvalidHeader;
        if (hdr.version != HEADER_VERSION) return error.InvalidHeader;
        if (hdr.width != width or hdr.height != height) return error.InvalidHeader;
        if (hdr.slot_count != slot_count) return error.InvalidHeader;
    }

    pub fn close(self: *ShmViewport) void {
        self.region.close();
    }

    /// Header pointer for typed access.
    pub fn header(self: *const ShmViewport) *Header {
        return @ptrCast(@alignCast(self.region.ptr));
    }

    /// Byte slice for one slot; `slot < slot_count` is a DEBUG-only assertion.
    pub fn slotBytes(self: *const ShmViewport, slot: u32) []u8 {
        std.debug.assert(slot < slot_count);
        const slot_bytes: usize = @as(usize, self.width) * @as(usize, self.height) * 4;
        const start = header_size + slot_bytes * slot;
        return self.region.ptr[start .. start + slot_bytes];
    }

    /// Writer-side: the slot that is not currently published.
    pub fn nextWriteSlot(self: *const ShmViewport) u32 {
        const last = @atomicLoad(u32, &self.header().last_complete, .acquire);
        return (last + 1) % slot_count;
    }

    /// Writer-side: publish the just-rendered slot.
    pub fn commit(self: *const ShmViewport, slot: u32) void {
        std.debug.assert(slot < slot_count);
        const h = self.header();
        @atomicStore(u32, &h.writer_slot, slot, .release);
        @atomicStore(u32, &h.last_complete, slot, .release);
        _ = @atomicRmw(u64, &h.frame_id, .Add, 1, .release);
    }

    /// Reader-side: the published slot, acquired against the writer's release.
    pub fn readSlot(self: *const ShmViewport) u32 {
        return @atomicLoad(u32, &self.header().last_complete, .acquire);
    }

    /// Reader-side bookkeeping only; nothing reads it back today.
    pub fn markReaderSlot(self: *const ShmViewport, slot: u32) void {
        std.debug.assert(slot < slot_count);
        @atomicStore(u32, &self.header().reader_slot, slot, .release);
    }

    /// Reader-side: unchanged since the last poll means no new frame.
    pub fn frameId(self: *const ShmViewport) u64 {
        return @atomicLoad(u64, &self.header().frame_id, .acquire);
    }
};

// One exe per viewport case in `tests/ipc/viewport_cases/` — the macOS shm quirk.

test "regionSize is header + two RGBA slot blocks" {
    const expected: usize = header_size + 2 * (1280 * 720 * 4);
    try std.testing.expectEqual(expected, regionSize(1280, 720));
}

test "header is exactly 128 bytes" {
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(Header));
}
