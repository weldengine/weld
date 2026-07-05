//! `etch_test` — thin CLI shim over the M1.0.15 Etch test runner
//! (`weld_etch.test_runner`). The shim owns arg parsing + file I/O + report
//! printing only; parse + type-check + run all live in the library, which
//! `weld test` (`engine-spec.md §26.1`) will consume through the same entry.
//!
//! CLI:
//!     etch_test <file.etch> [<file2.etch> ...]
//!
//! Each input file is its OWN compilation set (imports resolved as today).
//! For each file: parse → type-check → run its `test` blocks. Prints a per-test
//! `✓ <name> (<ms>)` / `✗ <name> — <message> (<file>:<line>)` / `- <name>
//! (skipped: <reason>)` line, then the `N passed / M failed / K skipped`
//! aggregate. Exits 0 iff every file has zero diagnostics AND zero test
//! failures; otherwise a nonzero exit.

const std = @import("std");
const weld_etch = @import("weld_etch");

const Diagnostic = weld_etch.Diagnostic;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena;
    const io = init.io;
    const argv = try init.minimal.args.toSlice(arena.allocator());
    const cwd = std.Io.Dir.cwd();

    var out_buf: [8 * 1024]u8 = undefined;
    var out_w = std.Io.File.stdout().writer(io, &out_buf);
    const out = &out_w.interface;

    if (argv.len < 2) {
        try out.writeAll("usage: etch_test <file.etch> [<file2.etch> ...]\n");
        try out.flush();
        return error.InvalidArgs;
    }

    var any_failure = false;
    var total_pass: u32 = 0;
    var total_fail: u32 = 0;
    var total_skip: u32 = 0;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const path = argv[i];
        const source = readWholeFile(arena.allocator(), io, cwd, path) catch |err| {
            try out.print("etch_test: cannot read {s}: {s}\n", .{ path, @errorName(err) });
            any_failure = true;
            continue;
        };

        // Parse.
        var pr = weld_etch.parseSource(gpa, source) catch |err| {
            try out.print("etch_test: parse failed for {s}: {s}\n", .{ path, @errorName(err) });
            any_failure = true;
            continue;
        };
        defer pr.deinit(gpa);
        if (pr.diagnostics.len > 0) {
            try out.print("{s}: {d} parse diagnostic(s)\n", .{ path, pr.diagnostics.len });
            for (pr.diagnostics) |d| try printDiag(out, path, source, d);
            any_failure = true;
            continue;
        }

        // Type-check.
        var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
        defer {
            for (diags.items) |*d| d.deinit(gpa);
            diags.deinit(gpa);
        }
        try weld_etch.TypeChecker.check(gpa, &pr.ast, &diags);
        if (diags.items.len > 0) {
            try out.print("{s}: {d} diagnostic(s)\n", .{ path, diags.items.len });
            for (diags.items) |d| try printDiag(out, path, source, d);
            any_failure = true;
            continue;
        }

        // Run the file's tests.
        var report = weld_etch.test_runner.run(gpa, io, &pr.ast) catch |err| {
            try out.print("etch_test: run failed for {s}: {s}\n", .{ path, @errorName(err) });
            any_failure = true;
            continue;
        };
        defer report.deinit();

        try out.print("{s}:\n", .{path});
        for (report.results) |r| {
            switch (r.status) {
                .passed => try out.print("  \u{2713} {s} ({d:.3} ms)\n", .{ r.name, msOf(r.duration_ns) }),
                .failed => {
                    const line = if (r.span) |s| lineOf(source, s.byte_start) else 0;
                    try out.print("  \u{2717} {s} \u{2014} {s} ({s}:{d})\n", .{ r.name, r.message orelse "test failed", path, line });
                },
                .skipped => try out.print("  - {s} (skipped: {s})\n", .{ r.name, r.message orelse "" }),
            }
        }
        try out.print("  {d} passed / {d} failed / {d} skipped\n", .{ report.passed, report.failed, report.skipped });

        total_pass += report.passed;
        total_fail += report.failed;
        total_skip += report.skipped;
        if (report.failed > 0) any_failure = true;
    }

    if (argv.len > 2) {
        try out.print("total: {d} passed / {d} failed / {d} skipped\n", .{ total_pass, total_fail, total_skip });
    }
    try out.flush();
    // Clean nonzero exit on any diagnostic / failure — no Zig error trace (the
    // shader_compiler `--check` precedent); the ✗ lines above are the report.
    if (any_failure) std.process.exit(1);
}

/// Nanoseconds → milliseconds (f64), for the per-test duration display.
fn msOf(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / @as(f64, std.time.ns_per_ms);
}

/// 1-based line number of a byte offset in `source` (newline count + 1).
fn lineOf(source: []const u8, byte: u32) usize {
    const end = @min(byte, source.len);
    var line: usize = 1;
    for (source[0..end]) |c| {
        if (c == '\n') line += 1;
    }
    return line;
}

fn printDiag(out: *std.Io.Writer, path: []const u8, source: []const u8, d: Diagnostic) !void {
    const line = lineOf(source, d.primary_span.byte_start);
    try out.print("  [{s}] {s} ({s}:{d})\n", .{ d.code.code(), d.primary_message, path, line });
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
