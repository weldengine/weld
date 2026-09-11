//! Common idiomatic Zig emitter — a SKELETON.
//!
//! Consumes an `ApiDescription` (already validated + resolved) and
//! produces the Zig wrapper `<name>_binding.zig` in the
//! `engine-c-bindings.md` §4 format. Emits the dlopen code for the 4
//! strategies (`dlopen`, `dlopen_loader_pattern`, `framework`,
//! `static_link`, cf. `engine-c-bindings.md` §4.6).
//!
//! NOTHING GOES THROUGH IT. The adapters `vk_xml` and `wayland_xml`
//! carry their own emission pipelines and write the idiomatic Zig
//! directly, so that their regeneration keeps producing an empty diff
//! against the committed bindings.
//!
//! It is meant for the seven authorised keepers (Opus, Assimp,
//! KTX/Basis, libdatachannel, ACL compressor, HarfBuzz, ONNX), which
//! describe their surface in `bindings/manual/*.api.zig` and have no
//! retroactive `empty diff` constraint.

const std = @import("std");
const api = @import("api_description.zig");

/// Errors surfaced by `emit`. Skeleton.
pub const EmitError = error{
    UnsupportedStrategy,
    UnsupportedTypeKind,
    OutOfMemory,
};

/// Emits the idiomatic Zig wrapper for `desc` into `out`.
/// SKELETON: writes a commented placeholder stating that the real
/// emission is short-circuited by the adapters `vk_xml` and
/// `wayland_xml`. The first keeper replaces this body with the full
/// emission of the four dlopen strategies.
pub fn emit(
    desc: api.ApiDescription,
    out: *std.Io.Writer,
) EmitError!void {
    out.print(
        "//! AUTO-GENERATED placeholder for {s} v{d}.{d}.{d}.\n",
        .{ desc.name, desc.version.major, desc.version.minor, desc.version.patch },
    ) catch return error.OutOfMemory;
    out.writeAll(
        "//! M0.2 / E5 — emitter skeleton. The vk_xml and wayland_xml\n" ++
            "//! adapters short-circuit this stage and write Zig directly\n" ++
            "//! (decision technique E5 (i), brief § Notes). Phase 1+ keepers\n" ++
            "//! will exercise this emitter for real.\n",
    ) catch return error.OutOfMemory;
}

test "emit writes a placeholder for a minimal description" {
    const gpa = std.testing.allocator;
    // Do NOT reach for `ArrayList.writer`: it was removed in Zig 0.16, and
    // `Io.Writer.Allocating` is the in-tree idiom
    // (`src/modules/asset_pipeline/format/intermediate.zig`). A test using it
    // does not compile, and an uncollected test says nothing about that.
    var aw = std.Io.Writer.Allocating.init(gpa);
    defer aw.deinit();
    const desc = api.ApiDescription{
        .name = "vulkan",
        .version = .{ .major = 1, .minor = 3, .patch = 0 },
        .source = .{ .xml_khronos = "bindings/upstream/vulkan/vk.xml" },
        .link = .{ .name = .{ .runtime = .{ .linux = "", .windows = "", .macos = "" } } },
    };
    try emit(desc, &aw.writer);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "vulkan") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "skeleton") != null);
}
