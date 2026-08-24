//! Rule `no_precision_crossing` — a float may be narrowed at the precision boundary and
//! nowhere else in the perimeter this rule governs.
//!
//! `engine-physics-queries.md` §1.11.8 states that the world/solver precision boundary is
//! unique and is crossed by ONE named conversion point, and by it alone. Before M1.1.15 the
//! forge module carried four private helpers of identical semantics under two names —
//! `widen`, `convVec3` twice, `convQuat` — and two of the three vector copies had already
//! diverged: one short-circuited when the two scalars coincided and the others did not. They
//! now all route through `forge/api/precision.zig`.
//!
//! **WHY THE RULE EXISTS AT ALL, rather than the unification alone.** The four sites were
//! collapsed in one pass and nothing would stop the fifth. That is the same argument
//! `no_float_reduce` makes about its thirteenth site, and it is the reason a rule written
//! down without a check is an intention.
//!
//! **WHAT IS FLAGGED, and the asymmetry is the whole design.** `@floatCast` — the narrowing
//! direction, solver → world. The widening direction has NO token to flag: `f32` coerces to
//! `f64` implicitly, so a tokenizer sees nothing. What guards that half is the TYPE SYSTEM
//! under `-Dphysics_f64`: `Vec(3, f32)` and `Vec(3, f64)` are distinct struct types, so an
//! unrouted aggregate crossing does not compile at all on the six `f64` cells of the CI
//! matrix. The two halves together are the verification; neither alone is.
//!
//! At the default precision the world and solver scalars coincide, so the type system
//! proves nothing there — which is precisely why the `f64` leg is a matrix axis and not an
//! occasional local run.
//!
//! **THE PERIMETER, and why it is two directories and not one.** The diagnostic this rule
//! emits makes a statement about the ENGINE — that §1.11.8's boundary is unique — so a
//! control that looked at one module would be claiming more than it checks. §1.11.8 places
//! the boundary AT THE INTERFACE TIER, and `src/interfaces/` is where M1.1.26 writes the
//! adapter, which is conversion code by definition. It is governed here from the day the
//! directory exists rather than the day the freeze discovers the gap. The crossing POINT
//! lives in `forge/api/` for a dependency reason — `forge_3d` cannot import the interface
//! tier without inverting — and that reason says nothing about where the guard must look.
//!
//! Everything else in `src/` is out: `core`, `etch`, `foundation` and `asset_pipeline` carry
//! narrowings of their own that this milestone made no claim about, and widening the rule to
//! them would be a different rule with a different argument.
//!
//! **TEST FILES ARE OUT, and the residual is named.** A deliberate exception to
//! `no_float_reduce`'s own argument against path allowlists. The reason they differ: a float
//! reduction in a bench CORRUPTS the measurement, so exempting a file there would hide a
//! defect; a `@floatCast` in a test is the assertion's own arithmetic — a test comparing a
//! solver value against a published `Transform` must narrow one of them to compare them at
//! all, and it is measuring the boundary rather than breaching it. Twenty-one such sites
//! exist across seven files. The residual: a production-grade helper written inside a test
//! file escapes this rule.
//!
//! **THE ESCAPE IS DECLARED, NEVER SILENT.** `WELD_NOT_A_WORLD_CROSSING` on the site's own
//! line exempts that site — but only if the FILE also appears in `declared_escapes` below,
//! with a reason and an owner. A marker alone silences nothing. Without that pairing a guard
//! converges towards zero coverage through additions each of which is locally justified and
//! collectively invisible, which is precisely the failure `dead_tests` answers, in this same
//! binary, with a declared exclusion list and a bilateral control.
//!
//! The control is bilateral in the same sense: an escape used without a declaration is
//! reported at its site, and a declaration whose file was READ and carried no marker is
//! reported as stale. The list is EMPTY today — measured, not assumed: zero `@floatCast`
//! survives in the perimeter and the marker occurs nowhere in the tree outside this file's own
//! test sources. Zero is the cheapest moment in the project's life to install the mechanism,
//! and both directions are exercised by this file's tests rather than by the tree's silence.
//!
//! **THE STALE HALF FOLLOWS VISITED FILES, and that is what makes it correct under a partial
//! scan.** `lint` also accepts an explicit path list — the `pre-commit` hook passes staged
//! files — and a declaration whose file was not read says NOTHING: it is neither used nor
//! stale, because nobody looked. Two earlier forms tried to establish COMPLETENESS of the scan
//! instead, first from an empty argument list and then from a set of root names, and each
//! traded one wrong verdict for another; the second was defended with a claim that
//! canonicalising the paths was impossible at Zig 0.16, which was FALSE —
//! `std.process.currentPathAlloc` and `std.Io.Dir.realPathFileAbsoluteAlloc` both exist. The
//! question does not need asking: a per-file fact answers it with neither a false positive nor
//! a false negative, whatever the caller's spelling.
//!
//! The one residual that reasoning leaves is a declaration whose file has been DELETED — never
//! visited, hence never stale, hence immortal. Closed by testing that the declared path
//! exists.
const std = @import("std");
const diag = @import("../diagnostic.zig");

