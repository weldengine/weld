//! Forward Opaque Pass — Phase 0 / M0.4.
//!
//! Deuxième passe du render graph Phase 0 (cf. brief §Scope). Render
//! l'ensemble des entités opaques avec depth test on + depth write on.
//! Tri front-to-back par bucket `(mesh_id, material_id)` — alimenté par
//! l'instancing batcher (cf. `src/modules/render/instancing/batcher.zig`).
//!
//! Phase 0 : pas de transparent pass (brief §Out-of-scope) ; pas de
//! MSAA ; pas de post-process. La sortie color est directement présentée
//! par le swapchain (ou capturée par la pass `capture` en mode
//! `--smoke-test`).

const std = @import("std");
const gal = @import("../../gal/main.zig");
const pass_mod = @import("../pass.zig");

/// Configuration de la forward opaque pass.
pub const Config = struct {
    /// Cible color (typiquement l'image courante de la swapchain).
    color_target: gal.types.TextureHandle,
    /// Depth buffer hérité du depth prepass.
    depth_target: gal.types.TextureHandle,
    /// Couleur de clear du color attachment.
    clear_color: gal.types.ColorClear = .{ .r = 0.05, .g = 0.05, .b = 0.08, .a = 1.0 },
};

/// Construit une Pass forward opaque prête à être ajoutée à un Graph.
pub fn buildPass(config: *const Config) pass_mod.Pass {
    return .{
        .name = "forward_opaque",
        .barrier_mode = .auto,
        .reads = &.{.{
            // Le depth est en read-only (depth test, pas write).
            .resource = .{ .texture = config.depth_target },
            .stage = .{ .fragment = true },
            .access = .{ .read = true },
            .layout = .depth_stencil_attachment,
        }},
        .writes = &.{.{
            .resource = .{ .texture = config.color_target },
            .stage = .{ .fragment = true },
            .access = .{ .write = true, .color_attachment = true },
            .layout = .color_attachment,
        }},
        .body = body,
        .ctx = @as(*anyopaque, @ptrCast(@constCast(config))),
    };
}

fn body(encoder: ?*anyopaque, ctx: ?*anyopaque) anyerror!void {
    _ = .{ encoder, ctx };
    // Phase 0 : la pass forward est exercée par `examples/triangle/` et
    // `bench/render_instancing.zig` (suite immédiate du milestone). Le
    // body effectif sera câblé via l'instancing batcher (drawIndexed
    // batchés par bucket).
}

test "forward: buildPass declares depth read + color write" {
    const t = std.testing;
    const color = gal.types.TextureHandle{ .inner = 10 };
    const depth = gal.types.TextureHandle{ .inner = 11 };
    const cfg: Config = .{ .color_target = color, .depth_target = depth };
    const p = buildPass(&cfg);
    try t.expectEqual(@as(usize, 1), p.reads.len);
    try t.expectEqual(@as(usize, 1), p.writes.len);
    try t.expectEqualStrings("forward_opaque", p.name);
    try t.expect(p.writes[0].access.color_attachment);
}
