//! PNG importer — source bytes → intermediate (`AssetDoc` + RGBA8 blob).
//!
//! Decodes via `codecs.png` and builds a `Texture2D` `<type>.asset.etch`
//! document plus the decoded RGBA8 blob. Pure (in-memory); writing the
//! `.texture.asset.etch` text and the `.weld/blobs/` blob is the offline
//! pipeline's job.

const std = @import("std");
const format = @import("../format/root.zig");
const hash = @import("../hash.zig");
const png = @import("../codecs/png/root.zig");
const common = @import("common.zig");

const Field = format.Field;
const AssetDoc = format.AssetDoc;

/// Imported asset (document arena + blob).
pub const Import = common.Import;

/// Errors raised by `import`.
pub const Error = error{OutOfMemory} || png.Error;

/// Import a PNG file (`src` bytes from `source_path`) into an intermediate.
/// `uuid` is the stable identity (canonical UUIDv7 string) the caller
/// resolved — generated on first import, preserved from the existing
/// `.asset.etch` on re-import.
pub fn import(gpa: std.mem.Allocator, source_path: []const u8, src: []const u8, uuid: []const u8) Error!Import {
    var img = try png.decode(gpa, src);
    errdefer img.deinit(gpa);

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const blob = img.pixels; // ownership transfers to Import on success
    const blob_hash = try a.dupe(u8, &hash.hex128(blob));

    const import_settings = try a.dupe(Field, &[_]Field{
        .{ .key = "srgb", .value = .{ .boolean = true } },
    });
    const cook_pc = try a.dupe(Field, &[_]Field{
        .{ .key = "format", .value = .{ .enum_literal = "rgba8" } },
    });
    const cook_settings = try a.dupe(Field, &[_]Field{
        .{ .key = "pc", .value = .{ .object = cook_pc } },
    });
    const extracted = try a.dupe(Field, &[_]Field{
        .{ .key = "width", .value = .{ .int = img.width } },
        .{ .key = "height", .value = .{ .int = img.height } },
        .{ .key = "channels", .value = .{ .int = 4 } },
        .{ .key = "blob", .value = .{ .string = blob_hash } },
    });

    const doc = AssetDoc{
        .name = try a.dupe(u8, std.fs.path.stem(source_path)),
        .uuid = try a.dupe(u8, uuid),
        .type_name = "Texture2D",
        .version = 1,
        .source = try a.dupe(u8, source_path),
        .source_hash = try a.dupe(u8, &hash.hex128(src)),
        .import_settings = import_settings,
        .cook_settings = cook_settings,
        .extracted = extracted,
    };

    return .{ .arena = arena, .doc = doc, .blob = blob };
}
