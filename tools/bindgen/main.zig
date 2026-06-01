//! Unified CLI of the Weld bindings system (M0.2 / E5).
//!
//! Minimalist dispatcher that invokes the right adapter based on
//! `--target`. Without `--target`, regenerates all configured
//! adapters (Vulkan + Wayland in M0.2).
//!
//! Architecture (cf. `engine-c-bindings.md` §1):
//!   adapters/*.zig (XML / C headers → output)
//!     → bindings/generated/*.api.zig (description sidecar)
//!     → core/emitter.zig (idiomatic Zig with dlopen)
//!     → src/.../<binding>.zig + tests
//!
//! M0.2 status: the adapters `vk_xml` and `wayland_xml` carry
//! the 1:1 pipeline from the old `tools/vk_gen/` /
//! `tools/wayland_gen/` and emit the idiomatic Zig
//! directly without going through `core/emitter.zig` (E5 (i)
//! technical decision, cf. brief § Notes). The skeleton
//! `core/{api_description, validator, resolver, emitter}.zig` is
//! laid down for the first Phase 1+ keepers.

const std = @import("std");

const vk_xml = @import("adapters/vk_xml.zig");
const wayland_xml = @import("adapters/wayland_xml.zig");

const Target = enum { all, vulkan, wayland };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena;
    const args = try init.minimal.args.toSlice(arena.allocator());

    var target: Target = .all;
    var i: usize = 1; // skip argv[0]
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--target")) {
            i += 1;
            if (i >= args.len) return error.MissingTargetValue;
            const v = args[i];
            if (std.mem.eql(u8, v, "vulkan") or std.mem.eql(u8, v, "vk")) {
                target = .vulkan;
            } else if (std.mem.eql(u8, v, "wayland") or std.mem.eql(u8, v, "wl")) {
                target = .wayland;
            } else if (std.mem.eql(u8, v, "all")) {
                target = .all;
            } else {
                return error.UnknownTarget;
            }
        }
        // Other flags ignored for now — adapters consume the same
        // init context so they don't need their own argv routing.
    }

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    switch (target) {
        .all => {
            try stdout.print("bindgen: regenerating all adapters\n", .{});
            try stdout.flush();
            try vk_xml.main(init);
            try wayland_xml.main(init);
        },
        .vulkan => {
            try stdout.print("bindgen: --target vulkan\n", .{});
            try stdout.flush();
            try vk_xml.main(init);
        },
        .wayland => {
            try stdout.print("bindgen: --target wayland\n", .{});
            try stdout.flush();
            try wayland_xml.main(init);
        },
    }
}
