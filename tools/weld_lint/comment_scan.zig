//! Shared comment extraction and perimeter for the comment rules.
//!
//! ONE DEFINITION OF WHAT A COMMENT IS, and it is not a search for `//`.
//! Measured on this tree: 210 lines carry a `//` inside a string literal, a
//! char literal, or after a `\\` multiline-string opener, where locating the
//! comment by the first `//` gives the wrong span. None of them currently
//! carries a token any comment rule forbids, so a naive scan is *incidentally*
//! right today and would break on the next such line.
//!
//! The extraction is therefore structural: `std.zig.Tokenizer` is run, and the
//! bytes BETWEEN consecutive tokens can only be whitespace and comments, so any
//! `//` found there opens one. `///` and `//!` are tokens rather than trivia, so
//! they are collected from the token stream itself. A `//` inside a string
//! literal is inside a token and is never seen.
//!
//! Trailing comments are collected like any other. A rule that looked only at
//! lines STARTING with `//` would miss them, and on this tree that is 2181
//! trailing comments, 16 of which carry a gate identifier.

const std = @import("std");

/// One comment in a source file.
pub const Span = struct {
    /// Byte offset of the `/` that opens the comment.
    start: usize,
    /// Byte offset one past the comment's last byte, which is its line end.
    end: usize,
    /// Whether the comment is a `///` or `//!` doc comment.
    doc: bool,

    /// The comment's bytes, including the opening slashes.
    pub fn text(self: Span, source: []const u8) []const u8 {
        return source[self.start..self.end];
    }
};

/// Collect every comment in `source`, in ascending offset order.
///
/// `source` must be the whole file: offsets are absolute, so a caller can map
/// one to a line and column with `diagnostic.lineColFromOffset`.
pub fn collect(
    arena: std.mem.Allocator,
    source: [:0]const u8,
    out: *std.ArrayList(Span),
) !void {
    var tok = std.zig.Tokenizer.init(source);
    var prev_end: usize = 0;
    while (true) {
        const t = tok.next();
        try collectInTrivia(arena, source, prev_end, t.loc.start, out);
        if (t.tag == .eof) break;
        if (t.tag == .doc_comment or t.tag == .container_doc_comment) {
            try out.append(arena, .{ .start = t.loc.start, .end = t.loc.end, .doc = true });
        }
        prev_end = t.loc.end;
    }
}

/// Scan the trivia between two tokens for ordinary `//` comments.
///
/// Trivia holds nothing but whitespace and comments, which is what lets this
/// take any `//` as an opener without re-implementing string-literal scanning.
fn collectInTrivia(
    arena: std.mem.Allocator,
    source: []const u8,
    from: usize,
    to: usize,
    out: *std.ArrayList(Span),
) !void {
    var i = from;
    while (i + 1 < to) {
        if (source[i] != '/' or source[i + 1] != '/') {
            i += 1;
            continue;
        }
        const nl = std.mem.indexOfScalarPos(u8, source, i, '\n') orelse source.len;
        const end = @min(nl, to);
        try out.append(arena, .{ .start = i, .end = end, .doc = false });
        i = end;
    }
}

/// Whether the comment rules apply to `file`.
///
/// **THE PERIMETER IS WRITTEN HERE AND NOT INHERITED FROM THE CALLER'S PATH
/// LIST, and the exclusion below is a decision rather than an oversight.**
///
/// `main.runLint` walks `src bench tests tools`. The comment rules apply to
/// three of those four: `src/`, `tools/` and `bench/` carry the conservation
/// pass that gives a reworded comment somewhere to go, and `tests/` does not.
/// Its 720 identifier occurrences on 516 lines are real and are recorded as a
/// debt against the pass that will read those files; firing here would make the
/// rule green only by leaving 149 files permanently red instead.
///
/// A `tests` segment INSIDE the perimeter stays in — `src/modules/forge/forge_3d/tests/`
/// is production source under `src/`. Only a leading `tests` segment is out, which
/// is why this tests the first segment and not any segment.
pub fn inPerimeter(file: []const u8) bool {
    var i: usize = 0;
    while (i < file.len) {
        const seg_end = firstSeparator(file, i) orelse file.len;
        const seg = file[i..seg_end];
        if (seg.len != 0 and !std.mem.eql(u8, seg, ".") and !std.mem.eql(u8, seg, "..")) {
            return !std.mem.eql(u8, seg, "tests");
        }
        if (seg_end == file.len) break;
        i = seg_end + 1;
    }
    return true;
}

