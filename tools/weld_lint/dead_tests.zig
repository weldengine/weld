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
//! **AT RESUMPTION, READ THIS BEFORE TOUCHING THE CLOSURE.** The second incoming
//! edge into `src/etch/zig_codegen/` crosses a MODULE boundary — the two live
//! test targets reach `codegen_zig` through `weld_etch` — and this analysis
//! follows RELATIVE imports only. So the closure measures one level and the
//! verdict is about another: the same scale mismatch as every other defect this
//! milestone found. **Do not hunt the edge by hand.** The per-step measurement
//! names it mechanically, and that is cheaper and does not depend on being right
//! about where to look.
//!
//! **STATUS: NOT WIRED. THE FIXPOINT IS NOW TOO PERMISSIVE, AND THE BILATERAL
//! CONTROL CAUGHT IT ON THE FIRST RUN.** Scoping the reference search to the
//! closure closed the three false deads — the run reports `clean` — but it opened
//! the direction that says green: `live_tests` reads **1884** against a suite
//! total of **1829**, and a count ABOVE the total is precisely the signature of a
//! guard that admits too much. `src/etch/zig_codegen/` is admitted although it
//! does not compile, so its 37 blocks are counted live and its declared exclusion
//! never fires. Sixteen — now twenty-one — passing fixtures did not see this;
//! ONE NUMBER DID.
//!
//! That is the control's whole point and it earned it immediately: too permissive
//! overshoots the total, too strict undershoots it, and only equality excludes
//! both. It is the gate for activation, not the fixture count.
//!
//! The remaining work, named: the cross-closure reference must not admit a file
//! through a binding whose name is referenced only in a file that is itself
//! reachable ONLY through that same binding — the mutual-reference shape
//! `zig_codegen` has. And the expected equality is PLATFORM-DEPENDENT: the guard
//! is static and blind to comptime dispatch, so on macOS expect
//! `live_tests = total + 4` for `gal/vulkan/conv.zig`, whose four blocks the Null
//! backend never collects, and expect exact equality on Linux.
//!
//! HISTORY — THREE FALSE DEADS, since closed and worth keeping:
//! First run: 116 files / 405 blocks reported dead. After the two defects named
//! below were fixed — loop-built and bare-array roots discovered, and the
//! inline-field-access rule folded INTO the reference test — the run reports
//! **3 files / 9 blocks**, and all three were probed empirically and are
//! COLLECTED. So the residue is three missed edges, and it is the SAFE
//! direction: no false ALIVE has been observed at any point. `live_tests`
//! reached 1829 against a suite total of 1829 before the last root form landed,
//! which is a strong corroboration of the closure itself.
//!
//! **THE REMAINING DEFECT IS NAMED, and it is one mechanism for all three: the
//! reference search is scoped to the BINDING FILE and must be scoped to the
//! CLOSURE.** `gal/root.zig` binds `pub const barriers` and never touches it —
//! but `render_graph/pass.zig` writes `gal.barriers.Access`, and that reference
//! is what makes the file live. Same for `comptime_query`, bound in
//! `ecs/root.zig` and referenced from `core/root.zig`. `transport_posix.zig` is
//! the third shape: `@import` inside a `switch` assigned to a referenced `const`,
//! which the head parser does not recognise as a binding at all.
//!
//! So the criterion stands — THE REFERENCE IS THE DISCRIMINANT — and the fix is
//! a FIXPOINT: a binding is live once its name is referenced anywhere already in
//! the closure, which can add files, which can add references. Two hypotheses
//! were eliminated on the way and are recorded so they are not retried: it is
//! not "the root file is special" (a `pub const` unreferenced ONE LEVEL DOWN
//! collects nothing either — measured), and it is not the syntax of the import.
//!
//! The three, for whoever closes them: `src/core/ecs/comptime_query.zig`,
//! `src/core/ipc/transport_posix.zig`, `src/modules/render/gal/barriers.zig`.
//! The closure control that AUTHORISES activation is not the fixture count: it is
//! `live_tests` equalling the suite's own collected total, two unrelated
//! computations landing on one number. It read 1829 against 1829 at an
//! intermediate state and must be redone on the final one.
//! Activation is a Gate F exit condition, and it is COUPLED to the doctrine:
//! writing "a dead test switches off compilation coverage" as normative while
//! nothing checks it is the milestone's own named prohibition.
//!
//! HISTORY OF THE TWO DEFECTS THE FIRST RUN FOUND. The
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
    /// Every closure file with its test count, so a delta can be DECOMPOSED.
    closure: std.ArrayList(Dead) = .empty,

    pub fn deinit(self: *Report, gpa: std.mem.Allocator) void {
        for (self.dead.items) |d| gpa.free(d.path);
        self.dead.deinit(gpa);
        for (self.closure.items) |c| gpa.free(c.path);
        self.closure.deinit(gpa);
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
        .reason = "the subtree IS elaborated — two live test targets reach `codegen_zig` through " ++
            "the `weld_etch` module boundary — but the subset the wire-in ADDS does not compile: " ++
            "`zig_codegen/tests/` and `cache.zig`, where `std.fs.cwd()` was removed at Zig 0.16 " ++
            "and the replacement takes an `io` parameter these functions do not have, so the " ++
            "repair changes the codegen cache's public signatures",
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
        // The DISCRIMINANT IS THE REFERENCE, never the syntax of the import.
        // An earlier version refused `@import("f.zig").decl` outright, which is
        // wrong: `pub const Graph = @import("graph.zig").Graph;` DOES pull that
        // file's tests once `Graph` is referenced, while `triangleIsFlat` pulled
        // nothing because nothing referenced it. Same syntax, opposite outcomes,
        // one rule. So the syntax test folds INTO the reference test rather than
        // preceding it, and an unbound inline access simply has no name to check.
        const name = bindingName(head) orelse continue;
        if (isReferenced(source, name, line_start)) try out.append(gpa, .{ .rel = rel });
    }
}

