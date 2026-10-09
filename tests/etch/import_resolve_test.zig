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
    \\const CAP: int = 8
    \\struct Pt { x: int = 0, y: int = 0 }
    \\struct Seg { a: Pt }
    \\struct Box<T> { v: T }
    \\enum Dir { north, south }
    \\struct Cfg { d: Dir = .north }
    \\resource Mode { d: Dir = .north }
    \\event Moved { d: Dir }
    \\fn twice(n: int) -> int { n * 2 }
    \\fn go() { }
    \\fn mk() -> Pt { Pt { x: 1 } }
    \\fn same<T>(t: T) -> T { t }
    \\trait Shape {
    \\  fn area(self) -> int
    \\}
    \\trait Doubler {
    \\  fn base(self) -> int
    \\  fn doubled(self) -> int { self.base() * 2 }
    \\}
    \\impl Pt {
    \\  fn len(self) -> int { self.x }
    \\  fn scaled(self, k: int) -> int { self.x * k }
    \\  fn origin() -> Pt { Pt { x: 0 } }
    \\}
    \\impl Shape for Pt {
    \\  fn area(self) -> int { self.x * self.y }
    \\}
    \\impl Doubler for Pt {
    \\  fn base(self) -> int { self.x }
    \\}
    \\fn shaped<T: Shape>(t: T) -> int { 0 }
    \\trait Hurt {
    \\  fn hp(self) -> int
    \\}
    \\impl Hurt for Entity when self has C {
    \\  fn hp(self) -> int { self.get(C).v }
    \\}
    \\type Meters = float
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
    .{ .name = "const read", .body = "rule r() { let x: int = CAP }" },
    .{ .name = "malformed const read type", .body = "rule r() { let x: bool = CAP }" },
    .{ .name = "struct literal", .body = "rule r() { let p = Pt { x: 1 } }" },
    .{ .name = "struct literal bad field", .body = "rule r() { let p = Pt { w: 1 } }" },
    .{ .name = "struct literal bad type", .body = "rule r() { let p = Pt { x: true } }" },
    .{ .name = "anon literal by annotation", .body = "rule r() { let p: Pt = .{ x: 1 } }" },
    .{ .name = "anon literal bad field", .body = "rule r() { let p: Pt = .{ w: 1 } }" },
    .{ .name = "nested anon field", .body = "rule r() { let s = Seg { a: .{ x: 1 } } }" },
    .{ .name = "struct field missing", .body = "rule r() { let s = Seg { } }" },
    .{ .name = "struct param and return", .body = "fn f(p: Pt) -> Pt { p }" },
    .{ .name = "struct field read", .body = "fn f(p: Pt) -> int { p.x }" },
    .{ .name = "struct field read unknown", .body = "fn f(p: Pt) -> int { p.w }" },
    .{ .name = "struct field read type", .body = "fn f(p: Pt) -> bool { p.x }" },
    .{ .name = "struct field of local struct", .body = "struct Wrap { p: Pt }" },
    .{ .name = "data entry type", .body = "data T: Pt {\n  a: { x: 1 },\n}" },
    .{ .name = "data entry bad field", .body = "data T: Pt {\n  a: { w: 1 },\n}" },
    .{ .name = "method call", .body = "fn f(p: Pt) -> int { p.len() }" },
    .{ .name = "associated fn", .body = "rule r() { let p = Pt.origin() }" },
    .{ .name = "trait method via lib impl", .body = "fn f(p: Pt) -> int { p.area() }" },
    .{ .name = "trait default method", .body = "fn f(p: Pt) -> int { p.doubled() }" },
    .{ .name = "unknown method", .body = "fn f(p: Pt) -> int { p.nope() }" },
    .{ .name = "bound via lib impl", .body = "fn g<T: Shape>(t: T) -> int { 0 }\nfn f(p: Pt) -> int { g(p) }" },
    .{ .name = "generic struct param", .body = "fn f(b: Box<int>) -> int { 0 }" },
    .{ .name = "generic struct literal", .body = "rule r() { let b = Box { v: 1 } }" },
    .{ .name = "enum value", .body = "rule r() { let d = Dir.north }" },
    .{ .name = "enum wrong variant", .body = "rule r() { let d = Dir.west }" },
    .{ .name = "match enum value", .body = "fn f() -> int {\n  let d = Dir.north\n  match d { Dir.north => 1, .south => 2 }\n}" },
    .{ .name = "match enum param", .body = "fn f(d: Dir) -> int { match d { Dir.north => 1, .south => 2 } }" },
    .{ .name = "match wrong variant", .body = "fn f(d: Dir) -> int { match d { .west => 1, _ => 0 } }" },
    .{ .name = "match non-exhaustive", .body = "fn f(d: Dir) -> int { match d { .north => 1 } }" },
    .{ .name = "enum shorthand in lib struct", .body = "rule r() { let c = Cfg { d: .south } }" },
    .{ .name = "enum shorthand wrong variant", .body = "rule r() { let c = Cfg { d: .west } }" },
    .{ .name = "enum field of local struct", .body = "struct L { d: Dir = .north }" },
    .{ .name = "enum field local struct lit", .body = "struct L { d: Dir = .north }\nrule r() { let l = L { d: .south } }" },
    .{ .name = "enum field of local resource", .body = "resource L { d: Dir = .north }" },
    .{ .name = "enum collection in resource", .body = "resource L { ds: Dir[] }" },
    .{ .name = "enum field of local event", .body = "event L { d: Dir }" },
    .{ .name = "enum field of lib resource", .body = "rule r() when resource Mode { let x = match get(Mode).d { .north => 1, .south => 2 } }" },
    .{ .name = "enum field of lib event", .body = "@on_event(Moved)\nrule r() { let x = match event.d { .north => 1, .south => 2 } }" },
    .{ .name = "enum param and return", .body = "fn f(d: Dir) -> Dir { d }" },
    .{ .name = "fn call", .body = "rule r() { let x = twice(2) }" },
    .{ .name = "fn call arity", .body = "rule r() { let x = twice(1, 2) }" },
    .{ .name = "fn call arg type", .body = "rule r() { let x = twice(true) }" },
    .{ .name = "fn call named arg", .body = "rule r() { let x = twice(m: 1) }" },
    .{ .name = "fn call result type", .body = "rule r() { let x: bool = twice(1) }" },
    .{ .name = "fn call struct result", .body = "rule r() { let y = mk().x }" },
    .{ .name = "fn call unit", .body = "rule r() { go() }" },
    .{ .name = "generic fn call", .body = "rule r() { let x: int = same(1) }" },
    .{ .name = "generic fn call result type", .body = "rule r() { let x: bool = same(1) }" },
    .{ .name = "lib bound via lib impl", .body = "fn f(p: Pt) -> int { shaped(p) }" },
    .{ .name = "lib bound unsatisfied", .body = "fn f() -> int { shaped(1) }" },
    .{ .name = "lib bound, local impl", .body = "struct Sq { s: int = 1 }\nimpl Shape for Sq {\n  fn area(self) -> int { 1 }\n}\nfn f(q: Sq) -> int { shaped(q) }" },
    .{ .name = "local inherent impl on lib struct", .body = "impl Pt {\n  fn sum(self) -> int { self.x + self.y }\n}\nfn f(p: Pt) -> int { p.sum() }" },
    .{ .name = "local trait for lib struct", .body = "trait Named {\n  fn nm(self) -> int\n}\nimpl Named for Pt {\n  fn nm(self) -> int { 1 }\n}\nfn f(p: Pt) -> int { p.nm() }" },
    .{ .name = "method arg type", .body = "fn f(p: Pt) -> int { p.scaled(true) }" },
    .{ .name = "method named arg", .body = "fn f(p: Pt) -> int { p.scaled(k: 2) }" },
    .{ .name = "method result type", .body = "fn f(p: Pt) -> bool { p.len() }" },
    .{ .name = "associated fn result field", .body = "rule r() { let x = Pt.origin().x }" },
    .{ .name = "method via fn result", .body = "rule r() { let x = mk().len() }" },
    .{ .name = "conditional lib impl proven", .body = "rule r(e: Entity) when e has C { let x = e.hp() }" },
    .{ .name = "conditional lib impl unproven", .body = "rule r(e: Entity) when e has D { let x = e.hp() }" },
    .{ .name = "self in a trait impl on a lib enum", .body = "trait Named {\n  fn nm(self) -> int\n}\nimpl Named for Dir {\n  fn nm(self) -> int { match self { .west => 1, _ => 0 } }\n}" },
    .{ .name = "local impl redefining a lib method", .body = "impl Pt {\n  fn len(self) -> int { 1 }\n}" },
    .{ .name = "impl lib trait for local", .body = "struct Sq { s: int = 1 }\nimpl Shape for Sq {\n  fn area(self) -> int { self.s }\n}" },
    .{ .name = "incomplete impl of lib trait", .body = "struct Sq { s: int = 1 }\nimpl Shape for Sq { }" },
    .{ .name = "lib trait default on local", .body = "struct Sq { s: int = 1 }\nimpl Doubler for Sq {\n  fn base(self) -> int { self.s }\n}\nfn f(q: Sq) -> int { q.doubled() }" },
    .{ .name = "bound on lib trait, local impl", .body = "struct Sq { s: int = 1 }\nimpl Shape for Sq {\n  fn area(self) -> int { 1 }\n}\nfn g<T: Shape>(t: T) -> int { 0 }\nfn f(q: Sq) -> int { g(q) }" },
    .{ .name = "alias as param type", .body = "fn f(m: Meters) -> float { m }" },
    .{ .name = "alias as alias target", .body = "type Km = Meters" },
    .{ .name = "alias let mismatch", .body = "rule r() { let m: Meters = true }" },
    .{ .name = "scene resource", .body = "scene \"S\" {\n  resources { R { v: 1 } }\n  entity \"e\" { uuid: \"7b3e2f1a-42a3-4f2b-8c9d-a3f2b1c98d4e\" C { v: 1 } }\n}" },
    .{ .name = "malformed scene resource field type", .body = "scene \"S\" {\n  resources { R { v: true } }\n  entity \"e\" { uuid: \"7b3e2f1a-42a3-4f2b-8c9d-a3f2b1c98d4e\" C { v: 1 } }\n}" },
};

