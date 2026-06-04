//! Shared cook assembly: lay out a runtime `.<type>.bin` as
//! `[40-byte header][metadata][data]`.
//!
//! The header is the E1-frozen `RuntimeHeader`, written via its explicit
//! little-endian `writeTo`/`toBytes` (no `@ptrCast` on write — the on-disk
//! bytes are produced field-by-field so the format is endianness-defined).

const std = @import("std");
const format = @import("../format/root.zig");
const hash = @import("../hash.zig");

/// Errors raised by the cookers.
pub const Error = error{
    /// A required `extracted` metadata field was missing or malformed.
    MissingMetadata,
    /// Allocation failed.
    OutOfMemory,
};

/// Assemble a `.bin`: header + metadata section + bulk data section. `hash`
/// is the BLAKE3-derived u64 of the data payload.
pub fn assemble(
    gpa: std.mem.Allocator,
    asset_type: format.AssetType,
    metadata: []const u8,
    data: []const u8,
) Error![]u8 {
    const md_off: u32 = @intCast(format.header_size);
    const data_off: u32 = md_off + @as(u32, @intCast(metadata.len));
    const total = @as(usize, data_off) + data.len;

    const out = try gpa.alloc(u8, total);
    errdefer gpa.free(out);

    const header = format.RuntimeHeader.init(.{
        .asset_type = asset_type,
        .metadata_offset = md_off,
        .metadata_size = @intCast(metadata.len),
        .data_offset = data_off,
        .data_size = @intCast(data.len),
        .hash = hash.u64Of(data),
    });
    const header_bytes = header.toBytes();
    @memcpy(out[0..format.header_size], &header_bytes);
    @memcpy(out[md_off..][0..metadata.len], metadata);
    @memcpy(out[data_off..][0..data.len], data);
    return out;
}