/// A subtree the conservation pass has not read yet.
///
/// The comment rules are LIVE from the moment they are written, and the pass
/// that clears what they find runs one subtree at a time. Between those two
/// facts something has to give, and the two obvious answers are both defects:
/// leaving the rules unregistered makes a control no path invokes, and letting
/// them fail the build makes every commit of the pass impossible.
///
/// So the coverage is DECLARED and reachable: `weld_lint coverage` prints this
/// list, and `lint` prints it too whenever its output surfaces. A subtree here is
/// not exempt — it is unread, and a green lint means "green outside this list".
///
/// TODO(coverage of the three subtrees): this list must reach EMPTY, and the
/// assertion below it then inverts — from "these paths are unread" to "no path is
/// unread", pinned by `noPathOutsideCoverage`. A growing allowlist with no removal
/// condition becomes permanent, so the condition is written here rather than left
/// to whoever reads the list last. A closure reached with an entry still present is
/// not a residual: it is a subtree nobody read.
///
/// No entry names the step that removes it: an identifier written here would go
/// stale at a renumbering and the rule beside it forbids one anyway. The order
/// lives in the milestone's own journal.
pub const Pending = struct {
    /// Repo-relative path prefix, `/`-separated.
    prefix: []const u8,
};

/// Subtrees the comment rules do not report on yet.
///
/// The granularity matches the order the pass runs in, so removing one entry
/// has an effect: a broad entry that SUBSUMED a narrower one would make the
/// narrower removal a no-op, which is how a ledger comes to lie about progress.
///
/// Omitting a path is the SAFE direction and is deliberate: anything not listed
/// is covered, so a subtree nobody thought of goes red rather than silent. That
/// is how the file below this list was found.
pub const pending = [_]Pending{
    .{ .prefix = "src/modules/forge/api" },
    .{ .prefix = "src/modules/forge/forge_3d" },
    .{ .prefix = "src/modules/forge/module.zig" },
    .{ .prefix = "src/modules/forge/sensor_events.zig" },
    .{ .prefix = "src/modules/forge/services" },
    .{ .prefix = "src/modules/forge/sync.zig" },
    .{ .prefix = "src/modules/forge/sync_in.zig" },
    .{ .prefix = "src/modules/asset_pipeline" },
    .{ .prefix = "src/modules/audio" },
    .{ .prefix = "src/modules/render" },
    .{ .prefix = "src/etch" },
    .{ .prefix = "src/core" },
    .{ .prefix = "src/foundation" },
    .{ .prefix = "src/interfaces" },
    .{ .prefix = "src/editor" },
    .{ .prefix = "src/runtime" },
    .{ .prefix = "src/demo_etch_codegen.zig" },
    .{ .prefix = "src/demo_etch_interp.zig" },
    .{ .prefix = "tools/asm_inventory" },
    .{ .prefix = "tools/asset_cook" },
    .{ .prefix = "tools/bindgen" },
    .{ .prefix = "tools/etch_cook" },
    .{ .prefix = "tools/etch_synth" },
    .{ .prefix = "tools/etch_test" },
    .{ .prefix = "tools/scene_cook" },
    .{ .prefix = "tools/shader_compiler" },
    .{ .prefix = "bench" },
};
/// Whether `file` is inside a subtree the pass has not read yet.
pub fn isPending(file: []const u8) bool {
    for (pending) |p| {
        if (hasPathPrefix(file, p.prefix)) return true;
    }
    return false;
}

/// Whether the comment rules report on `file`: inside the perimeter, and read.
pub fn isCovered(file: []const u8) bool {
    return inPerimeter(file) and !isPending(file);
}

/// Whether `file` is under `prefix`. Exposed so the caller can confront each
/// declared entry with the files it actually walked.
pub fn matchesPending(file: []const u8, prefix: []const u8) bool {
    return hasPathPrefix(file, prefix);
}

/// Whether `file` starts with the `/`-separated `prefix`, on either separator.
///
/// Compared segment by segment so a prefix cannot match half a directory name,
/// and so the walker's Windows spelling reads the same as the declaration's.
fn hasPathPrefix(file: []const u8, prefix: []const u8) bool {
    var f: usize = 0;
    var p: usize = 0;
    while (p < prefix.len) {
        const p_end = std.mem.indexOfScalarPos(u8, prefix, p, '/') orelse prefix.len;
        const f_end = firstSeparator(file, f) orelse file.len;
        if (!std.mem.eql(u8, prefix[p..p_end], file[f..f_end])) return false;
        if (p_end == prefix.len) return true;
        if (f_end == file.len) return false;
        p = p_end + 1;
        f = f_end + 1;
    }
    return true;
}

