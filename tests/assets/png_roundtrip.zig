//! M0.6 / E4 — PNG import → cook → load round-trip (brief §Acceptance).

const std = @import("std");
const assets = @import("weld_asset_pipeline");

const checker_png = @embedFile("data/checker.png");

test "png import-cook-load round-trip" {
    const gpa = std.testing.allocator;

    // Oracle: the E3 decoder gives the expected RGBA8.
    var img = try assets.codecs.png.decode(gpa, checker_png);
    defer img.deinit(gpa);

    // Import: source → intermediate doc + RGBA8 blob.
    var imp = try assets.importers.png.import(gpa, "checker.png", checker_png);
    defer imp.deinit(gpa);
    try std.testing.expectEqualStrings("Texture2D", imp.doc.type_name);
    try std.testing.expect(imp.doc.blobHash() != null);
    try std.testing.expectEqualSlices(u8, img.pixels, imp.blob);

    // Cook: intermediate → .texture.bin.
    const bin = try assets.cookers.cookTexture(gpa, imp.doc, imp.blob);
    defer gpa.free(bin);

    // Load: parse the frozen header and verify the payload + metadata.
    const header = try assets.RuntimeHeader.read(bin);
    try std.testing.expectEqual(assets.AssetType.texture, header.assetType().?);

    const meta = bin[header.metadata_offset..][0..header.metadata_size];
    try std.testing.expectEqual(img.width, std.mem.readInt(u32, meta[0..4], .little));
    try std.testing.expectEqual(img.height, std.mem.readInt(u32, meta[4..8], .little));

    const payload = bin[header.data_offset..][0..header.data_size];
    try std.testing.expectEqualSlices(u8, img.pixels, payload);
}
