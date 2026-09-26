//! Shader compiler tool, behind `zig build shaders` and `zig build shaders-check`.
//!
//! Every `.glsl` of `shader_dirs` compiles through `glslc`; `shaders` writes the
//! `.spv` beside it, `shaders-check` (`--check`) compares with the committed one.
//! The exit code is the `Outcome`, the most severe one met.

const std = @import("std");
const shader = @import("shader_pipeline_compiler");

/// Every directory holding committed `.glsl` and `.spv` pairs.
const shader_dirs = [_][]const u8{ "assets/shaders", "examples/vertical_slice/shaders" };

/// What a run established, as its exit code. Only `ok` and `drift` are verdicts;
/// the two others say that no verdict was reached.
const Outcome = enum(u8) {
    ok = 0,
    /// A committed `.spv` differs from a fresh compilation, or is missing.
    drift = 1,
    /// `glslc` could not be run at all.
    glslc_unavailable = 2,
    /// A shader could not be read, compiled or written, a `.glsl` carries no
    /// stage, or a directory holds no shader.
    incomplete = 3,

    fn severity(o: Outcome) u8 {
        return switch (o) {
            .ok => 0,
            .drift => 1,
            .incomplete => 2,
            .glslc_unavailable => 3,
        };
    }

    fn worst(a: Outcome, b: Outcome) Outcome {
        return if (b.severity() > a.severity()) b else a;
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const raw = try init.minimal.args.toSlice(init.arena.allocator());

    var check = false;
    var quiet = false;
    for (raw[1..]) |a| {
        if (std.mem.eql(u8, a, "--check")) check = true;
        if (std.mem.eql(u8, a, "--quiet")) quiet = true;
    }

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const out = &stderr_writer.interface;

    var outcome: Outcome = .ok;
    var handled: u32 = 0;
    if (!shader.isAvailable(gpa, io)) {
        try out.print("shader_compiler: glslc is not available on PATH — no verdict is implied\n", .{});
        outcome = .glslc_unavailable;
    } else for (shader_dirs) |dir_path| {
        outcome = outcome.worst(try runDir(gpa, io, out, dir_path, check, quiet, &handled));
        if (outcome == .glslc_unavailable) break;
    }

    try out.print("shader_compiler: {s} {d} shader(s): {t}\n", .{ if (check) "checked" else "compiled", handled, outcome });
    try out.flush();
    std.process.exit(@intFromEnum(outcome));
}

fn runDir(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    dir_path: []const u8,
    check: bool,
    quiet: bool,
    handled: *u32,
) !Outcome {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |e| {
        try out.print("shader_compiler: cannot open {s}: {t}\n", .{ dir_path, e });
        return .incomplete;
    };
    defer dir.close(io);

    var outcome: Outcome = .ok;
    var found: u32 = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".glsl")) continue;
        found += 1;
        const glsl_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, entry.name });
        defer gpa.free(glsl_path);
        const spv_path = try std.fmt.allocPrint(gpa, "{s}/{s}.spv", .{ dir_path, entry.name[0 .. entry.name.len - ".glsl".len] });
        defer gpa.free(spv_path);

        const one = try runShader(gpa, io, out, glsl_path, spv_path, entry.name, check, quiet);
        if (one == .ok or one == .drift) handled.* += 1;
        outcome = outcome.worst(one);
        if (outcome == .glslc_unavailable) return outcome;
    }
    if (found == 0) {
        try out.print("shader_compiler: {s} holds no .glsl\n", .{dir_path});
        return .incomplete;
    }
    return outcome;
}

fn runShader(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    glsl_path: []const u8,
    spv_path: []const u8,
    name: []const u8,
    check: bool,
    quiet: bool,
) !Outcome {
    const stage = shader.Stage.ofFileName(name) orelse {
        try out.print("shader_compiler: {s} carries no stage (.vert, .frag, .comp)\n", .{glsl_path});
        return .incomplete;
    };
    const src = readAll(gpa, io, glsl_path) catch |e| {
        try out.print("shader_compiler: cannot read {s}: {t}\n", .{ glsl_path, e });
        return .incomplete;
    };
    defer gpa.free(src);

    var result = shader.compile(gpa, io, src, stage, null) catch |e| {
        try out.print("shader_compiler: {s}: glslc failed: {t}\n", .{ glsl_path, e });
        return if (e == error.GlslcNotFound) .glslc_unavailable else .incomplete;
    };
    defer result.deinit(gpa);
    if (result.spv.len == 0) {
        try out.print("shader_compiler: {s} does not compile:\n{s}\n", .{ glsl_path, result.diagnostics });
        return .incomplete;
    }

    if (!check) {
        writeAll(io, spv_path, result.spv) catch |e| {
            try out.print("shader_compiler: cannot write {s}: {t}\n", .{ spv_path, e });
            return .incomplete;
        };
        if (!quiet) try out.print("shader_compiler: wrote {s} ({d} bytes)\n", .{ spv_path, result.spv.len });
        return .ok;
    }

    const committed = readAll(gpa, io, spv_path) catch |e| switch (e) {
        error.FileNotFound => {
            try out.print("shader_compiler[check]: DRIFT {s} is missing\n", .{spv_path});
            return .drift;
        },
        else => {
            try out.print("shader_compiler[check]: cannot read {s}: {t}\n", .{ spv_path, e });
            return .incomplete;
        },
    };
    defer gpa.free(committed);
    if (!std.mem.eql(u8, committed, result.spv)) {
        try out.print("shader_compiler[check]: DRIFT {s} ({d} vs {d} bytes)\n", .{ spv_path, committed.len, result.spv.len });
        return .drift;
    }
    if (!quiet) try out.print("shader_compiler[check]: OK {s}\n", .{spv_path});
    return .ok;
}

fn readAll(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const bytes = try gpa.alloc(u8, @intCast((try file.stat(io)).size));
    errdefer gpa.free(bytes);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    try reader.interface.readSliceAll(bytes);
    return bytes;
}

fn writeAll(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

test "the most severe outcome wins, whatever the order" {
    const all = [_]Outcome{ .ok, .drift, .incomplete, .glslc_unavailable };
    for (all, 0..) |a, i| for (all, 0..) |b, j| {
        try std.testing.expectEqual(all[@max(i, j)], a.worst(b));
    };
}

test "each outcome has its own exit code" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(Outcome.ok));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(Outcome.drift));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(Outcome.glslc_unavailable));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(Outcome.incomplete));
}