const name = "no_precision_crossing";

/// A directory this rule speaks about, in both separator spellings — the runner may pass
/// absolute or relative paths (`no_device_dispatch_outside_gal` precedent).
const GovernedPrefix = struct {
    posix: []const u8,
    win: []const u8,
    /// Why this directory is in the perimeter, so a future reader can judge an addition.
    why: []const u8,
};

/// The perimeter. Adding an entry is a claim that the boundary's uniqueness is checked
/// there, so each carries its reason.
const governed = [_]GovernedPrefix{
    .{
        .posix = "src/modules/forge/",
        .win = "src\\modules\\forge\\",
        .why = "the module that owns the crossing and held all four of the helpers it replaced",
    },
    .{
        .posix = "src/interfaces/",
        .win = "src\\interfaces\\",
        .why = "where `engine-physics-queries.md` §1.11.8 places the boundary, and where M1.1.26 " ++
            "writes the adapter — conversion code by definition",
    },
};

/// The one file allowed to narrow: the boundary itself.
const crossing_posix = "forge/api/precision.zig";
const crossing_win = "forge\\api\\precision.zig";

/// The per-site claim that a narrowing is not a world ↔ solver crossing. It only takes
/// effect in a file listed in `declared_escapes`.
const not_a_crossing_marker = "WELD_NOT_A_WORLD_CROSSING";

/// A site that deliberately narrows without crossing the world boundary, declared with its
/// reason and the milestone that owns it.
///
/// DECLARED, never silent — the distinction `dead_tests.Exclusion` draws between a known
/// debt and a hidden one, applied to the exemption of a guard rather than to a subtree.
pub const DeclaredEscape = struct {
    /// Path suffix identifying the file, in POSIX spelling.
    file: []const u8,
    reason: []const u8,
    owner: []const u8,
};

/// The tree's declared escapes. EMPTY, and that emptiness is the current state of the
/// perimeter rather than an unfinished list.
pub const declared_escapes = [_]DeclaredEscape{};

/// What the per-file pass observed, owned by the caller so no state survives between runs
/// and so the unit tests below cannot contaminate one another.
pub const Tally = struct {
    /// Whether the declaration's file was READ during this scan. A file nobody looked at
    /// cannot make its declaration stale.
    visited: [declared_escapes.len]bool = @splat(false),
    /// How many marked narrowings the declaration exempted.
    marked: [declared_escapes.len]u32 = @splat(0),
};

