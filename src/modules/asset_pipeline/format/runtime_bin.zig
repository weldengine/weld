//! FROZEN — see engine-phase-0-criteria.md C0.5 (M0.9)
//!
//! Runtime `.<type>.bin` zero-copy container — the 40-byte header and its
//! read / write / validate helpers.
//!
//! Layout frozen day 1 (M0.6, brief §Scope ▸ runtime format). 40 bytes,
//! 8-byte aligned, declared as an `extern struct` whose natural C layout
//! matches the on-disk bytes exactly: the explicit `_reserved` u32 at
//! offset 28 makes `hash` (u64) land at the 8-aligned offset 32, so
//! `@sizeOf == 40` with no implicit padding and the struct can be read
//! straight out of an mmap'd region with no repacking (E5).
//!
//! Endianness: the format is little-endian. Both Phase 0 targets
//! (x86_64, aarch64) are little-endian, so the in-memory `extern struct`
//! and the on-disk bytes coincide; `read` / `writeTo` are nonetheless
//! explicit per-field so a future big-endian port has a single place to
//! byte-swap.

const std = @import("std");
const AssetType = @import("asset_type.zig").AssetType;

/// File signature occupying the first 4 bytes of every `.bin`.
pub const magic: [4]u8 = .{ 'W', 'E', 'L', 'D' };

/// Total on-disk header size, in bytes. Frozen day 1.
pub const header_size: usize = 40;

/// Header format version. Bumped only on a breaking header-layout change
/// (payload-shape changes use the per-category payload `version`, not this).
pub const current_version: u16 = 1;

/// Target platform a `.bin` was cooked for. Stored in the header
/// `platform` field. Non-exhaustive so future platforms read back without
/// a format bump; M0.6 only cooks `pc`.
pub const Platform = enum(u16) {
    /// Desktop PC (Vulkan / D3D12).
    pc = 0,
    /// Mobile (Android / iOS).
    mobile = 1,
    /// Web (WebGPU).
    web = 2,
    _,

    /// Numeric value stored in the header `platform` field.
    pub fn toU16(self: Platform) u16 {
        return @intFromEnum(self);
    }
};

/// Errors surfaced by `read`.
pub const ReadError = error{
    /// The input slice is shorter than `header_size`.
    ShortBuffer,
    /// The first 4 bytes are not the `WELD` signature.
    BadMagic,
};

/// Errors surfaced by `validate` (M1.1.1-HF1 / D6).
pub const ValidateError = error{
    /// `version` is not `current_version`.
    UnsupportedVersion,
    /// A section escapes `[header_size, bin_len]` — including an
    /// `offset + size` that overflows.
    SectionOutOfBounds,
};

