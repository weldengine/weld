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
const no_precision_crossing = @import("rules/no_precision_crossing.zig");
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
        return runDeadTests(arena, init.io, stdout, argv[2..]);
    }

    try stdout.print("unknown subcommand: {s}\n\n", .{sub});
    try stdout.writeAll(usage_text);
    return 2;
}

fn runLint(arena: std.mem.Allocator, io: std.Io, paths: []const [:0]const u8, out: *std.Io.Writer) !u8 {
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(arena);

    // Whether this invocation reads the whole tree. Aggregate controls — the ones whose
    // verdict depends on having seen every file — may only run when it does.
    //
    // "No argument" was the FIRST form and it traded a false positive for a false negative:
    // `weld_lint lint src bench tests tools` names every default root explicitly and covers
    // everything, yet skipped the aggregate control. The test is now on COVERAGE — every
    // default root reached by some given path — so both spellings of a full scan qualify and
    // a genuinely partial list still does not.
    const full_scan = paths.len == 0 or coversEveryRoot(paths);
    if (paths.len == 0) {
        for (default_lint_paths) |p| try scan.collectZigFiles(arena, io, p, &files);
    } else {
        for (paths) |p| try scan.collectZigFiles(arena, io, p, &files);
    }

    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    defer diags.deinit(arena);

    // Owned here rather than inside the rule: the aggregate half of
    // `no_precision_crossing`'s bilateral control needs state across files, and module-level
    // state would survive between runs and contaminate that rule's own unit tests.
    var crossing_tally: no_precision_crossing.Tally = .{};

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
        try no_precision_crossing.check(arena, file, source, &diags, &crossing_tally);
    }

    // The second half of the bilateral control: a declared escape nobody used is stale.
    //
    // ONLY ON A FULL SCAN. This subcommand also accepts an explicit path list — the
    // `pre-commit` hook passes the staged files — and over a partial set an escape's own file
    // may simply not have been read. Running the stale check there would report the first
    // real exemption as stale on the next targeted scan, which is a guard failing on correct
    // input: the worst kind, because the fix a reader would reach for is deleting the
    // declaration.
    if (full_scan) {
        try no_precision_crossing.checkDeclarations(arena, &crossing_tally, &diags);
    }

    std.mem.sort(diag.Diagnostic, diags.items, {}, diag.Diagnostic.lessThan);
    for (diags.items) |d| {
        try out.print("{s}:{d}:{d}: {s}: {s}\n", .{ d.file, d.line, d.col, d.rule, d.message });
    }
    return if (diags.items.len == 0) @as(u8, 0) else @as(u8, 1);
}