/// Each diagnostic of `files` as its code and message, one per line: two
/// diagnostics of one code for different reasons read as different.
fn judgementOf(files: []const etch.ProjectFile, out: *std.ArrayListUnmanaged(u8)) !void {
    const gpa = std.testing.allocator;
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, files, &diags);
    for (diags.items) |d| try out.print(gpa, "{t} {s}\n", .{ d.code, d.primary_message });
}

test "a name an import binds is judged as its declaration is, position by position" {
    const gpa = std.testing.allocator;
    var differing: usize = 0;
    for (position_cases) |c| {
        const declared_src = try std.mem.concat(gpa, u8, &.{ positions_lib, c.body });
        defer gpa.free(declared_src);
        const imported_src = try std.mem.concat(gpa, u8, &.{ "import lib { C, D, R, P, Hit, CAP, Pt, Seg, Box, Dir, Cfg, Mode, Moved, twice, go, mk, same, Shape, Doubler, shaped, Hurt, Meters }\n", c.body });
        defer gpa.free(imported_src);
        var declared: std.ArrayListUnmanaged(u8) = .empty;
        defer declared.deinit(gpa);
        var imported: std.ArrayListUnmanaged(u8) = .empty;
        defer imported.deinit(gpa);
        try judgementOf(&.{.{ .name = "main.etch", .source = declared_src }}, &declared);
        try judgementOf(&.{ .{ .name = "lib.etch", .source = positions_lib }, .{ .name = "main.etch", .source = imported_src } }, &imported);
        if (!std.mem.eql(u8, declared.items, imported.items)) {
            differing += 1;
            std.debug.print("{s}:\n declared {{\n{s}}}\n imported {{\n{s}}}\n", .{ c.name, declared.items, imported.items });
        }
    }
    try std.testing.expectEqual(@as(usize, 0), differing);
}

