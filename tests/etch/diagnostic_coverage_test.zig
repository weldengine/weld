//! One test per diagnostic code that the type-checker emits and that nothing
//! asserted. The deliverable is coverage, not a count.
//!
//! Each test asserts its code is PRESENT. That direction is the whole point:
//! such a test goes red the day the checker stops emitting that code, which a
//! test asserting absence cannot do.
//!
//! WHAT THIS FILE DOES NOT COVER, and why none of it can be covered the same
//! way. Of the 203 declared codes, 138 already carry an assertion elsewhere and
//! 33 land here. The remaining 32 cannot have a test that reddens, because
//! there is nothing to stop emitting:
//!
//!   E0420 E0421 E1544 E1549 E1563 E1610 E1611 E1622 E1642 E1643 E1660 E1662
//!   E1663 E1667 E1668 E1688 E1691 E1692 E1694 E1700 E1701 E1724 E1725 E1748
//!   E1796 E1802 E1807 E1902 W1682 W1790 W1801
//!
//! appear ONLY in `src/etch/diagnostics.zig` — declared, referenced nowhere
//! else in the tree. `E1902` is the one with a reference, in the `.d.etch`
//! drift tool, as a report LABEL rather than an emitted diagnostic.
//!
//! `E0217` is the 32nd, left off that list only because the last test here
//! names it, to assert its absence.
//!
//! AND WHAT THE COUNT ITSELF DOES NOT SEE. The 138 is a STATIC reading of which
//! tests name which code, and it is not verified per code: a test may name a
//! code it does not exercise. That reading was wrong three times here — it
//! called E1208, E1209 and E1215 uncovered when inline tests in `interp.zig`
//! do cover them, through a helper whose parameter is `anytype` and therefore
//! invisible to any search over signatures. What settled it was mutation:
//! making the checker swallow a code and observing which tests go red. Only
//! the 33 below have been verified that way.

const std = @import("std");
const weld_etch = @import("weld_etch");

const Diagnostic = weld_etch.Diagnostic;
const DiagnosticCode = weld_etch.diagnostics.DiagnosticCode;

/// Parse + type-check one source, owning everything the two produce.
const Checked = struct {
    ast: weld_etch.parser.ParseResult,
    diags: std.ArrayListUnmanaged(Diagnostic),

    fn deinit(self: *Checked, gpa: std.mem.Allocator) void {
        for (self.diags.items) |*d| d.deinit(gpa);
        self.diags.deinit(gpa);
        self.ast.deinit(gpa);
    }
};

fn check(gpa: std.mem.Allocator, source: []const u8) !Checked {
    var pr = try weld_etch.parseSource(gpa, source);
    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    weld_etch.typeCheck(gpa, &pr.ast, &diags) catch {};
    return .{ .ast = pr, .diags = diags };
}

fn expectAnyCode(diags: []const Diagnostic, code: DiagnosticCode) !void {
    for (diags) |d| if (d.code == code) return;
    return error.DiagnosticCodeNotEmitted;
}

/// `true` when the source parsed with no diagnostics of its own. A program that
/// does not parse never reaches the checker, so a test whose target code is
/// absent AND whose parse was dirty is measuring its own syntax error.
fn parsedClean(c: Checked) bool {
    return c.ast.diagnostics.len == 0;
}

// ── harness control ──────────────────────────────────────
//
// It asserts a code this file does NOT own — `E0101` is already pinned in
// `src/etch/types.zig` — and that is deliberate. Every other test here can fail
// for two unrelated reasons: the program does not trigger its code, or this
// file cannot observe a code at all. This one separates them. If it is the only
// red, the programs are wrong; if it is red with everything else, the harness
// is.

test "harness control: this file can observe an emitted code at all" {
    const gpa = std.testing.allocator;
    var c = try check(gpa,
        \\component Health { current: float = 100.0 }
        \\component Health { max: float = 100.0 }
    );
    defer c.deinit(gpa);
    try std.testing.expect(parsedClean(c));
    try expectAnyCode(c.diags.items, .duplicate_symbol);
}

// ── cases ───────────────────────────────────────────────

// The span is the CALL site, and the trait walk runs only after inherent lookup
// fails — hence no inherent `impl N`.
test "E0211 ambiguous trait method" {
    const gpa = std.testing.allocator;
    var c = try check(gpa,
        \\struct N {
        \\  v: int = 0
        \\}
        \\
        \\trait A {
        \\  fn tag(self) -> int
        \\}
        \\
        \\trait B {
        \\  fn tag(self) -> int
        \\}
        \\
        \\impl A for N {
        \\  fn tag(self) -> int {
        \\    1
        \\  }
        \\}
        \\
        \\impl B for N {
        \\  fn tag(self) -> int {
        \\    2
        \\  }
        \\}
        \\
        \\fn pick(n: N) -> int {
        \\  n.tag()
        \\}
    );
    defer c.deinit(gpa);
    try std.testing.expect(parsedClean(c));
    try expectAnyCode(c.diags.items, .ambiguous_trait_method);
}

