//! `bindgen-check` and the `.d.etch` emitter (M1.1.15.2 G3,
//! `engine-c-bindings.md` §8.4).
//!
//! These exercise the SAME two functions the CLI calls — `emit_detch.emit` and
//! `emit_detch.diff` — so a regression in either is caught by `zig build test`
//! and not only by the manual step. What the tests cannot do is run the build
//! step itself; that counterfactual was run by hand, from BOTH sides, and its
//! verbatim output is in the milestone brief.

const std = @import("std");
const emit_detch = @import("emit_detch");
const services = @import("weld_etch").services;
const weld_etch = @import("weld_etch");
const toy = @import("toy_service");

const source_path = "tests/etch_services/toy_service.zig";
const emitter_path = "tools/bindgen/emit_detch.zig";

test "the committed .d.etch matches what the emitter produces" {
    const gpa = std.testing.allocator;
    const rendered = try emit_detch.emitAlloc(gpa, toy.spec, source_path, emitter_path);
    defer gpa.free(rendered);

    var lines: std.ArrayListUnmanaged(emit_detch.DiffLine) = .empty;
    defer lines.deinit(gpa);
    // `toy.declaration_source` is `@embedFile("toy.d.etch")` — the committed
    // artifact, read at compile time. This IS `bindgen-check`'s comparison.
    const differs = try emit_detch.diff(gpa, toy.declaration_source, rendered, &lines);
    if (differs) {
        for (lines.items) |l| switch (l.kind) {
            .same => {},
            .expected_only => std.debug.print("  {d:>4} - {s}\n", .{ l.line_no, l.text }),
            .actual_only => std.debug.print("  {d:>4} + {s}\n", .{ l.line_no, l.text }),
        };
    }
    try std.testing.expect(!differs);

    // NON-VACUITY: the comparison had something to compare. A zero-method spec,
    // or an emitter returning the empty string, would satisfy the assertion
    // above and prove nothing.
    try std.testing.expectEqual(@as(usize, 3), toy.spec.methods.len);
    try std.testing.expect(rendered.len > 100);
    try std.testing.expect(std.mem.indexOf(u8, rendered, emit_detch.header_line) != null);
}

test "bindgen-check fails on a divergent .d.etch" {
    const gpa = std.testing.allocator;
    const rendered = try emit_detch.emitAlloc(gpa, toy.spec, source_path, emitter_path);
    defer gpa.free(rendered);

    // DIRECTION 1 — the ARTIFACT is edited by hand. One line changed, and the
    // change touches both a parameter name and the `throws` marker, each of
    // which is derived from the Zig signature.
    const edited = try std.mem.replaceOwned(
        u8,
        gpa,
        toy.declaration_source,
        "fn risky(n: int) throws -> int",
        "fn risky(count: int) -> int",
    );
    defer gpa.free(edited);
    // The replacement must have HAPPENED, or the "divergence" below would be
    // the absence of one.
    try std.testing.expect(!std.mem.eql(u8, edited, toy.declaration_source));

    var lines: std.ArrayListUnmanaged(emit_detch.DiffLine) = .empty;
    defer lines.deinit(gpa);
    try std.testing.expect(try emit_detch.diff(gpa, edited, rendered, &lines));

    // The report NAMES the line, from both sides, at the same line number —
    // "it failed" is not the deliverable, the line-by-line diff is.
    var saw_committed = false;
    var saw_emitted = false;
    var committed_line: usize = 0;
    var emitted_line: usize = 0;
    for (lines.items) |l| switch (l.kind) {
        .same => {},
        .expected_only => {
            if (std.mem.indexOf(u8, l.text, "count: int") != null) {
                saw_committed = true;
                committed_line = l.line_no;
            }
        },
        .actual_only => {
            if (std.mem.indexOf(u8, l.text, "throws") != null) {
                saw_emitted = true;
                emitted_line = l.line_no;
            }
        },
    };
    try std.testing.expect(saw_committed);
    try std.testing.expect(saw_emitted);
    try std.testing.expectEqual(committed_line, emitted_line);

    // DIRECTION 2 — the ZIG is edited and the artifact is left alone, which is
    // the direction the guard actually claims: the spec is the source of truth.
    // A one-field change to the spec value stands in for the Zig edit.
    var moved = toy.spec;
    moved.version = toy.spec.version + 1;
    const rerendered = try emit_detch.emitAlloc(gpa, moved, source_path, emitter_path);
    defer gpa.free(rerendered);
    var lines2: std.ArrayListUnmanaged(emit_detch.DiffLine) = .empty;
    defer lines2.deinit(gpa);
    try std.testing.expect(try emit_detch.diff(gpa, toy.declaration_source, rerendered, &lines2));

    // COUNTERFACTUAL ON THE OBJECT: with the spec put back, the same comparison
    // is clean. Without it, a differ that reported a divergence unconditionally
    // would pass every assertion above.
    var lines3: std.ArrayListUnmanaged(emit_detch.DiffLine) = .empty;
    defer lines3.deinit(gpa);
    try std.testing.expect(!try emit_detch.diff(gpa, toy.declaration_source, rendered, &lines3));
}