const orphan_lib =
    \\trait Shape {
    \\  fn area(self) -> int
    \\}
    \\struct Pt { x: int = 0 }
;

const OrphanCase = struct { name: []const u8, main: []const u8, orphans: usize };
const orphan_cases = [_]OrphanCase{
    .{ .name = "imported trait for imported type", .main = "import lib { Shape, Pt }\nimpl Shape for Pt {\n  fn area(self) -> int { 0 }\n}", .orphans = 1 },
    .{ .name = "imported trait for Entity", .main = "import lib { Shape }\nimpl Shape for Entity {\n  fn area(self) -> int { 0 }\n}", .orphans = 1 },
    .{ .name = "imported trait for local type", .main = "import lib { Shape }\nstruct Sq { s: int = 1 }\nimpl Shape for Sq {\n  fn area(self) -> int { 0 }\n}", .orphans = 0 },
    .{ .name = "local trait for imported type", .main = "import lib { Pt }\ntrait Named {\n  fn nm(self) -> int\n}\nimpl Named for Pt {\n  fn nm(self) -> int { 0 }\n}", .orphans = 0 },
};

test "an impl whose trait and type are both of other modules is an orphan" {
    const gpa = std.testing.allocator;
    var wrong: usize = 0;
    for (orphan_cases) |c| {
        const files = [_]etch.ProjectFile{
            .{ .name = "lib.etch", .source = orphan_lib },
            .{ .name = "main.etch", .source = c.main },
        };
        var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
        defer deinitDiags(gpa, &diags);
        try etch.validateProject(gpa, &files, &diags);
        const orphans = countCode(diags.items, .orphan_impl);
        if (orphans != c.orphans or diags.items.len != c.orphans) {
            wrong += 1;
            std.debug.print("{s}: {d} orphan_impl among {d} diagnostics, expected {d}\n", .{ c.name, orphans, diags.items.len, c.orphans });
        }
    }
    try std.testing.expectEqual(@as(usize, 0), wrong);
}

const extended_pt = [_]etch.ProjectFile{
    .{ .name = "lib.etch", .source = "struct Pt { x: int = 0 }" },
    .{ .name = "ext1.etch", .source = "import lib { Pt }\nimpl Pt {\n  fn len(self) -> int { 1 }\n}" },
    .{ .name = "ext2.etch", .source = "import lib { Pt }\nimpl Pt {\n  fn len(self) -> int { 2 }\n}" },
};