// Any `while` in a walked stage body is the violation: the arm is unconditional,
// not a bound analysis.
test "E0400 shader mode violation" {
    const gpa = std.testing.allocator;
    var c = try check(gpa,
        \\shader U {
        \\  fragment() -> Color {
        \\    while true { }
        \\  }
        \\}
    );
    defer c.deinit(gpa);
    try std.testing.expect(parsedClean(c));
    try expectAnyCode(c.diags.items, .shader_mode_violation);
}

test "E1600 effect empty emitters" {
    const gpa = std.testing.allocator;
    var c = try check(gpa,
        \\effect Puff {
        \\}
    );
    defer c.deinit(gpa);
    try std.testing.expect(parsedClean(c));
    try expectAnyCode(c.diags.items, .effect_empty_emitters);
}

test "E1601 duplicate emitter name" {
    const gpa = std.testing.allocator;
    var c = try check(gpa,
        \\effect Puff {
        \\  emitter A {
        \\  }
        \\  emitter A {
        \\  }
        \\}
    );
    defer c.deinit(gpa);
    try std.testing.expect(parsedClean(c));
    try expectAnyCode(c.diags.items, .duplicate_emitter_name);
}

test "E1604 emitter ref not found" {
    const gpa = std.testing.allocator;
    var c = try check(gpa,
        \\effect Puff {
        \\  emitter A {
        \\  }
        \\  on B.hit {
        \\  }
        \\}
    );
    defer c.deinit(gpa);
    try std.testing.expect(parsedClean(c));
    try expectAnyCode(c.diags.items, .emitter_ref_not_found);
}

test "E1620 widget empty tree" {
    const gpa = std.testing.allocator;
    var c = try check(gpa,
        \\widget W() {}
    );
    defer c.deinit(gpa);
    try std.testing.expect(parsedClean(c));
    try expectAnyCode(c.diags.items, .widget_empty_tree);
}

test "E1621 widget screen worldspace conflict" {
    const gpa = std.testing.allocator;
    var c = try check(gpa,
        \\@screen
        \\@worldspace
        \\widget W() {
        \\  t()
        \\}
    );
    defer c.deinit(gpa);
    try std.testing.expect(parsedClean(c));
    try expectAnyCode(c.diags.items, .widget_screen_worldspace_conflict);
}

test "E1680 anim graph empty states" {
    const gpa = std.testing.allocator;
    var c = try check(gpa,
        \\anim_graph G {
        \\}
    );
    defer c.deinit(gpa);
    try std.testing.expect(parsedClean(c));
    try expectAnyCode(c.diags.items, .anim_graph_empty_states);
}

test "E1681 anim duplicate state name" {
    const gpa = std.testing.allocator;
    var c = try check(gpa,
        \\anim_graph G {
        \\  state A { clip: "a" transition -> A }
        \\  state A { clip: "a" transition -> A }
        \\}
    );
    defer c.deinit(gpa);
    try std.testing.expect(parsedClean(c));
    try expectAnyCode(c.diags.items, .anim_duplicate_state_name);
}

// `body_count` counts clip / blend / matching props only. A transition is an edge
// and does not count, so a state holding one has no body. The transition is here
// to keep W1681 quiet.
test "E1682 anim state body missing" {
    const gpa = std.testing.allocator;
    var c = try check(gpa,
        \\anim_graph G {
        \\  state A { transition -> A }
        \\}
    );
    defer c.deinit(gpa);
    try std.testing.expect(parsedClean(c));
    try expectAnyCode(c.diags.items, .anim_state_body_missing);
}

// Else-chained off the `body_count == 0` test, so this and E1682 can never both
// fire.
test "E1683 anim state body invalid" {
    const gpa = std.testing.allocator;
    var c = try check(gpa,
        \\anim_graph G {
        \\  state A { clip: "a" clip: "b" transition -> A }
        \\}
    );
    defer c.deinit(gpa);
    try std.testing.expect(parsedClean(c));
    try expectAnyCode(c.diags.items, .anim_state_body_invalid);
}

test "E1689 anim transition to not found" {
    const gpa = std.testing.allocator;
    var c = try check(gpa,
        \\anim_graph G {
        \\  state A { clip: "a" transition -> Missing }
        \\}
    );
    defer c.deinit(gpa);
    try std.testing.expect(parsedClean(c));
    try expectAnyCode(c.diags.items, .anim_transition_to_not_found);
}