/// Edges of `source` where a bound name counts as referenced if it appears in
/// `source` itself OR in any file of `live` — and in nothing else.
fn edgesOfLive(
    gpa: std.mem.Allocator,
    source: []const u8,
    live: []const []const u8,
    read: *const fn (path: []const u8) ?[]const u8,
    out: *std.ArrayList(Edge),
) !void {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, source, i, "@import(\"")) |at| {
        const start = at + "@import(\"".len;
        const end = std.mem.indexOfScalarPos(u8, source, start, '"') orelse break;
        const rel = source[start..end];
        i = end + 1;
        if (!std.mem.endsWith(u8, rel, ".zig")) continue;

        const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..at], '\n')) |p| p + 1 else 0;
        const head = std.mem.trim(u8, source[line_start..at], " \t");
        if (std.mem.endsWith(u8, head, "_ =")) {
            try out.append(gpa, .{ .rel = rel });
            continue;
        }
        const name = bindingName(head) orelse {
            // A binding the head parser does not recognise — an `@import` inside a
            // `switch` assigned to a referenced `const`, as `ipc/transport.zig`
            // does. Refusing it outright reported a live file dead; admitting it
            // whenever the enclosing statement binds SOMETHING keeps the criterion
            // (a reference exists) without teaching the parser every expression form.
            if (enclosingBindingReferenced(source, line_start, live, read)) {
                try out.append(gpa, .{ .rel = rel });
            }
            continue;
        };
        if (isReferenced(source, name, line_start)) {
            try out.append(gpa, .{ .rel = rel });
            continue;
        }
        for (live) |other| {
            const osrc = read(other) orelse continue;
            if (osrc.ptr == source.ptr) continue;
            if (isReferenced(osrc, name, osrc.len)) {
                try out.append(gpa, .{ .rel = rel });
                break;
            }
        }
    }
}

/// Whether the `const NAME = ` statement enclosing `line_start` binds a name that
/// is referenced in `source` or in the live set. Walks back to the nearest
/// `const … = ` line, which is where a multi-line `switch` binding starts.
fn enclosingBindingReferenced(
    source: []const u8,
    line_start: usize,
    live: []const []const u8,
    read: *const fn (path: []const u8) ?[]const u8,
) bool {
    var pos = line_start;
    var back: usize = 0;
    while (pos > 0 and back < 8) : (back += 1) {
        const prev_end = pos - 1;
        const prev_start = if (std.mem.lastIndexOfScalar(u8, source[0..prev_end], '\n')) |p| p + 1 else 0;
        const line = std.mem.trim(u8, source[prev_start..prev_end], " \t");
        if (bindingName(line)) |name| {
            if (isReferenced(source, name, prev_start)) return true;
            for (live) |other| {
                const osrc = read(other) orelse continue;
                if (osrc.ptr == source.ptr) continue;
                if (isReferenced(osrc, name, osrc.len)) return true;
            }
            return false;
        }
        pos = prev_start;
        if (prev_start == 0) break;
    }
    return false;
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

/// Whether a byte offset falls inside a `//` comment.
///
/// MEASURED, and by the worst possible route: the guard admitted all of
/// `src/etch/zig_codegen/` because `src/etch/root.zig` carries a COMMENT naming
/// `codegen_zig` — the very paragraph explaining why that subtree is dead. The
/// documentation of a corpse reported it alive. A reference search that reads
/// prose is not a reference search.
fn inComment(source: []const u8, at: usize) bool {
    const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..at], '\n')) |p| p + 1 else 0;
    var i = line_start;
    while (i + 1 < at) : (i += 1) {
        if (source[i] == '/' and source[i + 1] == '/') return true;
        if (source[i] == '"') return false; // a `//` inside a string is not a comment
    }
    return false;
}

