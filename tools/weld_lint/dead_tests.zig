//! Dead-test analysis — every in-tree file holding a `test` block must belong to
//! the analysis closure of some test target, or be a DECLARED exclusion.
//!
//! WHY A STATIC CLOSURE AND NOT A COUNT. M1.1.14 hunted dead tests three times
//! with three methods; two failed. A per-binary enumeration blew a ten-minute
//! budget, and pairing the ordered spec list against the summary tree produced
//! 79 mismatches because that tree does not follow declaration order. What the
//! class needs is a check that builds nothing and runs nothing.
//!
//! WHY IT MATTERS MORE THAN SLEEPING ASSERTIONS. An uncollected `test` block is
//! never ANALYSED, so the code it instantiates gets no elaboration and no
//! type-checking. That one mechanism explains both areas the sweep found:
//! `zig_codegen/cache.zig` stopped compiling when `std.fs.cwd()` was removed at
//! Zig 0.16 and nobody learned it, and a use-after-return in the render graph
//! survived ten milestones. A dead test switches off COMPILATION coverage.
//!
//! THE EDGE CRITERION, and it is a criterion rather than a heuristic — it was
//! derived from measurements that discriminate all four observed cases:
//!
//!   - `_ = @import("f.zig");` inside a `comptime` block → EDGE.
//!     The explicit reference guard.
//!   - `const n = @import("f.zig");` (or `pub const`) where `n` is referenced
//!     anywhere else in the file → EDGE. This is why `src/etch/lexer.zig`'s 17
//!     tests are collected although nothing pins the file: `parser.zig` binds it
//!     and uses it.
//!   - `const n = @import("f.zig");` never referenced → NO EDGE. This is why
//!     `zig_codegen/root.zig` was dead: `src/etch/root.zig` bound it as
//!     `pub const codegen_zig` and never touched the name.
//!   - `@import("f.zig").decl` used inline → NO EDGE. Analysing a single
//!     declaration does not analyse the file's tests. This is why
//!     `foundation/math/exact.zig` was dead behind
//!     `pub const triangleIsFlat = @import("exact.zig").triangleIsFlat`.
//!
//! It is an approximation of Zig's lazy analysis, and the direction of its error
//! matters: a missed edge yields a false DEAD, which is noisy but visible; an
//! invented edge yields a false ALIVE, which is the failure that says green and
//! is what the hostile fixtures exist to refuse.
//!
//! **STATUS AT M1.1.14: NOT WIRED INTO `zig build lint`, and here is why.** The
//! criterion above is CONFIRMED — the first run against the real tree tested it
//! and it survived. `src/modules/render/root.zig` binds everything with bare
//! `pub const` and its 45 tests ARE collected, which looked like a refutation
//! until the file was read: it carries a `comptime { _ = gal; … }` guard, so the
//! names ARE referenced. Bare `pub const` still collects nothing.
//!
//! What the run refuted is this IMPLEMENTATION, in two named places:
//!
//!   1. It discovers 18 roots and misses every target built by the `test_specs`
//!      LOOP, whose `root_source_file` is a loop variable and not a literal. All
//!      of `tests/` is therefore reported dead — false, and loud.
//!   2. The inline-field-access rule is too strong. `pub const Graph =
//!      @import("graph.zig").Graph;` DOES pull `graph.zig`'s tests when `Graph`
//!      is later referenced (render's comptime guard does exactly that), while
//!      `pub const triangleIsFlat = @import("exact.zig").triangleIsFlat;` pulled
//!      nothing because nothing referenced the name. The discriminator is the
//!      REFERENCE, as everywhere else in this criterion — not the syntax of the
//!      import. The rule must fold into the reference test rather than sit before it.
//!
//! Both defects push the same way, toward false DEAD, which is the direction
//! chosen on purpose: the run is noisy and visible instead of quiet and green.
//! Wiring it before those are fixed would make `zig build lint` report 116 files
//! it cannot justify, and a guard nobody can believe is worse than none.
//!
//! Only relative `.zig` imports are followed. A module-name import (`std`,
//! `weld_core`) crosses into a module that owns its own test target and its own
//! closure.

const std = @import("std");

/// One file that holds `test` blocks but sits outside every closure.
pub const Dead = struct {
    path: []const u8,
    tests: usize,
};

