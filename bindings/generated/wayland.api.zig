//! AUTO-GENERATED — A PLACEHOLDER, and nothing consumes it yet.
//!
//! Per `engine-c-bindings.md` §2.1 this file is the canonical `.api.zig`
//! description of the Wayland binding, produced by
//! `tools/bindgen/adapters/wayland_xml.zig` from
//! `bindings/upstream/wayland/wayland.xml` and the protocol XMLs.
//!
//! What the adapter ACTUALLY does today is port the legacy
//! `tools/wayland_gen/` pipeline one to one and emit the Zig bindings straight
//! to `src/core/platform/window/wayland_protocols/*.zig`, with no round trip
//! through this `ApiDescription` — the same choice taken on the Vulkan side and
//! for the same reason.
//!
//! An adapter consuming the canonical `.api.zig` pipeline populates this format
//! end to end.

const api = @import("../../tools/bindgen/core/api_description.zig");

pub const description = api.ApiDescription{
    .name = "wayland",
    .version = .{ .major = 1, .minor = 23, .patch = 0 },
    .source = .{ .xml_wayland = "bindings/upstream/wayland/wayland.xml" },
    .link = .{
        .name = .{ .runtime = .{
            .linux = "libwayland-client.so",
            .windows = "",
            .macos = "",
        } },
        .strategy = .dlopen_loader_pattern,
        .requirement = .hard,
        .soname_versions = &.{"0"},
    },
};