/// Whether `paths` reaches every default lint root. A path covers a root when it IS that root
/// or contains it as a prefix — `.` and `src` both cover `src`, and `src/core` covers nothing.
fn coversEveryRoot(paths: []const [:0]const u8) bool {
    for (default_lint_paths) |root| {
        var covered = false;
        for (paths) |p| {
            const trimmed = std.mem.trimEnd(u8, p, "/\\");
            if (std.mem.eql(u8, trimmed, ".") or std.mem.eql(u8, trimmed, root)) {
                covered = true;
                break;
            }
        }
        if (!covered) return false;
    }
    return true;
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
fn runDeadTests(arena: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, argv_extra: []const [:0]const u8) !u8 {
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

    // `--list` prints the closure file by file with its test count. A delta is
    // not a verdict until it is DECOMPOSED: a single number invites attribution
    // by guesswork, which is how five unaccounted blocks became thirteen.
    var want_list = false;
    var want_per_root = false;
    for (argv_extra) |a| {
        if (std.mem.eql(u8, a, "--list")) want_list = true;
        if (std.mem.eql(u8, a, "--per-root")) want_per_root = true;
    }
    if (want_list) {
        for (report.closure.items) |c| {
            if (c.tests > 0) try out.print("LIVE {d}\t{s}\n", .{ c.tests, c.path });
        }
    }
    if (want_per_root) try perRootControl(arena, out, roots.items, want_list);

    // The bilateral control. Two independent computations must land on one
    // number: this closure, and the suite's own collected total. Too permissive
    // overshoots it, too strict undershoots it, and only equality excludes both —
    // which is why the control, and not the fixture count, is what authorises
    // this guard. Twenty-odd passing fixtures once missed a defect that ONE
    // NUMBER caught on its first application.
    const os = @import("builtin").os.tag;
    const gap = dead_tests.uncollectedOn(os);
    const expected = report.live_tests - gap;
    try out.print(
        "dead-tests: control — closure {d} - {d} declared uncollected on {t} = {d} expected collected\n",
        .{ report.live_tests, gap, os, expected },
    );
    for (dead_tests.uncollected) |u| {
        if (u.only_on != null and u.only_on.? != os) continue;
        try out.print("  uncollected: {s} ({d} block(s)): {s}\n", .{ u.path, u.blocks, u.reason });
    }
    // LAYER ONE — THE UNCONDITIONAL CONFRONTATION, and its absence was the fourth
    // instance of "a control that exists and a path bypasses" in this milestone,
    // after the lint step in no workflow, the witnesses with no reader, and the
    // cache save outside its own size guard. This one was inside the tool built
    // against that family: the loop below runs ONLY when `--expect-collected=N` is
    // passed, and neither `build.zig` nor the CI passed it, so the tool printed its
    // expectation and then printed `clean` having compared it to nothing.
    //
    // `expected` is arithmetic on the closure and the declared gap; the number here
    // is written down by a human from the suite's own reported total. Equal, not
    // bounded: two computations of one quantity must AGREE, and a one-sided test
    // would admit drift in the permitted direction.
    const declared = dead_tests.expectedCollectedOn(os);
    if (expected != declared) {
        try out.print(
            "dead-tests: CONSERVATION FAILED — closure gives {d} expected collected, " ++
                "`expectedCollectedOn({t})` declares {d}.\n",
            .{ expected, os, declared },
        );
        try out.writeAll("The closure and the declared suite total have parted. Do NOT bump the\n" ++
            "declared number to match: that turns the control into arithmetic on itself,\n" ++
            "which is exactly how this check came to print a verdict it never computed.\n" ++
            "Run `zig build test --summary all`, read the collected total it reports, and\n" ++
            "reconcile against THAT — then decompose with `--per-root --list` if the two\n" ++
            "still disagree.\n");
        return 1;
    }
    try out.print(
        "dead-tests: conservation OK — closure and the declared suite total agree at {d}.\n",
        .{expected},
    );

    // LAYER TWO — the suite-DERIVED confrontation. CI parses `zig build test`'s own
    // summary and passes it here, which is what stops the declared number above from
    // being quietly aligned to a drifted closure.
    for (argv_extra) |a| {
        const prefix = "--expect-collected=";
        if (!std.mem.startsWith(u8, a, prefix)) continue;
        const got = std.fmt.parseInt(usize, a[prefix.len..], 10) catch {
            try out.print("dead-tests: --expect-collected needs a number, got '{s}'\n", .{a[prefix.len..]});
            return 2;
        };
        if (got != expected) {
            try out.print(
                "dead-tests: CONTROL FAILED — expected {d} collected, `zig build test` reported {d}.\n",
                .{ expected, got },
            );
            try out.writeAll("A gap in either direction is a finding. ABOVE the collected total means\n" ++
                "the closure admits what no binary runs; BELOW means it misses an edge and a\n" ++
                "dead file could hide behind it. Decompose with `--per-root --list` before\n" ++
                "touching either side, and declare a new term in `uncollected` only with the\n" ++
                "mechanism that explains it.\n");
            return 1;
        }
        try out.print("dead-tests: control OK — closure and suite agree at {d}.\n", .{expected});
    }

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

/// Per-root closure control — the quantity the suite's own total is comparable to.
///
/// WHY PER ROOT AND NOT GLOBALLY, because this is the defect the control itself
/// exposed. `analyze` carries ONE `seen` set across every root, so a file reached
/// by two test targets is counted ONCE. The suite counts it once PER BINARY: two
/// targets that both reach it compile it twice and run its tests twice. Comparing
/// the global closure against the suite total is therefore comparing a set
/// cardinality to a multiset cardinality — the same collected-versus-source unit
/// error this milestone has now made three times, in its own instrument.
///
/// The per-root sum counts with the SAME multiplicity the suite does, so the two
/// numbers are finally the same kind of thing and their difference is a finding
/// rather than an artefact of how each was computed.
///
/// A module import (`weld_core`, `weld_etch`) is deliberately not followed, here
/// as everywhere: Zig collects tests from the root module's own files and not
/// from the modules it imports, so following one would inflate this side against
/// a suite that never ran those tests in that binary.
fn perRootControl(
    arena: std.mem.Allocator,
    out: *std.Io.Writer,
    roots: []const []const u8,
    want_list: bool,
) !void {
    var sum: usize = 0;
    for (roots) |root| {
        var one = try dead_tests.analyze(arena, &.{root}, &.{}, &readForAnalysis);
        defer one.deinit(arena);
        sum += one.live_tests;
        try out.print("ROOT {d}\t{s}\n", .{ one.live_tests, root });
        if (want_list) {
            for (one.closure.items) |c| {
                if (c.tests > 0) try out.print("  in {s}: {d}\t{s}\n", .{ root, c.tests, c.path });
            }
        }
    }
    try out.print(
        "dead-tests: per-root closure sum = {d} test block(s) over {d} roots\n",
        .{ sum, roots.len },
    );
    try out.writeAll(
        "Compare against the suite's own collected total from `zig build test --summary all`.\n" ++
            "Expect a PLATFORM-DEPENDENT gap, announced before it is measured so a predicted\n" ++
            "difference is not read as a broken guard: on macOS the closure exceeds the\n" ++
            "collected total by the blocks of `src/modules/render/gal/vulkan/conv.zig`, which\n" ++
            "the Null backend never analyses; on Linux the two are equal once the declared\n" ++
            "exclusions are subtracted. This analysis is static and blind to comptime dispatch.\n",
    );
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
    \\      no_float_reduce, no_precision_crossing. Exits 0
    \\      if clean, 1 if any rule fires.
    \\
    \\  weld_lint dead-tests [--list] [--per-root]
    \\      Check that every file holding a `test` block belongs to the
    \\      analysis closure of some test target, or to a declared
    \\      exclusion. Exits 0 if clean, 1 if any file is outside.
    \\      --list      print the closure file by file with its count.
    \\      --per-root  print each root's own closure and their SUM —
    \\                  the quantity comparable to the suite's collected
    \\                  total, which counts a shared file once per binary.
    \\
    \\  weld_lint commit-msg <file>
    \\      Validate the title of the commit message at <file> against
    \\      the Conventional Commits subset enforced by Weld. Exits 0
    \\      if valid, 1 otherwise.
    \\
;