fn diagnosticsWith(gpa: std.mem.Allocator, main: []const u8, diags: *std.ArrayListUnmanaged(etch.Diagnostic)) !void {
    const files = extended_pt ++ [_]etch.ProjectFile{.{ .name = "main.etch", .source = main }};
    try etch.validateProject(gpa, &files, diags);
}

test "an inherent method two imported modules define is ambiguous at its call" {
    const gpa = std.testing.allocator;
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try diagnosticsWith(gpa, "import lib { Pt }\nimport ext1\nimport ext2\nfn f(p: Pt) -> int { p.len() }", &diags);
    try std.testing.expectEqual(@as(usize, 1), countCode(diags.items, .ambiguous_inherent_method));
    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
}

test "an inherent method one imported module defines is a method of the type" {
    const gpa = std.testing.allocator;
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try diagnosticsWith(gpa, "import lib { Pt }\nimport ext1\nfn f(p: Pt) -> int { p.len() }", &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
}

test "an inherent method of a module not imported is no method of the type" {
    const gpa = std.testing.allocator;
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try diagnosticsWith(gpa, "import lib { Pt }\nfn f(p: Pt) -> int { p.len() }", &diags);
    try std.testing.expectEqual(@as(usize, 1), countCode(diags.items, .type_mismatch));
    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
}

const InherentCase = struct { name: []const u8, files: []const etch.ProjectFile, ambiguous: usize };
const inherent_cases = [_]InherentCase{
    .{ .name = "two impls of one file", .ambiguous = 1, .files = &.{.{ .name = "main.etch", .source = "struct Pt { x: int = 0 }\nimpl Pt {\n  fn len(self) -> int { 1 }\n}\nimpl Pt {\n  fn len(self) -> int { 2 }\n}" }} },
    .{ .name = "one impl naming a method twice", .ambiguous = 1, .files = &.{.{ .name = "main.etch", .source = "struct Pt { x: int = 0 }\nimpl Pt {\n  fn len(self) -> int { 1 }\n  fn len(self) -> int { 2 }\n}" }} },
    .{ .name = "an impl beside an imported one", .ambiguous = 1, .files = &.{ extended_pt[0], extended_pt[1], .{ .name = "main.etch", .source = "import lib { Pt }\nimport ext1\nimpl Pt {\n  fn len(self) -> int { 3 }\n}" } } },
    .{ .name = "two impls of one file naming two methods", .ambiguous = 0, .files = &.{.{ .name = "main.etch", .source = "struct Pt { x: int = 0 }\nimpl Pt {\n  fn len(self) -> int { 1 }\n}\nimpl Pt {\n  fn wid(self) -> int { 2 }\n}" }} },
    .{ .name = "an impl beside an imported one naming another method", .ambiguous = 0, .files = &.{ extended_pt[0], extended_pt[1], .{ .name = "main.etch", .source = "import lib { Pt }\nimport ext1\nimpl Pt {\n  fn wid(self) -> int { 3 }\n}" } } },
};

test "two inherent methods of one name on one type are E0218" {
    const gpa = std.testing.allocator;
    var wrong: usize = 0;
    for (inherent_cases) |c| {
        var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
        defer deinitDiags(gpa, &diags);
        try etch.validateProject(gpa, c.files, &diags);
        const ambiguous = countCode(diags.items, .ambiguous_inherent_method);
        if (ambiguous != c.ambiguous or diags.items.len != c.ambiguous) {
            wrong += 1;
            std.debug.print("{s}: {d} E0218 among {d} diagnostics, expected {d}\n", .{ c.name, ambiguous, diags.items.len, c.ambiguous });
            for (diags.items) |d| std.debug.print("  {t} {s}\n", .{ d.code, d.primary_message });
        }
    }
    try std.testing.expectEqual(@as(usize, 0), wrong);
}

test "self in an impl on an enum is the enum" {
    const gpa = std.testing.allocator;
    const files = [_]etch.ProjectFile{.{ .name = "main.etch", .source =
        \\enum Dir { north, south }
        \\trait Named {
        \\  fn nm(self) -> int
        \\}
        \\impl Named for Dir {
        \\  fn nm(self) -> int { match self { .west => 1, _ => 0 } }
        \\}
    }};
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 1), countCode(diags.items, .enum_variant_not_found));
    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
}

test "a type a module imports is judged in its signatures as the declaration" {
    const gpa = std.testing.allocator;
    const ext = etch.ProjectFile{ .name = "use.etch", .source = "import lib { Pt }\nfn use_pt(p: Pt) -> int { p.x }" };
    var ok: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &ok);
    try etch.validateProject(gpa, &(extended_pt ++ [_]etch.ProjectFile{ ext, .{ .name = "main.etch", .source = "import lib { Pt }\nimport use { use_pt }\nfn f(p: Pt) -> int { use_pt(p) }" } }), &ok);
    try std.testing.expectEqual(@as(usize, 0), ok.items.len);
    var bad: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &bad);
    try etch.validateProject(gpa, &(extended_pt ++ [_]etch.ProjectFile{ ext, .{ .name = "main.etch", .source = "import lib { Pt }\nimport use { use_pt }\nfn f() -> int { use_pt(1) }" } }), &bad);
    try std.testing.expectEqual(@as(usize, 1), countCode(bad.items, .type_mismatch));
    try std.testing.expectEqual(@as(usize, 1), bad.items.len);
}

