//! Rules `comment_tags` and `comment_phase` — the shape of a tag, and the
//! absence of a phase mention outside one.
//!
//! Normative at `engine-zig-conventions.md` §12. Five forms, parenthesis
//! mandatory except for the bare safety marker, and no identifier inside a
//! parenthesis: the project has no tracker, so a debt is found by the words
//! written in it and an identifier there goes stale instead.
//!
//! **WHAT `comment_tags` DOES NOT DO, and why.** It does not police which words
//! may open a comment. The convention enumerates five forms and proscribes no
//! other vocabulary, so a word like a note or a review used in a sentence is
//! prose and must not fire. What the rule does police is the SHAPE of the five,
//! wherever they appear.
//!
//! It fires on a bare tag word used as a noun in prose, and that is deliberate
//! rather than tolerated: writing one bare is exactly the ambiguity the mandatory
//! parenthesis removes.
//!
//! **`comment_phase` IS CASE-SENSITIVE ON TWO SPELLINGS, and the third is the
//! reason.** A capitalised or upper-case phase mention is the project's phase, a
//! deferral in prose with no detectable expiry: it survives the implementation it
//! announced. An all-lower-case one is the ordinary noun — a two-phase commit, a
//! phase of an algorithm — and is not a deferral. A case-insensitive rule would
//! impose a vocabulary instead of detecting a debt.
//!
//! The exemption is the parenthesised argument of a tag: what is temporary
//! carries a tag, and a tag may name the phase that will remove it.
//!
//! Perimeter, its `tests/` exclusion and the declared unread subtrees:
//! `comment_scan.isCovered`.

const std = @import("std");
const diag = @import("../diagnostic.zig");
const comment_scan = @import("../comment_scan.zig");
const comment_identifiers = @import("comment_identifiers.zig");

const tags_name = "comment_tags";
const phase_name = "comment_phase";

/// The four tag words. The safety marker is the only one whose bare form is
/// legal, so it carries a flag rather than living in a second list.
const Tag = struct {
    word: []const u8,
    bare_ok: bool,
};

const tags = [_]Tag{
    .{ .word = "TODO", .bare_ok = false },
    .{ .word = "FIXME", .bare_ok = false },
    .{ .word = "HACK", .bare_ok = false },
    .{ .word = "SAFETY", .bare_ok = true },
};

/// A parenthesised tag argument, as a byte range within one comment.
const ArgSpan = struct {
    /// Offset of the byte after the opening parenthesis.
    from: usize,
    /// Offset of the closing parenthesis.
    to: usize,
};

/// Hook called by `main.runLint` once per `.zig` file.
pub fn check(
    arena: std.mem.Allocator,
    file: []const u8,
    source: [:0]const u8,
    out: *std.ArrayList(diag.Diagnostic),
) !void {
    if (!comment_scan.isCovered(file)) return;
    // A generated file's comments belong to its emitter — see
    // `comment_scan.isGenerated`. Both bounds this rule carries, the tag form
    // and the phase mention, are the emitter's to write.
    if (comment_scan.isGenerated(source)) return;

    var spans: std.ArrayList(comment_scan.Span) = .empty;
    defer spans.deinit(arena);
    try comment_scan.collect(arena, source, &spans);

    var args: std.ArrayList(ArgSpan) = .empty;
    defer args.deinit(arena);

    for (spans.items) |span| {
        const text = span.text(source);
        args.clearRetainingCapacity();
        try checkTags(arena, file, source, span.start, text, &args, out);
        try checkPhase(arena, file, source, span.start, text, args.items, out);
    }
}