test "the emitted artifact is a .d.etch the compiler accepts" {
    const gpa = std.testing.allocator;
    const rendered = try emit_detch.emitAlloc(gpa, toy.spec, source_path, emitter_path);
    defer gpa.free(rendered);

    // The guard protects an artifact; this is what makes the artifact worth
    // protecting. `@version` in PREFIX position and every method bodyless —
    // §20.1's `function_decl_no_body`, with `throws` before the return arrow.
    var pr = try weld_etch.parser.parseWithMode(gpa, rendered, .declaration_file);
    defer pr.deinit(gpa);
    for (pr.diagnostics) |d| std.debug.print("parse {s}: {s}\n", .{ d.code.code(), d.primary_message });
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);

    var diags: std.ArrayListUnmanaged(weld_etch.diagnostics.Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try weld_etch.types.TypeChecker.check(gpa, &pr.ast, &diags);
    for (diags.items) |d| std.debug.print("check {s}: {s}\n", .{ d.code.code(), d.primary_message });
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);

    try std.testing.expectEqual(@as(usize, 1), pr.ast.service_decls.items.len);
    const decl = pr.ast.service_decls.items[0];
    try std.testing.expectEqualStrings("toy", pr.ast.strings.slice(decl.name));
    try std.testing.expectEqual(@as(u32, 3), decl.methods_len);

    // Round trip on the two properties the emitter DERIVES, per method rather
    // than in aggregate: bodyless, and `throws` exactly where the spec says.
    const m = pr.ast.impl_methods.items;
    for (0..decl.methods_len) |i| {
        const parsed = m[decl.methods_start + i];
        try std.testing.expect(!parsed.has_body);
        try std.testing.expectEqualStrings(toy.spec.methods[i].name, pr.ast.strings.slice(parsed.name));
        try std.testing.expectEqual(toy.spec.methods[i].throws, parsed.throws);
    }
    // Non-vacuity on that last equality: the three are not all the same value.
    try std.testing.expect(toy.spec.methods[0].throws != toy.spec.methods[1].throws);
}

// ─── M1.1.15.2 G6 — the physics service and the sensor events ───────────────

const physics = @import("forge_services");
const sensor_events = @import("forge_sensor_events");

test "the physics service's committed .d.etch matches its ServiceSpec" {
    const gpa = std.testing.allocator;
    const rendered = try emit_detch.emitAlloc(
        gpa,
        physics.spec,
        "src/modules/forge/services/physics.zig",
        emitter_path,
    );
    defer gpa.free(rendered);
    var lines: std.ArrayListUnmanaged(emit_detch.DiffLine) = .empty;
    defer lines.deinit(gpa);
    try std.testing.expect(!try emit_detch.diff(gpa, physics.declaration_source, rendered, &lines));
    try std.testing.expectEqual(@as(usize, 4), physics.spec.methods.len);
}

test "the emitted physics and trigger declarations parse and resolve" {
    const gpa = std.testing.allocator;
    // The guard protects artifacts; this is what makes them worth protecting. All
    // three go through the SAME check, so a rendering rule that broke one and not
    // the others is caught where it happens.
    for ([_][]const u8{
        physics.declaration_source,
        sensor_events.enter_declaration_source,
        sensor_events.exit_declaration_source,
    }) |src| {
        var pr = try weld_etch.parser.parseWithMode(gpa, src, .declaration_file);
        defer pr.deinit(gpa);
        for (pr.diagnostics) |d| std.debug.print("parse {s}: {s}\n", .{ d.code.code(), d.primary_message });
        try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);

        var diags: std.ArrayListUnmanaged(weld_etch.diagnostics.Diagnostic) = .empty;
        defer {
            for (diags.items) |*d| d.deinit(gpa);
            diags.deinit(gpa);
        }
        try weld_etch.types.TypeChecker.check(gpa, &pr.ast, &diags);
        for (diags.items) |d| std.debug.print("check {s}: {s}\n", .{ d.code.code(), d.primary_message });
        try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    }
}

test "an Entity field carries no default and never a live handle" {
    // `0` IS A LIVE HANDLE to slot 0 generation 0 — the mistake
    // `CharacterMoveResult.ground_body` made before M1.1.12 — and a raw all-ones
    // pattern renders `-1`, which is not an entity in any reading. `Entity.null`,
    // the corpus's own spelling, is refused by the type-checker as a field
    // default. So the emitter writes NO default, which is the only thing that
    // says nothing untrue.
    try std.testing.expect(std.mem.indexOf(u8, sensor_events.enter_declaration_source, "trigger: Entity\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, sensor_events.enter_declaration_source, "= 0") == null);
    try std.testing.expect(std.mem.indexOf(u8, sensor_events.enter_declaration_source, "-1") == null);
    // And not `Entity.null` either, which the CHECKER refuses as a field default
    // — measured, `E1101`, on this very artifact.
    try std.testing.expect(std.mem.indexOf(u8, sensor_events.enter_declaration_source, "Entity.null") == null);

    // NON-VACUITY: a NON-entity default still renders as a literal, so the rule is
    // about the `Entity` type and not about defaults in general.
    try std.testing.expect(std.mem.indexOf(u8, toy.ping_declaration_source, "value: int = 0") != null);
}