test "an item imported under another name is judged as its declaration" {
    const gpa = std.testing.allocator;
    const main_ok =
        \\import lib { Pt as Point, twice as tw, Shape as Sh }
        \\fn g<T: Sh>(t: T) -> int { 0 }
        \\fn f(p: Point) -> int { p.len() + p.area() + tw(n: 1) + g(p) }
    ;
    const main_bad =
        \\import lib { twice as tw }
        \\fn f() -> int { tw(true) }
    ;
    var ok: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &ok);
    try etch.validateProject(gpa, &.{ .{ .name = "lib.etch", .source = positions_lib }, .{ .name = "main.etch", .source = main_ok } }, &ok);
    try std.testing.expectEqual(@as(usize, 0), ok.items.len);
    var bad: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &bad);
    try etch.validateProject(gpa, &.{ .{ .name = "lib.etch", .source = positions_lib }, .{ .name = "main.etch", .source = main_bad } }, &bad);
    try std.testing.expectEqual(@as(usize, 1), countCode(bad.items, .type_mismatch));
    try std.testing.expectEqual(@as(usize, 1), bad.items.len);
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

test "a collection field of an imported resource keeps its element type" {
    const gpa = std.testing.allocator;
    const files = [_]etch.ProjectFile{
        .{ .name = "lib.etch", .source = "enum Dir { north, south }\nresource Nav { dirs: Dir[], seen: Set<Dir>, names: [string: Dir] }\n" },
        .{ .name = "main.etch", .source =
        \\import lib { Nav, Dir }
        \\rule r() when resource Nav {
        \\  get_mut(Nav).dirs = 5
        \\  get_mut(Nav).seen = 5
        \\  get_mut(Nav).names = 5
        \\}
        },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 3), diags.items.len);
    try std.testing.expectEqual(@as(usize, 3), countCode(diags.items, .type_mismatch));
}

test "a mistyped field of an imported resource in a scene file is refused" {
    const gpa = std.testing.allocator;
    const files = [_]etch.ProjectFile{
        .{ .name = "lib.etch", .source = "resource Mode { players: int = 4, title: string = \"x\" }\ncomponent C { v: int = 0 }\n" },
        .{ .name = "level.scene.etch", .source =
        \\import lib { Mode, C }
        \\scene "S" {
        \\  resources { Mode { players: true, title: 3 } }
        \\  entity "e" { uuid: "7b3e2f1a-42a3-4f2b-8c9d-a3f2b1c98d4e" C { v: 1 } }
        \\}
        },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 2), diags.items.len);
    try std.testing.expectEqual(@as(usize, 2), countCode(diags.items, .resource_field_type_invalid));
}

