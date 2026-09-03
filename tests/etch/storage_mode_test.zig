//! M1.B — `@storage` consumed, and the Etch-side boundary of the day.
//!
//! WRITTEN AT G1, when the gate's exit was a declared no-op: the mode reached
//! the registry and nothing read it. That is no longer true — G2 delivered the
//! backend and G3 the routing — so the no-op pin was REPLACED by its opposite
//! rather than deleted, and this header is corrected rather than left standing
//! beside its correction. What the file holds now: the recorded mode with its
//! negative twin, the refusal diagnostics, an empty declaration, and the
//! CURRENT limit — a rule does not yet select an entity by a sparse component,
//! which is G7's planner and is pinned here so its arrival flips the assertion.
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

/// Read a component's first field as an Etch `float`, which is an f64.
fn readF64(world: *World, entity: weld_core.ecs.EntityId, cid: ComponentId) f64 {
    const b = world.componentBytes(entity, cid).?;
    return @bitCast(std.mem.readInt(u64, b[0..8], .little));
}

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

/// A sparse component whose field a rule reads and writes. The whole Etch
/// surface for a component is `get`/`get_mut` + a field path, so this is the
/// smallest program that exercises the bridge's handle end to end.
const src_rule =
    \\@storage(.sparse)
    \\component Burning { remaining: float = 3.0 }
    \\
    \\rule tick_burn(entity: Entity)
    \\    when entity has Burning
    \\{
    \\    let b = entity.get_mut(Burning)
    \\    b.remaining -= 1.0
    \\}
;

test "G5 boundary: a rule does NOT yet select an entity by a SPARSE component" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    var pr = try weld_etch.parseSource(gpa, src_rule);
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
    try typeCheckClean(gpa, &pr.ast);
    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();

    const burning = world.registry.idOf("Burning").?;
    // Spawned from the REGISTRY DEFAULTS rather than a hand-built payload: the
    // declaration says `remaining: float = 3.0`, so the default is the initial
    // value, and a hand-built buffer would have to guess the layout the Etch
    // front-end chose (a first version passed four bytes and tripped
    // `assert(bytes.len == elem_size)` — my test, not the routing).
    const e = try world.spawnDynamic(gpa, &.{burning});
    try std.testing.expect(world.hasComponentDyn(e, burning));
    // Etch's `float` is an f64 and the component is 8 bytes wide — measured, not
    // assumed: a first version read an f32 at offset 0 and got 0, which is the
    // low half of the f64. Three of this gate's failures were test premises
    // about the Etch front-end and none was a routing defect.
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), readF64(&world, e, burning), 1e-9);

    var report: weld_etch.RuntimeReport = .{};
    try interp.stepOnce(&world, &report);

    // THE BOUNDARY, pinned rather than asserted in prose. `when entity has
    // Burning` resolves through `World.queryDynamic`, which matches by
    // ARCHETYPE SIGNATURE — and since G3 a sparse component is not in one, so
    // the rule selects nothing and the body never runs. Measured, not
    // predicted: the value is unchanged at 3.0 and the write never happened.
    //
    // That is **G7**'s planner, not G5's handle: G5 makes the bridge's
    // `ComponentRef` bimodal, which is what the body needs ONCE it runs, and
    // until selection is bimodal no Etch rule reaches a sparse component at
    // all. So G5's own oracle lives at the bridge (inline in `ecs_bridge.zig`),
    // and this test is the limit made observable.
    //
    // G7 REPLACES this assertion by its opposite — `2.0` — exactly as G3
    // replaced G1's no-op pin. If it is still here at G11, the planner did not
    // land.
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), readF64(&world, e, burning), 1e-9);
}

/// An all-negative rule plus a sparse component: the entity carrying only the
/// sparse one lives in the EMPTY archetype, which an all-negative term matches.
const src_all_negative =
    \\@storage(.sparse)
    \\component Burning { remaining: float = 3.0 }
    \\component Frozen { flag: bool = false }
    \\
    \\rule scan_unfrozen(entity: Entity)
    \\    when not entity has Frozen
    \\{
    \\    let seen = 1
    \\}
;

test "an all-negative rule VISITS an entity that carries only sparse components" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    var pr = try weld_etch.parseSource(gpa, src_all_negative);
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
    try typeCheckClean(gpa, &pr.ast);
    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();

    const burning = world.registry.idOf("Burning").?;
    const frozen = world.registry.idOf("Frozen").?;

    // Carries ONLY a sparse component, so its archetype signature is empty.
    const bare = try world.spawnDynamic(gpa, &.{burning});
    // And one the rule must exclude, so the count below is a discrimination.
    _ = try world.spawnDynamic(gpa, &.{frozen});
    try std.testing.expectEqual(
        @as(usize, 0),
        world.dynamicArchetype(world.dynamicLocation(bare).?.archetype_idx).component_ids.len,
    );

    var report: weld_etch.RuntimeReport = .{};
    try interp.stepOnce(&world, &report);

    // THE OTHER HALF of the empty-archetype permission G2 opened and G3's report
    // did not mention: G3 pinned that an all-negative query MATCHES the empty
    // archetype (`dq.matching`), which is not the same claim as ITERATING it —
    // "iterating a zero-column archetype has never been exercised anywhere",
    // in the brief's own words. Measured here: `per_slot` starts at
    // `@sizeOf(EntityId)`, so a zero-column archetype gets a real finite
    // capacity, and the walk yields the entity.
    //
    // EXACTLY ONE: the `Frozen` carrier is excluded, so this is not "the rule
    // visits everything".
    try std.testing.expectEqual(@as(u64, 1), report.entities_iterated);
}
