//! CLI unifié du système de bindings Weld (M0.2 / E5).
//!
//! Dispatcher minimaliste qui invoque le bon adapter selon
//! `--target`. Sans `--target`, régénère tous les adapters
//! configurés (Vulkan + Wayland en M0.2).
//!
//! Architecture (cf. `engine-c-bindings.md` §1) :
//!   adapters/*.zig (XML / headers C → output)
//!     → bindings/generated/*.api.zig (description sidecar)
//!     → core/emitter.zig (Zig idiomatique avec dlopen)
//!     → src/.../<binding>.zig + tests
//!
//! Statut M0.2 : les adapters `vk_xml` et `wayland_xml` portent
//! le pipeline 1:1 depuis l'ancien `tools/vk_gen/` /
//! `tools/wayland_gen/` et émettent directement le Zig
//! idiomatique sans passer par `core/emitter.zig` (décision
//! technique E5 (i), cf. brief § Notes). Le squelette
//! `core/{api_description, validator, resolver, emitter}.zig` est
//! posé pour les premiers keepers Phase 1+.

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
