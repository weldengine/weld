//! glTF importer — source bytes → intermediate (`AssetDoc` + vertex blob).
//!
//! Decodes via `codecs.gltf` and builds a `StaticMesh`
//! `<type>.asset.etch` document plus a blob = positions (f32) ++ indices
//! (u32), all little-endian. Pure (in-memory).

const std = @import("std");
const format = @import("../format/root.zig");
const hash = @import("../hash.zig");
const gltf = @import("../codecs/gltf/root.zig");
const common = @import("common.zig");

const Field = format.Field;
const Value = format.Value;
const AssetDoc = format.AssetDoc;

/// Imported asset (document arena + blob).
pub const Import = common.Import;

/// Errors raised by `import`.
pub const Error = error{OutOfMemory} || gltf.Error;

/// Import a glTF file (`src` bytes from `source_path`) into an intermediate.
/// `uuid` is the caller-resolved stable identity (canonical UUIDv7 string).
pub fn import(gpa: std.mem.Allocator, source_path: []const u8, src: []const u8, uuid: []const u8) Error!Import {
    var mesh = try gltf.decode(gpa, src);
    defer mesh.deinit(gpa);

    // Blob: positions (f32 LE) followed by indices (u32 LE).
    const pos_bytes = mesh.positions.len * 4;
    const idx_bytes = mesh.indices.len * 4;
    const blob = try gpa.alloc(u8, pos_bytes + idx_bytes);
    errdefer gpa.free(blob);
    for (mesh.positions, 0..) |p, i| std.mem.writeInt(u32, blob[i * 4 ..][0..4], @bitCast(p), .little);
    for (mesh.indices, 0..) |idx, i| std.mem.writeInt(u32, blob[pos_bytes + i * 4 ..][0..4], idx, .little);

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const min_arr = try a.dupe(Value, &[_]Value{
        .{ .float = mesh.bounds_min[0] }, .{ .float = mesh.bounds_min[1] }, .{ .float = mesh.bounds_min[2] },
    });
    const max_arr = try a.dupe(Value, &[_]Value{
        .{ .float = mesh.bounds_max[0] }, .{ .float = mesh.bounds_max[1] }, .{ .float = mesh.bounds_max[2] },
    });
    const bounds_obj = try a.dupe(Field, &[_]Field{
        .{ .key = "min", .value = .{ .array = min_arr } },
        .{ .key = "max", .value = .{ .array = max_arr } },
    });
    const extracted = try a.dupe(Field, &[_]Field{
        .{ .key = "vertex_count", .value = .{ .int = mesh.vertex_count } },
        .{ .key = "index_count", .value = .{ .int = @intCast(mesh.indices.len) } },
        .{ .key = "bounds", .value = .{ .object = bounds_obj } },
        .{ .key = "blob", .value = .{ .string = try a.dupe(u8, &hash.hex128(blob)) } },
    });

    const doc = AssetDoc{
        .name = try a.dupe(u8, std.fs.path.stem(source_path)),
        .uuid = try a.dupe(u8, uuid),
        .type_name = "StaticMesh",
        .version = 1,
        .source = try a.dupe(u8, source_path),
        .source_hash = try a.dupe(u8, &hash.hex128(src)),
        .extracted = extracted,
    };

    return .{ .arena = arena, .doc = doc, .blob = blob };
}
