//! `etch_cook` — thin CLI shim over the consolidated cook library
//! (`weld_etch.codegen_zig.consolidate`, M0.8 E3-D, D-S5-etchcook-inproc).
//! The shim owns arg parsing and file I/O only; parse + type-check +
//! codegen + namespace wrapping + the `programs` table all live in the
//! library, which the bench harness consumes IN-PROCESS (no child process
//! on the timed path). The CLI remains for the build-graph cooks
//! (`b.addRunArtifact`): the 61-program differential corpus and the demo.
//!
//! CLI:
//!     etch_cook --output <out.zig> <name1>=<path1.etch> [<name2>=<path2.etch> ...]
//!
//! Each input arg pairs a short alphanumeric **namespace name** (used as the
//! Zig identifier of the nested struct) with the path to its source file.
//! Output is written to `--output` (created / truncated), plus a
//! `<output>.stats` sidecar (rules + distinct signatures — Gate 4
//! reporting). The tool exits with code 0 on success and 1 on the first
//! input that fails parse/type-check/codegen.

const std = @import("std");
const weld_etch = @import("weld_etch");
const consolidate = weld_etch.codegen_zig.consolidate;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(arena.allocator());

    var output: ?[]const u8 = null;
    var inputs: std.ArrayListUnmanaged(consolidate.NamedSource) = .empty;

    const cwd = std.Io.Dir.cwd();

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--output")) {
            i += 1;
            if (i >= argv.len) return die(io, "missing argument after --output");
            output = argv[i];
            continue;
        }
        // Positional arg: `<name>=<path>`
        const eq = std.mem.indexOfScalar(u8, a, '=') orelse return die(io, "input arg must be `<name>=<path>`");
        const path = a[eq + 1 ..];
        const source = readWholeFile(arena.allocator(), io, cwd, path) catch |err| {
            std.debug.print("etch_cook: cannot read {s}: {s}\n", .{ path, @errorName(err) });
            return err;
        };
        try inputs.append(arena.allocator(), .{
            .name = a[0..eq],
            .source = source,
        });
    }
    if (output == null) return die(io, "missing --output");
    if (inputs.items.len == 0) return die(io, "no inputs provided");

    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(gpa);

    const stats = try consolidate.cookConsolidated(gpa, inputs.items, &buffer);

    try writeOutput(io, cwd, output.?, buffer.items);

    // Stats sidecar — consumed for Gate 4 reporting. One line per metric,
    // key=value (whitespace-tolerant). The path mirrors the output with a
    // `.stats` suffix so consumers know where to look without an extra
    // CLI flag.
    var stats_path_buf: [512]u8 = undefined;
    const stats_path = try std.fmt.bufPrint(&stats_path_buf, "{s}.stats", .{output.?});
    var stats_text: [128]u8 = undefined;
    const stats_bytes = try std.fmt.bufPrint(&stats_text, "rules={d}\ndistinct_signatures={d}\n", .{ stats.rules, stats.distinct_signatures });
    try writeOutput(io, cwd, stats_path, stats_bytes);
}

fn die(io: std.Io, msg: []const u8) error{InvalidArgs} {
    var b: [256]u8 = undefined;
    var ew = std.Io.File.stderr().writer(io, &b);
    const w = &ew.interface;
    w.print("etch_cook: {s}\n", .{msg}) catch {};
    w.flush() catch {};
    return error.InvalidArgs;
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
