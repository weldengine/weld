//! Cross-file `import` resolution under `validateProject`: the module
//! dependency graph, its topological order and cycle detection, then the
//! selective-import resolution — cross-file type and const, and the codes that
//! refuse.
//!
//! The cycle code is `E0108` and NOT `E0101`, which is `DuplicateSymbol`.

const std = @import("std");
const etch = @import("weld_etch");
const DiagnosticCode = etch.diagnostics.DiagnosticCode;

fn countCode(diags: []const etch.Diagnostic, code: DiagnosticCode) usize {
    var n: usize = 0;
    for (diags) |d| {
        if (d.code == code) n += 1;
    }
    return n;
}

fn deinitDiags(gpa: std.mem.Allocator, diags: *std.ArrayListUnmanaged(etch.Diagnostic)) void {
    for (diags.items) |*d| d.deinit(gpa);
    diags.deinit(gpa);
}

test "import cycle errors" {
    const gpa = std.testing.allocator;
    // module `a` imports `b`, module `b` imports `a` → a 2-cycle closes on the
    // back-edge → exactly one E0108.
    const files = [_]etch.ProjectFile{
        .{ .name = "a.etch", .source = "import b" },
        .{ .name = "b.etch", .source = "import a" },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 1), countCode(diags.items, .import_cycle));
}

test "linear import is not a cycle" {
    const gpa = std.testing.allocator;
    // `a` imports `b`, `b` imports nothing → acyclic, no E0108 (guards the DFS
    // against over-reporting a forward edge as a back-edge).
    const files = [_]etch.ProjectFile{
        .{ .name = "a.etch", .source = "import b" },
        .{ .name = "b.etch", .source = "component Marker { id: int = 0 }" },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .import_cycle));
}

test "selective import resolves a cross-file type" {
    const gpa = std.testing.allocator;
    // `main` imports the component `Health` from `lib` and uses it in a type
    // position (`type HA = Health`). The imported `TYPE_IDENT` must resolve, so
    // no E0102 UndefinedSymbol — the imported set reaches type resolution.
    const files = [_]etch.ProjectFile{
        .{ .name = "lib.etch", .source = "component Health { current: float = 100.0 }" },
        .{ .name = "main.etch", .source =
        \\import lib { Health }
        \\type HA = Health
        },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .undefined_symbol));
}

test "unknown export errors (E0104)" {
    const gpa = std.testing.allocator;
    // `lib` exports `Health`; `main` selectively imports `Nope`, which `lib` does
    // not export → exactly one E0104 (and Health is unaffected).
    const files = [_]etch.ProjectFile{
        .{ .name = "lib.etch", .source = "component Health { current: float = 100.0 }" },
        .{ .name = "main.etch", .source = "import lib { Nope }" },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 1), countCode(diags.items, .unknown_export));
}

test "valid selective import emits no import diagnostic (binding)" {
    const gpa = std.testing.allocator;
    // `main` imports an item `lib` actually exports → the binding succeeds with no
    // E0103/E0104.
    const files = [_]etch.ProjectFile{
        .{ .name = "lib.etch", .source = "component Health { current: float = 100.0 }" },
        .{ .name = "main.etch", .source = "import lib { Health }" },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .unknown_export));
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .not_a_module));
}

test "import of a missing module errors (E0103)" {
    const gpa = std.testing.allocator;
    // `main` imports `ghost`, which names no file in the set → exactly one E0103.
    const files = [_]etch.ProjectFile{
        .{ .name = "main.etch", .source = "import ghost" },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 1), countCode(diags.items, .not_a_module));
}

test "selective import resolves a cross-file const" {
    const gpa = std.testing.allocator;
    // `lib` declares a top-level `const`; `main` selectively imports it. The
    // const is exported (public) and resolvable → no E0104 / E0107 / E0103.
    const files = [_]etch.ProjectFile{
        .{ .name = "lib.etch", .source = "const ROOM_CAP: int = 8" },
        .{ .name = "main.etch", .source = "import lib { ROOM_CAP }" },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .unknown_export));
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .import_private_item));
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .not_a_module));
}

test "import of a private item errors (E0107, activation)" {
    const gpa = std.testing.allocator;
    // `lib` declares a `private component`; `main` selectively imports it. The
    // item is in `lib`'s exports flagged `.private` → exactly one E0107.
    const files = [_]etch.ProjectFile{
        .{ .name = "lib.etch", .source = "private component Secret { hash: u32 = 0 }" },
        .{ .name = "main.etch", .source = "import lib { Secret }" },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 1), countCode(diags.items, .import_private_item));
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .unknown_export));
}