/// Whether `name` appears as an identifier anywhere outside its own binding line,
/// ignoring occurrences inside comments.
fn isReferenced(source: []const u8, name: []const u8, binding_line_start: usize) bool {
    const binding_line_end = std.mem.indexOfScalarPos(u8, source, binding_line_start, '\n') orelse source.len;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, source, i, name)) |at| {
        i = at + name.len;
        if (at >= binding_line_start and at < binding_line_end) continue; // its own binding
        const before_ok = at == 0 or !isIdentChar(source[at - 1]);
        const after = at + name.len;
        const after_ok = after >= source.len or !isIdentChar(source[after]);
        if (before_ok and after_ok and !inComment(source, at)) return true;
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

    // FIXPOINT, and it extends ONLY through files that are ALREADY LIVE.
    //
    // The reference that makes a binding live is often in ANOTHER file:
    // `gal/root.zig` binds `pub const barriers` and never touches it, while
    // `render_graph/pass.zig` writes `gal.barriers.Access`. Scoping the search to
    // the binding file reported three live files dead.
    //
    // WIDENING THE SCOPE OPENS THE FALSE ALIVE — the first time in this analysis
    // that the error could point that way, and the direction that says green. The
    // restriction is what closes it: a reference only counts when it comes from a
    // file already in the closure. `src/etch/zig_codegen/` is exactly the shape
    // that would break a naive version — 37 dead blocks across files that
    // reference each other — and none of them is ever scanned, because none of
    // them is ever live.
    var head: usize = 0;
    while (true) {
        const before = queue.items.len;
        while (head < queue.items.len) : (head += 1) {
            const path = queue.items[head];
            const src = read(path) orelse continue;
            report.in_closure += 1;
            const n = countTests(src);
            report.live_tests += n;
            try report.closure.append(gpa, .{ .path = try gpa.dupe(u8, path), .tests = n });
        }
        // Re-scan every live file: a file admitted in this round can carry the
        // reference that makes an earlier file's binding live.
        //
        // Admissions are STAGED and appended after the scan. Appending inside the
        // loop reallocates `queue.items` and leaves `path` dangling into freed
        // memory — which segfaulted on Zig's `0xaa` poison at the first real run.
        var pending: std.ArrayList([]const u8) = .empty;
        defer pending.deinit(gpa);
        for (queue.items) |path| {
            const src = read(path) orelse continue;
            var edges: std.ArrayList(Edge) = .empty;
            defer edges.deinit(gpa);
            try edgesOfLive(gpa, src, queue.items, read, &edges);
            for (edges.items) |e| {
                const resolved = try resolveRel(gpa, path, e.rel);
                if (seen.contains(resolved)) {
                    gpa.free(resolved);
                    continue;
                }
                try seen.put(gpa, try gpa.dupe(u8, resolved), {});
                try pending.append(gpa, resolved);
            }
        }
        for (pending.items) |r| try queue.append(gpa, r);
        if (pending.items.len == 0 and queue.items.len == before) break;
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

test "an inline field access whose name is NEVER referenced is DEAD" {
    // `foundation/math/exact.zig` exactly: bound as
    // `pub const triangleIsFlat = @import("exact.zig").triangleIsFlat;` and
    // referenced by nothing, so its two tests never ran.
    //
    // This fixture ORIGINALLY bound `f` and then wrote `pub const g = f;`, which
    // references it — it therefore encoded the refuted rule (syntax decides) and
    // passed only because the implementation shared the mistake. Corrected here
    // with its sibling below, which is the same syntax with the reference present.
    const gpa = std.testing.allocator;
    var r = try runFixture(gpa, &.{
        .{ "m/root.zig", "pub const f = @import(\"leaf.zig\").f;\n" },
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
    try loopRoots(gpa, build_zig, &roots);
    return roots;
}

/// Extracts the literal paths of a `test_specs`-style table.
///
/// A target whose `root_source_file` is a LOOP VARIABLE has no literal to find
/// at its `createModule`, so the first version of this file missed every one of
/// them and reported all of `tests/` dead. The paths are still literals — in the
/// table the loop walks — so they are read from there.
pub fn loopRoots(gpa: std.mem.Allocator, build_zig: []const u8, out: *std.ArrayList([]const u8)) !void {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, build_zig, i, ".path = \"")) |at| {
        const s2 = at + ".path = \"".len;
        const e = std.mem.indexOfScalarPos(u8, build_zig, s2, '"') orelse break;
        i = e + 1;
        const path = build_zig[s2..e];
        if (!std.mem.endsWith(u8, path, ".zig")) continue;
        try out.append(gpa, try gpa.dupe(u8, path));
    }

    // A second table shape: a bare `[_][]const u8{ "a.zig", "b.zig" }` array,
    // which the IPC targets use. Matched on the ELEMENT form — a line whose whole
    // content is a quoted `.zig` path followed by a comma — rather than on any
    // `.zig` string anywhere in `build.zig`, because a loose match would invent
    // roots, and an invented root yields a false ALIVE.
    var it = std.mem.splitScalar(u8, build_zig, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len < 8 or t[0] != '"') continue;
        if (!std.mem.endsWith(u8, t, "\".zig\",") and !std.mem.endsWith(u8, t, ".zig\",")) continue;
        const e = std.mem.lastIndexOfScalar(u8, t, '"') orelse continue;
        if (e == 0) continue;
        try out.append(gpa, try gpa.dupe(u8, t[1..e]));
    }
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

test "a root whose path is a loop variable is still discovered" {
    // DEFECT 1, pinned. The first version read only literal `root_source_file`
    // arguments, so every target built by the `test_specs` loop was invisible and
    // all of `tests/` reported dead. The paths ARE literals — in the table the
    // loop walks — and that is where they are read from.
    const gpa = std.testing.allocator;
    const src =
        \\const test_specs = [_]Spec{
        \\    .{ .path = "tests/a/one.zig" },
        \\    .{ .path = "tests/a/two.zig" },
        \\};
        \\for (test_specs) |spec| {
        \\    const t_mod = b.createModule(.{ .root_source_file = b.path(spec.path) });
        \\    const t = b.addTest(.{ .root_module = t_mod });
        \\}
        \\
    ;
    var roots = try rootsFromBuildZig(gpa, src);
    defer {
        for (roots.items) |r| gpa.free(r);
        roots.deinit(gpa);
    }
    try std.testing.expectEqual(@as(usize, 2), roots.items.len);
    try std.testing.expectEqualStrings("tests/a/one.zig", roots.items[0]);
    try std.testing.expectEqualStrings("tests/a/two.zig", roots.items[1]);
}

test "an inline field access whose name IS referenced is ALIVE" {
    // DEFECT 2, pinned, and it is the counterpart of the third fixture above:
    // same syntax, opposite outcome, decided by the reference alone. This is
    // `render_graph.Graph` — `pub const Graph = @import("graph.zig").Graph;` with
    // a `comptime { _ = render_graph.Graph; }` guard — whose six tests ARE
    // collected, against `exact.zig`, which nothing referenced.
    const gpa = std.testing.allocator;
    var r = try runFixture(gpa, &.{
        .{ "m/root.zig", "pub const Graph = @import(\"graph.zig\").Graph;\ncomptime { _ = Graph; }\n" },
        .{ "m/graph.zig", "pub const Graph = struct {};\ntest \"graph\" {}\n" },
    }, &.{"m/root.zig"});
    defer r.deinit(gpa);
    defer Fixture.files.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), r.dead.items.len);
    try std.testing.expectEqual(@as(usize, 1), r.live_tests);
}