test "E1690 anim transition condition not bool" {
    const gpa = std.testing.allocator;
    var c = try check(gpa,
        \\anim_graph G {
        \\  params {
        \\    speed: float = 0.0
        \\  }
        \\  state A { clip: "a" transition -> A when speed }
        \\}
    );
    defer c.deinit(gpa);
    try std.testing.expect(parsedClean(c));
    try expectAnyCode(c.diags.items, .anim_transition_condition_not_bool);
}

// The accepted set is a fixed catalogue of numeric and vector types; `string` is
// outside it.
test "E1695 anim param type invalid" {
    const gpa = std.testing.allocator;
    var c = try check(gpa,
        \\anim_graph G {
        \\  params {
        \\    label: string
        \\  }
        \\  state A { clip: "a" transition -> A }
        \\}
    );
    defer c.deinit(gpa);
    try std.testing.expect(parsedClean(c));
    try expectAnyCode(c.diags.items, .anim_param_type_invalid);
}

test "E1720 score no sections" {
    const gpa = std.testing.allocator;
    var c = try check(gpa,
        \\audio_score "s" {
        \\}
    );
    defer c.deinit(gpa);
    try std.testing.expect(parsedClean(c));
    try expectAnyCode(c.diags.items, .score_no_sections);
}

test "E1721 duplicate section name" {
    const gpa = std.testing.allocator;
    var c = try check(gpa,
        \\audio_score "s" {
        \\  section A {
        \\  }
        \\  section A {
        \\  }
        \\}
    );
    defer c.deinit(gpa);
    try std.testing.expect(parsedClean(c));
    try expectAnyCode(c.diags.items, .duplicate_section_name);
}

test "E1722 duplicate stem name" {
    const gpa = std.testing.allocator;
    var c = try check(gpa,
        \\audio_score "s" {
        \\  stems {
        \\    bass: { clip: "a.ogg" }
        \\    bass: { clip: "b.ogg" }
        \\  }
        \\}
    );
    defer c.deinit(gpa);
    try std.testing.expect(parsedClean(c));
    try expectAnyCode(c.diags.items, .duplicate_stem_name);
}

test "E1726 score transition from not found" {
    const gpa = std.testing.allocator;
    var c = try check(gpa,
        \\audio_score "s" {
        \\  section A {
        \\    can_transition_to: [B]
        \\  }
        \\}
    );
    defer c.deinit(gpa);
    try std.testing.expect(parsedClean(c));
    try expectAnyCode(c.diags.items, .score_transition_from_not_found);
}

// The condition is SYNTACTIC — the value must be an `.int_lit` — and the message's
// "positive" is not enforced: `tempo: 0` emits nothing, while `tempo: -120` fires
// because unary minus is not an int literal. A float is used because no later
// parser change can fold it into one.
test "E1728 tempo invalid" {
    const gpa = std.testing.allocator;
    var c = try check(gpa,
        \\audio_score "s" {
        \\  tempo: 1.5
        \\  section A {
        \\  }
        \\}
    );
    defer c.deinit(gpa);
    try std.testing.expect(parsedClean(c));
    try expectAnyCode(c.diags.items, .tempo_invalid);
}

test "E1740 sequence no tracks" {
    const gpa = std.testing.allocator;
    var c = try check(gpa,
        \\sequence S {}
    );
    defer c.deinit(gpa);
    try std.testing.expect(parsedClean(c));
    try expectAnyCode(c.diags.items, .sequence_no_tracks);
}

test "E1741 duplicate track name" {
    const gpa = std.testing.allocator;
    var c = try check(gpa,
        \\sequence S {
        \\  track T: EventTrack { 0.0s: play "a" }
        \\  track T: EventTrack { 0.0s: play "a" }
        \\}
    );
    defer c.deinit(gpa);
    try std.testing.expect(parsedClean(c));
    try expectAnyCode(c.diags.items, .duplicate_track_name);
}

test "E1742 track type unknown" {
    const gpa = std.testing.allocator;
    var c = try check(gpa,
        \\sequence S {
        \\  track T: BogusTrack { 0.0s: play "a" }
        \\}
    );
    defer c.deinit(gpa);
    try std.testing.expect(parsedClean(c));
    try expectAnyCode(c.diags.items, .track_type_unknown);
}

test "E1744 keyframe out of range" {
    const gpa = std.testing.allocator;
    var c = try check(gpa,
        \\sequence S {
        \\  duration: 1.0
        \\  track T: EventTrack { 5.0s: play "a" }
        \\}
    );
    defer c.deinit(gpa);
    try std.testing.expect(parsedClean(c));
    try expectAnyCode(c.diags.items, .keyframe_out_of_range);
}