test "a public declaration alongside a private one stays importable" {
    const gpa = std.testing.allocator;
    // Visibility is per-declaration: `Public` imports clean, `Secret` is E0107.
    const files = [_]etch.ProjectFile{
        .{ .name = "lib.etch", .source =
        \\private component Secret { hash: u32 = 0 }
        \\component Public { value: int = 0 }
        },
        .{ .name = "main.etch", .source =
        \\import lib { Public }
        \\import lib { Secret }
        },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 1), countCode(diags.items, .import_private_item));
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .unknown_export));
}

test "a test block is not exported (E0104 on import)" {
    const gpa = std.testing.allocator;
    // `lib` declares a `test` block; it is registered intra-module but never
    // exported → selectively importing its name is E0104 UnknownExport.
    const files = [_]etch.ProjectFile{
        .{ .name = "lib.etch", .source = "test \"secret_test\" { }" },
        .{ .name = "main.etch", .source = "import lib { secret_test }" },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 1), countCode(diags.items, .unknown_export));
}

test "entity.get reaches an imported component in a test body" {
    const gpa = std.testing.allocator;
    const files = [_]etch.ProjectFile{
        .{ .name = "lib.etch", .source = "component Health { current: float = 100.0 }" },
        .{ .name = "main.etch", .source =
        \\import lib { Health }
        \\test "t" {
        \\  let w = test_world()
        \\  let e = w.spawn_with([Health { current: 1.0 }])
        \\  let v = e.get(Health).current
        \\}
        },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .undefined_symbol));
}

test "a hook reaches imported requires and own components" {
    const gpa = std.testing.allocator;
    const files = [_]etch.ProjectFile{
        .{ .name = "lib.etch", .source =
        \\component Health { current: float = 100.0 }
        \\component Weapon { damage: float = 1.0 }
        },
        .{ .name = "base.prefab.etch", .source =
        \\import lib { Health }
        \\prefab "Base" { entity "r" { Health {} } }
        },
        .{ .name = "mod.prefab.etch", .source =
        \\import lib { Health, Weapon }
        \\prefab "Mod" extends "Base" requires Health {
        \\  entity "m" { Weapon {} }
        \\  on_attach { entity.get_mut(Health).current += entity.get(Weapon).damage }
        \\}
        },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
}

const positions_lib =
    \\component C { v: int = 0 }
    \\component D { v: int = 0 }
    \\resource R { v: int = 0 }
    \\event P { v: int = 0 }
    \\event Hit { who: Entity }
    \\
;

const Case = struct { name: []const u8, body: []const u8 };
const position_cases = [_]Case{
    .{ .name = "when has", .body = "rule r(entity: Entity) when entity has C { }" },
    .{ .name = "when has changed", .body = "rule r(entity: Entity) when entity has C changed { }" },
    .{ .name = "when has field filter", .body = "rule r(entity: Entity) when entity has C { v == 1 } { }" },
    .{ .name = "when has expr filter", .body = "rule r(entity: Entity) when entity has C { v > 0 } { }" },
    .{ .name = "when resource", .body = "rule r() when resource R { }" },
    .{ .name = "when resource changed", .body = "rule r() when resource R changed { }" },
    .{ .name = "when resource filter", .body = "rule r() when resource R { v > 0 } { }" },
    .{ .name = "body get", .body = "rule r(entity: Entity) when entity has C { let x = entity.get(C).v }" },
    .{ .name = "body get_mut", .body = "rule r(entity: Entity) when entity has C { entity.get_mut(C).v += 1 }" },
    .{ .name = "body resource get", .body = "rule r() when resource R { let x = get(R).v }" },
    .{ .name = "emit", .body = "rule r() { emit P { v: 1 } }" },
    .{ .name = "emit bad field", .body = "rule r() { emit P { w: 1 } }" },
    .{ .name = "await global_event", .body = "async rule r(e: Entity) when e has C { await global_event(P) }" },
    .{ .name = "await global_event filter", .body = "async rule r(e: Entity) when e has C { await global_event(P { v: 1 }) }" },
    .{ .name = "await entity_event", .body = "async rule r(e: Entity) when e has C { await entity_event(e, Hit) }" },
    .{ .name = "on_event", .body = "@on_event(P)\nrule r() { let x = event.v }" },
    .{ .name = "on_added", .body = "@on_added(C)\nrule r(entity: Entity, value: C) {}" },
    .{ .name = "body add", .body = "rule r(entity: Entity) when entity has C { entity.add(D { v: 1 }) }" },
    .{ .name = "body remove", .body = "rule r(entity: Entity) when entity has C { entity.remove(D) }" },
    .{ .name = "body spawn", .body = "rule r() { spawn(C { v: 1 }) }" },
    .{ .name = "sequence emit", .body = "sequence S {\n  track T: EventTrack { 0.0s: emit P { v: 1 } }\n}" },
    .{ .name = "quest emit", .body = "fn check() -> bool { true }\nquest Q {\n  stage a {\n    objective main: check()\n    on_complete: emit P { v: 1 }\n  }\n}" },
    .{ .name = "dialogue emit", .body = "dialogue Talk {\n  speaker \"npc\" { line: \"x\" }\n  emit P { v: 1 }\n  -> end\n}" },
    .{ .name = "dialogue has", .body = "dialogue Talk {\n  speaker \"npc\" { line: \"x\" when player has C { v < 5 } }\n}" },
    .{ .name = "behavior has", .body = "behavior B {\n  selector {\n    sequence when self has C { v < 5 } {\n      action: emit P { v: 1 }\n    }\n  }\n}" },
    .{ .name = "behavior get", .body = "behavior B {\n  selector {\n    condition: self.get(C).v > 0\n  }\n}" },
    .{ .name = "malformed when has field filter", .body = "rule r(entity: Entity) when entity has C { w == 1 } { }" },
    .{ .name = "malformed when has expr filter", .body = "rule r(entity: Entity) when entity has C { w > 0 } { }" },
    .{ .name = "malformed when resource filter", .body = "rule r() when resource R { w > 0 } { }" },
    .{ .name = "malformed body get", .body = "rule r(entity: Entity) when entity has C { let x = entity.get(C).w }" },
    .{ .name = "malformed body get type", .body = "rule r(entity: Entity) when entity has C { entity.get_mut(C).v = true }" },
    .{ .name = "malformed body resource get", .body = "rule r() when resource R { let x = get(R).w }" },
    .{ .name = "malformed emit type", .body = "rule r() { emit P { v: true } }" },
    .{ .name = "malformed await filter", .body = "async rule r(e: Entity) when e has C { await global_event(P { w: 1 }) }" },
    .{ .name = "malformed on_event field", .body = "@on_event(P)\nrule r() { let x = event.w }" },
    .{ .name = "malformed body add field", .body = "rule r(entity: Entity) when entity has C { entity.add(D { w: 1 }) }" },
    .{ .name = "malformed body spawn field", .body = "rule r() { spawn(C { w: 1 }) }" },
    .{ .name = "malformed when has resource", .body = "rule r(entity: Entity) when entity has R { }" },
    .{ .name = "malformed when resource comp", .body = "rule r() when resource C { }" },
    .{ .name = "malformed emit component", .body = "rule r() { emit C { v: 1 } }" },
};

fn codesOf(files: []const etch.ProjectFile, out: *std.ArrayListUnmanaged(DiagnosticCode)) !void {
    const gpa = std.testing.allocator;
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, files, &diags);
    for (diags.items) |d| try out.append(gpa, d.code);
}

