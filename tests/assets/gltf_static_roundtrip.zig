//! M0.6 / E4 — glTF static import → cook → load round-trip (brief §Acceptance).

const std = @import("std");
const assets = @import("weld_asset_pipeline");

const cube_gltf = @embedFile("data/cube.gltf");

test "gltf static import-cook-load round-trip" {
    const gpa = std.testing.allocator;

    // Oracle: the E3 decoder.
    var mesh = try assets.codecs.gltf.decode(gpa, cube_gltf);
    defer mesh.deinit(gpa);

    // Import → cook.
    var imp = try assets.importers.gltf.import(gpa, "cube.gltf", cube_gltf, "0190b3f0-1c2d-7e4a-8b6c-001122334455");
    defer imp.deinit(gpa);
    try std.testing.expectEqualStrings("StaticMesh", imp.doc.type_name);
    try std.testing.expectEqualStrings("0190b3f0-1c2d-7e4a-8b6c-001122334455", imp.doc.uuid);

    const bin = try assets.cookers.cookMesh(gpa, imp.doc, imp.blob);
    defer gpa.free(bin);

    // Load: header + metadata (vertex/index counts, bounds).
    const header = try assets.RuntimeHeader.read(bin);
    try std.testing.expectEqual(assets.AssetType.mesh, header.assetType().?);

    const meta = bin[header.metadata_offset..][0..header.metadata_size];
    try std.testing.expectEqual(mesh.vertex_count, std.mem.readInt(u32, meta[0..4], .little));
    try std.testing.expectEqual(@as(u32, @intCast(mesh.indices.len)), std.mem.readInt(u32, meta[4..8], .little));
    const min_x: f32 = @bitCast(std.mem.readInt(u32, meta[8..12], .little));
    const max_x: f32 = @bitCast(std.mem.readInt(u32, meta[20..24], .little));
    try std.testing.expectEqual(mesh.bounds_min[0], min_x);
    try std.testing.expectEqual(mesh.bounds_max[0], max_x);

    // Payload = positions (f32) ++ indices (u32).
    const payload = bin[header.data_offset..][0..header.data_size];
    try std.testing.expectEqual(mesh.positions.len * 4 + mesh.indices.len * 4, payload.len);
    // First position component round-trips bit-exact.
    const p0: f32 = @bitCast(std.mem.readInt(u32, payload[0..4], .little));
    try std.testing.expectEqual(mesh.positions[0], p0);
}
