//! Weld custom linter — CLI entry point.
//!
//! Two subcommands wire into `build.zig`:
//!   - `lint [path]...`         — walk the given paths (default
//!     `src/ bench/ tests/ tools/`, including the linter's own
//!     sources so it stays exemplary) and apply rules 1–6. Exits
//!     non-zero if any rule fires.
//!   - `commit-msg <file>`      — validate the title of the commit
//!     message at `file` against the Conventional Commits subset
//!     enforced by Weld. Exits non-zero on the first violation.
//!
//! Diagnostics are printed in `file:line:col:rule:message` form,
//! sorted deterministically by `(file, line, col, rule)`.

const std = @import("std");
const scan = @import("scan.zig");
const diag = @import("diagnostic.zig");
const no_cimport = @import("rules/no_cimport.zig");
const no_usingnamespace = @import("rules/no_usingnamespace.zig");
const doc_comments = @import("rules/doc_comments.zig");
const c_module_isolation = @import("rules/c_module_isolation.zig");
const conventional_commit = @import("rules/conventional_commit.zig");
const no_device_dispatch_outside_gal = @import("rules/no_device_dispatch_outside_gal.zig");
const no_float_reduce = @import("rules/no_float_reduce.zig");
const dead_tests = @import("dead_tests.zig");

const default_lint_paths = [_][]const u8{ "src", "bench", "tests", "tools" };

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    if (argv.len < 2) {
        try stdout.writeAll(usage_text);
        return 2;
    }

    const sub = argv[1];

    if (std.mem.eql(u8, sub, "lint")) {
        return runLint(arena, init.io, argv[2..], stdout);
    }
    if (std.mem.eql(u8, sub, "commit-msg")) {
        return runCommitMsg(arena, init.io, argv[2..], stdout);
    }
    if (std.mem.eql(u8, sub, "dead-tests")) {
        return runDeadTests(arena, init.io, stdout);
    }

    try stdout.print("unknown subcommand: {s}\n\n", .{sub});
    try stdout.writeAll(usage_text);
    return 2;
}

fn runLint(arena: std.mem.Allocator, io: std.Io, paths: []const [:0]const u8, out: *std.Io.Writer) !u8 {
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(arena);

    if (paths.len == 0) {
        for (default_lint_paths) |p| try scan.collectZigFiles(arena, io, p, &files);
    } else {
        for (paths) |p| try scan.collectZigFiles(arena, io, p, &files);
    }

    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    defer diags.deinit(arena);

    for (files.items) |file| {
        const source = scan.readSourceZ(arena, io, file) catch |err| {
            try out.print("warn: cannot read {s}: {t}\n", .{ file, err });
            continue;
        };
        try no_cimport.check(arena, file, source, &diags);
        try no_usingnamespace.check(arena, file, source, &diags);
        try doc_comments.check(arena, file, source, &diags);
        try c_module_isolation.check(arena, file, source, &diags);
        try no_device_dispatch_outside_gal.check(arena, file, source, &diags);
        try no_float_reduce.check(arena, file, source, &diags);
    }

    std.mem.sort(diag.Diagnostic, diags.items, {}, diag.Diagnostic.lessThan);
    for (diags.items) |d| {
        try out.print("{s}:{d}:{d}: {s}: {s}\n", .{ d.file, d.line, d.col, d.rule, d.message });
    }
    return if (diags.items.len == 0) @as(u8, 0) else @as(u8, 1);
}

fn runCommitMsg(arena: std.mem.Allocator, io: std.Io, args: []const [:0]const u8, out: *std.Io.Writer) !u8 {
    if (args.len != 1) {
        try out.writeAll("usage: weld_lint commit-msg <commit-message-file>\n");
        return 2;
    }
    const path = args[0];

    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    defer diags.deinit(arena);

    try conventional_commit.validateFile(arena, io, path, &diags);

    for (diags.items) |d| {
        try out.print("{s}:{d}:{d}: {s}: {s}\n", .{ d.file, d.line, d.col, d.rule, d.message });
    }
    return if (diags.items.len == 0) @as(u8, 0) else @as(u8, 1);
}