test "an empty literal for a field of an imported resource in a scene file takes its type" {
    const gpa = std.testing.allocator;
    const files = [_]etch.ProjectFile{
        .{ .name = "lib.etch", .source = "resource Bag { xs: int[] = [1], n: int = 0 }\ncomponent C { v: int = 0 }\n" },
        .{ .name = "level.scene.etch", .source =
        \\import lib { Bag, C }
        \\scene "S" {
        \\  resources { Bag { xs: [], n: [] } }
        \\  entity "e" { uuid: "7b3e2f1a-42a3-4f2b-8c9d-a3f2b1c98d4e" C { v: 1 } }
        \\}
        },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    try std.testing.expectEqual(@as(usize, 1), countCode(diags.items, .resource_field_type_invalid));
}

test "a component and an imported resource of one name are refused, the runtime naming both alike" {
    const gpa = std.testing.allocator;
    const files = [_]etch.ProjectFile{
        .{ .name = "lib.etch", .source = "resource Mode { x: int = 0 }\n" },
        .{ .name = "main.etch", .source = "import lib { Mode as Setting }\ncomponent Mode { v: int = 0 }\n" },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    try std.testing.expectEqual(@as(usize, 1), countCode(diags.items, .duplicate_symbol));
}

const foreign_geo =
    \\struct Pos { x: int = 0 }
    \\enum Dir { north, south }
    \\component Health { hp: int = 0 }
    \\resource Score { n: int = 0 }
    \\event Hit { amount: int = 0 }
    \\trait Shape {
    \\  fn area(self) -> int
    \\}
    \\type HA = Health
    \\private struct Hidden { h: int = 0 }
    \\fn mk() -> Pos { Pos { x: 1 } }
    \\fn arr() -> int[3] { [1, 2, 3] }
    \\fn mkh(h: HA) -> int { 0 }
    \\fn take(p: Pos) -> int { p.x }
    \\fn pass(e: Error) -> int { 0 }
    \\fn wrap<T>(t: T) -> Pos { Pos { x: 1 } }
    \\impl Pos {
    \\  fn shift(self, by: Dir) -> Pos { self }
    \\}
;

const foreign_files = [_]etch.ProjectFile{
    .{ .name = "base.etch", .source = "component Armor { v: int = 0 }\ntype HB = Armor" },
    .{ .name = "geo.etch", .source = foreign_geo },
    .{ .name = "use.etch", .source = "import geo as g\nfn relay(p: g.Pos) -> g.Pos { p }" },
    .{ .name = "svc.d.etch", .source = "import geo { Pos }\nservice sv {\n  fn mk() -> Pos\n}" },
};

const ForeignCase = struct {
    name: []const u8,
    main: []const u8,
    codes: []const DiagnosticCode = &.{},
    extra: ?etch.ProjectFile = null,
};

const foreign_refused = [_]ForeignCase{
    .{ .name = "a foreign return the file never names", .main = "import geo { mk }\nfn f() -> int { mk() }", .codes = &.{.return_type_mismatch} },
    .{ .name = "a foreign return the file names under another binding", .main = "import geo { mk, Pos as Q }\nfn f() -> int { mk() }", .codes = &.{.return_type_mismatch} },
    .{ .name = "a foreign return a local type shadows", .main = "import geo { mk }\nstruct Pos { y: bool = false }\nfn f() -> Pos { mk() }", .codes = &.{.return_type_mismatch} },
    .{ .name = "a foreign parameter through its module's alias", .main = "import geo { mkh }\nfn f() -> int { mkh(1) }", .codes = &.{.type_mismatch} },
    .{ .name = "a foreign parameter through an alias its module imports", .main = "import ali { mkb }\nfn f() -> int { mkb(1) }", .codes = &.{.type_mismatch}, .extra = .{ .name = "ali.etch", .source = "import base { HB }\nfn mkb(h: HB) -> int { 0 }" } },
    .{ .name = "a foreign fixed-array return", .main = "import geo { arr }\nfn f() -> int { arr() }", .codes = &.{.return_type_mismatch} },
    .{ .name = "a foreign signature written qualified", .main = "import use { relay }\nimport geo { mk }\nfn f() -> int { relay(mk()) }", .codes = &.{.return_type_mismatch} },
    .{ .name = "a foreign parameter", .main = "import geo { take }\nfn f() -> int { take(1) }", .codes = &.{.type_mismatch} },
    .{ .name = "a foreign Error parameter", .main = "import geo { pass }\nfn f() -> int { pass(1) }", .codes = &.{.type_mismatch} },
    .{ .name = "a foreign generic fn's concrete return", .main = "import geo { wrap }\nfn f() -> int { wrap(1) }", .codes = &.{.return_type_mismatch} },
    .{ .name = "a foreign method's parameter and return", .main = "import geo { Pos }\nfn f(p: Pos) -> int { p.shift(1) }", .codes = &.{ .type_mismatch, .return_type_mismatch } },
    .{ .name = "a dynamic array passed for a foreign fixed parameter", .main = "import fx { take3 }\nfn f() -> int {\n  let d: int[] = [1]\n  take3(d)\n}", .codes = &.{.type_mismatch}, .extra = .{ .name = "fx.etch", .source = "fn take3(a: int[3]) -> int { 0 }" } },
    .{ .name = "a foreign dynamic return as a fixed tail", .main = "import fx { dyn }\nfn f() -> int[3] { dyn() }", .codes = &.{.return_type_mismatch}, .extra = .{ .name = "fx.etch", .source = "fn dyn() -> int[] { [1] }" } },
    .{ .name = "a dynamic array passed for a service's fixed parameter", .main = "rule r() {\n  let d: int[] = [1]\n  let k = sf.take(d)\n}", .codes = &.{.type_mismatch}, .extra = .{ .name = "sf.d.etch", .source = "service sf {\n  fn take(a: int[3]) -> int\n}" } },
    .{ .name = "a service return the caller never names", .main = "rule r() {\n  let n: int = sv.mk()\n}", .codes = &.{.type_mismatch} },
    .{ .name = "a service signature naming no type", .main = "fn f() -> int { 0 }", .codes = &.{.undefined_symbol}, .extra = .{ .name = "bad.d.etch", .source = "service sv2 {\n  fn bad(x: Nope) -> int\n}" } },
    .{ .name = "a qualified alias", .main = "import geo as g\nfn f() -> int {\n  let x: g.HA = 1\n  0\n}", .codes = &.{.type_mismatch} },
    .{ .name = "an absent qualified member", .main = "import geo as g\nfn f() -> int {\n  let x: g.Nope = 1\n  0\n}", .codes = &.{.unknown_export} },
    .{ .name = "a private qualified member", .main = "import geo as g\nfn f() -> int {\n  let x: g.Hidden = 1\n  0\n}", .codes = &.{.import_private_item} },
    .{ .name = "a qualified type of no module alias", .main = "import geo as g\nfn f() -> int {\n  let x: h.Pos = 1\n  0\n}", .codes = &.{.undefined_symbol} },
    .{ .name = "a qualified trait as a type", .main = "import geo as g\nfn f() -> int {\n  let x: g.Shape = 1\n  0\n}", .codes = &.{.undefined_symbol} },
    .{ .name = "an absent qualified member in an optional field", .main = "import geo as g\nstruct S { p: g.Nope? }", .codes = &.{.unknown_export} },
    .{ .name = "an absent qualified parameter", .main = "import geo as g\nfn f(p: g.Nope) -> int { 0 }", .codes = &.{.unknown_export} },
    .{ .name = "an absent qualified optional return", .main = "import geo as g\nfn f() -> g.Nope? { none }", .codes = &.{.unknown_export} },
    .{ .name = "an absent qualified rule parameter", .main = "import geo as g\nrule r(p: g.Nope) {\n}", .codes = &.{.unknown_export} },
    .{ .name = "an absent qualified method parameter", .main = "import geo as g\nstruct Q { x: int = 0 }\nimpl Q {\n  fn m(self, p: g.Nope) -> int { 0 }\n}", .codes = &.{.unknown_export} },
    .{ .name = "a qualified struct as a component field", .main = "import geo as g\ncomponent C { p: g.Pos }", .codes = &.{.undefined_symbol} },
    .{ .name = "one method of one name on one type written under two names", .main = "import geo { Pos, Pos as P2 }\nimpl Pos {\n  fn a(self) -> int { 0 }\n}\nimpl P2 {\n  fn a(self) -> int { 1 }\n}", .codes = &.{.ambiguous_inherent_method} },
    .{ .name = "a field a qualified struct lacks", .main = "import geo as g\nfn f(p: g.Pos) -> int { p.nope }", .codes = &.{.invalid_field_filter} },
    .{ .name = "a field a qualified struct lacks, a local one having it", .main = "import geo as g\nstruct Pos { y: bool = false }\nfn f(p: g.Pos) -> bool { p.y }", .codes = &.{.invalid_field_filter} },
    .{ .name = "a qualified struct is not the local one of its name", .main = "import geo as g\nstruct Pos { y: bool = false }\nfn f(p: g.Pos) -> Pos { p }", .codes = &.{.return_type_mismatch} },
    .{ .name = "a qualified enum is not the local one of its name", .main = "import geo as g\nenum Dir { east }\nfn f(d: g.Dir) -> Dir { d }", .codes = &.{.return_type_mismatch} },
    .{ .name = "a field a qualified component lacks", .main = "import geo as g\nfn f(h: g.Health) -> int { h.nope }", .codes = &.{.invalid_field_filter} },
    .{ .name = "a field a qualified resource lacks", .main = "import geo as g\nfn f(r: g.Score) -> int { r.nope }", .codes = &.{.invalid_field_filter} },
    .{ .name = "a component of a name a whole-module import brings", .main = "import geo as g\ncomponent Health { v: int = 0 }", .codes = &.{.duplicate_symbol} },
    .{ .name = "an empty literal passed for a service's fixed parameter", .main = "rule r() {\n  let k = sf.take([])\n}", .codes = &.{.type_mismatch}, .extra = .{ .name = "sf.d.etch", .source = "service sf {\n  fn take(a: int[3]) -> int\n}" } },
    .{ .name = "an int for an audio_graph's imported enum param", .main = "import geo { Dir }\naudio_graph G {\n  params {\n    d: Dir = 5\n  }\n  output(wave_player(\"a.wav\"))\n}", .codes = &.{.type_mismatch} },
    .{ .name = "a local enum's variant for an audio_graph's qualified enum param", .main = "import geo as g\nenum Wind { west }\naudio_graph G {\n  params {\n    d: g.Dir = .west\n  }\n  output(wave_player(\"a.wav\"))\n}", .codes = &.{.enum_variant_not_found} },
};

const foreign_accepted = [_]ForeignCase{
    .{ .name = "a foreign return named", .main = "import geo { mk, Pos }\nfn f() -> Pos { mk() }" },
    .{ .name = "a foreign return written qualified", .main = "import geo as g\nimport geo { mk }\nfn f() -> g.Pos { mk() }" },
    .{ .name = "a qualified struct field", .main = "import geo as g\nstruct S { p: g.Pos }" },
    .{ .name = "a qualified optional struct field", .main = "import geo as g\nstruct S { p: g.Pos? }" },
    .{ .name = "a field of a qualified struct", .main = "import geo as g\nfn f(p: g.Pos) -> int { p.x }" },
    .{ .name = "two spellings of one declaration", .main = "import geo { Pos as P2 }\nimport geo as g\nfn f(p: P2) -> g.Pos { p }" },
    .{ .name = "a foreign alias parameter", .main = "import geo { mkh, Health }\nfn f(h: Health) -> int { mkh(h) }" },
    .{ .name = "a foreign parameter through an alias its module imports", .main = "import ali { mkb }\nimport base { Armor }\nfn f(a: Armor) -> int { mkb(a) }", .extra = .{ .name = "ali.etch", .source = "import base { HB }\nfn mkb(h: HB) -> int { 0 }" } },
    .{ .name = "a foreign fixed-array return", .main = "import geo { arr }\nfn f() -> int[3] { arr() }" },
    .{ .name = "a foreign qualified signature", .main = "import use { relay }\nimport geo { mk }\nfn f() -> int { relay(mk()).x }" },
    .{ .name = "a foreign enum parameter of a method", .main = "import geo { Pos, Dir }\nfn f(p: Pos) -> Pos { p.shift(.north) }" },
    .{ .name = "a shorthand against a qualified enum", .main = "import geo as g\nfn f(d: g.Dir) -> bool { d == .north }" },
    .{ .name = "a service return the caller never names", .main = "rule r() {\n  let p = sv.mk()\n}" },
    .{ .name = "an Error across modules", .main = "import geo { pass }\nfn f(e: Error) -> int { pass(e) }" },
    .{ .name = "a field of a qualified component", .main = "import geo as g\nfn f(h: g.Health) -> int { h.hp }" },
    .{ .name = "a foreign generic fn's concrete return", .main = "import geo { wrap, Pos }\nfn f() -> Pos { wrap(1) }" },
    .{ .name = "one enum under two names gives a shorthand one enum", .main = "import geo { Dir, Dir as D2 }\nfn f() -> bool {\n  let d = .north\n  true\n}" },
    .{ .name = "an empty literal passed for a service's dynamic parameter", .main = "rule r() {\n  let k = sf.take([])\n}", .extra = .{ .name = "sf.d.etch", .source = "service sf {\n  fn take(a: int[]) -> int\n}" } },
    .{ .name = "an anonymous literal passed for a service's struct parameter", .main = "rule r() {\n  let k = sf.put(.{ x: 1 })\n}", .extra = .{ .name = "sf.d.etch", .source = "import geo { Pos }\nservice sf {\n  fn put(p: Pos) -> int\n}" } },
    .{ .name = "an anonymous literal in a data entry's optional field of a qualified struct", .main = "import geo as g\nstruct Item { p: g.Pos? = none }\ndata Db: Item {\n  e: { p: .{ x: 1 } },\n}" },
    .{ .name = "an anonymous literal in a data entry of a foreign entry type", .main = "import items { Item }\ndata Db: Item {\n  e: { p: .{ x: 1 } },\n}", .extra = .{ .name = "items.etch", .source = "import geo { Pos }\nstruct Item { p: Pos? = none }" } },
    .{ .name = "a variant for an audio_graph's imported enum param", .main = "import geo { Dir }\naudio_graph G {\n  params {\n    d: Dir = .south\n  }\n  output(wave_player(\"a.wav\"))\n}" },
    .{ .name = "an anonymous literal for an audio_graph's qualified struct param", .main = "import geo as g\naudio_graph G {\n  params {\n    p: g.Pos = .{ x: 1 }\n  }\n  output(wave_player(\"a.wav\"))\n}" },
};

/// Whether `main`, beside the foreign modules, draws exactly `c.codes`.
fn foreignJudged(c: ForeignCase) !bool {
    const gpa = std.testing.allocator;
    const main = etch.ProjectFile{ .name = "main.etch", .source = c.main };
    var files: std.ArrayListUnmanaged(etch.ProjectFile) = .empty;
    defer files.deinit(gpa);
    try files.appendSlice(gpa, &foreign_files);
    if (c.extra) |e| try files.append(gpa, e);
    try files.append(gpa, main);
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, files.items, &diags);
    var right = diags.items.len == c.codes.len;
    for (c.codes) |code| {
        var want: usize = 0;
        for (c.codes) |k| {
            if (k == code) want += 1;
        }
        if (countCode(diags.items, code) != want) right = false;
    }
    if (!right) {
        std.debug.print("{s}:\n", .{c.name});
        for (diags.items) |d| std.debug.print("  {t} {s}\n", .{ d.code, d.primary_message });
    }
    return right;
}

test "a foreign type is the declaration it names, refused where it does not fit" {
    var wrong: usize = 0;
    for (foreign_refused) |c| {
        if (!try foreignJudged(c)) wrong += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), wrong);
}

test "a foreign type is the declaration it names, accepted where it fits" {
    var wrong: usize = 0;
    for (foreign_accepted) |c| {
        if (!try foreignJudged(c)) wrong += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), wrong);
}