/// Hook called by `main.runLint` once per `.zig` file.
///
/// Tokenizes and flags every `@floatCast` builtin in a governed production file. Tokenizing
/// rather than substring matching is what keeps the rule off its own prose: this file names
/// `@floatCast` in the doc comment above, and a doc comment is one token.
pub fn check(
    arena: std.mem.Allocator,
    file: []const u8,
    source: [:0]const u8,
    out: *std.ArrayList(diag.Diagnostic),
    tally: *Tally,
) !void {
    // The visit is recorded BEFORE the perimeter test, deliberately: a declaration pointing at
    // a file this rule does not govern would otherwise never be visited, never be stale, and
    // sit there for good. Recorded, it is read and unmarked, hence reported.
    if (declaredIndexIn(&declared_escapes, file)) |i| {
        const seen: []bool = &tally.visited;
        seen[i] = true;
    }
    if (!governs(file)) return;

    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const tok = tokenizer.next();
        if (tok.tag == .eof) break;
        if (tok.tag != .builtin) continue;
        if (!std.mem.eql(u8, source[tok.loc.start..tok.loc.end], "@floatCast")) continue;

        const pos = diag.lineColFromOffset(source, tok.loc.start);

        if (hasMarkerOnItsLine(source, tok.loc.start)) {
            if (declaredIndexFor(file)) |i| {
                // Through a slice, not the array: `declared_escapes` is empty today, and
                // indexing a zero-length ARRAY is a compile error even on a branch that
                // cannot be reached. A slice moves the bound to run time, so the mechanism
                // compiles at a count of zero — which is the count it must be installed at.
                const hits: []u32 = &tally.marked;
                hits[i] += 1;
                continue;
            }
            // The marker is present and the file is not declared: the site is NOT exempt,
            // and saying so here rather than silently flagging it as an ordinary crossing is
            // what tells the author which of the two things to fix.
            try out.append(arena, .{
                .file = file,
                .line = pos.line,
                .col = pos.col,
                .rule = name,
                .message = "a `WELD_NOT_A_WORLD_CROSSING` marker exempts nothing on its own — add this file to `declared_escapes` in `tools/weld_lint/rules/no_precision_crossing.zig`, with a reason and an owning milestone, or route the narrowing through `forge/api/precision.zig`",
            });
            continue;
        }

        try out.append(arena, .{
            .file = file,
            .line = pos.line,
            .col = pos.col,
            .rule = name,
            .message = "narrowing a float here spells a second precision boundary, which `engine-physics-queries.md` §1.11.8 makes unique — convert through `forge/api/precision.zig` (`cross.vec3ToWorld` / `cross.quatToWorld`), or declare a non-world narrowing with a `WELD_NOT_A_WORLD_CROSSING` comment on this line AND an entry in `declared_escapes`",
        });
    }
}

/// The second half of the bilateral control, called once after the scan.
///
/// A declaration is stale when its file was READ and carried no marker, or when the file does
/// not exist at all. A file the scan never opened says nothing either way.
pub fn checkDeclarations(
    arena: std.mem.Allocator,
    io: std.Io,
    tally: *const Tally,
    out: *std.ArrayList(diag.Diagnostic),
) !void {
    try reportStale(arena, io, &declared_escapes, &tally.visited, &tally.marked, out);
}

/// The body of the control, over an explicit list. Split out for ONE reason: the tree's list
/// is empty, so a test driving `checkDeclarations` alone would pass against a function that
/// returned immediately. The tests below drive THIS — the shipped code — over a non-empty
/// fixture, instead of a mirror of it written in the test, which is a motif this repository
/// has already paid for once.
///
/// `checkDeclarations` is the only binding to the real list, so no caller can point the
/// tree's control at a fixture by accident.
fn reportStale(
    arena: std.mem.Allocator,
    io: std.Io,
    declared: []const DeclaredEscape,
    visited: []const bool,
    marked: []const u32,
    out: *std.ArrayList(diag.Diagnostic),
) !void {
    std.debug.assert(declared.len == visited.len and declared.len == marked.len);
    for (declared, visited, marked) |e, was_read, hits| {
        // THE DELETED-FILE RESIDUAL, and it is the reason this needs `io` at all. A declaration
        // whose file is gone is never visited, hence never stale by the rule above, hence
        // immortal. The path is repo-relative and the linter runs from the repository root —
        // the same assumption `scan.zig` makes with `Dir.cwd()`.
        const exists = blk: {
            _ = std.Io.Dir.cwd().statFile(io, e.file, .{}) catch break :blk false;
            break :blk true;
        };
        if (!exists) {
            try out.append(arena, .{
                .file = e.file,
                .line = 1,
                .col = 1,
                .rule = name,
                .message = "this `declared_escapes` entry names a file that does not exist — the declaration outlived what it exempted and should be removed",
            });
            continue;
        }
        // NOT VISITED SAYS NOTHING. `lint` accepts a partial file list, so a declaration whose
        // file this scan never opened is neither used nor stale: reporting it would be a guard
        // failing on correct input, and the fix a reader would reach for is deleting a
        // declaration that was doing its job.
        if (!was_read) continue;
        if (hits != 0) continue;
        try out.append(arena, .{
            .file = e.file,
            .line = 1,
            .col = 1,
            .rule = name,
            .message = "this `declared_escapes` entry exempts nothing — its file was read and carried no marked narrowing, so the declaration is stale and should be removed",
        });
    }
}

