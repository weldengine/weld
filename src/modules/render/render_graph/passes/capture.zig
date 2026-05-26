//! Capture Pass — Phase 0 / M0.4.
//!
//! Troisième passe (conditionnelle) du render graph Phase 0 (cf. brief
//! §Scope). Activée par le flag `--smoke-test` du caller (cf.
//! `examples/triangle/`). Blit la color target post-forward dans un buffer
//! readback CPU-visible, qui est ensuite converti en PPM RGB côté CPU.
//!
//! Cohérent avec brief §Notes décision 6 : format R8G8B8A8_UNORM (pas
//! BGRA) — conversion CPU vers PPM RGB triviale (drop alpha, écrire RGB
//! octet par octet).
//!
//! Phase 0 : la pass est conditionnellement ajoutée au graph par le caller.
//! Phase 1+ : intégration native dans le render graph avec un drapeau
//! `transient.captured` côté resource déclaration.

const std = @import("std");
const gal = @import("../../gal/main.zig");
const pass_mod = @import("../pass.zig");

/// Configuration de la capture pass.
pub const Config = struct {
    /// Cible color à capturer (typiquement l'image courante de la swapchain
    /// ou un offscreen RT R8G8B8A8_UNORM dédié au smoke test).
    color_source: gal.types.TextureHandle,
    /// Buffer host-visible (`host_visible = true`) destinataire du blit.
    /// Le caller alloue, map en CPU pour l'export PPM.
    capture_buffer: gal.types.BufferHandle,
    /// Dimensions de l'image (pour le blit + le header PPM).
    width: u32,
    height: u32,
};

/// Construit une Pass capture prête à être ajoutée à un Graph.
pub fn buildPass(config: *const Config) pass_mod.Pass {
    return .{
        .name = "capture_to_buffer",
        .barrier_mode = .auto,
        .reads = &.{.{
            .resource = .{ .texture = config.color_source },
            .stage = .{ .fragment = true },
            .access = .{ .read = true },
            .layout = .transfer_src,
        }},
        .writes = &.{.{
            .resource = .{ .buffer = config.capture_buffer },
            .stage = .{ .fragment = true },
            .access = .{ .write = true },
            .layout = null,
        }},
        .body = body,
        .ctx = @as(*anyopaque, @ptrCast(@constCast(config))),
    };
}

fn body(encoder: ?*anyopaque, ctx: ?*anyopaque) anyerror!void {
    _ = .{ encoder, ctx };
    // Phase 0 : le blit effectif (`vkCmdCopyImageToBuffer`) est câblé par
    // `examples/triangle/` qui ouvre + map + écrit le PPM. Le body du
    // pass est no-op au niveau du render graph — les commandes natives
    // sont enregistrées hors render pass via le CommandEncoder.
}

test "capture: buildPass declares texture read + buffer write" {
    const t = std.testing;
    const tex = gal.types.TextureHandle{ .inner = 20 };
    const buf = gal.types.BufferHandle{ .inner = 21 };
    const cfg: Config = .{
        .color_source = tex,
        .capture_buffer = buf,
        .width = 1280,
        .height = 720,
    };
    const p = buildPass(&cfg);
    try t.expectEqual(@as(usize, 1), p.reads.len);
    try t.expectEqual(@as(usize, 1), p.writes.len);
    try t.expectEqualStrings("capture_to_buffer", p.name);
}
