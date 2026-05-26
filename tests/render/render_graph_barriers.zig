//! Render Graph auto-tracking barriers tests — Phase 0 / M0.4.
//!
//! Couvre brief §Critères d'acceptation > Tests :
//! - `auto-tracking inserts read-after-write barrier` — 2 passes, pass A
//!   écrit Texture T, pass B lit T → barrier image layout transition +
//!   access mask inséré entre A et B
//! - `explicit mode skips auto-tracking` — pass marqué BarrierExplicit
//!   → aucune barrier auto-insérée

const std = @import("std");
const render = @import("weld_render");
const Graph = render.render_graph.Graph;
const TextureHandle = render.gal.types.TextureHandle;

fn noopBody(encoder: ?*anyopaque, ctx: ?*anyopaque) anyerror!void {
    _ = .{ encoder, ctx };
}

test "auto-tracking inserts read-after-write barrier" {
    var g = Graph.init(std.testing.allocator);
    defer g.deinit();

    const t = TextureHandle{ .inner = 42 };

    // Pass A : write as color attachment
    _ = try g.addPass(.{
        .name = "A_write",
        .body = noopBody,
        .barrier_mode = .auto,
        .writes = &.{.{
            .resource = .{ .texture = t },
            .stage = .{ .fragment = true },
            .access = .{ .write = true, .color_attachment = true },
            .layout = .color_attachment,
        }},
    });

    // Pass B : read as sampled
    _ = try g.addPass(.{
        .name = "B_read",
        .body = noopBody,
        .barrier_mode = .auto,
        .reads = &.{.{
            .resource = .{ .texture = t },
            .stage = .{ .fragment = true },
            .access = .{ .read = true, .sampled = true },
            .layout = .shader_read_only,
        }},
    });

    try g.compile();
    try g.trackBarriers();

    const barriers_emitted = g.barriers.consumeRecorded();
    try std.testing.expect(barriers_emitted.len >= 1);

    // La dernière barrière doit transitionner color_attachment → shader_read_only.
    const last = barriers_emitted[barriers_emitted.len - 1];
    try std.testing.expectEqual(@as(?render.gal.escape_hatches.TextureLayout, .color_attachment), last.old_layout);
    try std.testing.expectEqual(@as(?render.gal.escape_hatches.TextureLayout, .shader_read_only), last.new_layout);
}

test "explicit mode skips auto-tracking" {
    var g = Graph.init(std.testing.allocator);
    defer g.deinit();

    const t = TextureHandle{ .inner = 99 };
    _ = try g.addPass(.{
        .name = "A_write_explicit",
        .body = noopBody,
        .barrier_mode = .explicit,
        .writes = &.{.{
            .resource = .{ .texture = t },
            .stage = .{ .fragment = true },
            .access = .{ .write = true, .color_attachment = true },
            .layout = .color_attachment,
        }},
    });
    _ = try g.addPass(.{
        .name = "B_read_explicit",
        .body = noopBody,
        .barrier_mode = .explicit,
        .reads = &.{.{
            .resource = .{ .texture = t },
            .stage = .{ .fragment = true },
            .access = .{ .read = true, .sampled = true },
            .layout = .shader_read_only,
        }},
    });

    try g.compile();
    try g.trackBarriers();
    try std.testing.expectEqual(@as(usize, 0), g.barriers.consumeRecorded().len);
}