/// 40-byte runtime header. Field order and offsets are frozen day 1; the
/// `comptime` block below pins them so a refactor that reorders fields or
/// changes a type fails to compile rather than silently breaking the
/// on-disk format.
pub const RuntimeHeader = extern struct {
    /// `WELD` signature.
    magic: [4]u8,
    /// Header format version (`current_version`).
    version: u16,
    /// Asset category (`AssetType` value via `assetType`).
    asset_type: u16,
    /// Target platform (`Platform` value).
    platform: u16,
    /// Reserved bit flags; zero in M0.6.
    flags: u16,
    /// Byte offset of the bulk data section from the start of the file.
    data_offset: u32,
    /// Byte length of the bulk data section.
    data_size: u32,
    /// Byte offset of the metadata section from the start of the file.
    metadata_offset: u32,
    /// Byte length of the metadata section.
    metadata_size: u32,
    /// Reserved (zero-filled); makes `hash` land at the 8-aligned offset
    /// 32. Reserved for future small fields (additive, no version bump).
    _reserved: u32,
    /// Content hash of the cooked payload (cache / integrity check).
    hash: u64,

    comptime {
        std.debug.assert(@sizeOf(RuntimeHeader) == header_size);
        std.debug.assert(@alignOf(RuntimeHeader) == 8);
        std.debug.assert(@offsetOf(RuntimeHeader, "magic") == 0);
        std.debug.assert(@offsetOf(RuntimeHeader, "version") == 4);
        std.debug.assert(@offsetOf(RuntimeHeader, "asset_type") == 6);
        std.debug.assert(@offsetOf(RuntimeHeader, "platform") == 8);
        std.debug.assert(@offsetOf(RuntimeHeader, "flags") == 10);
        std.debug.assert(@offsetOf(RuntimeHeader, "data_offset") == 12);
        std.debug.assert(@offsetOf(RuntimeHeader, "data_size") == 16);
        std.debug.assert(@offsetOf(RuntimeHeader, "metadata_offset") == 20);
        std.debug.assert(@offsetOf(RuntimeHeader, "metadata_size") == 24);
        std.debug.assert(@offsetOf(RuntimeHeader, "_reserved") == 28);
        std.debug.assert(@offsetOf(RuntimeHeader, "hash") == 32);
    }

    /// Construct a header with the `WELD` magic filled in and `_reserved`
    /// zeroed. `version` defaults to `current_version` and `platform` to
    /// `.pc`.
    pub fn init(params: struct {
        asset_type: AssetType,
        data_offset: u32,
        data_size: u32,
        metadata_offset: u32,
        metadata_size: u32,
        hash: u64,
        version: u16 = current_version,
        platform: Platform = .pc,
        flags: u16 = 0,
    }) RuntimeHeader {
        return .{
            .magic = magic,
            .version = params.version,
            .asset_type = params.asset_type.toU16(),
            .platform = params.platform.toU16(),
            .flags = params.flags,
            .data_offset = params.data_offset,
            .data_size = params.data_size,
            .metadata_offset = params.metadata_offset,
            .metadata_size = params.metadata_size,
            ._reserved = 0,
            .hash = params.hash,
        };
    }

    /// Decode the stored `asset_type` field, or `null` if it is not a known
    /// `AssetType` variant.
    pub fn assetType(self: RuntimeHeader) ?AssetType {
        return AssetType.fromU16(self.asset_type);
    }

    /// Serialize the header into a fixed 40-byte buffer, little-endian.
    pub fn writeTo(self: RuntimeHeader, buf: *[header_size]u8) void {
        @memcpy(buf[0..4], &self.magic);
        std.mem.writeInt(u16, buf[4..6], self.version, .little);
        std.mem.writeInt(u16, buf[6..8], self.asset_type, .little);
        std.mem.writeInt(u16, buf[8..10], self.platform, .little);
        std.mem.writeInt(u16, buf[10..12], self.flags, .little);
        std.mem.writeInt(u32, buf[12..16], self.data_offset, .little);
        std.mem.writeInt(u32, buf[16..20], self.data_size, .little);
        std.mem.writeInt(u32, buf[20..24], self.metadata_offset, .little);
        std.mem.writeInt(u32, buf[24..28], self.metadata_size, .little);
        std.mem.writeInt(u32, buf[28..32], self._reserved, .little);
        std.mem.writeInt(u64, buf[32..40], self.hash, .little);
    }

    /// Serialize the header into a freshly returned 40-byte array.
    pub fn toBytes(self: RuntimeHeader) [header_size]u8 {
        var buf: [header_size]u8 = undefined;
        self.writeTo(&buf);
        return buf;
    }

    /// Parse and validate a header from the front of `bytes`, little-endian.
    /// Validates length and magic only; the caller checks `version` /
    /// `assetType` against what it expects.
    ///
    /// Errors:
    ///   - `error.ShortBuffer` if `bytes.len < header_size`
    ///   - `error.BadMagic` if the signature is not `WELD`
    pub fn read(bytes: []const u8) ReadError!RuntimeHeader {
        if (bytes.len < header_size) return error.ShortBuffer;
        if (!std.mem.eql(u8, bytes[0..4], &magic)) return error.BadMagic;
        return .{
            .magic = magic,
            .version = std.mem.readInt(u16, bytes[4..6], .little),
            .asset_type = std.mem.readInt(u16, bytes[6..8], .little),
            .platform = std.mem.readInt(u16, bytes[8..10], .little),
            .flags = std.mem.readInt(u16, bytes[10..12], .little),
            .data_offset = std.mem.readInt(u32, bytes[12..16], .little),
            .data_size = std.mem.readInt(u32, bytes[16..20], .little),
            .metadata_offset = std.mem.readInt(u32, bytes[20..24], .little),
            .metadata_size = std.mem.readInt(u32, bytes[24..28], .little),
            ._reserved = std.mem.readInt(u32, bytes[28..32], .little),
            .hash = std.mem.readInt(u64, bytes[32..40], .little),
        };
    }

    /// Structural validation of a header parsed from a `.bin` of total length
    /// `bin_len`, run right after `read`. Confirms the version and that the
    /// data and metadata sections lie fully within `[header_size, bin_len]`,
    /// using overflow-safe (u64-widened) arithmetic so a crafted
    /// `offset + size` that wraps in u32 cannot slip past the bounds test.
    ///
    /// The payload hash-equality check (`hash == hash.u64Of(data section)`) is
    /// performed by the caller (`Loader.readBin`), which owns the bytes — this
    /// method needs only the length.
    ///
    /// Errors:
    ///   - `error.UnsupportedVersion` if `version != current_version`
    ///   - `error.SectionOutOfBounds` if a section escapes the file bounds
    pub fn validate(self: RuntimeHeader, bin_len: usize) ValidateError!void {
        if (self.version != current_version) return error.UnsupportedVersion;
        const len: u64 = bin_len;
        const hdr: u64 = header_size;
        const data_off: u64 = self.data_offset;
        const data_end: u64 = data_off + @as(u64, self.data_size);
        if (data_off < hdr or data_end > len) return error.SectionOutOfBounds;
        const md_off: u64 = self.metadata_offset;
        const md_end: u64 = md_off + @as(u64, self.metadata_size);
        if (md_off < hdr or md_end > len) return error.SectionOutOfBounds;
    }
};

