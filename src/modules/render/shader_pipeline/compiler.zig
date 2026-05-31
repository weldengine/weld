//! Shader compiler — Phase 0 / M0.4.
//!
//! Compiles GLSL shaders into SPIR-V by spawning the `glslc` CLI (consistent
//! with brief §Notes decision 7: no shaderc/glslang binding, the keeper count
//! stays at 7).
//!
//! Consistent with brief §Notes ("glslc is a peer dependency only
//! for `zig build shaders` (regeneration) or for the dev runtime hot-reload.
//! The standard `zig build` build does not depend on `glslc`."). If
//! `glslc` is absent from PATH, `compile` returns `error.GlslcNotFound`.
//!
//! Zig 0.16 API: `std.process.run` (which takes `io: Io`) — not
//! `std.process.Child.init` which no longer exists.

const std = @import("std");

/// Global counter to generate unique temp file names.
var unique_id: std.atomic.Value(u64) = .init(0);

/// Shader stage supported in Phase 0. Phase 1+ extends it (geometry, tessellation,
/// raygen/closesthit/miss for RT).
pub const Stage = enum {
    vertex,
    fragment,
    compute,

    pub fn glslcArg(self: Stage) []const u8 {
        return switch (self) {
            .vertex => "-fshader-stage=vertex",
            .fragment => "-fshader-stage=fragment",
            .compute => "-fshader-stage=compute",
        };
    }
};

/// Compilation errors. `GlslcNotFound` is the expected error when
/// the tool is not installed (cf. brief §Observable behavior).
pub const CompileError = error{
    GlslcNotFound,
    GlslcCrashed,
    GlslSyntaxError,
    OutOfMemory,
    InvalidUtf8,
    ProcessSpawnFailed,
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

/// Compiles `source` (GLSL text) to SPIR-V via glslc. The caller must
/// pass the correct `stage` (glslc needs it for shader model
/// selection). `entry_point` defaults to "main".
///
/// Returns `error.GlslcNotFound` if glslc is not findable in
/// PATH — usable as a heuristic to disable hot-reload.
///
/// Phase 0: uses `std.process.run` (Zig 0.16 API). The caller provides
/// the required `io: std.Io` instance.
pub fn compile(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    stage: Stage,
    entry_point: ?[]const u8,
) CompileError!Result {
    // Writes the source to a temp file. Unique name via an atomic
    // counter (avoids the dependency on `std.time.nanoTimestamp` which
    // no longer exists in Zig 0.16).
    const id = unique_id.fetchAdd(1, .monotonic);
    var tmp_buf: [128]u8 = undefined;
    const tmp_name = std.fmt.bufPrint(&tmp_buf, "/tmp/weld_shader_{d}.glsl", .{id}) catch return error.OutOfMemory;

    {
        var file = std.Io.Dir.cwd().createFile(io, tmp_name, .{ .truncate = true }) catch return error.ProcessSpawnFailed;
        defer file.close(io);
        file.writeStreamingAll(io, source) catch return error.ProcessSpawnFailed;
    }
    defer {
        std.Io.Dir.cwd().deleteFile(io, tmp_name) catch {};
    }

    // Builds argv.
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
    argv.append(allocator, "-o") catch return error.OutOfMemory;
    argv.append(allocator, "-") catch return error.OutOfMemory;
    argv.append(allocator, tmp_name) catch return error.OutOfMemory;

    const run_result = std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = std.Io.Limit.limited(16 * 1024 * 1024),
        .stderr_limit = std.Io.Limit.limited(1024 * 1024),
    }) catch |e| switch (e) {
        error.FileNotFound => return error.GlslcNotFound,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ProcessSpawnFailed,
    };
    defer allocator.free(run_result.stdout);
    defer allocator.free(run_result.stderr);

    switch (run_result.term) {
        .exited => |code| if (code != 0) {
            const diag = allocator.dupe(u8, run_result.stderr) catch return error.OutOfMemory;
            return Result{ .spv = &.{}, .diagnostics = diag };
        },
        else => return error.GlslcCrashed,
    }

    // SPIR-V in stdout. Basic validation: ≥ 4 bytes.
    if (run_result.stdout.len < 4) return error.GlslSyntaxError;
    const spv = allocator.dupe(u8, run_result.stdout) catch return error.OutOfMemory;
    const diag = allocator.dupe(u8, run_result.stderr) catch return error.OutOfMemory;
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

test "compiler: isAvailable does not crash" {
    // Purely structural test — calls the fn and verifies it returns
    // a bool without crashing, regardless of the actual presence of glslc.
    _ = isAvailable(std.testing.allocator, std.testing.io);
}