/// What an analysis pass found, including the size of what it looked at.
///
/// The counts are not decoration: this tool exists because a probe rendered a
/// verdict over an object it had not measured, four times in one milestone. A
/// report that says "0 dead" over 0 files examined is the same defect wearing
/// the tool's own badge.
pub const Report = struct {
    /// Files reached from at least one root.
    in_closure: usize = 0,
    /// Files under the scanned roots holding at least one `test` block.
    with_tests: usize = 0,
    /// Test blocks counted in the closure.
    live_tests: usize = 0,
    /// Files holding tests and outside every closure, excluding declarations.
    dead: std.ArrayList(Dead) = .empty,
    /// Files matched by a declared exclusion, reported and not failed on.
    excluded: usize = 0,
    /// Test blocks inside declared exclusions.
    excluded_tests: usize = 0,

    pub fn deinit(self: *Report, gpa: std.mem.Allocator) void {
        for (self.dead.items) |d| gpa.free(d.path);
        self.dead.deinit(gpa);
    }
};

/// A deliberate refusal to elaborate a subtree, with the milestone that owns it.
///
/// An exclusion is DECLARED, never silent: that is what separates a known debt
/// from a hidden one, and it is why `zig_codegen` has a legitimate status here
/// rather than an embarrassed absence.
pub const Exclusion = struct {
    prefix: []const u8,
    reason: []const u8,
    owner: []const u8,
};

/// The tree's declared exclusions.
pub const exclusions = [_]Exclusion{
    .{
        .prefix = "src/etch/zig_codegen/",
        .reason = "cache.zig does not compile under the pinned Zig 0.16 — `std.fs.cwd()` was " ++
            "removed and the replacement takes an `io` parameter these functions do not have, " ++
            "so the repair changes the codegen cache's public signatures",
        .owner = "M1.D.5",
    },
};

/// Whether `path` falls under a declared exclusion.
pub fn excludedBy(path: []const u8) ?Exclusion {
    for (exclusions) |e| {
        if (std.mem.indexOf(u8, path, e.prefix) != null) return e;
    }
    return null;
}

/// Counts the top-level `test` declarations in `source`.
pub fn countTests(source: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        const t = std.mem.trimStart(u8, line, " \t");
        if (!std.mem.startsWith(u8, t, "test")) continue;
        if (t.len == 4) continue;
        const c = t[4];
        if (c != ' ' and c != '\t') continue;
        const rest = std.mem.trimStart(u8, t[4..], " \t");
        if (rest.len == 0) continue;
        if (rest[0] == '"' or rest[0] == '{' or std.ascii.isAlphabetic(rest[0]) or rest[0] == '_') n += 1;
    }
    return n;
}

/// One outgoing edge: the relative import path a file's analysis reaches.
const Edge = struct { rel: []const u8 };

/// Extracts the edges of `source` under the criterion documented at the top.
///
/// Two passes, because the second criterion needs to know whether a bound name
/// is used and a name can be used before its binding is read.
fn edgesOf(gpa: std.mem.Allocator, source: []const u8, out: *std.ArrayList(Edge)) !void {
    // Pass 1 — every `@import("…")` occurrence, with the binding name if any and
    // whether it is consumed inline by a field access.
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, source, i, "@import(\"")) |at| {
        const start = at + "@import(\"".len;
        const end = std.mem.indexOfScalarPos(u8, source, start, '"') orelse break;
        const rel = source[start..end];
        i = end + 1;
        if (!std.mem.endsWith(u8, rel, ".zig")) continue;

        // Inline field access — `@import("f.zig").decl` — analyses one decl, not
        // the file, so it is NOT an edge.
        const after = std.mem.trimStart(u8, source[end + 1 ..], " \t\n");
        if (after.len >= 2 and after[0] == ')' and after[1] == '.') continue;

        // Find the statement head to classify the binding.
        const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..at], '\n')) |p| p + 1 else 0;
        const head = std.mem.trim(u8, source[line_start..at], " \t");

        // `head` is trimmed on BOTH ends, so the trailing space of `_ = ` is gone.
        // Comparing against `"_ = "` matched nothing and reported the pinned file
        // dead — caught by this file's own fixture, which is what they are for.
        if (std.mem.endsWith(u8, head, "_ =")) {
            try out.append(gpa, .{ .rel = rel }); // explicit reference guard
            continue;
        }
        const name = bindingName(head) orelse continue;
        if (isReferenced(source, name, line_start)) try out.append(gpa, .{ .rel = rel });
    }
}

