//! Render Graph topological sort tests — Phase 0 / M0.4.
//!
//! Couvre brief §Critères d'acceptation > Tests :
//! - `graph produces correct topological order on known DAG`
//! - `graph detects cycle and returns error`
//!
//! Ces tests sont déjà présents en inline dans `graph.zig` mais le brief
//! demande un fichier dédié — on les duplique ici pour matcher exactement
//! la check-list.

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

    // DAG : A → B → C, et D indépendant. Doit donner A < B < C ordering.
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

    // Vérifier A < B < C.
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
