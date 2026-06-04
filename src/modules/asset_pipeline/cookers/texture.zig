//! Texture cooker — intermediate → `.texture.bin`.
//!
//! M0.6 payload is raw RGBA8 (no mipmaps, no GPU block compression — brief
//! §Out-of-scope). Metadata section: `width` u32, `height` u32 (LE).

const std = @import("std");
const format = @import("../format/root.zig");
const common = @import("common.zig");

/// Cook a texture intermediate (`doc` + decoded RGBA8 `blob`) into a
/// `.texture.bin`. `width`/`height` are read from `doc.extracted`.
pub fn cook(gpa: std.mem.Allocator, doc: format.AssetDoc, blob: []const u8) common.Error![]u8 {
    const width = format.intermediate.fieldInt(doc.extracted, "width") orelse return error.MissingMetadata;
    const height = format.intermediate.fieldInt(doc.extracted, "height") orelse return error.MissingMetadata;

    var meta: [8]u8 = undefined;
    std.mem.writeInt(u32, meta[0..4], @intCast(width), .little);
    std.mem.writeInt(u32, meta[4..8], @intCast(height), .little);

    return common.assemble(gpa, .texture, &meta, blob);
}
