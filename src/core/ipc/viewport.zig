//! Viewport framebuffer shared between the runtime (writer) and the
//! editor (reader). Double-buffered per the S6 brief — `engine-
//! ipc.md` §4.2 specifies three slots for Phase 1-2 but S6 narrows
//! to two to keep the spike tight. The protocol of `last_complete` /
//! `writer_slot` / `reader_slot` atomics is unchanged; Phase 0.6
//! lifts the slot count to three without changing the public API.
//!
//! Layout (1280×720 RGBA8_UNORM, total ≈ 7 MB):
//!
//! ```
//! offset 0       header (128 bytes, cache-line aligned)
//! offset 128     slot 0 framebuffer = width × height × 4 bytes
//! offset 128 + N slot 1 framebuffer = width × height × 4 bytes
//! ```
//!
//! Writer protocol (runtime):
//!   1. `slot = (header.writer_slot + 1) % 2` (i.e. the slot the
//!      reader is *not* currently looking at)
//!   2. Render into `slot`'s pixel block.
//!   3. `header.last_complete.store(slot, .release)` —
//!      publishes the frame.
//!   4. `header.writer_slot.store(slot, .release)` — bookkeeping for
//!      the next iteration.
//!
//! Reader protocol (editor):
//!   1. `slot = header.last_complete.load(.acquire)` — paired with
//!      the writer's `.release` to make pixel writes visible.
//!   2. Copy the pixel block (or sample it directly if backed by GPU
//!      memory in Phase 3).
//!   3. Optionally record `header.reader_slot` (informational —
//!      lets the writer avoid clobbering an in-flight read on the
//!      Phase 0.6 triple-buffer path).
//!
//! The header itself sits inside the shared region; both sides access
//! atomics through the same physical pages, no locks needed.

const std = @import("std");

const shm = @import("shm.zig");

/// Pixel format negotiated at handshake. S6 supports only the
/// single value; the field exists so Phase 0.6 + Phase 3 can pick a
/// vendor-friendlier swapchain format without breaking layout
/// compatibility.
pub const PixelFormat = enum(u32) {
    rgba8_unorm = 0,
};

/// Pixel-grid dimensions of a viewport frame in shared memory.
pub const Resolution = struct {
    width: u32,
    height: u32,
};

/// S6 viewport resolution per the brief. Locked here (single source
/// of truth) so the editor and runtime can size their staging
/// buffers identically.
pub const default_resolution: Resolution = .{ .width = 1280, .height = 720 };

/// Number of slots in the rotating buffer. Phase 0.6 lifts to 3
/// (triple buffering).
pub const slot_count: u32 = 2;

/// Header magic — distinct from the framing layer's `'WELD'` magic
/// so a confused mmap can't be mistaken for a frame buffer.
pub const HEADER_MAGIC: u32 = 0x57565057; // 'WVPW' (Weld Viewport, Phase Weld)

/// Header revision. Bumped on any layout change of either the
/// header struct or the slot indexing.
pub const HEADER_VERSION: u16 = 1;

/// Header offset within the shared region. The slot pixel blocks
/// follow immediately, each aligned to 4 bytes (RGBA8).
pub const header_size: usize = 128;

