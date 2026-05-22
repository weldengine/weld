//! Vulkan binding adapter for the unified bindgen pipeline (M0.2 /
//! E5). Port 1:1 of the legacy `tools/vk_gen/` — same parser, same
//! whitelist, same emitter. Lives under `tools/bindgen/adapters/`
//! per `engine-c-bindings.md` §2.1.
//!
//! Pipeline:
//!     bindings/upstream/vulkan/vk.xml
//!         → parser.parse() (XML tree)
//!         → parser.extractModel() (full model)
//!         → parser.applyWhitelist() (filtered to Vulkan 1.3 core + 5 ext)
//!         → emit.emit() (idiomatic Zig per engine-c-bindings.md §4.2)
//!         → write src/core/platform/vk.zig
//!
//! Usage:
//!     zig build bindgen-vk
//! or (via the unified dispatcher):
//!     zig build bindgen -- --target vulkan

const std = @import("std");
const parser = @import("vk_xml/parser.zig");
const emit = @import("vk_xml/emit.zig");

/// Whitelist for the S2 spike. Stored as data (not magic) per the brief.
/// Includes the four feature blocks per Vulkan version (BASE / GRAPHICS /
/// COMPUTE / aggregate) for 1.0 → 1.3, plus the five extensions the spike
/// uses to talk to the surface, swapchain, and validation layers.
const whitelist = parser.Whitelist{
    .features = &.{
        "VK_BASE_VERSION_1_0",
        "VK_GRAPHICS_VERSION_1_0",
        "VK_COMPUTE_VERSION_1_0",
        "VK_VERSION_1_0",
        "VK_BASE_VERSION_1_1",
        "VK_GRAPHICS_VERSION_1_1",
        "VK_COMPUTE_VERSION_1_1",
        "VK_VERSION_1_1",
        "VK_BASE_VERSION_1_2",
        "VK_GRAPHICS_VERSION_1_2",
        "VK_COMPUTE_VERSION_1_2",
        "VK_VERSION_1_2",
        "VK_BASE_VERSION_1_3",
        "VK_GRAPHICS_VERSION_1_3",
        "VK_COMPUTE_VERSION_1_3",
        "VK_VERSION_1_3",
    },
    .extensions = &.{
        "VK_KHR_surface",
        "VK_KHR_swapchain",
        "VK_KHR_wayland_surface",
        "VK_KHR_win32_surface",
        "VK_EXT_debug_utils",
    },
    // Platforms we accept extensions for. `wayland` and `win32` come from
    // the registry's `<platforms>` block.
    .platforms = &.{ "wayland", "win32" },
};

const input_path = "bindings/upstream/vulkan/vk.xml";
const output_path = "src/core/platform/vk.zig";

pub fn main(init: std.process.Init) !void {
    var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_alloc.deinit();
    const gpa = debug_alloc.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var dir = std.Io.Dir.cwd();

    // ---- read ----
    const xml_bytes = try readEntireFile(gpa, init.io, dir, input_path);
    defer gpa.free(xml_bytes);

    // ---- parse ----
    var tree = try parser.parse(gpa, xml_bytes);
    defer tree.deinit();
    try stdout.print("vk_gen: parsed {s} ({d} bytes)\n", .{ input_path, xml_bytes.len });

    // ---- extract ----
    var model = try parser.extractModel(gpa, tree);
    defer model.deinit();
    try stdout.print("vk_gen: model {d} handles, {d} enums, {d} bitmasks, {d} structs, {d} unions, {d} funcpointers, {d} aliases, {d} commands, {d} extensions\n", .{
        model.handles.len,
        model.enum_groups.len,
        model.bitmasks.len,
        model.structs.len,
        model.unions.len,
        model.funcpointers.len,
        model.aliases.len,
        model.commands.len,
        model.extensions.len,
    });

    // ---- whitelist ----
    var filtered = try parser.applyWhitelist(gpa, model, whitelist, tree);
    defer filtered.deinit();
    try stdout.print("vk_gen: filtered {d} handles, {d} enums, {d} bitmasks, {d} structs, {d} unions, {d} funcpointers, {d} aliases, {d} commands, {d} extensions\n", .{
        filtered.handles.len,
        filtered.enum_groups.len,
        filtered.bitmasks.len,
        filtered.structs.len,
        filtered.unions.len,
        filtered.funcpointers.len,
        filtered.aliases.len,
        filtered.commands.len,
        filtered.extensions.len,
    });

    // ---- emit ----
    var out_buf: std.ArrayList(u8) = .empty;
    defer out_buf.deinit(gpa);
    try emit.emit(gpa, filtered, &out_buf);

    // ---- write ----
    dir.createDirPath(init.io, "src/core/platform") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var out_file = try dir.createFile(init.io, output_path, .{});
    defer out_file.close(init.io);
    var write_buf: [16 * 1024]u8 = undefined;
    var w = out_file.writer(init.io, &write_buf);
    try w.interface.writeAll(out_buf.items);
    try w.interface.flush();

    try stdout.print("vk_gen: wrote {s} ({d} bytes)\n", .{ output_path, out_buf.items.len });
    try stdout.flush();
}

fn readEntireFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const buf = try gpa.alloc(u8, stat.size);
    errdefer gpa.free(buf);
    var read_buf: [16 * 1024]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    var written: usize = 0;
    while (written < buf.len) {
        const n = try reader.interface.readSliceShort(buf[written..]);
        if (n == 0) break;
        written += n;
    }
    return buf[0..written];
}
