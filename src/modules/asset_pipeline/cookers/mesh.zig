//! Mesh cooker — intermediate → `.mesh.bin` (version 1).
//!
//! M0.6 payload is raw f32 vertices + u32 indices (no quantization — that
//! is a Phase 1 `.mesh.bin` version bump, brief §Out-of-scope). Metadata
//! section: `vertex_count` u32, `index_count` u32, bounds min/max (6 × f32),
//! all little-endian.

const std = @import("std");
const format = @import("../format/root.zig");
const common = @import("common.zig");

const Value = format.Value;

/// Cook a mesh intermediate (`doc` + `blob` = positions f32 ++ indices u32)
/// into a `.mesh.bin`. Counts and bounds are read from `doc.extracted`.
pub fn cook(gpa: std.mem.Allocator, doc: format.AssetDoc, blob: []const u8) common.Error![]u8 {
    const vertex_count = format.intermediate.fieldInt(doc.extracted, "vertex_count") orelse return error.MissingMetadata;
    const index_count = format.intermediate.fieldInt(doc.extracted, "index_count") orelse return error.MissingMetadata;
    const bounds = readBounds(doc.extracted) orelse return error.MissingMetadata;

    var meta: [32]u8 = undefined;
    std.mem.writeInt(u32, meta[0..4], @intCast(vertex_count), .little);
    std.mem.writeInt(u32, meta[4..8], @intCast(index_count), .little);
    inline for (0..3) |i| std.mem.writeInt(u32, meta[8 + i * 4 ..][0..4], @bitCast(bounds.min[i]), .little);
    inline for (0..3) |i| std.mem.writeInt(u32, meta[20 + i * 4 ..][0..4], @bitCast(bounds.max[i]), .little);

    return common.assemble(gpa, .mesh, &meta, blob);
}

const Bounds = struct { min: [3]f32, max: [3]f32 };

fn readBounds(extracted: []const format.Field) ?Bounds {
    for (extracted) |f| {
        if (std.mem.eql(u8, f.key, "bounds")) {
            const obj = switch (f.value) {
                .object => |o| o,
                else => return null,
            };
            return .{
                .min = readVec3(obj, "min") orelse return null,
                .max = readVec3(obj, "max") orelse return null,
            };
        }
    }
    return null;
}

fn readVec3(obj: []const format.Field, key: []const u8) ?[3]f32 {
    for (obj) |f| {
        if (std.mem.eql(u8, f.key, key)) {
            const arr = switch (f.value) {
                .array => |a| a,
                else => return null,
            };
            if (arr.len < 3) return null;
            var v: [3]f32 = undefined;
            for (0..3) |i| v[i] = switch (arr[i]) {
                .float => |x| @floatCast(x),
                .int => |x| @floatFromInt(x),
                else => return null,
            };
            return v;
        }
    }
    return null;
}
