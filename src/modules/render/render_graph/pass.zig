//! Pass — Phase 0 / M0.4.
//!
//! Abstraction of a render graph pass. A Pass declares its
//! read + written resources (Buffers and Textures) and provides a
//! `body` function that records the actual commands on a
//! GAL `RenderPassEncoder`.
//!
//! The graph uses the reads/writes declarations to:
//! 1. Compute the topological execution order
//! 2. Insert the barriers automatically via the `BarrierTracker`
//!    (cf. `gal/barriers.zig`), unless `barrier_mode = .explicit`

const std = @import("std");
const gal = @import("../gal/root.zig");
const escape = gal.escape_hatches;

/// Reference to a resource read or written by a pass.
pub const ResourceRef = union(enum) {
    buffer: gal.types.BufferHandle,
    texture: gal.types.TextureHandle,
};

/// Declared usage of a resource by a pass — feeds the BarrierTracker.
pub const ResourceUsage = struct {
    resource: ResourceRef,
    /// Shader stage where the resource is consumed/produced.
    stage: gal.types.ShaderStage,
    /// Access (write, read, color_attachment, depth_attachment, sampled).
    /// The tracker inserts barriers between passes according to these masks.
    access: gal.barriers.Access,
    /// Layout required for this pass (textures only).
    layout: ?escape.TextureLayout = null,
};

/// Signature of a pass's body function. Phase 0: GAL
/// `RenderPassEncoder` encoder + opaque user context.
pub const PassBody = *const fn (encoder: ?*anyopaque, ctx: ?*anyopaque) anyerror!void;

/// Definition of a pass in the graph.
pub const Pass = struct {
    /// Debug name for the inspector + logs.
    name: []const u8,
    /// Barrier tracking mode (cf. `escape_hatches.BarrierMode`).
    barrier_mode: escape.BarrierMode = .auto,
    /// Resources read by the pass.
    reads: []const ResourceUsage = &.{},
    /// Resources written by the pass.
    writes: []const ResourceUsage = &.{},
    /// Body function — executed when recording the command buffer.
    body: PassBody,
    /// User context passed to `body`. Phase 0: opaque, the caller
    /// casts to its concrete type. Phase 1+: RTTI-typed.
    ctx: ?*anyopaque = null,
    /// Depth ordering hint (used for front-to-back sorting by
    /// the forward pass — lower passes execute first).
    /// Phase 0: not used by the strict topological sort.
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