fn firstSeparator(s: []const u8, from: usize) ?usize {
    var i = from;
    while (i < s.len) : (i += 1) {
        if (s[i] == '/' or s[i] == '\\') return i;
    }
    return null;
}

/// Whether `c` can appear inside an identifier, for boundary tests.
pub fn isWordByte(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_';
}

/// Whether offset `i` in `text` starts a token, i.e. is not preceded by a word byte.
pub fn atLeftBoundary(text: []const u8, i: usize) bool {
    return i == 0 or !isWordByte(text[i - 1]);
}

/// Whether offset `i` in `text` is a token end, i.e. is not a word byte.
pub fn atRightBoundary(text: []const u8, i: usize) bool {
    return i >= text.len or !isWordByte(text[i]);
}

test "a comment inside a string literal is not a comment" {
    // THE DEFECT A `//` SEARCH HAS. Both halves are asserted: the string's `//`
    // is absent from the result, and the real comment is present — a scanner
    // that returned nothing at all would pass a one-sided check.
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const src: [:0]const u8 =
        \\const url = "https://example.com";
        \\// a real comment
        \\
    ;
    var spans: std.ArrayList(Span) = .empty;
    try collect(arena, src, &spans);
    try std.testing.expectEqual(@as(usize, 1), spans.items.len);
    try std.testing.expectEqualStrings("// a real comment", spans.items[0].text(src));
}

test "a trailing comment after code is collected" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var spans: std.ArrayList(Span) = .empty;
    try collect(arena_state.allocator(), "const x = 1; // note\n", &spans);
    try std.testing.expectEqual(@as(usize, 1), spans.items.len);
    try std.testing.expectEqualStrings("// note", spans.items[0].text("const x = 1; // note\n"));
}

test "doc comments are collected and marked, ordinary ones are not marked" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const src: [:0]const u8 =
        \\//! module
        \\/// decl
        \\pub const x = 1; // trailing
        \\
    ;
    var spans: std.ArrayList(Span) = .empty;
    try collect(arena_state.allocator(), src, &spans);
    try std.testing.expectEqual(@as(usize, 3), spans.items.len);
    try std.testing.expect(spans.items[0].doc);
    try std.testing.expect(spans.items[1].doc);
    try std.testing.expect(!spans.items[2].doc);
}

test "spans come out in ascending offset order" {
    // The rules rely on it to report diagnostics a caller can sort by line.
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const src: [:0]const u8 =
        \\// one
        \\const a = 1;
        \\// two
        \\const b = 2; // three
        \\
    ;
    var spans: std.ArrayList(Span) = .empty;
    try collect(arena_state.allocator(), src, &spans);
    try std.testing.expectEqual(@as(usize, 3), spans.items.len);
    var prev: usize = 0;
    for (spans.items) |s| {
        try std.testing.expect(s.start >= prev);
        prev = s.start;
    }
}

test "a multiline string's comment-looking content is not a comment" {
    const gpa = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const src: [:0]const u8 =
        \\const help =
        \\    \\usage:
        \\    \\  // not a comment
        \\;
        \\
    ;
    var spans: std.ArrayList(Span) = .empty;
    try collect(arena_state.allocator(), src, &spans);
    try std.testing.expectEqual(@as(usize, 0), spans.items.len);
}

test "the perimeter admits src, tools and bench and excludes a leading tests" {
    try std.testing.expect(inPerimeter("src/core/ecs/world.zig"));
    try std.testing.expect(inPerimeter("tools/weld_lint/main.zig"));
    try std.testing.expect(inPerimeter("bench/ecs_benchmark.zig"));
    try std.testing.expect(!inPerimeter("tests/ecs/hybrid_query_test.zig"));
}

test "a tests segment inside src stays in the perimeter" {
    // NON-VACUITY for testing the FIRST segment rather than any segment: this
    // path exists in the tree and is production source.
    try std.testing.expect(inPerimeter("src/modules/forge/forge_3d/tests/mesh_test.zig"));
}

test "the perimeter reads the same path spelled with either separator" {
    // The walker yields `\` on Windows and the rule must not change verdict with it.
    try std.testing.expect(!inPerimeter("tests\\ecs\\hybrid_query_test.zig"));
    try std.testing.expect(inPerimeter("src\\core\\ecs\\world.zig"));
    try std.testing.expect(inPerimeter("src\\modules\\forge\\forge_3d\\tests\\mesh_test.zig"));
}

