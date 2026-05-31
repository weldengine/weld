//! Common idiomatic Zig emitter (M0.2 / E5 skeleton).
//!
//! Consumes an `ApiDescription` (already validated + resolved) and
//! produces the Zig wrapper `<name>_binding.zig` in the
//! `engine-c-bindings.md` §4 format. Emits the dlopen code for the 4
//! strategies (`dlopen`, `dlopen_loader_pattern`, `framework`,
//! `static_link`, cf. `engine-c-bindings.md` §4.6).
//!
//! M0.2 status: **structural skeleton**. The adapters
//! `vk_xml` and `wayland_xml` carry their own 1:1 emission
//! pipelines from `tools/vk_gen/` / `tools/wayland_gen/`
//! and write the idiomatic Zig directly without going through
//! this common emitter (E5 (i) technical decision of the brief —
//! preservation of the non-negotiable "empty diff" criterion).
//!
//! This emitter will be exercised by the first Phase 1+ keepers
//! (Opus, Assimp, KTX/Basis, libdatachannel, ACL compressor,
//! HarfBuzz, ONNX) which describe their surface in
//! `bindings/manual/*.api.zig` and have no retroactive `empty diff`
//! constraint.

const std = @import("std");
const api = @import("api_description.zig");

/// Errors surfaced by `emit`. M0.2 skeleton.
pub const EmitError = error{
    UnsupportedStrategy,
    UnsupportedTypeKind,
    OutOfMemory,
};

/// Emits the idiomatic Zig wrapper for `desc` into `out`.
/// M0.2 skeleton: writes a commented placeholder stating that
/// the real emission is short-circuited by the adapters
/// `vk_xml` and `wayland_xml`; the first Phase 1+ adapters
/// will replace this body with the full emission of the 4
/// dlopen strategies.
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
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var aw = buf.writer(gpa).adaptToNewApi(&.{});
    const desc = api.ApiDescription{
        .name = "vulkan",
        .version = .{ .major = 1, .minor = 3, .patch = 0 },
        .source = .{ .xml_khronos = "bindings/upstream/vulkan/vk.xml" },
        .link = .{ .name = .{ .runtime = .{ .linux = "", .windows = "", .macos = "" } } },
    };
    try emit(desc, &aw.new_interface);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "vulkan") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "skeleton") != null);
}