/// The bound name of `const NAME = ` / `pub const NAME = `, or null.
fn bindingName(head: []const u8) ?[]const u8 {
    var h = head;
    if (std.mem.startsWith(u8, h, "pub ")) h = std.mem.trimStart(u8, h["pub ".len..], " \t");
    if (!std.mem.startsWith(u8, h, "const ")) return null;
    h = std.mem.trimStart(u8, h["const ".len..], " \t");
    const eq = std.mem.indexOfScalar(u8, h, '=') orelse return null;
    const name = std.mem.trim(u8, h[0..eq], " \t");
    if (name.len == 0) return null;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return null;
    return name;
}

/// Whether `name` appears as an identifier anywhere outside its own binding line.
fn isReferenced(source: []const u8, name: []const u8, binding_line_start: usize) bool {
    const binding_line_end = std.mem.indexOfScalarPos(u8, source, binding_line_start, '\n') orelse source.len;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, source, i, name)) |at| {
        i = at + name.len;
        if (at >= binding_line_start and at < binding_line_end) continue; // its own binding
        const before_ok = at == 0 or !isIdentChar(source[at - 1]);
        const after = at + name.len;
        const after_ok = after >= source.len or !isIdentChar(source[after]);
        if (before_ok and after_ok) return true;
    }
    return false;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Resolves `rel` against the directory of `from`, normalising `..` segments.
fn resolveRel(gpa: std.mem.Allocator, from: []const u8, rel: []const u8) ![]u8 {
    const dir = std.fs.path.dirname(from) orelse ".";
    const joined = try std.fs.path.join(gpa, &.{ dir, rel });
    defer gpa.free(joined);
    return normalise(gpa, joined);
}

/// Collapses `a/b/../c` to `a/c` and normalises separators to `/`.
fn normalise(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(gpa);
    var it = std.mem.splitAny(u8, path, "/\\");
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (parts.items.len > 0) _ = parts.pop();
            continue;
        }
        try parts.append(gpa, seg);
    }
    return std.mem.join(gpa, "/", parts.items);
}

/// Walks the closure from `roots` and reports every file with tests outside it.
///
/// `read` supplies file contents so the analysis is testable against fixtures
/// without touching the filesystem layout the tool normally walks.
pub fn analyze(
    gpa: std.mem.Allocator,
    roots: []const []const u8,
    all_files: []const []const u8,
    read: *const fn (path: []const u8) ?[]const u8,
) !Report {
    var report: Report = .{};
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        seen.deinit(gpa);
    }
    var queue: std.ArrayList([]const u8) = .empty;
    defer {
        for (queue.items) |q| gpa.free(q);
        queue.deinit(gpa);
    }

    for (roots) |r| {
        const n = try normalise(gpa, r);
        if (seen.contains(n)) {
            gpa.free(n);
            continue;
        }
        try seen.put(gpa, try gpa.dupe(u8, n), {});
        try queue.append(gpa, n);
    }

    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const path = queue.items[head];
        const src = read(path) orelse continue;
        report.in_closure += 1;
        report.live_tests += countTests(src);

        var edges: std.ArrayList(Edge) = .empty;
        defer edges.deinit(gpa);
        try edgesOf(gpa, src, &edges);
        for (edges.items) |e| {
            const resolved = try resolveRel(gpa, path, e.rel);
            if (seen.contains(resolved)) {
                gpa.free(resolved);
                continue;
            }
            try seen.put(gpa, try gpa.dupe(u8, resolved), {});
            try queue.append(gpa, resolved);
        }
    }

    for (all_files) |f| {
        const src = read(f) orelse continue;
        const n = countTests(src);
        if (n == 0) continue;
        report.with_tests += 1;
        const norm = try normalise(gpa, f);
        defer gpa.free(norm);
        if (seen.contains(norm)) continue;
        if (excludedBy(norm)) |_| {
            report.excluded += 1;
            report.excluded_tests += n;
            continue;
        }
        try report.dead.append(gpa, .{ .path = try gpa.dupe(u8, norm), .tests = n });
    }
    return report;
}