fn checkTags(
    arena: std.mem.Allocator,
    file: []const u8,
    source: [:0]const u8,
    base: usize,
    text: []const u8,
    args: *std.ArrayList(ArgSpan),
    out: *std.ArrayList(diag.Diagnostic),
) !void {
    var i: usize = 0;
    while (i < text.len) {
        if (!comment_scan.atLeftBoundary(text, i)) {
            i += 1;
            continue;
        }
        const tag = matchTag(text, i) orelse {
            i += 1;
            continue;
        };
        const after = i + tag.word.len;
        if (!comment_scan.atRightBoundary(text, after)) {
            i += 1;
            continue;
        }
        i = after;

        if (after >= text.len or text[after] != '(') {
            if (!tag.bare_ok) {
                try emit(arena, file, source, base + i - tag.word.len, tags_name, out, try std.fmt.allocPrint(
                    arena,
                    "tag `{s}` needs a parenthesis naming what is missing",
                    .{tag.word},
                ));
            }
            continue;
        }

        const close = matchingParen(text, after) orelse {
            try emit(arena, file, source, base + after, tags_name, out, try std.fmt.allocPrint(
                arena,
                "tag `{s}` has an unterminated parenthesis",
                .{tag.word},
            ));
            continue;
        };
        const arg = text[after + 1 .. close];
        try args.append(arena, .{ .from = after + 1, .to = close });
        if (comment_identifiers.firstIn(arg)) |m| {
            try emit(arena, file, source, base + after + 1, tags_name, out, try std.fmt.allocPrint(
                arena,
                "tag `{s}` names the identifier `{s}`; name the thing textually instead",
                .{ tag.word, arg[0..@min(arg.len, m.len + 40)] },
            ));
        }
        i = close + 1;
    }
}

fn checkPhase(
    arena: std.mem.Allocator,
    file: []const u8,
    source: [:0]const u8,
    base: usize,
    text: []const u8,
    args: []const ArgSpan,
    out: *std.ArrayList(diag.Diagnostic),
) !void {
    var i: usize = 0;
    while (i < text.len) {
        if (!comment_scan.atLeftBoundary(text, i)) {
            i += 1;
            continue;
        }
        const n = matchPhase(text, i) orelse {
            i += 1;
            continue;
        };
        if (!insideAnyArg(args, i)) {
            try emit(arena, file, source, base + i, phase_name, out, "a phase mention in a comment; what is temporary carries a tag, " ++
                "what is not is written in the present");
        }
        i += n;
    }
}

fn emit(
    arena: std.mem.Allocator,
    file: []const u8,
    source: [:0]const u8,
    offset: usize,
    rule: []const u8,
    out: *std.ArrayList(diag.Diagnostic),
    message: []const u8,
) !void {
    const pos = diag.lineColFromOffset(source, offset);
    try out.append(arena, .{
        .file = file,
        .line = pos.line,
        .col = pos.col,
        .rule = rule,
        .message = message,
    });
}

fn matchTag(text: []const u8, i: usize) ?Tag {
    for (tags) |t| {
        if (i + t.word.len <= text.len and std.mem.eql(u8, text[i .. i + t.word.len], t.word)) return t;
    }
    return null;
}

