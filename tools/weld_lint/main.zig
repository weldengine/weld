//! Weld custom linter — CLI entry point.
//!
//! Two subcommands wire into `build.zig`:
//!   - `lint [path]...`         — walk the given paths (default
//!     `src/ bench/ tests/ tools/`, including the linter's own
//!     sources so it stays exemplary) and apply rules 1–4. Exits
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

const usage_text =
    \\usage:
    \\  weld_lint lint [path]...
    \\      Walk the given paths (default `src bench tests tools`) and
    \\      apply rules: no_cimport, no_usingnamespace, doc_comments,
    \\      c_module_isolation, no_device_dispatch_outside_gal. Exits 0
    \\      if clean, 1 if any rule fires.
    \\
    \\  weld_lint commit-msg <file>
    \\      Validate the title of the commit message at <file> against
    \\      the Conventional Commits subset enforced by Weld. Exits 0
    \\      if valid, 1 otherwise.
    \\
;
