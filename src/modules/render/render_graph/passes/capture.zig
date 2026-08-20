//! Capture Pass — Phase 0 / M0.4.
//!
//! Third (conditional) pass of the Phase 0 render graph (cf. brief
//! §Scope). Activated by the caller's `--smoke-test` flag (cf.
//! `examples/triangle/`). Blits the post-forward color target into a
//! CPU-visible readback buffer, which is then converted to PPM RGB on the CPU.
//!
//! Consistent with brief §Notes decision 6: R8G8B8A8_UNORM format (not
//! BGRA) — trivial CPU-to-PPM RGB conversion (drop alpha, write RGB
//! byte by byte).
//!
//! Phase 0: the pass is conditionally added to the graph by the caller.
//! Phase 1+: native integration into the render graph with a
//! `transient.captured` flag on the resource declaration side.

const std = @import("std");
const gal = @import("../../gal/root.zig");
const pass_mod = @import("../pass.zig");

/// Configuration of the capture pass.
pub const Config = struct {
    /// Color target to capture (typically the current swapchain image
    /// or an offscreen RT R8G8B8A8_UNORM dedicated to the smoke test).
    color_source: gal.types.TextureHandle,
    /// Host-visible buffer (`host_visible = true`) destination of the blit.
    /// The caller allocates it, maps it on the CPU for the PPM export.
    capture_buffer: gal.types.BufferHandle,
    /// Image dimensions (for the blit + the PPM header).
    width: u32,
    height: u32,
    /// Storage the returned `Pass.reads`/`Pass.writes` point at.
    ///
    /// M1.1.14 — before this field, `buildPass` returned slices of an ANONYMOUS
    /// LITERAL built in its own stack frame, so the `Pass` carried a dangling
    /// pointer the moment it returned. Measured: `writes.ptr` was a stack address,
    /// the access mask read `false` immediately after the call, and a fresh call at
    /// the SAME address read `true`. Live since M0.4 and invisible because nothing
    /// compiled this file's tests until the M1.1.14 dead-test sweep.
    ///
    /// The config owns it and introduces NO new lifetime constraint: the config is
    /// already the pass's `ctx`, so it had to outlive the pass by construction.
    read_storage: [1]pass_mod.ResourceUsage = undefined,
    write_storage: [1]pass_mod.ResourceUsage = undefined,
};

/// Builds a capture Pass ready to be added to a Graph.
pub fn buildPass(config: *Config) pass_mod.Pass {
    config.read_storage[0] = .{
        .resource = .{ .texture = config.color_source },
        .stage = .{ .fragment = true },
        .access = .{ .read = true },
        .layout = .transfer_src,
    };
    config.write_storage[0] = .{
        .resource = .{ .buffer = config.capture_buffer },
        .stage = .{ .fragment = true },
        .access = .{ .write = true },
        .layout = null,
    };
    return .{
        .name = "capture_to_buffer",
        .barrier_mode = .auto,
        .reads = config.read_storage[0..],
        .writes = config.write_storage[0..],
        .body = body,
        .ctx = @as(*anyopaque, @ptrCast(@constCast(config))),
    };
}

fn body(encoder: ?*anyopaque, ctx: ?*anyopaque) anyerror!void {
    _ = .{ encoder, ctx };
    // Phase 0: the actual blit (`vkCmdCopyImageToBuffer`) is wired by
    // `examples/triangle/` which opens + maps + writes the PPM. The pass
    // body is a no-op at the render graph level — the native commands
    // are recorded outside the render pass via the CommandEncoder.
}

test "capture: buildPass declares texture read + buffer write" {
    const t = std.testing;
    const tex = gal.types.TextureHandle{ .inner = 20 };
    const buf = gal.types.BufferHandle{ .inner = 21 };
    var cfg: Config = .{
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
