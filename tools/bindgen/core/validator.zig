//! `ApiDescription` validator — a SKELETON.
//!
//! Meant to check the internal consistency of a description before emission:
//! resolved type refs, no unhandled cycles, consistent annotations (cf.
//! `engine-c-bindings.md` §9.2), between an adapter and `emitter`.
//!
//! NOTHING CALLS IT. `tools/bindgen/main.zig` names it in a comment and invokes
//! it nowhere, because the adapters `vk_xml` and `wayland_xml` short-circuit the
//! `.api.zig` → `emitter` pipeline and leave no complete description to check.
//! The skeleton is in place for the first adapter that consumes an
//! `ApiDescription` as its canonical input.

const std = @import("std");
const api = @import("api_description.zig");

/// Errors surfaced by `validate`. Bounded at the skeleton level; the real
/// content arrives with the first adapter that produces an `ApiDescription`
/// exercising the rules.
pub const ValidationError = error{
    UnresolvedTypeRef,
    UnsupportedCycle,
    InconsistentAnnotations,
    NameCollision,
};

/// Checks the internal consistency of an `ApiDescription`. Skeleton — always
/// `Ok`. The real checks (ref resolution, cycle detection, ownership
/// consistency) arrive with the first adapter that consumes an
/// `ApiDescription`.
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