test "a name an import binds is judged as its declaration is, position by position" {
    const gpa = std.testing.allocator;
    var differing: usize = 0;
    for (position_cases) |c| {
        const declared_src = try std.mem.concat(gpa, u8, &.{ positions_lib, c.body });
        defer gpa.free(declared_src);
        const imported_src = try std.mem.concat(gpa, u8, &.{ "import lib { C, D, R, P, Hit }\n", c.body });
        defer gpa.free(imported_src);
        var declared: std.ArrayListUnmanaged(DiagnosticCode) = .empty;
        defer declared.deinit(gpa);
        var imported: std.ArrayListUnmanaged(DiagnosticCode) = .empty;
        defer imported.deinit(gpa);
        try codesOf(&.{.{ .name = "main.etch", .source = declared_src }}, &declared);
        try codesOf(&.{ .{ .name = "lib.etch", .source = positions_lib }, .{ .name = "main.etch", .source = imported_src } }, &imported);
        if (!std.mem.eql(DiagnosticCode, declared.items, imported.items)) {
            differing += 1;
            std.debug.print("{s}: declared {any}, imported {any}\n", .{ c.name, declared.items, imported.items });
        }
    }
    try std.testing.expectEqual(@as(usize, 0), differing);
}

test "a composite value for a field of an imported component is refused" {
    const gpa = std.testing.allocator;
    const files = [_]etch.ProjectFile{
        .{ .name = "lib.etch", .source = "component C { n: int = 0 }" },
        .{ .name = "level.scene.etch", .source =
        \\import lib { C }
        \\scene "L" { entity "e" { uuid: "00000000-0000-0000-0000-000000000001" C { n: [1, 2] } } }
        },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 1), countCode(diags.items, .scene_component_field_type_invalid));
}

test "one component under two local names is one type" {
    const gpa = std.testing.allocator;
    const files = [_]etch.ProjectFile{
        .{ .name = "lib.etch", .source = "component Health { current: float = 100.0 }" },
        .{ .name = "main.etch", .source =
        \\import lib { Health }
        \\import lib { Health as HP }
        \\fn cur(h: Health) -> float { h.current }
        \\rule r(entity: Entity) when entity has HP {
        \\  let c = cur(entity.get(HP))
        \\}
        },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
}
