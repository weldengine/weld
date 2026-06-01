//! Canonical `.api.zig` format consumed by the unified Weld bindgen
//! generator (cf. `engine-c-bindings.md` §3).
//!
//! M0.2 / E5 status: **structural skeleton**. The format is laid down
//! and frozen for the Phase 1+ adapters (Opus, Assimp, KTX/Basis,
//! libdatachannel, ACL compressor, HarfBuzz, ONNX). In M0.2, the
//! two effective adapters — `vk_xml` and `wayland_xml` — carry
//! the 1:1 pipeline from the old `tools/vk_gen/` /
//! `tools/wayland_gen/` and write the idiomatic Zig directly
//! without going through this intermediate `ApiDescription`. The
//! E5 (i) technical decision records this pragmatic workaround
//! to preserve the non-negotiable "empty diff" criterion.
//!
//! The format defined here is meant to become the **canonical
//! input** of `core/emitter.zig` for future adapters and
//! manual bindings (`bindings/manual/*.api.zig`). The
//! `bindings/generated/*.api.zig` produced by the M0.2 adapters
//! contain a minimal `ApiDescription` filling in `name` /
//! `version` / `source` — enough to distinguish a manual
//! description from a generated one and preserve the pipeline's
//! auditability. The full contract (types, functions, ownership,
//! loading strategies) will be exercised by the first Phase 1
//! keepers.

const std = @import("std");

/// Semantic versioning of an API. Informational — used for
/// description diffs and migration warnings.
pub const Version = struct {
    major: u16,
    minor: u16,
    patch: u16,
};

/// Origin of the C / Objective-C / XML definitions of a description.
pub const Source = union(enum) {
    /// C headers consumed via `addTranslateC` (keepers via
    /// manual `.api.zig`).
    c_headers: []const []const u8,
    /// Khronos XML consumed by a dedicated adapter (vk.xml, xr.xml).
    xml_khronos: []const u8,
    /// Wayland / freedesktop XML.
    xml_wayland: []const u8,
    /// Objective-C runtime bridge (libobjc + Apple frameworks).
    objc_runtime: struct {
        framework: []const u8,
        platform_filter: PlatformFilter,
    },
    /// No source — pure output (Weld Tier 3 C API export).
    output_only,
    /// Manually written description (Phase 1+ keepers via
    /// `bindings/manual/*.api.zig`).
    manual,
};

/// Platform filter for `objc_runtime` sources. `both` =
/// macOS + iOS, same selectors and same framework.
pub const PlatformFilter = enum { macos, ios, both };

/// Loading strategy of a lib. 4 variants exposed in
/// M0.2 (cf. `engine-c-bindings.md` §4.6); only
/// `dlopen_loader_pattern` is effectively exercised by the
/// M0.2 adapters (Vulkan + Wayland).
pub const Strategy = enum {
    /// dlopen + dlsym per function. Default of the C keepers.
    dlopen,
    /// Khronos pattern: dlopen the loader, then getProcAddr per
    /// function. Imposed by the standard's architecture (Vulkan,
    /// OpenGL, OpenXR, Wayland).
    dlopen_loader_pattern,
    /// Apple framework — build-time link via `-framework`,
    /// rpath resolution at runtime.
    framework,
    /// Build-time static linkage (PS5/Xbox/Switch consoles,
    /// iOS if required by the App Store).
    static_link,
};

/// Behavior of the module's init if the lib is absent.
pub const Requirement = enum {
    /// Init failure = failure of the module that consumes the binding.
    hard,
    /// Init failure = the feature is disabled, the engine
    /// continues with an `isAvailable() == false`.
    soft,
};

/// Lib name per platform. Variants cover the dlopen paths
/// and the build-time overrides (console static archive,
/// Apple framework).
pub const LibName = union(enum) {
    runtime: struct {
        linux: []const u8,
        windows: []const u8,
        macos: []const u8,
    },
    static_archive: []const u8,
    framework: []const u8,
};

/// Full loading block of a lib. Combines name +
/// strategy + requirement + target ABI versions.
pub const Link = struct {
    name: LibName,
    strategy: Strategy = .dlopen,
    requirement: Requirement = .hard,
    soname_versions: []const []const u8 = &.{},
};

/// Category of a type declaration emitted by the adapter.
pub const TypeKind = enum {
    opaque_handle,
    extern_struct,
    alias,
    enum_tag,
    function_ptr,
    tagged_union,
};

/// Minimalist type declaration — details will be fleshed out
/// when a first adapter consumes the `ApiDescription` as a
/// real input.
pub const TypeDecl = struct {
    name: []const u8,
    c_name: ?[]const u8 = null,
    kind: TypeKind,
};

/// Minimalist function declaration — skeleton for
/// Phase 1+ adapters.
pub const FunctionDecl = struct {
    zig_name: []const u8,
    c_name: []const u8,
};

/// Generation annotations (overrides, hints) — skeleton.
pub const Pragmas = struct {
    rename: []const RenameRule = &.{},
    skip: []const []const u8 = &.{},
    force_inline: []const []const u8 = &.{},
};

/// Renaming rule for an identifier.
pub const RenameRule = struct {
    from: []const u8,
    to: []const u8,
};

/// Root of the `.api.zig` format. A complete description of a
/// C / Objective-C / XML surface consumed by Weld.
pub const ApiDescription = struct {
    name: []const u8,
    version: Version,
    source: Source,
    link: Link,
    types: []const TypeDecl = &.{},
    functions: []const FunctionDecl = &.{},
    pragmas: Pragmas = .{},
};

test "ApiDescription is comptime constructible" {
    // Sanity check — the format compiles and a minimal description
    // can be built at comptime.
    const desc = ApiDescription{
        .name = "vulkan",
        .version = .{ .major = 1, .minor = 3, .patch = 0 },
        .source = .{ .xml_khronos = "bindings/upstream/vulkan/vk.xml" },
        .link = .{
            .name = .{ .runtime = .{
                .linux = "libvulkan.so",
                .windows = "vulkan-1",
                .macos = "libvulkan",
            } },
            .strategy = .dlopen_loader_pattern,
            .requirement = .hard,
        },
    };
    try std.testing.expectEqualStrings("vulkan", desc.name);
    try std.testing.expectEqual(@as(u16, 1), desc.version.major);
}