/// Whether this rule speaks about `file`: inside the perimeter, in production, and not the
/// boundary file itself.
fn governs(file: []const u8) bool {
    var inside = false;
    for (governed) |g| {
        if (std.mem.indexOf(u8, file, g.posix) != null or
            std.mem.indexOf(u8, file, g.win) != null)
        {
            inside = true;
            break;
        }
    }
    if (!inside) return false;

    if (std.mem.indexOf(u8, file, crossing_posix) != null) return false;
    if (std.mem.indexOf(u8, file, crossing_win) != null) return false;

    return !isTest(file);
}

/// The index of `file` in `declared_escapes`, or null. Matched on a path SUFFIX so an
/// absolute and a relative spelling of the same file agree, and SEPARATOR-INSENSITIVELY so a
/// POSIX-spelled declaration matches the `\\`-spelled path the runner passes on Windows.
///
/// The first version compared with `std.mem.endsWith` against a POSIX-spelled entry, which on
/// Windows can never match: the escape would silently stop exempting, the site would be
/// reported as an undeclared marker, and the tree would go red on one platform only. The
/// awareness already existed one function below — `isTest` handles `\\tests\\` beside
/// `/tests/` — and this one had lost it.
fn declaredIndexFor(file: []const u8) ?usize {
    return declaredIndexIn(&declared_escapes, file);
}

/// The lookup itself, over an explicit list. Split for the same reason as `reportStale`: the
/// tree's list is EMPTY, so this function never iterates and a test driving `declaredIndexFor`
/// could not tell a separator-aware match from a POSIX-only one. Measured — the first
/// counter-factual written for the separator fix reverted the comparison here and failed no
/// test at all, because the only test on it drove `endsWithPath` directly and proved the
/// helper correct without proving the call site used it.
fn declaredIndexIn(declared: []const DeclaredEscape, file: []const u8) ?usize {
    for (declared, 0..) |e, i| {
        if (endsWithPath(file, e.file)) return i;
    }
    return null;
}

/// Whether `path` ends with `suffix`, treating `/` and `\\` as the same separator. Compared
/// from the end so a longer absolute path matches a relative declaration.
fn endsWithPath(path: []const u8, suffix: []const u8) bool {
    if (suffix.len > path.len) return false;
    const tail = path[path.len - suffix.len ..];
    for (tail, suffix) |a, b| {
        if (a == b) continue;
        if (isSep(a) and isSep(b)) continue;
        return false;
    }
    return true;
}

fn isSep(c: u8) bool {
    return c == '/' or c == '\\';
}

/// Whether `file` is a test file — a `/tests/` directory component, or a `_test.zig` name.
/// Both forms occur in the tree and neither implies the other.
fn isTest(file: []const u8) bool {
    if (std.mem.indexOf(u8, file, "/tests/") != null) return true;
    if (std.mem.indexOf(u8, file, "\\tests\\") != null) return true;
    return std.mem.endsWith(u8, file, "_test.zig");
}