// ---------------------------------------------------------------------------
// Tests — the hostile fixtures the criterion is only believable with
// ---------------------------------------------------------------------------

const Fixture = struct {
    var files: std.StringHashMapUnmanaged([]const u8) = .empty;
    fn read(path: []const u8) ?[]const u8 {
        return files.get(path);
    }
};

fn runFixture(
    gpa: std.mem.Allocator,
    entries: []const [2][]const u8,
    roots: []const []const u8,
) !Report {
    Fixture.files = .empty;
    for (entries) |e| try Fixture.files.put(gpa, e[0], e[1]);
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    for (entries) |e| try names.append(gpa, e[0]);
    return analyze(gpa, roots, names.items, &Fixture.read);
}

test "a test three imports deep is ALIVE" {
    // The false-DEAD direction. Each hop binds a name AND references it, which
    // is the ordinary way a module reaches its files; a closure that stops short
    // would condemn most of the tree.
    const gpa = std.testing.allocator;
    var r = try runFixture(gpa, &.{
        .{ "m/root.zig", "const a = @import(\"a.zig\");\npub const A = a.T;\n" },
        .{ "m/a.zig", "const b = @import(\"b.zig\");\npub const T = b.U;\n" },
        .{ "m/b.zig", "const c = @import(\"c.zig\");\npub const U = c.V;\n" },
        .{ "m/c.zig", "pub const V = u8;\ntest \"deep\" {}\n" },
    }, &.{"m/root.zig"});
    defer r.deinit(gpa);
    defer Fixture.files.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), r.dead.items.len);
    try std.testing.expectEqual(@as(usize, 4), r.in_closure);
    try std.testing.expectEqual(@as(usize, 1), r.live_tests);
}

test "a file bound but never referenced is DEAD" {
    // The false-ALIVE direction, and the one that kills: it says green. This is
    // `zig_codegen` exactly — `pub const codegen_zig = @import(...)`, never used.
    const gpa = std.testing.allocator;
    var r = try runFixture(gpa, &.{
        .{ "m/root.zig", "pub const orphan = @import(\"orphan.zig\");\n" },
        .{ "m/orphan.zig", "test \"never analysed\" {}\ntest \"nor this\" {}\n" },
    }, &.{"m/root.zig"});
    defer r.deinit(gpa);
    defer Fixture.files.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), r.dead.items.len);
    try std.testing.expectEqualStrings("m/orphan.zig", r.dead.items[0].path);
    try std.testing.expectEqual(@as(usize, 2), r.dead.items[0].tests);
}

test "an inline field access on an import is not an edge" {
    // `foundation/math/exact.zig` exactly: reached only as
    // `@import("exact.zig").triangleIsFlat`, which analyses one decl.
    const gpa = std.testing.allocator;
    var r = try runFixture(gpa, &.{
        .{ "m/root.zig", "pub const f = @import(\"leaf.zig\").f;\npub const g = f;\n" },
        .{ "m/leaf.zig", "pub fn f() void {}\ntest \"leaf\" {}\n" },
    }, &.{"m/root.zig"});
    defer r.deinit(gpa);
    defer Fixture.files.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), r.dead.items.len);
    try std.testing.expectEqualStrings("m/leaf.zig", r.dead.items[0].path);
}

test "an explicit comptime reference guard is an edge" {
    const gpa = std.testing.allocator;
    var r = try runFixture(gpa, &.{
        .{ "m/root.zig", "comptime {\n    _ = @import(\"pinned.zig\");\n}\n" },
        .{ "m/pinned.zig", "test \"pinned\" {}\n" },
    }, &.{"m/root.zig"});
    defer r.deinit(gpa);
    defer Fixture.files.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), r.dead.items.len);
    try std.testing.expectEqual(@as(usize, 1), r.live_tests);
}

test "a declared exclusion is reported, not failed on" {
    const gpa = std.testing.allocator;
    var r = try runFixture(gpa, &.{
        .{ "m/root.zig", "pub const x = @import(\"src/etch/zig_codegen/cache.zig\");\n" },
        .{ "src/etch/zig_codegen/cache.zig", "test \"excluded\" {}\n" },
    }, &.{"m/root.zig"});
    defer r.deinit(gpa);
    defer Fixture.files.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), r.dead.items.len);
    try std.testing.expectEqual(@as(usize, 1), r.excluded);
    try std.testing.expectEqual(@as(usize, 1), r.excluded_tests);
}

