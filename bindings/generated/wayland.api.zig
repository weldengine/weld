//! AUTO-GENERATED placeholder — M0.2 / E5.
//!
//! Per `engine-c-bindings.md` §2.1, this file is the canonical
//! `.api.zig` description of the Wayland binding, produced by
//! `tools/bindgen/adapters/wayland_xml.zig` from
//! `bindings/upstream/wayland/wayland.xml` and the protocol XMLs.
//!
//! **M0.2 status — placeholder.** The wayland_xml adapter ports
//! the legacy `tools/wayland_gen/` pipeline 1:1 and emits the Zig
//! bindings directly to
//! `src/core/platform/window/wayland_protocols/*.zig` without
//! round-tripping through this `ApiDescription`. Decision
//! technique (i) — cf.
//! `briefs/M0.2-rtti-resources-events-bindgen.md` § Notes.
//!
//! Phase 1+ adapters consuming the canonical `.api.zig` pipeline
//! will populate this format end-to-end.

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
