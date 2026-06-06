//! M0.8 / E1 — top-level recovery sync-point.
//!
//! After a parse error inside a top-level construct the parser advances to
//! the next top-level keyword (or EOF) and resumes, so a file with several
//! broken constructs yields one diagnostic per broken construct while the
//! sane constructs still land in the AST. This is the minimal M0.8 recovery
//! (top-level resync only) — the full panic-mode cascade with virtual
//! tokens and fine sync points is Phase 1 / S2+ (`etch-parser.md` §11, §23).

const std = @import("std");
const etch = @import("weld_etch");

test "top-level resync surfaces one diagnostic per broken construct and keeps sane constructs" {
    const gpa = std.testing.allocator;
    // Three constructs; the middle one is broken — a field default with no
    // value expression (`= }`). The S3 parser would have aborted the whole
    // file at the first error; with the M0.8 sync-point the parser records a
    // diagnostic, resyncs at the next `component` keyword, and still parses
    // the two sane constructs around the broken one.
    var result = try etch.parseSource(gpa,
        \\component Alpha { a: int = 1 }
        \\component Bravo { b: int = }
        \\component Charlie { c: int = 3 }
    );
    defer result.deinit(gpa);

    // The one broken construct produces at least one diagnostic.
    try std.testing.expect(result.diagnostics.len >= 1);

    // The two sane constructs appear in the returned AST; the broken one
    // does not (its declaration is appended only after a clean body parse,
    // which never completes before the error unwinds to the sync-point).
    try std.testing.expectEqual(@as(usize, 2), result.ast.items.len);

    var saw_alpha = false;
    var saw_charlie = false;
    var saw_bravo = false;
    for (result.ast.component_decls.items) |cd| {
        const name = result.ast.strings.slice(cd.name);
        if (std.mem.eql(u8, name, "Alpha")) saw_alpha = true;
        if (std.mem.eql(u8, name, "Bravo")) saw_bravo = true;
        if (std.mem.eql(u8, name, "Charlie")) saw_charlie = true;
    }
    try std.testing.expect(saw_alpha);
    try std.testing.expect(saw_charlie);
    try std.testing.expect(!saw_bravo);
}

test "recovery resumes across multiple broken constructs (one diagnostic each)" {
    const gpa = std.testing.allocator;
    // Two broken constructs separated by a sane one: each broken construct
    // contributes its own diagnostic, and the sane constructs survive.
    var result = try etch.parseSource(gpa,
        \\component Good1 { a: int = 1 }
        \\resource Broken1 { x: int = }
        \\component Good2 { b: int = 2 }
        \\rule broken2(entity: Entity) when entity has { }
        \\component Good3 { c: int = 3 }
    );
    defer result.deinit(gpa);

    // Two broken constructs → at least two diagnostics.
    try std.testing.expect(result.diagnostics.len >= 2);

    // The three sane constructs are present (2 components + ... let the
    // count assert it). Good1 / Good2 / Good3 land in the AST.
    var good_count: usize = 0;
    for (result.ast.component_decls.items) |cd| {
        const name = result.ast.strings.slice(cd.name);
        if (std.mem.startsWith(u8, name, "Good")) good_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), good_count);
}

test "clean source still yields zero diagnostics under the recovery loop" {
    const gpa = std.testing.allocator;
    var result = try etch.parseSource(gpa,
        \\component Health { current: float = 100.0, max: float = 100.0 }
        \\rule heal(entity: Entity)
        \\  when entity has Health
        \\{
        \\  entity.get_mut(Health).current += 1.0
        \\}
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 2), result.ast.items.len);
}