/// Whether the site at `offset` carries the escape marker on ITS OWN line. The line above is
/// deliberately not consulted: a shorter reach cannot leak a claim onto a neighbouring
/// statement, which is a failure `no_float_reduce` had to fix after the fact.
fn hasMarkerOnItsLine(source: []const u8, offset: usize) bool {
    const line_start = if (std.mem.lastIndexOfScalar(u8, source[0..offset], '\n')) |i| i + 1 else 0;
    const line_end = std.mem.indexOfScalarPos(u8, source, offset, '\n') orelse source.len;
    return std.mem.indexOf(u8, source[line_start..line_end], not_a_crossing_marker) != null;
}

// --- tests -------------------------------------------------------------------

/// Runs the rule over `source` as if it were `path`, and returns how many diagnostics it
/// produced. The path is a parameter because this rule is scoped by path, and a helper that
/// hard-coded one would leave the scoping itself unmeasured.
fn countOn(path: []const u8, source: [:0]const u8) !usize {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    var tally: Tally = .{};
    try check(arena_state.allocator(), path, source, &diags, &tally);
    defer diags.deinit(arena_state.allocator());
    return diags.items.len;
}

const forge_prod = "src/modules/forge/forge_3d/body_manager.zig";
const interface_prod = "src/interfaces/PhysicsModule.zig";

test "a narrowing in a governed production file is flagged" {
    try std.testing.expectEqual(@as(usize, 1), try countOn(forge_prod, "const x: f32 = @floatCast(y);\n"));
    // Several on one line are each reported — a per-line count would under-report a
    // three-component conversion, which is the exact shape this rule meets in practice.
    try std.testing.expectEqual(@as(usize, 3), try countOn(
        forge_prod,
        "const v = .{ @floatCast(a[0]), @floatCast(a[1]), @floatCast(a[2]) };\n",
    ));
}

test "the perimeter is the forge module AND the interface tier, and nothing else" {
    // THE INTERFACE TIER, which §1.11.8 names as the boundary's home and where M1.1.26
    // writes the adapter. The rule ignored it until F-F1: the directory was one milestone
    // old and held declarations only, so the gap would have been found by the freeze.
    try std.testing.expectEqual(@as(usize, 1), try countOn(interface_prod, "const x: f32 = @floatCast(y);\n"));
    try std.testing.expectEqual(@as(usize, 1), try countOn(forge_prod, "const x: f32 = @floatCast(y);\n"));

    // And NOT the rest of `src/`. These carry narrowings of their own that this rule makes
    // no claim about; flagging them would be a different rule with a different argument.
    // The identical source above is flagged, so what is measured here is the perimeter and
    // not a source the rule never reports.
    try std.testing.expectEqual(@as(usize, 0), try countOn("src/core/ecs/world.zig", "const x: f32 = @floatCast(y);\n"));
    try std.testing.expectEqual(@as(usize, 0), try countOn("src/foundation/math/vec.zig", "const x: f32 = @floatCast(y);\n"));
    try std.testing.expectEqual(@as(usize, 0), try countOn("src/etch/ecs_bridge.zig", "const x: f32 = @floatCast(y);\n"));
}

test "every path predicate holds in the Windows spelling too" {
    // THE MISSING HALF. The rule's perimeter, its boundary exemption and its test exclusion
    // were each measured in the POSIX spelling only, while the runner passes `\\`-separated
    // paths on Windows — so a rule that worked on two platforms and not on the third would
    // have passed every test above.
    try std.testing.expectEqual(@as(usize, 1), try countOn(
        "src\\modules\\forge\\forge_3d\\body_manager.zig",
        "const x: f32 = @floatCast(y);\n",
    ));
    try std.testing.expectEqual(@as(usize, 1), try countOn(
        "src\\interfaces\\PhysicsModule.zig",
        "const x: f32 = @floatCast(y);\n",
    ));
    try std.testing.expectEqual(@as(usize, 0), try countOn(
        "src\\modules\\forge\\api\\precision.zig",
        "const x: f32 = @floatCast(y);\n",
    ));
    try std.testing.expectEqual(@as(usize, 0), try countOn(
        "src\\modules\\forge\\forge_3d\\tests\\mesh_test.zig",
        "const x: f32 = @floatCast(y);\n",
    ));
    try std.testing.expectEqual(@as(usize, 0), try countOn(
        "src\\core\\ecs\\world.zig",
        "const x: f32 = @floatCast(y);\n",
    ));
}

