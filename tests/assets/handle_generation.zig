//! Asset registry stale-handle acceptance test.
//!
//! Allocate a handle ("load"), capture it, unload, and assert the captured
//! handle no longer resolves — a generation mismatch.
//!
//! Exercised at the REGISTRY surface, which is the frozen identity layer; the
//! full importer → cook → load → unload round-trip wires that same registry
//! into the async loader and is covered in `loader_async.zig`.

const std = @import("std");
const assets = @import("weld_asset_pipeline");

const Registry = assets.Registry;
const AssetType = assets.AssetType;

test "stale handle after unload is rejected" {
    const gpa = std.testing.allocator;
    var reg = Registry.init();
    defer reg.deinit(gpa);

    // "load" — allocate a handle for a texture asset (refcount 1).
    const handle = try reg.alloc(gpa, .texture);
    try std.testing.expect(reg.isAlive(handle));
    try std.testing.expectEqual(AssetType.texture, reg.resolve(handle).?.asset_type.?);

    // "unload" — frees the slot and bumps its generation.
    try reg.unload(gpa, handle);

    // The captured handle is now stale: it resolves to nothing and every
    // verb that takes it reports a stale handle.
    try std.testing.expect(!reg.isAlive(handle));
    try std.testing.expectEqual(@as(?Registry.Resolved, null), reg.resolve(handle));
    try std.testing.expectError(error.StaleHandle, reg.retain(handle));

    // Re-allocating recycles the same slot with a different generation, and
    // the stale handle stays rejected even though the index now points at a
    // live asset again.
    const fresh = try reg.alloc(gpa, .texture);
    try std.testing.expectEqual(handle.index, fresh.index);
    try std.testing.expect(fresh.generation != handle.generation);
    try std.testing.expect(reg.isAlive(fresh));
    try std.testing.expect(!reg.isAlive(handle));
}