/// `dead-tests` — every in-tree file holding a `test` block must belong to the
/// analysis closure of some test target, or be a declared exclusion.
///
/// The roots are DERIVED from `build.zig` rather than kept beside it: a
/// hand-maintained list drifts the first time a target is added, and drift here
/// reads as "no dead tests", which is the failure mode that says green.
fn runDeadTests(arena: std.mem.Allocator, io: std.Io, out: *std.Io.Writer) !u8 {
    const build_src = scan.readSourceZ(arena, io, "build.zig") catch {
        try out.writeAll("dead-tests: cannot read build.zig\n");
        return 2;
    };
    var roots = try dead_tests.rootsFromBuildZig(arena, build_src);
    defer roots.deinit(arena);

    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(arena);
    for (default_lint_paths) |p| try scan.collectZigFiles(arena, io, p, &files);

    // The reader closes over an arena and the io handle through a file-scope
    // slot: `analyze` takes a plain function pointer so its fixtures can drive
    // it without a filesystem at all.
    reader_arena = arena;
    reader_io = io;
    var report = try dead_tests.analyze(arena, roots.items, files.items, &readForAnalysis);
    defer report.deinit(arena);

    // The report states the SIZE of what it judged. A tool built because probes
    // rendered verdicts over unmeasured objects does not get to skip that.
    try out.print(
        "dead-tests: {d} roots, {d} files in closure, {d} files with tests, {d} live test blocks\n",
        .{ roots.items.len, report.in_closure, report.with_tests, report.live_tests },
    );
    if (report.excluded > 0) {
        try out.print("dead-tests: {d} file(s), {d} test block(s) under a DECLARED exclusion:\n", .{ report.excluded, report.excluded_tests });
        for (dead_tests.exclusions) |e| {
            try out.print("  {s} (owner {s}): {s}\n", .{ e.prefix, e.owner, e.reason });
        }
    }
    if (report.dead.items.len == 0) {
        if (report.with_tests == 0) {
            try out.writeAll("dead-tests: examined ZERO files with tests — the run proves nothing\n");
            return 2;
        }
        try out.writeAll("dead-tests: clean.\n");
        return 0;
    }
    var blocks: usize = 0;
    for (report.dead.items) |d| blocks += d.tests;
    try out.print("dead-tests: {d} file(s) holding {d} test block(s) are outside every closure:\n", .{ report.dead.items.len, blocks });
    for (report.dead.items) |d| try out.print("  {s}: {d} test block(s)\n", .{ d.path, d.tests });
    try out.writeAll("A test block outside every closure is never ANALYSED: no elaboration, no\n" ++
        "type-check, so an API that disappears under a toolchain bump is not reported.\n" ++
        "Wire the file into a test target's closure, or add a DECLARED exclusion with\n" ++
        "its owning milestone in `tools/weld_lint/dead_tests.zig`.\n");
    return 1;
}

var reader_arena: std.mem.Allocator = undefined;
var reader_io: std.Io = undefined;

/// Filesystem reader handed to `analyze`; returns null for anything unreadable.
fn readForAnalysis(path: []const u8) ?[]const u8 {
    return scan.readSourceZ(reader_arena, reader_io, path) catch null;
}

const usage_text =
    \\usage:
    \\  weld_lint lint [path]...
    \\      Walk the given paths (default `src bench tests tools`) and
    \\      apply rules: no_cimport, no_usingnamespace, doc_comments,
    \\      c_module_isolation, no_device_dispatch_outside_gal,
    \\      no_float_reduce. Exits 0
    \\      if clean, 1 if any rule fires.
    \\
    \\  weld_lint dead-tests
    \\      Check that every file holding a `test` block belongs to the
    \\      analysis closure of some test target, or to a declared
    \\      exclusion. Exits 0 if clean, 1 if any file is outside.
    \\
    \\  weld_lint commit-msg <file>
    \\      Validate the title of the commit message at <file> against
    \\      the Conventional Commits subset enforced by Weld. Exits 0
    \\      if valid, 1 otherwise.
    \\
;
