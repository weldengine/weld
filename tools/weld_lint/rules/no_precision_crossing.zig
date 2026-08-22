//! Rule `no_precision_crossing` — a forge production file may not narrow a float.
//!
//! `engine-physics-queries.md` §1.11.8 states that the world/solver precision boundary is
//! unique and is crossed by ONE named conversion point, and by it alone. Before M1.1.15 the
//! module carried four private helpers of identical semantics under two names — `widen`,
//! `convVec3` twice, `convQuat` — and two of the three vector copies had already diverged:
//! one short-circuited when the two scalars coincided and the others did not. They now all
//! route through `forge/api/precision.zig`.
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
//! **SCOPE, and the residual it leaves.** Production files under `src/modules/forge/`. Test
//! files are excluded, by path, and that is a deliberate exception to `no_float_reduce`'s
//! own argument against path allowlists. The reason they differ: a float reduction in a
//! bench CORRUPTS the measurement, so exempting a file there would hide a defect; a
//! `@floatCast` in a test is the assertion's own arithmetic — a test comparing a solver
//! value against a published `Transform` must narrow one of them to compare them at all, and
//! it is measuring the boundary rather than breaching it. Twenty-one such sites exist across
//! seven files. The residual is named and not hidden: a production-grade helper written
//! inside a test file escapes this rule.
//!
//! **THE ESCAPE.** `WELD_NOT_A_WORLD_CROSSING` on the site's own line, for a narrowing that
//! is genuinely not world ↔ solver. It has ZERO users today — measured, not assumed — so its
//! behaviour is established by this file's own tests and by nothing else. The marker is
//! accepted on the site's line only, deliberately narrower than `no_float_reduce`'s
//! line-above allowance: a `@floatCast` is a short expression, the claim fits beside it, and
//! a narrower escape cannot leak onto a neighbour.

const std = @import("std");
const diag = @import("../diagnostic.zig");

const name = "no_precision_crossing";

/// The module this rule governs, on both separators — the runner may pass absolute or
/// relative paths (`no_device_dispatch_outside_gal` precedent).
const module_posix = "src/modules/forge/";
const module_win = "src\\modules\\forge\\";

/// The one file allowed to narrow: the boundary itself.
const crossing_posix = "forge/api/precision.zig";
const crossing_win = "forge\\api\\precision.zig";

/// The per-site claim that a narrowing is not a world ↔ solver crossing.
const not_a_crossing_marker = "WELD_NOT_A_WORLD_CROSSING";

/// Hook called by `main.runLint` once per `.zig` file.
///
/// Tokenizes and flags every `@floatCast` builtin in a forge production file. Tokenizing
/// rather than substring matching is what keeps the rule off its own prose: this file names
/// `@floatCast` in the doc comment above, and a doc comment is one token.
pub fn check(
    arena: std.mem.Allocator,
    file: []const u8,
    source: [:0]const u8,
    out: *std.ArrayList(diag.Diagnostic),
) !void {
    if (!governs(file)) return;

    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const tok = tokenizer.next();
        if (tok.tag == .eof) break;
        if (tok.tag != .builtin) continue;
        if (!std.mem.eql(u8, source[tok.loc.start..tok.loc.end], "@floatCast")) continue;
        if (hasMarkerOnItsLine(source, tok.loc.start)) continue;

        const pos = diag.lineColFromOffset(source, tok.loc.start);
        try out.append(arena, .{
            .file = file,
            .line = pos.line,
            .col = pos.col,
            .rule = name,
            .message = "narrowing a float here spells a second precision boundary, which `engine-physics-queries.md` §1.11.8 makes unique — convert through `forge/api/precision.zig` (`cross.vec3ToWorld` / `cross.quatToWorld`), or declare a non-world narrowing with a `WELD_NOT_A_WORLD_CROSSING` comment on this line",
        });
    }
}

/// Whether this rule speaks about `file`: a forge file, in production, that is not the
/// boundary itself.
fn governs(file: []const u8) bool {
    const in_module = std.mem.indexOf(u8, file, module_posix) != null or
        std.mem.indexOf(u8, file, module_win) != null;
    if (!in_module) return false;

    if (std.mem.indexOf(u8, file, crossing_posix) != null) return false;
    if (std.mem.indexOf(u8, file, crossing_win) != null) return false;

    return !isTest(file);
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
    try check(arena_state.allocator(), path, source, &diags);
    defer diags.deinit(arena_state.allocator());
    return diags.items.len;
}

const prod = "src/modules/forge/forge_3d/body_manager.zig";

test "a narrowing in a forge production file is flagged" {
    try std.testing.expectEqual(@as(usize, 1), try countOn(prod, "const x: f32 = @floatCast(y);\n"));
    // Several on one line are each reported — a per-line count would under-report a
    // three-component conversion, which is the exact shape this rule meets in practice.
    try std.testing.expectEqual(@as(usize, 3), try countOn(
        prod,
        "const v = .{ @floatCast(a[0]), @floatCast(a[1]), @floatCast(a[2]) };\n",
    ));
}

test "the boundary file itself is allowed to narrow" {
    // Non-vacuity: the SAME source is flagged above under a production path, so what is
    // measured here is the path exemption and not a source the rule never flags.
    try std.testing.expectEqual(@as(usize, 0), try countOn(
        "src/modules/forge/api/precision.zig",
        "const x: f32 = @floatCast(y);\n",
    ));
}

test "test files are out of scope, in both spellings" {
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
}

test "the rule speaks only about the forge module" {
    try std.testing.expectEqual(@as(usize, 0), try countOn(
        "src/core/ecs/world.zig",
        "const x: f32 = @floatCast(y);\n",
    ));
}

test "the escape exempts the site it sits on, and only that one" {
    try std.testing.expectEqual(@as(usize, 0), try countOn(
        prod,
        "const x: f32 = @floatCast(y); // WELD_NOT_A_WORLD_CROSSING: two solver widths\n",
    ));
    // NON-VACUITY: two sites, one marker — exactly one must survive. A rule that exempted
    // the whole FILE would report zero here and would still pass the single-site test above.
    try std.testing.expectEqual(@as(usize, 1), try countOn(prod,
        \\const a: f32 = @floatCast(y); // WELD_NOT_A_WORLD_CROSSING
        \\const b: f32 = @floatCast(z);
        \\
    ));
    // And the marker does NOT reach down from the line above — deliberately narrower than
    // `no_float_reduce`'s allowance, so a claim cannot drift onto a neighbour.
    try std.testing.expectEqual(@as(usize, 1), try countOn(prod,
        \\// WELD_NOT_A_WORLD_CROSSING
        \\const b: f32 = @floatCast(z);
        \\
    ));
}

test "the rule is written on tokens, so prose naming the builtin is not a site" {
    try std.testing.expectEqual(@as(usize, 0), try countOn(
        prod,
        "/// Never write `@floatCast` outside the boundary.\nconst x = 1;\n",
    ));
    try std.testing.expectEqual(@as(usize, 0), try countOn(
        prod,
        "// @floatCast(a[0]) is what this replaces.\nconst x = 1;\n",
    ));
}

test "a different cast builtin is not a site" {
    // `@intCast` and `@as` narrow nothing across the precision boundary, and flagging them
    // would make the rule about casts in general rather than about that boundary.
    try std.testing.expectEqual(@as(usize, 0), try countOn(prod, "const x: u8 = @intCast(y);\n"));
    try std.testing.expectEqual(@as(usize, 0), try countOn(prod, "const x = @as(f32, y);\n"));
}