test "the lookup itself is separator-aware, not merely the helper it calls" {
    // NON-VACUITY for the test below. `declared_escapes` is empty, so `declaredIndexFor`
    // never iterates and a POSIX-only comparison inside it is unreachable — a probe that
    // reverted it failed nothing. This drives the shipped lookup over a fixture, which is
    // what makes the separator awareness observable AT THE CALL SITE.
    const fixture = [_]DeclaredEscape{
        .{ .file = "forge_3d/body_manager.zig", .reason = "probe", .owner = "probe" },
    };
    try std.testing.expectEqual(@as(?usize, 0), declaredIndexIn(&fixture, "src/modules/forge/forge_3d/body_manager.zig"));
    try std.testing.expectEqual(@as(?usize, 0), declaredIndexIn(&fixture, "src\\modules\\forge\\forge_3d\\body_manager.zig"));
    try std.testing.expectEqual(@as(?usize, null), declaredIndexIn(&fixture, "src/modules/forge/forge_3d/mesh.zig"));
}

test "a declared escape matches whichever separator the runner used" {
    // The declaration is written in POSIX spelling by convention; the path is not under this
    // rule's control. Both directions are measured, and the mixed case is what a naive
    // `endsWith` fails.
    try std.testing.expect(endsWithPath("src/modules/forge/forge_3d/body_manager.zig", "forge_3d/body_manager.zig"));
    try std.testing.expect(endsWithPath("src\\modules\\forge\\forge_3d\\body_manager.zig", "forge_3d/body_manager.zig"));
    try std.testing.expect(endsWithPath("src/modules/forge/forge_3d/body_manager.zig", "forge_3d\\body_manager.zig"));
    // NON-VACUITY: it is a suffix match on path components and not a substring test that
    // says yes to everything.
    try std.testing.expect(!endsWithPath("src/modules/forge/forge_3d/mesh.zig", "forge_3d/body_manager.zig"));
    try std.testing.expect(!endsWithPath("body_manager.zig", "forge_3d/body_manager.zig"));
}

test "the boundary file itself is allowed to narrow" {
    try std.testing.expectEqual(@as(usize, 0), try countOn(
        "src/modules/forge/api/precision.zig",
        "const x: f32 = @floatCast(y);\n",
    ));
}

test "test files are out of scope, in both spellings and in both governed directories" {
    try std.testing.expectEqual(@as(usize, 0), try countOn(
        "src/modules/forge/forge_3d/tests/mesh_test.zig",
        "const x: f32 = @floatCast(y);\n",
    ));
    // `_test.zig` outside a `tests/` directory — the two forms both occur in the tree and
    // neither implies the other, so both are measured.
    try std.testing.expectEqual(@as(usize, 0), try countOn(
        "tests/physics/transform_sync_test.zig",
        "const x: f32 = @floatCast(y);\n",
    ));
    try std.testing.expectEqual(@as(usize, 0), try countOn(
        "src/interfaces/PhysicsModule_test.zig",
        "const x: f32 = @floatCast(y);\n",
    ));
}

test "an undeclared marker exempts nothing, and says which of the two things to fix" {
    // The site is still reported — with the OTHER message, because the author who wrote a
    // marker has already decided the narrowing is legitimate and needs to be told that the
    // declaration is what is missing, not the conversion.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    defer diags.deinit(arena_state.allocator());
    var tally: Tally = .{};
    try check(
        arena_state.allocator(),
        forge_prod,
        "const x: f32 = @floatCast(y); // WELD_NOT_A_WORLD_CROSSING: two solver widths\n",
        &diags,
        &tally,
    );
    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    try std.testing.expect(std.mem.indexOf(u8, diags.items[0].message, "declared_escapes") != null);
    try std.testing.expect(std.mem.indexOf(u8, diags.items[0].message, "exempts nothing on its own") != null);
}

