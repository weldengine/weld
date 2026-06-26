//! `scene_cook` — thin CLI shim around the M1.0.4 scene cook. Parses args + does
//! file I/O; all real work is `weld_etch.scene_cook.cook` + `weld_core.scene
//! .writer.write` in-process. Mirrors `tools/etch_cook` / `tools/asset_cook`.
//!
//!   scene_cook --output <out.scene.bin> <in.scene.etch>

const std = @import("std");

const weld_etch = @import("weld_etch");
const weld_core = @import("weld_core");

const scene_cook = weld_etch.scene_cook;
const writer = weld_core.scene.writer;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var output: ?[]const u8 = null;
    var input: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--output")) {
            i += 1;
            if (i >= args.len) return die(io, "missing path after --output");
            output = args[i];
        } else if (std.mem.startsWith(u8, a, "--")) {
            return die(io, "unknown flag");
        } else {
            if (input != null) return die(io, "more than one input file");
            input = a;
        }
    }
    const out_path = output orelse return die(io, "missing --output <out.scene.bin>");
    const in_path = input orelse return die(io, "missing <in.scene.etch>");

    const dir = std.Io.Dir.cwd();
    const source = readWholeFile(gpa, io, dir, in_path) catch |err| {
        try printErr(io, "cannot read input: ", @errorName(err));
        return err;
    };
    defer gpa.free(source);

    var diag: []const u8 = "";
    var cooked = scene_cook.cook(gpa, source, &diag) catch |err| {
        try printErr(io, "cook failed: ", if (diag.len > 0) diag else @errorName(err));
        return err;
    };
    defer cooked.deinit(gpa);

    const bytes = try writer.write(gpa, cooked.model, &cooked.registry);
    defer gpa.free(bytes);

    try writeOutput(io, dir, out_path, bytes);
}

fn die(io: std.Io, msg: []const u8) error{InvalidArgs} {
    printErr(io, "", msg) catch {};
    return error.InvalidArgs;
}

fn printErr(io: std.Io, prefix: []const u8, msg: []const u8) !void {
    var b: [512]u8 = undefined;
    var ew = std.Io.File.stderr().writer(io, &b);
    const w = &ew.interface;
    try w.print("scene_cook: {s}{s}\n", .{ prefix, msg });
    try w.flush();
}

fn readWholeFile(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) ![]u8 {
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

fn writeOutput(io: std.Io, dir: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |sub| {
        if (sub.len > 0) {
            dir.createDirPath(io, sub) catch |err| switch (err) {
                error.PathAlreadyExists, error.NotDir => {},
                else => return err,
            };
        }
    }
    var file = try dir.createFile(io, path, .{});
    defer file.close(io);
    var write_buf: [16 * 1024]u8 = undefined;
    var w = file.writer(io, &write_buf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}
