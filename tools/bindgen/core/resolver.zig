//! Cross-api import resolver — a SKELETON.
//!
//! Resolves type references between distinct `.api.zig`
//! (e.g. `openxr.api.zig` imports `VkInstance` from
//! `vulkan.api.zig` — cf. `engine-c-bindings.md` §3.5
//! `ImportDecl`). Builds the `C name → Zig qualified name`
//! mapping table consumed by the emitter.
//!
//! NO ADAPTER CROSSES AN INTER-API IMPORT: Vulkan and Wayland are
//! autonomous. The skeleton is laid down for the first that does —
//! OpenXR reusing the Vulkan types, or a keeper depending on another
//! via `ImportDecl`.

const std = @import("std");
const api = @import("api_description.zig");

/// Resolved reference of a cross-api type: `(api_name, type_name)`.
pub const ResolvedRef = struct {
    api_name: []const u8,
    type_name: []const u8,
};

/// Errors surfaced by `resolveImports`. Skeleton.
pub const ResolverError = error{
    UnknownImport,
    AmbiguousTypeName,
    CircularImport,
};

/// Resolves the imports of an `ApiDescription` against a slice
/// of other available descriptions. Skeleton — always returns
/// `Ok` for lack of an adapter to exercise.
pub fn resolveImports(
    desc: api.ApiDescription,
    available: []const api.ApiDescription,
) ResolverError!void {
    _ = desc;
    _ = available;
    // Fleshed out by the first adapter that exercises an `ImportDecl`.
}

test "resolveImports is a no-op skeleton in M0.2" {
    const desc = api.ApiDescription{
        .name = "vulkan",
        .version = .{ .major = 1, .minor = 3, .patch = 0 },
        .source = .{ .xml_khronos = "bindings/upstream/vulkan/vk.xml" },
        .link = .{ .name = .{ .runtime = .{ .linux = "", .windows = "", .macos = "" } } },
    };
    try resolveImports(desc, &.{});
}