test "the marker's per-site reach is unchanged, and it does not reach down a line" {
    // Two sites, one marker: with the escape undeclared BOTH are now reported, so what this
    // measures is the reach and not the exemption. The counts differ by exactly the marked
    // site's message, checked above.
    try std.testing.expectEqual(@as(usize, 2), try countOn(forge_prod,
        \\const a: f32 = @floatCast(y); // WELD_NOT_A_WORLD_CROSSING
        \\const b: f32 = @floatCast(z);
        \\
    ));
    // The line above is deliberately out of reach — narrower than `no_float_reduce`'s
    // allowance, so a claim cannot drift onto a neighbour.
    try std.testing.expectEqual(@as(usize, 1), try countOn(forge_prod,
        \\// WELD_NOT_A_WORLD_CROSSING
        \\const b: f32 = @floatCast(z);
        \\
    ));
}

test "the declaration list is empty, and the control runs on it" {
    try std.testing.expectEqual(@as(usize, 0), declared_escapes.len);

    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    defer diags.deinit(arena_state.allocator());
    const tally: Tally = .{};
    try checkDeclarations(arena_state.allocator(), threaded.io(), &tally, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
}

test "stale follows the VISITED file, and a missing file is reported whatever the visit" {
    // NON-VACUITY for the test above, which runs on an EMPTY list and would pass against a
    // control that returned immediately. This drives `reportStale` — the shipped body, not a
    // mirror of it — over a non-empty fixture, on all four combinations that matter.
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // `build.zig` exists at the repository root, where the linter runs; the second path does
    // not exist anywhere, which is the point of it.
    const present = [_]DeclaredEscape{.{ .file = "build.zig", .reason = "a probe", .owner = "none" }};
    const missing = [_]DeclaredEscape{.{ .file = "no_such_file_xyz.zig", .reason = "a probe", .owner = "none" }};

    const Case = struct {
        fn count(
            alloc: std.mem.Allocator,
            handle: std.Io,
            declared: []const DeclaredEscape,
            visited: bool,
            marked: u32,
        ) !usize {
            var arena_state = std.heap.ArenaAllocator.init(alloc);
            defer arena_state.deinit();
            var diags: std.ArrayList(diag.Diagnostic) = .empty;
            defer diags.deinit(arena_state.allocator());
            try reportStale(
                arena_state.allocator(),
                handle,
                declared,
                &.{visited},
                &.{marked},
                &diags,
            );
            return diags.items.len;
        }
    };

    // READ and unmarked: stale. This is the case the control exists for.
    try std.testing.expectEqual(@as(usize, 1), try Case.count(gpa, io, &present, true, 0));
    // READ and marked: silent, the declaration is doing its job.
    try std.testing.expectEqual(@as(usize, 0), try Case.count(gpa, io, &present, true, 3));
    // NOT READ: silent. A partial scan says less, never something false — this is the whole
    // reason the control follows visits instead of trying to establish completeness.
    try std.testing.expectEqual(@as(usize, 0), try Case.count(gpa, io, &present, false, 0));
    // MISSING FILE: reported even unvisited, which is the residual that rule leaves — a
    // declaration whose file is gone is never visited, hence would be immortal.
    try std.testing.expectEqual(@as(usize, 1), try Case.count(gpa, io, &missing, false, 0));
}

test "the rule is written on tokens, so prose naming the builtin is not a site" {
    try std.testing.expectEqual(@as(usize, 0), try countOn(
        forge_prod,
        "/// Never write `@floatCast` outside the boundary.\nconst x = 1;\n",
    ));
    try std.testing.expectEqual(@as(usize, 0), try countOn(
        forge_prod,
        "// @floatCast(a[0]) is what this replaces.\nconst x = 1;\n",
    ));
}

test "a different cast builtin is not a site" {
    // `@intCast` and `@as` narrow nothing across the precision boundary, and flagging them
    // would make the rule about casts in general rather than about that boundary.
    try std.testing.expectEqual(@as(usize, 0), try countOn(forge_prod, "const x: u8 = @intCast(y);\n"));
    try std.testing.expectEqual(@as(usize, 0), try countOn(forge_prod, "const x = @as(f32, y);\n"));
}
