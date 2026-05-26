//! Pass — Phase 0 / M0.4.
//!
//! Abstraction d'une passe du render graph. Une Pass déclare ses
//! resources lues + écrites (Buffers et Textures) et fournit une
//! fonction `body` qui enregistre les commandes effectives sur un
//! `RenderPassEncoder` GAL.
//!
//! Le graph utilise les déclarations reads/writes pour :
//! 1. Calculer l'ordre topologique d'exécution
//! 2. Insérer les barriers automatiquement via le `BarrierTracker`
//!    (cf. `gal/barriers.zig`), sauf si `barrier_mode = .explicit`

const std = @import("std");
const gal = @import("../gal/main.zig");
const escape = gal.escape_hatches;

/// Référence à une resource lue ou écrite par une pass.
pub const ResourceRef = union(enum) {
    buffer: gal.types.BufferHandle,
    texture: gal.types.TextureHandle,
};

/// Usage déclaré d'une resource par une pass — alimente le BarrierTracker.
pub const ResourceUsage = struct {
    resource: ResourceRef,
    /// Stage shader où la resource est consommée/produite.
    stage: gal.types.ShaderStage,
    /// Accès (write, read, color_attachment, depth_attachment, sampled).
    /// Le tracker insère des barriers entre passes selon ces masks.
    access: gal.barriers.Access,
    /// Layout requis pour cette pass (uniquement pour les textures).
    layout: ?escape.TextureLayout = null,
};

/// Signature de la fonction body d'une pass. Phase 0 : encoder
/// `RenderPassEncoder` GAL + context utilisateur opaque.
pub const PassBody = *const fn (encoder: ?*anyopaque, ctx: ?*anyopaque) anyerror!void;

/// Définition d'une pass dans le graph.
pub const Pass = struct {
    /// Nom debug pour l'inspector + logs.
    name: []const u8,
    /// Mode de tracking des barriers (cf. `escape_hatches.BarrierMode`).
    barrier_mode: escape.BarrierMode = .auto,
    /// Resources lues par la pass.
    reads: []const ResourceUsage = &.{},
    /// Resources écrites par la pass.
    writes: []const ResourceUsage = &.{},
    /// Fonction body — exécutée à l'enregistrement du command buffer.
    body: PassBody,
    /// Context utilisateur passé à `body`. Phase 0 : opaque, le caller
    /// caste à son type concret. Phase 1+ : RTTI-typed.
    ctx: ?*anyopaque = null,
    /// Profondeur ordering hint (utilisé pour le tri front-to-back par
    /// le forward pass — passes inférieures s'exécutent en premier).
    /// Phase 0 : non utilisé par le tri topologique strict.
    depth_hint: f32 = 0,
};

test "pass: ResourceRef tags compile" {
    const t = std.testing;
    const ref_b: ResourceRef = .{ .buffer = .{ .inner = 1 } };
    const ref_t: ResourceRef = .{ .texture = .{ .inner = 2 } };
    try t.expectEqual(@as(u64, 1), ref_b.buffer.inner);
    try t.expectEqual(@as(u64, 2), ref_t.texture.inner);
}

test "pass: ResourceUsage with access masks compose" {
    const t = std.testing;
    const usage: ResourceUsage = .{
        .resource = .{ .texture = .{ .inner = 10 } },
        .stage = .{ .fragment = true },
        .access = .{ .write = true, .color_attachment = true },
        .layout = .color_attachment,
    };
    try t.expect(usage.access.write);
    try t.expect(usage.access.color_attachment);
    try t.expect(!usage.access.depth_attachment);
}
