//! Wayland binding generator entry point.
//!
//! Reads the three vendored protocol XMLs and emits one Zig file per
//! protocol under `src/core/platform/window/wayland_protocols/`.
//! Throwaway in S3 (cf. `engine-c-bindings.md` §10.1).
//!
//! Usage:
//!     zig build bindgen-wayland

const std = @import("std");
const parser = @import("parser.zig");
const emit = @import("emit.zig");

const Job = struct {
    input: []const u8,
    module: []const u8,
    output: []const u8,
};

const jobs = [_]Job{
    .{
        .input = "bindings/upstream/wayland/wayland.xml",
        .module = "core",
        .output = "src/core/platform/window/wayland_protocols/core.zig",
    },
    .{
        .input = "bindings/upstream/wayland/protocols/xdg-shell.xml",
        .module = "xdg_shell",
        .output = "src/core/platform/window/wayland_protocols/xdg_shell.zig",
    },
    .{
        .input = "bindings/upstream/wayland/protocols/xdg-decoration-unstable-v1.xml",
        .module = "xdg_decoration",
        .output = "src/core/platform/window/wayland_protocols/xdg_decoration.zig",
    },
};

pub fn main(init: std.process.Init) !void {
    var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_alloc.deinit();
    const gpa = debug_alloc.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var dir = std.Io.Dir.cwd();

    // Pass 1: parse all three protocols and build a global catalog so the
    // emitter can resolve cross-protocol interface references.
    var trees: [jobs.len]parser.Tree = undefined;
    var decls: [jobs.len]emit.ProtocolDecl = undefined;
    var alive: usize = 0;
    defer for (0..alive) |i| trees[i].deinit();

    for (jobs, 0..) |j, i| {
        const xml = try readEntireFile(gpa, init.io, dir, j.input);
        defer gpa.free(xml);
        trees[i] = try parser.parse(gpa, xml);
        alive += 1;
        const proto = try parser.extractProtocol(gpa, &trees[i]);
        decls[i] = .{
            .module_name = j.module,
            .output_path = j.output,
            .protocol = proto,
        };
        try stdout.print(
            "wayland_gen: parsed {s} ({d} interfaces)\n",
            .{ j.input, proto.interfaces.len },
        );
    }

    const catalog = try emit.buildCatalog(gpa, &decls);
    defer gpa.free(catalog.entries);

    // Pass 2: emit each protocol file.
    dir.createDirPath(init.io, "src/core/platform/window/wayland_protocols") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    for (decls, 0..) |d, i| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        try emit.emitProtocol(gpa, d, catalog, i == 0, &buf);

        var f = try dir.createFile(init.io, d.output_path, .{});
        defer f.close(init.io);
        var write_buf: [16 * 1024]u8 = undefined;
        var w = f.writer(init.io, &write_buf);
        try w.interface.writeAll(buf.items);
        try w.interface.flush();

        try stdout.print(
            "wayland_gen: wrote {s} ({d} bytes)\n",
            .{ d.output_path, buf.items.len },
        );
    }

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