test "relative parent segments resolve" {
    const gpa = std.testing.allocator;
    var r = try runFixture(gpa, &.{
        .{ "m/sub/root.zig", "const up = @import(\"../up.zig\");\npub const U = up.U;\n" },
        .{ "m/up.zig", "pub const U = u8;\ntest \"up\" {}\n" },
    }, &.{"m/sub/root.zig"});
    defer r.deinit(gpa);
    defer Fixture.files.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), r.dead.items.len);
    try std.testing.expectEqual(@as(usize, 1), r.live_tests);
}

test "countTests counts declarations and not prose" {
    try std.testing.expectEqual(@as(usize, 2), countTests("test \"a\" {}\ntest {}\n"));
    try std.testing.expectEqual(@as(usize, 0), countTests("// test \"a\" {}\n/// test {}\n"));
    try std.testing.expectEqual(@as(usize, 0), countTests("const testing = 1;\ntesting_only();\n"));
}

// ---------------------------------------------------------------------------
// Root discovery
// ---------------------------------------------------------------------------

/// Extracts every `addTest` root source path from `build_zig`.
///
/// DERIVED, never duplicated. A hand-kept list beside `build.zig` would drift
/// the first time a target is added, and drift here reads as "no dead tests" —
/// the failure that says green. Two shapes are matched: `b.createModule` and
/// `b.addModule`, both keyed by the variable `addTest` roots at.
pub fn rootsFromBuildZig(gpa: std.mem.Allocator, build_zig: []const u8) !std.ArrayList([]const u8) {
    var roots: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (roots.items) |r| gpa.free(r);
        roots.deinit(gpa);
    }
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, build_zig, i, ".root_module = ")) |at| {
        const name_start = at + ".root_module = ".len;
        var name_end = name_start;
        while (name_end < build_zig.len and isIdentChar(build_zig[name_end])) name_end += 1;
        i = name_end;
        // Only the ones an `addTest` roots at.
        const line_start = if (std.mem.lastIndexOfScalar(u8, build_zig[0..at], '\n')) |p| p + 1 else 0;
        if (std.mem.indexOf(u8, build_zig[line_start..at], "addTest") == null) continue;
        const mod = build_zig[name_start..name_end];
        if (try modulePath(gpa, build_zig, mod)) |p| try roots.append(gpa, p);
    }
    return roots;
}

/// The `root_source_file` path of the module bound to `name`, if it is a literal.
fn modulePath(gpa: std.mem.Allocator, build_zig: []const u8, name: []const u8) !?[]u8 {
    var buf: [128]u8 = undefined;
    const decl = std.fmt.bufPrint(&buf, "const {s} = b.", .{name}) catch return null;
    const at = std.mem.indexOf(u8, build_zig, decl) orelse return null;
    const key = std.mem.indexOfPos(u8, build_zig, at, "root_source_file = b.path(\"") orelse return null;
    // Guard against running past the declaration into the next one.
    if (key - at > 400) return null;
    const s = key + "root_source_file = b.path(\"".len;
    const e = std.mem.indexOfScalarPos(u8, build_zig, s, '"') orelse return null;
    return try gpa.dupe(u8, build_zig[s..e]);
}

test "rootsFromBuildZig picks addTest roots and skips other modules" {
    const gpa = std.testing.allocator;
    const src =
        \\const a_module = b.createModule(.{
        \\    .root_source_file = b.path("src/a/root.zig"),
        \\});
        \\const not_a_test = b.createModule(.{
        \\    .root_source_file = b.path("src/never/root.zig"),
        \\});
        \\const exe = b.addExecutable(.{ .root_module = not_a_test });
        \\const a_tests = b.addTest(.{ .root_module = a_module });
        \\
    ;
    var roots = try rootsFromBuildZig(gpa, src);
    defer {
        for (roots.items) |r| gpa.free(r);
        roots.deinit(gpa);
    }
    try std.testing.expectEqual(@as(usize, 1), roots.items.len);
    try std.testing.expectEqualStrings("src/a/root.zig", roots.items[0]);
}
