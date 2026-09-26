//! Shader compiler: compiles GLSL to SPIR-V by spawning the `glslc` CLI (no
//! shaderc binding, `ARCH-024`).
//!
//! `glslc` is needed by `zig build shaders`, `zig build shaders-check` and the
//! dev hot-reload only; `zig build` does not depend on it.

const std = @import("std");

/// The supported shader stages (geometry, tessellation
/// raygen/closesthit/miss for RT).
pub const Stage = enum {
    vertex,
    fragment,
    compute,

    /// The stage a shader file's name carries (`*.vert*`, `*.frag*`,
    /// `*.comp*`), or null when it carries none.
    pub fn ofFileName(name: []const u8) ?Stage {
        if (std.mem.indexOf(u8, name, ".vert") != null) return .vertex;
        if (std.mem.indexOf(u8, name, ".frag") != null) return .fragment;
        if (std.mem.indexOf(u8, name, ".comp") != null) return .compute;
        return null;
    }

    pub fn glslcArg(self: Stage) []const u8 {
        return switch (self) {
            .vertex => "-fshader-stage=vertex",
            .fragment => "-fshader-stage=fragment",
            .compute => "-fshader-stage=compute",
        };
    }
};

/// Compilation errors. `GlslcNotFound` is the expected error when
/// the tool is not installed.
pub const CompileError = error{
    GlslcNotFound,
    GlslcCrashed,
    GlslSyntaxError,
    OutOfMemory,
    InvalidUtf8,
    ProcessSpawnFailed,
    /// Reading glslc's output or waiting for it failed.
    GlslcIoFailed,
};

/// Result of a compilation.
pub const Result = struct {
    /// SPIR-V bytes (4-byte aligned). Owned by the caller — to be freed via
    /// `allocator.free`.
    spv: []u8,
    /// Diagnostics returned by glslc (stdout + stderr concatenated).
    /// Empty if the compilation succeeded without warning.
    diagnostics: []u8,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        if (self.spv.len > 0) allocator.free(self.spv);
        if (self.diagnostics.len > 0) allocator.free(self.diagnostics);
        self.* = undefined;
    }
};

/// Compiles `source` (GLSL text) to SPIR-V via glslc, which reads it on
/// stdin. The caller must pass the correct `stage` (glslc needs it for shader
/// model selection). `entry_point` defaults to "main".
///
/// Returns `error.GlslcNotFound` if glslc is not findable in PATH. A source
/// glslc refuses is not an error: the result carries no SPIR-V and glslc's
/// diagnostics.
pub fn compile(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    stage: Stage,
    entry_point: ?[]const u8,
) CompileError!Result {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    argv.append(allocator, "glslc") catch return error.OutOfMemory;
    argv.append(allocator, stage.glslcArg()) catch return error.OutOfMemory;
    var ep_buf: ?[]u8 = null;
    defer if (ep_buf) |b| allocator.free(b);
    if (entry_point) |ep| {
        const ep_arg = std.fmt.allocPrint(allocator, "-fentry-point={s}", .{ep}) catch return error.OutOfMemory;
        ep_buf = ep_arg;
        argv.append(allocator, ep_arg) catch return error.OutOfMemory;
    }
    argv.appendSlice(allocator, &.{ "-o", "-", "-" }) catch return error.OutOfMemory;

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |e| switch (e) {
        error.FileNotFound => return error.GlslcNotFound,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ProcessSpawnFailed,
    };
    defer child.kill(io);

    // glslc reads all of its input before it writes anything, so the whole
    // source goes in before either output is read. A write that fails means
    // glslc has exited; its exit status and stderr say why.
    child.stdin.?.writeStreamingAll(io, source) catch {};
    child.stdin.?.close(io);
    child.stdin = null;

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();
    while (multi_reader.fill(64, .none)) |_| {} else |err| switch (err) {
        error.EndOfStream => {},
        else => return error.GlslcIoFailed,
    }
    multi_reader.checkAnyError() catch return error.GlslcIoFailed;
    const term = child.wait(io) catch return error.GlslcIoFailed;

    const stdout = multi_reader.toOwnedSlice(0) catch return error.OutOfMemory;
    defer allocator.free(stdout);
    const stderr = multi_reader.toOwnedSlice(1) catch return error.OutOfMemory;
    defer allocator.free(stderr);

    switch (term) {
        .exited => |code| if (code != 0) {
            const diag = allocator.dupe(u8, stderr) catch return error.OutOfMemory;
            return Result{ .spv = &.{}, .diagnostics = diag };
        },
        else => return error.GlslcCrashed,
    }

    // SPIR-V in stdout. Basic validation: ≥ 4 bytes.
    if (stdout.len < 4) return error.GlslSyntaxError;
    const spv = allocator.dupe(u8, stdout) catch return error.OutOfMemory;
    const diag = allocator.dupe(u8, stderr) catch return error.OutOfMemory;
    return Result{ .spv = spv, .diagnostics = diag };
}

/// Checks whether `glslc` is findable on PATH. Useful to gate
/// hot-reload. Returns `false` rather than an error — heuristic.
pub fn isAvailable(allocator: std.mem.Allocator, io: std.Io) bool {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "glslc", "--version" },
        .stdout_limit = std.Io.Limit.limited(4096),
        .stderr_limit = std.Io.Limit.limited(4096),
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

test "compiler: Stage.glslcArg covers all stages" {
    const t = std.testing;
    try t.expectEqualStrings("-fshader-stage=vertex", Stage.vertex.glslcArg());
    try t.expectEqualStrings("-fshader-stage=fragment", Stage.fragment.glslcArg());
    try t.expectEqualStrings("-fshader-stage=compute", Stage.compute.glslcArg());
}

test "compiler: a file name gives its stage, or none" {
    const t = std.testing;
    try t.expectEqual(Stage.vertex, Stage.ofFileName("a.vert.glsl").?);
    try t.expectEqual(Stage.fragment, Stage.ofFileName("a.frag.glsl").?);
    try t.expectEqual(Stage.compute, Stage.ofFileName("a.comp.glsl").?);
    try t.expectEqual(@as(?Stage, null), Stage.ofFileName("a.glsl"));
}

test "compiler: isAvailable does not crash" {
    // Purely structural test — calls the fn and verifies it returns
    // a bool without crashing, regardless of the actual presence of glslc.
    _ = isAvailable(std.testing.allocator, std.testing.io);
}