/// Header laid out at offset 0 of the shared region. The atomics
/// are `u32` so they fit in a single store on every Weld target.
/// Total size 128 bytes — see `_reserved` for the padding budget.
pub const Header = extern struct {
    magic: u32, // +4 = 4
    version: u16, // +2 = 6
    _pad0: u16 = 0, // +2 = 8
    width: u32, // +4 = 12
    height: u32, // +4 = 16
    /// PixelFormat as u32 — extern struct can't embed Zig enums.
    format: u32, // +4 = 20
    slot_count: u32, // +4 = 24
    /// Updated by the writer to the slot currently being rendered.
    /// Informational for the reader.
    writer_slot: u32, // +4 = 28
    /// Updated by the reader to record which slot it is reading.
    /// Informational for the writer.
    reader_slot: u32, // +4 = 32
    /// Published by the writer with `.release` at the end of each
    /// frame. Reader loads with `.acquire`. The actual atomic ops
    /// happen through `std.atomic` accessors on the field address —
    /// the field type is `u32` for `extern struct` compatibility.
    last_complete: u32, // +4 = 36
    _pad1: u32 = 0, // +4 = 40 (pad before u64-aligned frame_id)
    /// Monotonic frame counter — informational only. The reader
    /// can detect "no new frame since last poll" by comparing this
    /// to a cached value.
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

/// Total bytes required for a viewport region of `(width × height)`
/// RGBA8 pixels and `slot_count` slots.
pub fn regionSize(width: u32, height: u32) usize {
    const slot_bytes: usize = @as(usize, width) * @as(usize, height) * 4;
    return header_size + slot_bytes * slot_count;
}

/// Error set for `ShmViewport` operations — composed with `shm.Error`.
pub const Error = error{
    InvalidHeader,
} || shm.Error;

/// Convenience wrapper around a `ShmRegion` configured as a
/// double-buffered viewport.
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
        // Zero both slots so an early reader doesn't observe stale
        // pages from a previously crashed editor (`shm_open` returns
        // a fresh region but mmap may surface old pages briefly).
        const slot_bytes: usize = @as(usize, width) * @as(usize, height) * 4;
        @memset(region.ptr[header_size .. header_size + slot_bytes * slot_count], 0);

        return .{ .region = region, .width = width, .height = height };
    }

    /// Runtime side. Attaches to an existing region and validates
    /// the header.
    pub fn open(name: []const u8, width: u32, height: u32) Error!ShmViewport {
        const size = regionSize(width, height);
        var region = try shm.ShmRegion.open(name, size);
        errdefer region.close();

        const hdr: *Header = @ptrCast(@alignCast(region.ptr));
        if (hdr.magic != HEADER_MAGIC) return error.InvalidHeader;
        if (hdr.version != HEADER_VERSION) return error.InvalidHeader;
        if (hdr.width != width or hdr.height != height) return error.InvalidHeader;
        if (hdr.slot_count != slot_count) return error.InvalidHeader;

        return .{ .region = region, .width = width, .height = height };
    }

    pub fn close(self: *ShmViewport) void {
        self.region.close();
    }

    /// Header pointer for typed access.
    pub fn header(self: *const ShmViewport) *Header {
        return @ptrCast(@alignCast(self.region.ptr));
    }

    /// Byte slice for the given slot. The slot index must be `<
    /// slot_count` — debug-only assertion (no runtime check).
    pub fn slotBytes(self: *const ShmViewport, slot: u32) []u8 {
        std.debug.assert(slot < slot_count);
        const slot_bytes: usize = @as(usize, self.width) * @as(usize, self.height) * 4;
        const start = header_size + slot_bytes * slot;
        return self.region.ptr[start .. start + slot_bytes];
    }

    /// Writer-side: pick the next slot to render into (the one not
    /// currently published).
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

    /// Reader-side: snapshot the currently published slot. Pairs
    /// with the writer's `.release` via the `.acquire` load.
    pub fn readSlot(self: *const ShmViewport) u32 {
        return @atomicLoad(u32, &self.header().last_complete, .acquire);
    }

    /// Reader-side: optional bookkeeping — record which slot was
    /// last consumed so the writer can avoid clobbering it on the
    /// Phase 0.6 triple-buffer path.
    pub fn markReaderSlot(self: *const ShmViewport, slot: u32) void {
        std.debug.assert(slot < slot_count);
        @atomicStore(u32, &self.header().reader_slot, slot, .release);
    }

    /// Reader-side: monotonic frame counter. Reader can compare
    /// against a cached value to skip a redundant blit when no new
    /// frame has been committed.
    pub fn frameId(self: *const ShmViewport) u64 {
        return @atomicLoad(u64, &self.header().frame_id, .acquire);
    }
};

// Runtime tests live in `tests/ipc/viewport_cases/*.zig` — one exe
// per case to dodge the macOS BSD shm intra-process quirk.

test "regionSize is header + two RGBA slot blocks" {
    const expected: usize = header_size + 2 * (1280 * 720 * 4);
    try std.testing.expectEqual(expected, regionSize(1280, 720));
}

test "header is exactly 128 bytes" {
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(Header));
}