test "a bare string-array table of roots is discovered, and only its elements" {
    // The IPC targets, built from a `[_][]const u8` list. Matched on the ELEMENT
    // form: a loose "any .zig string in build.zig" would pick up `b.path` calls
    // for executables and invent roots, and an invented root says ALIVE.
    const gpa = std.testing.allocator;
    const src =
        \\const ipc_specs = [_][]const u8{
        \\    "tests/ipc/framing.zig",
        \\    "tests/ipc/shm.zig",
        \\};
        \\const exe_mod = b.createModule(.{ .root_source_file = b.path("src/runtime/main.zig") });
        \\
    ;
    var roots = try rootsFromBuildZig(gpa, src);
    defer {
        for (roots.items) |r| gpa.free(r);
        roots.deinit(gpa);
    }
    try std.testing.expectEqual(@as(usize, 2), roots.items.len);
    try std.testing.expectEqualStrings("tests/ipc/framing.zig", roots.items[0]);
    try std.testing.expectEqualStrings("tests/ipc/shm.zig", roots.items[1]);
}

test "a file referenced ONLY from outside the closure is DEAD" {
    // FIXTURE 7 — it guards the direction the fixpoint opened, and it is the only
    // one that can say green when it should say red. `outside.zig` binds AND
    // references `victim.zig`, but nothing ever admits `outside.zig`, so that
    // reference must not count. This is `src/etch/zig_codegen/` exactly: 37 dead
    // blocks across files that reference each other.
    const gpa = std.testing.allocator;
    var r = try runFixture(gpa, &.{
        .{ "m/root.zig", "pub const nothing = u8;\n" },
        .{ "m/outside.zig", "const victim = @import(\"victim.zig\");\npub const V = victim.V;\n" },
        .{ "m/victim.zig", "pub const V = u8;\ntest \"victim\" {}\n" },
    }, &.{"m/root.zig"});
    defer r.deinit(gpa);
    defer Fixture.files.deinit(gpa);

    // One dead FILE, not two: only files holding `test` blocks are counted, and
    // `outside.zig` holds none. Expecting two was my own error — the report
    // counts dead TESTS' homes, never every unreached file.
    try std.testing.expectEqual(@as(usize, 1), r.dead.items.len);
    try std.testing.expectEqualStrings("m/victim.zig", r.dead.items[0].path);
    try std.testing.expectEqual(@as(usize, 0), r.live_tests);
}