/// Offset of the parenthesis closing the one at `open`, or null.
///
/// Nesting is counted rather than assumed absent: a tag naming a call would
/// otherwise close on the inner parenthesis and hand a truncated argument to the
/// identifier check.
fn matchingParen(text: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var i = open;
    while (i < text.len) : (i += 1) {
        if (text[i] == '(') depth += 1;
        if (text[i] == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

/// Length of a phase mention starting at `i`, or null.
///
/// The word, then a SEPARATOR, then a digit. The separator is whitespace, a
/// hyphen, or whitespace then a hyphen, so `Phase <n>`, the pre-zero archive's
/// `Phase -<n>` and the compound `Phase-<n>` are one mention in three
/// orthographies. The compound escaped this predicate while the separator had
/// to BEGIN with whitespace, and 43 of them were standing in the tree when that
/// was measured. With no separator at all there is no mention.
///
/// The digits are written `<n>` above on purpose: spelled out, this doc comment
/// would be a phase mention and the rule would report itself.
fn matchPhase(text: []const u8, i: usize) ?usize {
    const word = if (hasPrefix(text, i, "Phase"))
        "Phase"
    else if (hasPrefix(text, i, "PHASE"))
        "PHASE"
    else
        return null;
    var j = i + word.len;
    if (!comment_scan.atRightBoundary(text, j)) return null;
    const sep_start = j;
    while (j < text.len and (text[j] == ' ' or text[j] == '\t')) j += 1;
    if (j < text.len and text[j] == '-') j += 1;
    if (j == sep_start) return null;
    if (j >= text.len or text[j] < '0' or text[j] > '9') return null;
    j += 1;
    return j - i;
}

fn insideAnyArg(args: []const ArgSpan, i: usize) bool {
    for (args) |a| {
        if (i >= a.from and i < a.to) return true;
    }
    return false;
}

fn hasPrefix(text: []const u8, i: usize, needle: []const u8) bool {
    return i + needle.len <= text.len and std.mem.eql(u8, text[i .. i + needle.len], needle);
}

/// Diagnostics `check` produces for `source` at `file`, filtered to `rule`.
fn countRule(rule: []const u8, file: []const u8, source: [:0]const u8) !usize {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    try check(arena, file, source, &diags);
    var n: usize = 0;
    for (diags.items) |d| {
        if (std.mem.eql(u8, d.rule, rule)) n += 1;
    }
    return n;
}

fn tagCount(source: [:0]const u8) !usize {
    return countRule(tags_name, "tools/weld_lint/x.zig", source);
}

fn phaseCount(source: [:0]const u8) !usize {
    return countRule(phase_name, "tools/weld_lint/x.zig", source);
}

test "a named tag is accepted and a bare one is rejected" {
    try std.testing.expectEqual(@as(usize, 0), try tagCount("// TODO(soft-body LOD): only the highest is built\n"));
    try std.testing.expectEqual(@as(usize, 1), try tagCount("// TODO: only the highest is built\n"));
}

test "the bare safety marker is accepted and its parenthesised form too" {
    // The one form whose bare spelling is legal, and the reason it carries a
    // flag rather than a second list.
    try std.testing.expectEqual(@as(usize, 0), try tagCount("// SAFETY: the caller holds the registry\n"));
    try std.testing.expectEqual(@as(usize, 0), try tagCount("// SAFETY(no_float_reduce): explicit left fold\n"));
}

test "an identifier inside a tag parenthesis is rejected" {
    // Written as source data: the tree has no tracker, so a name is what makes a
    // debt findable and an identifier there goes stale at a renumbering.
    try std.testing.expectEqual(@as(usize, 1), try tagCount("// TODO(M1.D.18): fix the thing\n"));
    try std.testing.expectEqual(@as(usize, 1), try tagCount("// FIXME(G7): wrong under replay\n"));
    try std.testing.expectEqual(@as(usize, 0), try tagCount("// FIXME(sleep detection under rollback): wrong under replay\n"));
}

test "the other three named forms need their parenthesis" {
    try std.testing.expectEqual(@as(usize, 1), try tagCount("// FIXME: wrong\n"));
    try std.testing.expectEqual(@as(usize, 1), try tagCount("// HACK: work around it\n"));
    try std.testing.expectEqual(@as(usize, 0), try tagCount("// HACK(vendor driver descriptor pool reset): drop when fixed\n"));
}

test "an unterminated parenthesis is reported rather than swallowed" {
    try std.testing.expectEqual(@as(usize, 1), try tagCount("// TODO(soft-body LOD: unterminated\n"));
}

test "a nested parenthesis does not truncate the argument" {
    // Without depth counting the argument would end at the inner close and the
    // identifier past it would go unseen.
    try std.testing.expectEqual(@as(usize, 1), try tagCount("// TODO(the call foo(x) then M1.B): fix\n"));
    try std.testing.expectEqual(@as(usize, 0), try tagCount("// TODO(the call foo(x) then the rest): fix\n"));
}

test "a tag word inside a longer word is not a tag" {
    try std.testing.expectEqual(@as(usize, 0), try tagCount("// TODOS are tracked elsewhere\n"));
    try std.testing.expectEqual(@as(usize, 0), try tagCount("// the SAFETYNET module\n"));
}

test "a capitalised phase mention is rejected" {
    try std.testing.expectEqual(@as(usize, 1), try phaseCount("// Phase 2 will do X\n"));
    try std.testing.expectEqual(@as(usize, 1), try phaseCount("// PHASE 1 transfer note\n"));
    try std.testing.expectEqual(@as(usize, 1), try phaseCount("// the pre-zero Phase -1 archive\n"));
    // The COMPOUND form is the same mention and was escaping: the separator used to
    // have to begin with whitespace, so a hyphen alone fell through.
    try std.testing.expectEqual(@as(usize, 1), try phaseCount("// this `const` is the Phase-1 default\n"));
    try std.testing.expectEqual(@as(usize, 1), try phaseCount("// PHASE-2 lowering\n"));
    // …and a separator is still REQUIRED, so a bare compound word is not a mention.
    try std.testing.expectEqual(@as(usize, 0), try phaseCount("// Phase1 is not a spelling anyone uses\n"));
    try std.testing.expectEqual(@as(usize, 0), try phaseCount("// a Phase-locked loop\n"));
}

test "a lower-case phase is ordinary language and is accepted" {
    // Four real occurrences in the tree are of this shape and none is a
    // deferral; catching them would impose a vocabulary.
    try std.testing.expectEqual(@as(usize, 0), try phaseCount("// two-phase commit, phase 1 spawns first\n"));
    try std.testing.expectEqual(@as(usize, 0), try phaseCount("// phase 2 of the algorithm\n"));
}

test "a phase word with no digit is not a mention" {
    try std.testing.expectEqual(@as(usize, 0), try phaseCount("// the Phase of the moon\n"));
    try std.testing.expectEqual(@as(usize, 0), try phaseCount("// Phased rollout\n"));
}

test "a phase mention inside a tag parenthesis is exempt" {
    // BOTH DIRECTIONS on the exemption: exempt inside, reported outside, on the
    // same words — otherwise the silence would prove nothing about the exemption.
    try std.testing.expectEqual(@as(usize, 0), try phaseCount("// TODO(Phase 2 rollout): handle wraparound\n"));
    try std.testing.expectEqual(@as(usize, 1), try phaseCount("// Phase 2 rollout: handle wraparound\n"));
}

test "the tag rule accepts a well-formed line the identifier rule also accepts" {
    // The paired case: a tag naming a feature textually, on a line that
    // must be clean under both rules at once.
    try std.testing.expectEqual(@as(usize, 0), try tagCount("// TODO(soft-body LOD)\n"));
    try std.testing.expectEqual(@as(usize, 0), try phaseCount("// TODO(soft-body LOD)\n"));
}

test "both rules speak on a read file and are silent on the two silenced kinds" {
    const src: [:0]const u8 = "// TODO: and Phase 2\n";
    try std.testing.expectEqual(@as(usize, 1), try countRule(tags_name, "tools/weld_lint/x.zig", src));
    try std.testing.expectEqual(@as(usize, 1), try countRule(phase_name, "tools/weld_lint/x.zig", src));
    try std.testing.expectEqual(@as(usize, 0), try countRule(tags_name, "tests/x.zig", src));
    var buf: [256]u8 = undefined;
    if (comment_scan.anUnreadExample(&buf)) |unread| {
        try std.testing.expectEqual(@as(usize, 0), try countRule(phase_name, unread, src));
    }
    try std.testing.expectEqual(@as(usize, 0), try countRule(tags_name, "bench/x.zig", src));
}

test "a phase mention in a string literal is not reported" {
    try std.testing.expectEqual(@as(usize, 0), try phaseCount("const s = \"Phase 2\";\n"));
}