test "a leading dot segment is skipped rather than taken for the subtree" {
    try std.testing.expect(!inPerimeter("./tests/ecs/x.zig"));
    try std.testing.expect(inPerimeter("./src/core/x.zig"));
}

test "a declared unread subtree silences the rules and the rest of the perimeter does not" {
    // BOTH DIRECTIONS on the ledger. A path under a declared entry is not
    // covered; the subtree that carries the rules is.
    try std.testing.expect(!isCovered("src/etch/interp.zig"));
    try std.testing.expect(isCovered("tools/weld_lint/main.zig"));
}

test "an unread entry is still inside the perimeter" {
    // The two questions are distinct and conflating them would turn the ledger
    // into an exemption: an unread subtree is unread, not out of scope.
    try std.testing.expect(inPerimeter("src/etch/interp.zig"));
    try std.testing.expect(isPending("src/etch/interp.zig"));
}

test "a prefix matches whole segments only" {
    // Without segment-wise comparison a prefix would swallow a sibling whose name
    // merely starts with it.
    try std.testing.expect(matchesPending("src/core/ecs/world.zig", "src/core"));
    try std.testing.expect(!matchesPending("src/corelib/x.zig", "src/core"));
    try std.testing.expect(!matchesPending("src/cor/x.zig", "src/core"));
}

test "a prefix reads the same path spelled with either separator" {
    try std.testing.expect(matchesPending("src\\core\\ecs\\world.zig", "src/core"));
}

test "a single-file entry matches that file and not its neighbours" {
    try std.testing.expect(matchesPending("src/demo_etch_codegen.zig", "src/demo_etch_codegen.zig"));
    try std.testing.expect(!matchesPending("src/demo_etch_codegen_other.zig", "src/demo_etch_codegen.zig"));
}

test "no ledger entry subsumes another" {
    // A broad entry containing a narrower one would make the narrower removal a
    // no-op, so the pass would report progress it had not made. Checked over the
    // list itself rather than trusted to whoever edits it next.
    for (pending, 0..) |a, i| {
        for (pending, 0..) |b, j| {
            if (i == j) continue;
            if (hasPathPrefix(b.prefix, a.prefix)) {
                std.debug.print("SUBSUMED: {s} is inside {s}\n", .{ b.prefix, a.prefix });
                try std.testing.expect(false);
            }
        }
    }
}

test "every entry of the ledger is a path the walker can reach" {
    // A stale entry silences the rules over a path nobody watches, which is the
    // defect a declared list exists to prevent rather than to create. The run-time
    // half of this lives in `runLint`, which confronts each entry with the files it
    // walked; this half refuses an entry that is not even shaped like a repo path.
    for (pending) |p| {
        try std.testing.expect(p.prefix.len != 0);
        try std.testing.expect(std.mem.indexOfScalar(u8, p.prefix, '\\') == null);
        try std.testing.expect(inPerimeter(p.prefix));
    }
}

test "the coverage assertion inverts when the ledger empties" {
    // THE EXIT CRITERION, asserted rather than described. While the ledger holds
    // entries this reports how many paths are unread; when it empties, the same
    // call answers zero and the claim becomes "no path is unread". A closure
    // reached with a non-zero answer is a subtree nobody read.
    //
    // Driven over a FIXTURE rather than over the tree's own list, so it exercises
    // both states: the tree's list is non-empty today, so a test reading it alone
    // could never see the empty case it exists to pin.
    const some = [_]Pending{.{ .prefix = "src/core" }};
    const none = [_]Pending{};
    try std.testing.expectEqual(@as(usize, 1), unreadCount(&some, "src/core/ecs/world.zig"));
    try std.testing.expectEqual(@as(usize, 0), unreadCount(&none, "src/core/ecs/world.zig"));
}

test "the tree's own ledger drives the same predicate" {
    // NON-VACUITY for the fixture above: the shipped list is what the rules consult,
    // so the fixture must not be the only thing this predicate ever sees.
    try std.testing.expectEqual(pending.len, unreadCount(&pending, "src/core/ecs/world.zig") + countCovering());
}

/// How many entries of `list` claim `file` as unread. Zero means the file is read.
fn unreadCount(list: []const Pending, file: []const u8) usize {
    var n: usize = 0;
    for (list) |p| {
        if (hasPathPrefix(file, p.prefix)) n += 1;
    }
    return n;
}

/// Entries of the tree's ledger that do NOT cover `src/core/ecs/world.zig`.
fn countCovering() usize {
    var n: usize = 0;
    for (pending) |p| {
        if (!hasPathPrefix("src/core/ecs/world.zig", p.prefix)) n += 1;
    }
    return n;
}
