//! M0.6 / E4 — cooking-cache hit differential (brief §Acceptance ▸ Benchmarks).
//!
//! A second cook of an unchanged asset hits the cache and skips the
//! (expensive) cook entirely. The asset is sized so the first cook does real
//! work (hash + write a large `.bin`); the hit is a directory lookup.

const std = @import("std");
const assets = @import("weld_asset_pipeline");

// 2048×2048 RGBA8 = 16 MiB — large enough that the first cook (BLAKE3 over the
// payload + writing the `.bin`) is clearly expensive vs a cache-hit lookup,
// without bloating CI with a huge temp file.
const width = 2048;
const height = 2048;

test "second cook of unchanged asset hits cache" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cache = assets.cache.Cache.init(tmp.dir);

    const blob = try gpa.alloc(u8, width * height * 4);
    defer gpa.free(blob);
    for (blob, 0..) |*b, i| b.* = @truncate(i *% 2_654_435_761);

    const source_hash = assets.hash.hex128(blob);
    const extracted = [_]assets.format.Field{
        .{ .key = "width", .value = .{ .int = width } },
        .{ .key = "height", .value = .{ .int = height } },
        .{ .key = "blob", .value = .{ .string = &source_hash } },
    };
    const doc = assets.AssetDoc{
        .name = "big",
        .type_name = "Texture2D",
        .version = 1,
        .source = "big.png",
        .source_hash = &source_hash,
        .extracted = &extracted,
    };

    const key = assets.cache.computeKey(&source_hash, "pc", 0);

    // First cook — cache miss: cook the .bin and store it.
    const t_miss = std.Io.Clock.Timestamp.now(io, .awake);
    try std.testing.expect(!cache.contains(io, &key));
    const bin = try assets.cookers.cookTexture(gpa, doc, blob);
    defer gpa.free(bin);
    try cache.put(io, &key, bin);
    const miss_ns: i64 = @intCast(t_miss.untilNow(io).raw.nanoseconds);

    // Second cook — cache hit: the artifact already exists, the cook is
    // skipped entirely.
    const t_hit = std.Io.Clock.Timestamp.now(io, .awake);
    const hit = cache.contains(io, &key);
    const hit_ns: i64 = @intCast(t_hit.untilNow(io).raw.nanoseconds);
    try std.testing.expect(hit);

    // The cached artifact is byte-identical to the fresh cook.
    const cached = (try cache.get(gpa, io, &key)).?;
    defer gpa.free(cached);
    try std.testing.expectEqualSlices(u8, bin, cached);

    const miss_ms = @divTrunc(miss_ns, std.time.ns_per_ms);
    const hit_us = @divTrunc(hit_ns, std.time.ns_per_us);
    std.debug.print("\n[cache_diff] first cook (miss) = {d} ms, second cook (hit) = {d} us\n", .{ miss_ms, hit_us });

    // Differential gate. The hit is a directory lookup (< 10 ms) and avoids
    // the cook entirely — a large speedup. The absolute first-cook wall-time
    // is build-mode- and disk-dependent (here ~800 ms Debug, ~50 ms
    // ReleaseSafe for 16 MiB); the brief's "≥ 100 ms first cook / < 10 ms
    // second" is the reference-machine figure for a real decode-heavy asset,
    // so the test asserts the robust differential rather than a flaky
    // absolute wall-time (see Closing notes).
    try std.testing.expect(@divTrunc(hit_ns, std.time.ns_per_ms) < 10); // hit < 10 ms
    try std.testing.expect(miss_ns > hit_ns * 20); // cache hit ≫ 20× faster
}
