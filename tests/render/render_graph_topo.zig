//! Render Graph topological sort tests — Phase 0 / M0.4.
//!
//! Covers brief §Acceptance criteria > Tests:
//! - `graph produces correct topological order on known DAG`
//! - `graph detects cycle and returns error`
//!
//! These tests are already present inline in `graph.zig` but the brief
//! requires a dedicated file — we duplicate them here to match the
//! check-list exactly.

const std = @import("std");
const render = @import("weld_render");
const Graph = render.render_graph.Graph;
const TextureHandle = render.gal.types.TextureHandle;

fn noopBody(encoder: ?*anyopaque, ctx: ?*anyopaque) anyerror!void {
    _ = .{ encoder, ctx };
}

test "graph produces correct topological order on known DAG" {
    var g = Graph.init(std.testing.allocator);
    defer g.deinit();

    // DAG : A → B → C, and D independent. Must give A < B < C ordering.
    const t1 = TextureHandle{ .inner = 100 };
    const t2 = TextureHandle{ .inner = 200 };

    const idx_a = try g.addPass(.{
        .name = "A",
        .body = noopBody,
        .writes = &.{.{
            .resource = .{ .texture = t1 },
            .stage = .{ .fragment = true },
            .access = .{ .write = true, .color_attachment = true },
            .layout = .color_attachment,
        }},
    });
    const idx_b = try g.addPass(.{
        .name = "B",
        .body = noopBody,
        .reads = &.{.{
            .resource = .{ .texture = t1 },
            .stage = .{ .fragment = true },
            .access = .{ .read = true, .sampled = true },
            .layout = .shader_read_only,
        }},
        .writes = &.{.{
            .resource = .{ .texture = t2 },
            .stage = .{ .fragment = true },
            .access = .{ .write = true, .color_attachment = true },
            .layout = .color_attachment,
        }},
    });
    const idx_c = try g.addPass(.{
        .name = "C",
        .body = noopBody,
        .reads = &.{.{
            .resource = .{ .texture = t2 },
            .stage = .{ .fragment = true },
            .access = .{ .read = true, .sampled = true },
            .layout = .shader_read_only,
        }},
    });
    const idx_d = try g.addPass(.{ .name = "D", .body = noopBody });

    try g.compile();
    try std.testing.expectEqual(@as(usize, 4), g.execution_order.items.len);

    // Verify A < B < C.
    var pos: [4]?usize = .{ null, null, null, null };
    for (g.execution_order.items, 0..) |pi, i| {
        if (pi == idx_a) pos[0] = i;
        if (pi == idx_b) pos[1] = i;
        if (pi == idx_c) pos[2] = i;
        if (pi == idx_d) pos[3] = i;
    }
    for (pos) |p| try std.testing.expect(p != null);
    try std.testing.expect(pos[0].? < pos[1].?);
    try std.testing.expect(pos[1].? < pos[2].?);
}

test "graph detects cycle and returns error" {
    var g = Graph.init(std.testing.allocator);
    defer g.deinit();
    const t1 = TextureHandle{ .inner = 1 };
    const t2 = TextureHandle{ .inner = 2 };
    _ = try g.addPass(.{
        .name = "A",
        .body = noopBody,
        .reads = &.{.{
            .resource = .{ .texture = t2 },
            .stage = .{ .fragment = true },
            .access = .{ .read = true, .sampled = true },
        }},
        .writes = &.{.{
            .resource = .{ .texture = t1 },
            .stage = .{ .fragment = true },
            .access = .{ .write = true, .color_attachment = true },
        }},
    });
    _ = try g.addPass(.{
        .name = "B",
        .body = noopBody,
        .reads = &.{.{
            .resource = .{ .texture = t1 },
            .stage = .{ .fragment = true },
            .access = .{ .read = true, .sampled = true },
        }},
        .writes = &.{.{
            .resource = .{ .texture = t2 },
            .stage = .{ .fragment = true },
            .access = .{ .write = true, .color_attachment = true },
        }},
    });
    try std.testing.expectError(error.RenderGraphCycle, g.compile());
}

test "graph WAW two writers same resource: ordered by insertion, not a cycle" {
    // M0.5 item 7 (latent bug repro): two passes writing the SAME resource
    // with no RAW relation between them must be serialized by insertion order
    // (lower index first), NOT reported as error.RenderGraphCycle. Guards the
    // WAW-symmetry bug in `passDependsOn` (edges in both directions → false
    // cycle). RED before the fix, green after.
    var g = Graph.init(std.testing.allocator);
    defer g.deinit();

    const t = TextureHandle{ .inner = 42 };
    const writer_a = try g.addPass(.{
        .name = "writer_a",
        .body = noopBody,
        .writes = &.{.{
            .resource = .{ .texture = t },
            .stage = .{ .fragment = true },
            .access = .{ .write = true, .color_attachment = true },
            .layout = .color_attachment,
        }},
    });
    const writer_b = try g.addPass(.{
        .name = "writer_b",
        .body = noopBody,
        .writes = &.{.{
            .resource = .{ .texture = t },
            .stage = .{ .fragment = true },
            .access = .{ .write = true, .color_attachment = true },
            .layout = .color_attachment,
        }},
    });

    // Must compile without a false cycle.
    try g.compile();
    try std.testing.expectEqual(@as(usize, 2), g.execution_order.items.len);

    // Insertion-order tiebreak: writer_a (added first) precedes writer_b.
    var pos_a: ?usize = null;
    var pos_b: ?usize = null;
    for (g.execution_order.items, 0..) |pi, i| {
        if (pi == writer_a) pos_a = i;
        if (pi == writer_b) pos_b = i;
    }
    try std.testing.expect(pos_a != null and pos_b != null);
    try std.testing.expect(pos_a.? < pos_b.?);
}