test "E1745 keyframes unordered" {
    const gpa = std.testing.allocator;
    var c = try check(gpa,
        \\sequence S {
        \\  track T: EventTrack {
        \\    2.0s: play "a"
        \\    1.0s: play "b"
        \\  }
        \\}
    );
    defer c.deinit(gpa);
    try std.testing.expect(parsedClean(c));
    try expectAnyCode(c.diags.items, .keyframes_unordered);
}

test "E1746 event track event unknown" {
    const gpa = std.testing.allocator;
    var c = try check(gpa,
        \\sequence S {
        \\  track T: EventTrack { 0.0s: emit Missing {} }
        \\}
    );
    defer c.deinit(gpa);
    try std.testing.expect(parsedClean(c));
    try expectAnyCode(c.diags.items, .event_track_event_unknown);
}

test "E1749 fps invalid" {
    const gpa = std.testing.allocator;
    var c = try check(gpa,
        \\sequence S {
        \\  fps: 0
        \\  track T: EventTrack { 0.0s: play "a" }
        \\}
    );
    defer c.deinit(gpa);
    try std.testing.expect(parsedClean(c));
    try expectAnyCode(c.diags.items, .fps_invalid);
}

test "E1750 sequence duration invalid" {
    const gpa = std.testing.allocator;
    var c = try check(gpa,
        \\sequence S {
        \\  duration: 0
        \\  track T: EventTrack { 0.0s: play "a" }
        \\}
    );
    defer c.deinit(gpa);
    try std.testing.expect(parsedClean(c));
    try expectAnyCode(c.diags.items, .sequence_duration_invalid);
}

test "E1820 locale empty" {
    const gpa = std.testing.allocator;
    var c = try check(gpa,
        \\locale fr {
        \\}
    );
    defer c.deinit(gpa);
    try std.testing.expect(parsedClean(c));
    try expectAnyCode(c.diags.items, .locale_empty);
}

// A FORM check, not a code table: `english` fails on length alone. An uppercase
// `EN` would lex as TYPE_IDENT and be a parse error, never reaching the checker.
test "E1821 locale code invalid" {
    const gpa = std.testing.allocator;
    var c = try check(gpa,
        \\locale english {
        \\  "ui.title" = "Menu"
        \\}
    );
    defer c.deinit(gpa);
    try std.testing.expect(parsedClean(c));
    try expectAnyCode(c.diags.items, .locale_code_invalid);
}

test "E1822 locale duplicate key" {
    const gpa = std.testing.allocator;
    var c = try check(gpa,
        \\locale fr {
        \\  "ui.title" = "Menu"
        \\  "ui.title" = "Accueil"
        \\}
    );
    defer c.deinit(gpa);
    try std.testing.expect(parsedClean(c));
    try expectAnyCode(c.diags.items, .locale_duplicate_key);
}

// B must transition ELSEWHERE, never to itself — a self-transition puts B into
// `reached` and suppresses the warning.
test "W1680 anim unreachable state" {
    const gpa = std.testing.allocator;
    var c = try check(gpa,
        \\anim_graph G {
        \\  state A { clip: "a" transition -> A }
        \\  state B { clip: "b" transition -> A }
        \\}
    );
    defer c.deinit(gpa);
    try std.testing.expect(parsedClean(c));
    try expectAnyCode(c.diags.items, .anim_unreachable_state);
}

test "W1681 anim deadend state" {
    const gpa = std.testing.allocator;
    var c = try check(gpa,
        \\anim_graph G {
        \\  state A { clip: "a" }
        \\}
    );
    defer c.deinit(gpa);
    try std.testing.expect(parsedClean(c));
    try expectAnyCode(c.diags.items, .anim_deadend_state);
}

test "W1740 empty track" {
    const gpa = std.testing.allocator;
    var c = try check(gpa,
        \\sequence S {
        \\  track T: EventTrack {}
        \\}
    );
    defer c.deinit(gpa);
    try std.testing.expect(parsedClean(c));
    try expectAnyCode(c.diags.items, .empty_track);
}

test "E0217 has no producer: an impl naming two undeclared symbols answers undefined_symbol" {
    const gpa = std.testing.allocator;
    // WRONG FIX when the loop below reddens: deleting it. An undeclared trait
    // or type is not a foreign one, so `orphan_impl` never answers this program.
    var c = try check(gpa,
        \\impl Missing for Absent { fn f(self) { } }
    );
    defer c.deinit(gpa);
    try std.testing.expect(parsedClean(c));
    try expectAnyCode(c.diags.items, .undefined_symbol);
    for (c.diags.items) |d| {
        try std.testing.expect(d.code != .orphan_impl);
    }
}
