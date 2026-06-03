//! Depth Prepass — Phase 0 / M0.4.
//!
//! First pass of the Phase 0 render graph (cf. brief §Scope).
//! Writes only the D32_SFLOAT depth buffer (no stencil). The
//! forward opaque that follows reads this depth buffer via depth test on +
//! depth write off (early-Z).
//!
//! Phase 1+: replaced by the V-Buffer pass (cf. `engine-render.md` §4).
//! The slot remains for tests / legacy scenes compatibility.

const std = @import("std");
const gal = @import("../../gal/root.zig");
const pass_mod = @import("../pass.zig");

/// Configuration of the depth prepass.
pub const Config = struct {
    /// Depth buffer texture (D32_SFLOAT format expected, cf. brief).
    depth_target: gal.types.TextureHandle,
    /// Depth clear value (1.0 by default — reverse-Z = 0.0 Phase 1+).
    depth_clear: f32 = 1.0,
};

/// Builds a depth-prepass Pass ready to be added to a Graph.
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

/// Pass body — Phase 0: no-op (the brief states that the actual
/// rendering of objects happens Phase 1+ via the V-Buffer). The pass exists
/// to wire the depth buffer into the graph and exercise barrier insertion.
fn body(encoder: ?*anyopaque, ctx: ?*anyopaque) anyerror!void {
    _ = .{ encoder, ctx };
    // Phase 0: no drawcalls — the depth buffer is just cleared by
    // the render pass load op. The Phase 0 instancing bench uses
    // the forward directly (without prepass) — this pass is exercised by
    // the barrier insertion tests.
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
