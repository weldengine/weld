//! Public surface of the S5 codegen module —
//! `briefs/S5-etch-codegen-zig.md` Scope: "Codegen surface published as
//! `weld_etch.codegen_zig` with a stable entry point ... plus minimal error
//! type `CodegenError`".
//!
//! Three entry points:
//! - `generateToBuffer(gpa, ast, source_path, &out_buffer)` — render the
//!   generated Zig source into a caller-owned buffer. Used by unit tests
//!   and by callers that want full control over the output sink.
//! - `generateToPath(gpa, source_path, source, output_dir, cache_dir)` —
//!   end-to-end: parse + type-check + lower + write file. Skips the write
//!   step on cache-hit (per-file xxHash cache).
//! - `cookTree(gpa, inputs, output_dir, cache_dir)` — drive the generation
//!   over a slice of input files; used by the bench harness and the
//!   `zig build run-demo-etch-codegen` step.

const std = @import("std");
const ast_mod = @import("../ast.zig");
const parser_mod = @import("../parser.zig");
const types_mod = @import("../types.zig");
const diag_mod = @import("../diagnostics.zig");

/// AST → cooked Zig lowering step (the main codegen body).
pub const lower = @import("lower.zig");
/// xxHash-based per-file cache that lets unchanged sources skip emission.
pub const cache = @import("cache.zig");
/// Codegen error set + diagnostic helpers.
pub const errors = @import("errors.zig");
/// Etch type → Zig type mapping table.
pub const type_map = @import("type_map.zig");
/// Low-level Zig output writer used by `lower`.
pub const emit = @import("emit.zig");

// Pull the dedicated `tests/` files into the module's import graph so
// `zig build test` picks them up. The brief locates these tests under
// `src/etch/zig_codegen/tests/` per the file layout convention; the
// imports keep them discoverable without a separate test executable.
comptime {
    _ = @import("tests/lower_test.zig");
    _ = @import("tests/cache_test.zig");
    _ = @import("tests/errors_test.zig");
}

const CodegenError = errors.CodegenError;
/// Returned by `generateToBuffer` and `generateToPath`. Surfaced at
/// the module root so `tools/etch_cook` can declare it in function
/// signatures without depending on the `lower.zig` internal path.
pub const GenerateStats = lower.GenerateStats;
const Hash = cache.Hash;

/// Result of `generateToPath` — stats, whether the cache hit, and the
/// source hash so callers can persist it independently.
pub const Outcome = struct {
    stats: GenerateStats,
    /// `true` if the file was regenerated; `false` if the cache hit and
    /// the on-disk artifact was reused as-is.
    regenerated: bool,
    /// xxHash of the source content (always populated).
    source_hash: Hash,
};

/// Errors that the end-to-end pipeline (`generateToPath` / `cookTree`)
/// can surface — composed with `CodegenError` and `Allocator.Error`.
pub const PipelineError = error{
    ParseFailed,
    TypeCheckFailed,
} || CodegenError || std.mem.Allocator.Error;

/// Render the generated Zig source for the given AST into `out_buffer`.
/// The caller owns `out_buffer` and is responsible for `deinit`.
pub fn generateToBuffer(
    gpa: std.mem.Allocator,
    ast: *const ast_mod.AstArena,
    source_path: []const u8,
    out_buffer: *std.ArrayListUnmanaged(u8),
) CodegenError!GenerateStats {
    return try lower.generateFile(gpa, ast, source_path, out_buffer);
}

/// End-to-end: parse + type-check + lower + write the resulting Zig file
/// under `output_dir/<source_path>.zig`. Skips emission when the source's
/// content hash matches the per-file cache entry. Returns an `Outcome`
/// with stats and a `regenerated` flag.
pub fn generateToPath(
    gpa: std.mem.Allocator,
    source_path: []const u8,
    source: []const u8,
    output_dir: []const u8,
    cache_dir: []const u8,
) PipelineError!Outcome {
    const hash = cache.computeHash(source);
    const cached = cache.readCachedHash(gpa, cache_dir, source_path) catch null;
    if (cached) |c| {
        if (c == hash) {
            return .{
                .stats = .{},
                .regenerated = false,
                .source_hash = hash,
            };
        }
    }

    var pr = try parser_mod.parse(gpa, source);
    defer pr.deinit(gpa);
    if (pr.diagnostics.len > 0) return PipelineError.ParseFailed;

    var diags: std.ArrayListUnmanaged(diag_mod.Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    types_mod.TypeChecker.check(gpa, &pr.ast, &diags) catch return PipelineError.TypeCheckFailed;
    if (diags.items.len > 0) return PipelineError.TypeCheckFailed;

    var out_buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer out_buffer.deinit(gpa);

    const stats = try generateToBuffer(gpa, &pr.ast, source_path, &out_buffer);

    try writeFileAndCache(gpa, output_dir, cache_dir, source_path, hash, out_buffer.items);

    return .{ .stats = stats, .regenerated = true, .source_hash = hash };
}

fn writeFileAndCache(
    gpa: std.mem.Allocator,
    output_dir: []const u8,
    cache_dir: []const u8,
    source_path: []const u8,
    hash: Hash,
    bytes: []const u8,
) !void {
    // Compose `<output_dir>/<source_path>.zig` (preserving the directory
    // shape of the input layout under the output root).
    const out_rel = try std.fmt.allocPrint(gpa, "{s}.zig", .{source_path});
    defer gpa.free(out_rel);
    const out_full = try std.fs.path.join(gpa, &.{ output_dir, out_rel });
    defer gpa.free(out_full);
    if (std.fs.path.dirname(out_full)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    const file = try std.fs.cwd().createFile(out_full, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);

    try cache.writeHash(gpa, cache_dir, source_path, hash);
}

/// One input entry for `cookTree` — relative path + source bytes.
pub const InputSpec = struct {
    path: []const u8,
    source: []const u8,
};

/// Run the codegen pipeline over a slice of `(path, source)` pairs. Each
/// entry is independent — a failure on one does not stop the others; the
/// caller inspects the returned slice for per-entry outcomes.
pub fn cookTree(
    gpa: std.mem.Allocator,
    inputs: []const InputSpec,
    output_dir: []const u8,
    cache_dir: []const u8,
    out_outcomes: *std.ArrayListUnmanaged(NamedOutcome),
) PipelineError!void {
    for (inputs) |in| {
        const o = generateToPath(gpa, in.path, in.source, output_dir, cache_dir) catch |err| {
            try out_outcomes.append(gpa, .{
                .path = in.path,
                .err = err,
                .outcome = null,
            });
            continue;
        };
        try out_outcomes.append(gpa, .{
            .path = in.path,
            .err = null,
            .outcome = o,
        });
    }
}

/// Per-entry result of `cookTree` — either a successful `Outcome` or
/// a `PipelineError`, tagged by the original `path`.
pub const NamedOutcome = struct {
    path: []const u8,
    outcome: ?Outcome,
    err: ?PipelineError,
};

// Dedicated `CodegenError` path tests live under
// `src/etch/zig_codegen/tests/errors_test.zig` and are pulled into the
// module's import graph above so `zig build test` exercises them.
