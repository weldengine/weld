//! Forward Opaque Pass.
//!
//! Second pass of the render graph. Renders
//! all opaque entities with depth test on + depth write on.
//! Front-to-back sorting by `(mesh_id, material_id)` bucket — fed by
//! the instancing batcher (cf. `src/modules/render/instancing/batcher.zig`).
//!
//! No transparent pass; no
//! MSAA; no post-process. The color output is presented directly
//! by the swapchain (or captured by the `capture` pass in
//! `--smoke-test` mode).

const std = @import("std");
const gal = @import("../../gal/root.zig");
const pass_mod = @import("../pass.zig");

/// Configuration of the forward opaque pass.
pub const Config = struct {
    /// Color target (typically the current swapchain image).
    color_target: gal.types.TextureHandle,
    /// Depth buffer inherited from the depth prepass.
    depth_target: gal.types.TextureHandle,
    /// Clear color of the color attachment.
    clear_color: gal.types.ColorClear = .{ .r = 0.05, .g = 0.05, .b = 0.08, .a = 1.0 },
    /// Storage the returned `Pass.reads`/`Pass.writes` point at.
    ///
    /// Without this field, `buildPass` would return slices of an ANONYMOUS
    /// LITERAL built in its own stack frame, so the `Pass` would carry a
    /// dangling pointer the moment it returned.
    ///
    /// The config owns it and introduces NO new lifetime constraint: the config is
    /// already the pass's `ctx`, so it had to outlive the pass by construction.
    read_storage: [1]pass_mod.ResourceUsage = undefined,
    write_storage: [1]pass_mod.ResourceUsage = undefined,
};

/// Builds a forward opaque Pass ready to be added to a Graph.
pub fn buildPass(config: *Config) pass_mod.Pass {
    // The depth is read-only (depth test, not write).
    config.read_storage[0] = .{
        .resource = .{ .texture = config.depth_target },
        .stage = .{ .fragment = true },
        .access = .{ .read = true },
        .layout = .depth_stencil_attachment,
    };
    config.write_storage[0] = .{
        .resource = .{ .texture = config.color_target },
        .stage = .{ .fragment = true },
        .access = .{ .write = true, .color_attachment = true },
        .layout = .color_attachment,
    };
    return .{
        .name = "forward_opaque",
        .barrier_mode = .auto,
        .reads = config.read_storage[0..],
        .writes = config.write_storage[0..],
        .body = body,
        .ctx = @as(*anyopaque, @ptrCast(@constCast(config))),
    };
}

fn body(encoder: ?*anyopaque, ctx: ?*anyopaque) anyerror!void {
    _ = .{ encoder, ctx };
    // TODO(forward pass body): this body is a NO-OP, so the pass renders
    // nothing and is exercised only by `examples/triangle/` and
    // `bench/render_instancing.zig`. Wiring it means drawIndexed batched by
    // bucket through the instancing batcher.
}

test "forward: buildPass declares depth read + color write" {
    const t = std.testing;
    const color = gal.types.TextureHandle{ .inner = 10 };
    const depth = gal.types.TextureHandle{ .inner = 11 };
    var cfg: Config = .{ .color_target = color, .depth_target = depth };
    const p = buildPass(&cfg);
    try t.expectEqual(@as(usize, 1), p.reads.len);
    try t.expectEqual(@as(usize, 1), p.writes.len);
    try t.expectEqualStrings("forward_opaque", p.name);
    try t.expect(p.writes[0].access.color_attachment);
    // Both slices must point INTO the config, never at a returned frame.
    try t.expectEqual(@as([*]const pass_mod.ResourceUsage, &cfg.read_storage), p.reads.ptr);
    try t.expectEqual(@as([*]const pass_mod.ResourceUsage, &cfg.write_storage), p.writes.ptr);
}
