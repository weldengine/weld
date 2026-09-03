//! M1.B / G1 — `@storage` consumed: the mode reaches the runtime registry, and
//! nothing reads it yet.
//!
//! The gate's exit is deliberately a **declared no-op**. After G1 a component
//! annotated `@storage(.sparse)` is recorded as `sparse` in the registry and is
//! still stored exactly as a table component — there is no sparse backend
//! before G2. This file is what makes that sentence observable instead of
//! asserted: one test reads the recorded mode, the next shows the storage did
//! not move.
//!
//! Why the mode test matters more than its size suggests: `@storage` was
//! recognised by the parser and validated for applicability since M0.8, and its
//! VALUE was read by no code at all. This is the test that would have failed
//! for the four months during which the annotation was a no-op, and there was
//! none.

const std = @import("std");
const weld_etch = @import("weld_etch");
const weld_core = @import("weld_core");

const World = weld_core.ecs.world.World;
const ComponentId = weld_core.ecs.registry.ComponentId;
const StorageKind = weld_core.ecs.registry.StorageKind;
const Interpreter = weld_etch.Interpreter;
const Diagnostic = weld_etch.Diagnostic;
const lower = weld_etch.codegen_zig.lower;

/// One sparse component, one plain one, so every assertion below has its
/// negative twin in the same program rather than in a second scene.
const src_mixed =
    \\@storage(.sparse)
    \\component Burning { remaining: float = 3.0 }
    \\component Health { current: float = 100.0 }
;

fn typeCheckClean(gpa: std.mem.Allocator, arena: *weld_etch.Ast) !void {
    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try weld_etch.typeCheck(gpa, arena, &diags);
    if (diags.items.len != 0) {
        for (diags.items) |d| std.debug.print("unexpected diagnostic {s}: {s}\n", .{ d.code.code(), d.primary_message });
        return error.UnexpectedDiagnostic;
    }
}

test "the registry records the storage mode a component declared" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    var pr = try weld_etch.parseSource(gpa, src_mixed);
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
    try typeCheckClean(gpa, &pr.ast);

    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();

    const burning = world.registry.idOf("Burning").?;
    const health = world.registry.idOf("Health").?;

    // The annotated component carries the mode it declared…
    try std.testing.expectEqual(StorageKind.sparse, world.registry.componentStorage(burning));
    // …and the un-annotated one carries the domain's default, which is what
    // makes the first assertion a discrimination and not a constant.
    try std.testing.expectEqual(StorageKind.table, world.registry.componentStorage(health));
}

test "a sparse component leaves the archetype signature and lives in its own store" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    var pr = try weld_etch.parseSource(gpa, src_mixed);
    defer pr.deinit(gpa);
    try typeCheckClean(gpa, &pr.ast);
    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();

    const burning = world.registry.idOf("Burning").?;
    const health = world.registry.idOf("Health").?;

    const e = try world.spawnDynamic(gpa, &[_]ComponentId{ burning, health });

    // REPLACES the G1 pin `G1 leaves the mode a declared no-op: a sparse
    // component still stores as table`, whose assertions were
    // `expect(arch.hasComponent(burning))` and
    // `expect(arch.hasComponent(health))` — both true then, because nothing
    // read the mode. G3 is what ends that no-op, so the pin is replaced by its
    // OPPOSITE rather than deleted: `burning` must now be ABSENT from the
    // signature. (The G1 comment said G2 would change it; G2 delivered the
    // backend and G3 the routing.)
    const loc = world.dynamicLocation(e).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    try std.testing.expect(!arch.hasComponent(burning));
    // …while the table component stays exactly where it was, which is what
    // makes the line above a discrimination and not a constant: an
    // implementation that dropped every component from every signature would
    // pass the first assertion and fail this one.
    try std.testing.expect(arch.hasComponent(health));

    // The entity nevertheless CARRIES the sparse component, answered through
    // the routed World-level entries. Asserting only the archetype's absence
    // would be an absence witness with no presence witness beside it — the
    // shape that lets "routed" and "silently dropped" pass the same test.
    try std.testing.expect(world.hasComponentDyn(e, burning));
    try std.testing.expect(world.hasComponentDyn(e, health));
    try std.testing.expect(world.componentBytes(e, burning) != null);

    // And the row really is in the sparse store, read from the backend rather
    // than through the entry under test.
    const store = world.sparse_stores.getConst(burning).?;
    try std.testing.expect(store.contains(e));
    try std.testing.expectEqual(@as(usize, 1), store.len());

    // The recorded mode survived the spawn — the registry is the mode's home,
    // not the archetype and not the store.
    try std.testing.expectEqual(StorageKind.sparse, world.registry.componentStorage(burning));
}

test "an empty component declaration is legal, and its declared mode records" {
    // The probe M1.B/G0 could not settle without compiling: the spec's own
    // example of a sparse tag is `@storage(.sparse) component InCombat {}`, and
    // NO Etch-declared empty component exists anywhere in the corpora. Reading
    // the wiring said it should pass — `parseComponentDecl` loops
    // `while (peek() != .rbrace)`, so an immediate `}` yields zero fields, and
    // the type-checker has no field-count floor. This compiles that reading.
    //
    // The zero-SIZE case has a table-side twin in production already
    // (`Sleeping = extern struct {}`, `src/modules/forge/api/components.zig`),
    // so what is new here is only the Etch spelling.
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    var pr = try weld_etch.parseSource(gpa,
        \\@storage(.sparse)
        \\component InCombat {}
    );
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
    try typeCheckClean(gpa, &pr.ast);

    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();

    const id = world.registry.idOf("InCombat").?;
    try std.testing.expectEqual(StorageKind.sparse, world.registry.componentStorage(id));
    try std.testing.expectEqual(@as(u16, 0), world.registry.componentSize(id));
}

test "the codegen refuses a sparse component, with its own typed error" {
    const gpa = std.testing.allocator;
    var pr = try weld_etch.parseSource(gpa, src_mixed);
    defer pr.deinit(gpa);
    try typeCheckClean(gpa, &pr.ast);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);

    // `SparseStorageUnsupported` and not `UnsupportedConstruct`: the generic
    // variant already covers generics, `async`, `throws` and optional fields,
    // so asserting it could not tell this refusal from any of those.
    try std.testing.expectError(
        error.SparseStorageUnsupported,
        lower.generateFile(gpa, &pr.ast, "storage_mode_test.etch", &buf),
    );
}

test "counter-factual: the same program without @storage lowers" {
    // Without this the refusal test proves only that SOMETHING about the
    // program is refused. The two sources differ in exactly one line — the
    // annotation — so what is measured is the annotation and not the shape.
    const gpa = std.testing.allocator;
    var pr = try weld_etch.parseSource(gpa,
        \\component Burning { remaining: float = 3.0 }
        \\component Health { current: float = 100.0 }
    );
    defer pr.deinit(gpa);
    try typeCheckClean(gpa, &pr.ast);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);

    const stats = try lower.generateFile(gpa, &pr.ast, "storage_mode_test.etch", &buf);
    try std.testing.expectEqual(@as(u32, 2), stats.components);
    try std.testing.expect(buf.items.len > 0);
}
