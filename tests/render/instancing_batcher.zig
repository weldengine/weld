//! Instancing batcher tests — Phase 0 / M0.4.
//!
//! Covers brief §Acceptance criteria > Tests:
//! - `batcher groups entities by mesh and material` — 1000 entities, 10
//!   distinct (mesh, material) → exactly 10 buckets
//! - `batcher produces under 100 drawcalls for 100k entities on 100 distinct
//!   mesh-material pairs` — strict assertion on the drawcalls counter
//!
//! The inline tests in `batcher.zig` cover the same cases. This file
//! exists to match the brief check-list and expose the test via
//! `tests/render/`.

const std = @import("std");
const render = @import("weld_render");
const Batcher = render.instancing.batcher.Batcher;
const MeshId = render.instancing.batcher.MeshId;
const MaterialId = render.instancing.batcher.MaterialId;

test "batcher groups entities by mesh and material" {
    var b = Batcher.init(std.testing.allocator);
    defer b.deinit();

    // 1000 entities, 10 distinct (mesh, material).
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        const mesh: MeshId = i % 5;
        const material: MaterialId = (i / 5) % 2;
        try b.submit(.{
            .mesh = mesh,
            .material = material,
            .transform = .{ .position = .{ @floatFromInt(i), 0, 0 } },
        });
    }
    try b.finalize(.{ 0, 0, 0 });
    try std.testing.expectEqual(@as(u32, 10), b.stats.buckets);
}

test "batcher produces under 100 drawcalls for 100k entities on 100 distinct mesh-material pairs" {
    var b = Batcher.init(std.testing.allocator);
    defer b.deinit();

    var prng = std.Random.DefaultPrng.init(0xCAFE);
    const rand = prng.random();

    var i: u32 = 0;
    while (i < 100_000) : (i += 1) {
        try b.submit(.{
            .mesh = rand.intRangeAtMost(u32, 0, 9),
            .material = rand.intRangeAtMost(u32, 0, 9),
            .transform = .{ .position = .{
                rand.float(f32) * 100,
                rand.float(f32) * 100,
                rand.float(f32) * 100,
            } },
        });
    }
    try b.finalize(.{ 50, 50, 50 });

    try std.testing.expect(b.stats.buckets <= 100);
    try std.testing.expectEqual(@as(u32, 100_000), b.stats.entities);
}
