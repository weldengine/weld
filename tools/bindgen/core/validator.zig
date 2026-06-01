//! `ApiDescription` validator (M0.2 / E5 skeleton).
//!
//! Checks the internal consistency of a description before emission:
//! resolved type refs, no unhandled cycles, consistent
//! annotations (cf. `engine-c-bindings.md` §9.2). Run by
//! `tools/bindgen/main.zig` after each adapter and before
//! `emitter`.
//!
//! M0.2 status: **skeleton**. The adapters `vk_xml` and
//! `wayland_xml` short-circuit the `.api.zig` →
//! `emitter` pipeline in M0.2 (E5 (i) technical decision), so the
//! validator has no complete description to check in this
//! milestone. The skeleton is in place for the Phase 1+ adapters
//! that will consume `ApiDescription` as the canonical input.

const std = @import("std");
const api = @import("api_description.zig");

/// Errors surfaced by `validate`. Bounded at the M0.2
/// skeleton level; the real content will be fleshed out when a first
/// Phase 1 adapter produces an `ApiDescription` exercising the
/// rules.
pub const ValidationError = error{
    UnresolvedTypeRef,
    UnsupportedCycle,
    InconsistentAnnotations,
    NameCollision,
};

/// Checks the internal consistency of an `ApiDescription`. M0.2
/// skeleton — always `Ok`. The real checks
/// (ref resolution, cycle detection, ownership consistency)
/// are introduced by the first Phase 1+ adapters that
/// consume `ApiDescription`.
pub fn validate(desc: api.ApiDescription) ValidationError!void {
    // Minimalist safeguard: an empty name is a signal that we
    // are not using the format. Prefer to raise explicitly rather
    // than let an inconsistent description slip through to
    // the emitter.
    if (desc.name.len == 0) return error.NameCollision;
}

test "validate accepts a minimal description" {
    const desc = api.ApiDescription{
        .name = "vulkan",
        .version = .{ .major = 1, .minor = 3, .patch = 0 },
        .source = .{ .xml_khronos = "bindings/upstream/vulkan/vk.xml" },
        .link = .{
            .name = .{ .runtime = .{
                .linux = "libvulkan.so",
                .windows = "vulkan-1",
                .macos = "libvulkan",
            } },
        },
    };
    try validate(desc);
}

test "validate rejects empty name" {
    const desc = api.ApiDescription{
        .name = "",
        .version = .{ .major = 0, .minor = 0, .patch = 0 },
        .source = .manual,
        .link = .{ .name = .{ .runtime = .{ .linux = "", .windows = "", .macos = "" } } },
    };
    try std.testing.expectError(error.NameCollision, validate(desc));
}