test "the same file referenced from INSIDE the closure is ALIVE" {
    // The twin, by the pairing rule: same shape, discriminant inverted, verdict
    // inverted. `helper.zig` is admitted, so ITS reference to `victim` counts —
    // which is `render_graph/pass.zig` writing `gal.barriers.Access` for a name
    // `gal/root.zig` binds and never touches.
    const gpa = std.testing.allocator;
    var r = try runFixture(gpa, &.{
        .{ "m/root.zig", "const helper = @import(\"helper.zig\");\ncomptime { _ = helper; }\npub const victim = @import(\"victim.zig\");\n" },
        .{ "m/helper.zig", "pub const use = victim.V;\n" },
        .{ "m/victim.zig", "pub const V = u8;\ntest \"victim\" {}\n" },
    }, &.{"m/root.zig"});
    defer r.deinit(gpa);
    defer Fixture.files.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 0), r.dead.items.len);
    try std.testing.expectEqual(@as(usize, 1), r.live_tests);
}

test "a name occurring only in a COMMENT is not a reference" {
    // The defect that admitted all of `zig_codegen`: `src/etch/root.zig` names
    // `codegen_zig` in the paragraph explaining why that subtree is DEAD, and the
    // reference search read it as a use. Its twin below is the same name in code.
    const gpa = std.testing.allocator;
    var r = try runFixture(gpa, &.{
        .{ "m/root.zig", "pub const orphan = @import(\"orphan.zig\");\n// orphan is held, see M1.D.5\n" },
        .{ "m/orphan.zig", "test \"dead\" {}\n" },
    }, &.{"m/root.zig"});
    defer r.deinit(gpa);
    defer Fixture.files.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), r.dead.items.len);
}

test "the same name in CODE is a reference" {
    const gpa = std.testing.allocator;
    var r = try runFixture(gpa, &.{
        .{ "m/root.zig", "pub const orphan = @import(\"orphan.zig\");\npub const O = orphan.V;\n" },
        .{ "m/orphan.zig", "pub const V = u8;\ntest \"live\" {}\n" },
    }, &.{"m/root.zig"});
    defer r.deinit(gpa);
    defer Fixture.files.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), r.dead.items.len);
    try std.testing.expectEqual(@as(usize, 1), r.live_tests);
}
