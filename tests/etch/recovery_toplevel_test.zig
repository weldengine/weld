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

test "recovery resyncs at a top-level `type` alias after a broken construct (M0.8 lockstep)" {
    const gpa = std.testing.allocator;
    // A broken component precedes a valid `type` alias. Because `kw_type` is
    // in recoverToTopLevel's stop-set — extended IN LOCKSTEP with the
    // parseTopLevel `type` production — the alias is not skipped: it lands in
    // the AST. Without the lockstep extension the recovery loop would run past
    // `type Meters = float` to EOF and silently drop a valid construct.
    var result = try etch.parseSource(gpa,
        \\component Broken { x: int = }
        \\type Meters = float
        \\component After { y: float = 0.0 }
    );
    defer result.deinit(gpa);

    try std.testing.expect(result.diagnostics.len >= 1);

    // The valid `type` alias survived the resync.
    var saw_alias = false;
    for (result.ast.type_alias_decls.items) |ta| {
        if (std.mem.eql(u8, result.ast.strings.slice(ta.name), "Meters")) saw_alias = true;
    }
    try std.testing.expect(saw_alias);

    // The construct after the alias survived too.
    var saw_after = false;
    for (result.ast.component_decls.items) |cd| {
        if (std.mem.eql(u8, result.ast.strings.slice(cd.name), "After")) saw_after = true;
    }
    try std.testing.expect(saw_after);
}

test "recovery resyncs at a top-level `fn` after a broken construct (M0.8 E2 lockstep)" {
    const gpa = std.testing.allocator;
    // A broken component precedes a valid top-level `fn`. Because `kw_fn` joined
    // recoverToTopLevel's stop-set IN LOCKSTEP with the parseTopLevel `fn`
    // production (M0.8 E2 block 2 — the first top-level keyword E2 introduces),
    // the function is not skipped: it lands in the AST. Without the lockstep
    // extension the recovery loop would run past `fn double` to EOF and silently
    // drop a valid construct.
    var result = try etch.parseSource(gpa,
        \\component Broken { x: int = }
        \\fn double(n: int) -> int { n * 2 }
        \\component After { y: float = 0.0 }
    );
    defer result.deinit(gpa);

    try std.testing.expect(result.diagnostics.len >= 1);

    // The valid `fn` survived the resync.
    var saw_fn = false;
    for (result.ast.fn_decls.items) |fd| {
        if (std.mem.eql(u8, result.ast.strings.slice(fd.name), "double")) saw_fn = true;
    }
    try std.testing.expect(saw_fn);

    // The construct after the function survived too.
    var saw_after = false;
    for (result.ast.component_decls.items) |cd| {
        if (std.mem.eql(u8, result.ast.strings.slice(cd.name), "After")) saw_after = true;
    }
    try std.testing.expect(saw_after);
}

test "recovery resyncs at a top-level `async fn` after a broken construct (M0.8 E2 lockstep)" {
    const gpa = std.testing.allocator;
    // The `async` starter also joined recoverToTopLevel's stop-set in lockstep
    // (an `async fn` is a top-level construct in E2). A broken construct before
    // an `async fn` must not swallow it.
    var result = try etch.parseSource(gpa,
        \\component Broken { x: int = }
        \\async fn tick(n: int) -> int { n }
        \\component After { y: float = 0.0 }
    );
    defer result.deinit(gpa);

    try std.testing.expect(result.diagnostics.len >= 1);
    var saw_fn = false;
    for (result.ast.fn_decls.items) |fd| {
        if (std.mem.eql(u8, result.ast.strings.slice(fd.name), "tick")) saw_fn = true;
    }
    try std.testing.expect(saw_fn);
}

test "recovery keeps a rule exercising the E1 body constructs after a broken construct" {
    const gpa = std.testing.allocator;
    // A broken component precedes a rule whose body exercises every E1
    // foundation (arrays + indexing, closures + calls, for-in, loop/break,
    // try/catch/throw). The parser resyncs at `rule` and the whole body parses
    // cleanly — proving the new body constructs did not regress top-level
    // recovery (the forward-note survival check; no new top-level keyword was
    // added in these tranches, so `recoverToTopLevel`'s stop-set is unchanged).
    var result = try etch.parseSource(gpa,
        \\component Broken { x: int = }
        \\component Acc { out: int = 0 }
        \\rule mix(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  let arr = [1, 2, 3]
        \\  let double = |n: int| n * 2
        \\  let mut s = 0
        \\  for v in arr {
        \\    s += double(v)
        \\  }
        \\  let x = loop { break s }
        \\  try {
        \\    throw x
        \\  } catch err {
        \\    s = err
        \\  }
        \\  entity.get_mut(Acc).out = s
        \\}
    );
    defer result.deinit(gpa);

    // The broken component yields a diagnostic; the rule after it survives.
    try std.testing.expect(result.diagnostics.len >= 1);
    var saw_mix = false;
    for (result.ast.rule_decls.items) |rd| {
        if (std.mem.eql(u8, result.ast.strings.slice(rd.name), "mix")) saw_mix = true;
    }
    try std.testing.expect(saw_mix);
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
