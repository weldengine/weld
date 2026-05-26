//! Depth Prepass — Phase 0 / M0.4.
//!
//! Première passe du render graph Phase 0 (cf. brief §Scope).
//! Écrit uniquement le D32_SFLOAT depth buffer (pas de stencil). Le
//! forward opaque qui suit lit ce depth buffer via depth test on +
//! depth write off (early-Z).
//!
//! Phase 1+ : remplacé par le V-Buffer pass (cf. `engine-render.md` §4).
//! Le slot reste pour la compatibilité tests / scènes legacy.

const std = @import("std");
const gal = @import("../../gal/main.zig");
const pass_mod = @import("../pass.zig");

/// Configuration de la depth prepass.
pub const Config = struct {
    /// Texture du depth buffer (format D32_SFLOAT attendu, cf. brief).
    depth_target: gal.types.TextureHandle,
    /// Valeur de clear depth (1.0 par défaut — reverse-Z = 0.0 Phase 1+).
    depth_clear: f32 = 1.0,
};

/// Construit une Pass depth-prepass prête à être ajoutée à un Graph.
pub fn buildPass(config: *const Config) pass_mod.Pass {
    return .{
        .name = "depth_prepass",
        .barrier_mode = .auto,
        .reads = &.{},
        .writes = &.{.{
            .resource = .{ .texture = config.depth_target },
            .stage = .{ .vertex = true, .fragment = true },
            .access = .{ .write = true, .depth_attachment = true },
            .layout = .depth_stencil_attachment,
        }},
        .body = body,
        .ctx = @as(*anyopaque, @ptrCast(@constCast(config))),
    };
}

/// Body de la pass — Phase 0 : no-op (le brief stipule que le rendering
/// effectif des objets se fait Phase 1+ via le V-Buffer). La pass existe
/// pour câbler le depth buffer dans le graph et exercer le barrier insertion.
fn body(encoder: ?*anyopaque, ctx: ?*anyopaque) anyerror!void {
    _ = .{ encoder, ctx };
    // Phase 0 : pas de drawcalls — le depth buffer est juste cleared par
    // la load op de la render pass. Le bench instancing Phase 0 utilise
    // directement le forward (sans prepass) — cette passe est exercée par
    // les tests de barrier insertion.
}

test "depth_prepass: buildPass populates writes" {
    const t = std.testing;
    const tex = gal.types.TextureHandle{ .inner = 1 };
    const cfg: Config = .{ .depth_target = tex };
    const p = buildPass(&cfg);
    try t.expectEqual(@as(usize, 0), p.reads.len);
    try t.expectEqual(@as(usize, 1), p.writes.len);
    try t.expectEqualStrings("depth_prepass", p.name);
    try t.expect(p.writes[0].access.depth_attachment);
}
