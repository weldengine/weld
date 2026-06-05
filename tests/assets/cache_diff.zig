//! M0.6 / E4 — cooking-cache hit functional test (brief §Acceptance ▸ Benchmarks).
//!
//! A second cook of an unchanged asset hits the cache and returns the
//! byte-identical artifact without re-cooking. This is the *correctness*
//! half of the brief's cache criterion: a miss → hit transition plus
//! byte-identity. It is deterministic and cross-host — no wall-clock
//! assertion — so it belongs in the `zig build test` gate.
//!
//! The *performance* half — the cold-cook-vs-hit time differential — is a
//! host- and load-dependent measurement, so it lives in the bench suite
//! (`bench/asset_cache.zig`, `zig build bench-asset-cache`), measured under
//! the opposable protocol on the reference machine. The original M0.6 test
//! asserted an absolute millisecond ratio inside the correctness gate, which
//! red-failed on slower / Windows CI runners (a single cache-hit sample can
//! spike on a page fault, AV scan, or cold directory). That debt was flagged
//! in the M0.7 brief (§ Acted deviations → "Known debt left untouched") and
//! is resolved here by moving the timing out of the gate, leaving only the
//! deterministic functional assertions below.

const std = @import("std");
const assets = @import("weld_asset_pipeline");

// 256×256 RGBA8 = 256 KiB — large enough to exercise a real cook (header +
// metadata + payload copy + BLAKE3 content hash) and a non-trivial
// byte-identity check, small enough to keep the correctness gate fast on
// every host. The larger 16 MiB asset that makes a *cold cook* expensive
// (the point of the timing differential) is the bench's concern, not the
// gate's.
const width = 256;
const height = 256;

test "second cook of unchanged asset hits cache and returns identical bytes" {
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

    // First cook — cache miss: the artifact is absent, so we cook it and
    // store it.
    try std.testing.expect(!cache.contains(io, &key));
    const bin = try assets.cookers.cookTexture(gpa, doc, blob);
    defer gpa.free(bin);
    try cache.put(io, &key, bin);

    // Second cook — cache hit: the artifact now exists, so the cook is
    // skipped entirely (the runtime serves the stored `.bin`).
    try std.testing.expect(cache.contains(io, &key));

    // The cached artifact is byte-identical to the fresh cook.
    const cached = (try cache.get(gpa, io, &key)).?;
    defer gpa.free(cached);
    try std.testing.expectEqualSlices(u8, bin, cached);
}