test "runtime header round-trips through its bytes" {
    const original = RuntimeHeader.init(.{
        .asset_type = .texture,
        .data_offset = header_size,
        .data_size = 4096,
        .metadata_offset = header_size + 4096,
        .metadata_size = 64,
        .hash = 0xDEADBEEFCAFEF00D,
    });

    const bytes = original.toBytes();
    try std.testing.expectEqual(@as(usize, header_size), bytes.len);

    const parsed = try RuntimeHeader.read(&bytes);
    try std.testing.expectEqual(original, parsed);
    try std.testing.expectEqual(AssetType.texture, parsed.assetType().?);
    try std.testing.expectEqual(@as(u16, current_version), parsed.version);
    try std.testing.expectEqual(@as(u32, 0), parsed._reserved);
}

test "runtime header layout is frozen at 40 bytes" {
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(RuntimeHeader));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(RuntimeHeader));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(RuntimeHeader, "hash"));
    try std.testing.expectEqual(@as(usize, 28), @offsetOf(RuntimeHeader, "_reserved"));

    const bytes = RuntimeHeader.init(.{
        .asset_type = .mesh,
        .data_offset = 40,
        .data_size = 0,
        .metadata_offset = 40,
        .metadata_size = 0,
        .hash = 0,
    }).toBytes();
    try std.testing.expectEqualSlices(u8, "WELD", bytes[0..4]);
}

test "runtime header read rejects a short buffer" {
    const short = [_]u8{ 'W', 'E', 'L', 'D' } ++ [_]u8{0} ** 10;
    try std.testing.expectError(error.ShortBuffer, RuntimeHeader.read(&short));
}

test "runtime header read rejects a bad magic" {
    var bytes = RuntimeHeader.init(.{
        .asset_type = .audio,
        .data_offset = 40,
        .data_size = 0,
        .metadata_offset = 40,
        .metadata_size = 0,
        .hash = 0,
    }).toBytes();
    bytes[1] = 'X';
    try std.testing.expectError(error.BadMagic, RuntimeHeader.read(&bytes));
}

test "validate rejects out-of-bounds sections" {
    // A 48-byte file cannot hold a 100-byte data section.
    const big_data = RuntimeHeader.init(.{
        .asset_type = .texture,
        .metadata_offset = header_size,
        .metadata_size = 0,
        .data_offset = header_size,
        .data_size = 100,
        .hash = 0,
    });
    try std.testing.expectError(error.SectionOutOfBounds, big_data.validate(header_size + 8));

    // Metadata section overruns the file.
    const big_meta = RuntimeHeader.init(.{
        .asset_type = .texture,
        .metadata_offset = header_size,
        .metadata_size = 100,
        .data_offset = header_size,
        .data_size = 0,
        .hash = 0,
    });
    try std.testing.expectError(error.SectionOutOfBounds, big_meta.validate(header_size));

    // A data_offset that points inside the header is rejected.
    const under_header = RuntimeHeader.init(.{
        .asset_type = .texture,
        .metadata_offset = header_size,
        .metadata_size = 0,
        .data_offset = 8,
        .data_size = 0,
        .hash = 0,
    });
    try std.testing.expectError(error.SectionOutOfBounds, under_header.validate(header_size));
}

test "validate rejects an unsupported version" {
    var h = RuntimeHeader.init(.{
        .asset_type = .texture,
        .metadata_offset = header_size,
        .metadata_size = 0,
        .data_offset = header_size,
        .data_size = 0,
        .hash = 0,
    });
    try h.validate(header_size); // header-only baseline is valid
    h.version = current_version + 1;
    try std.testing.expectError(error.UnsupportedVersion, h.validate(header_size));
}

test "validate rejects offset+size overflow" {
    // data_offset + data_size wraps in u32 (40 + 0xFFFFFFFF == 39) but the
    // u64-widened bounds check sees 4294967335 > bin_len and rejects it.
    const h = RuntimeHeader.init(.{
        .asset_type = .texture,
        .metadata_offset = header_size,
        .metadata_size = 0,
        .data_offset = header_size,
        .data_size = std.math.maxInt(u32),
        .hash = 0,
    });
    try std.testing.expectError(error.SectionOutOfBounds, h.validate(1024));
}
