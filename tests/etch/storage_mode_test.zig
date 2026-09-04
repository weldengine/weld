//! M1.B — `@storage` consumed, and the Etch-side boundary of the day.
//!
//! WRITTEN AT G1, when the gate's exit was a declared no-op: the mode reached
//! the registry and nothing read it. That is no longer true — G2 delivered the
//! backend and G3 the routing — so the no-op pin was REPLACED by its opposite
//! rather than deleted, and this header is corrected rather than left standing
//! beside its correction. What the file holds now: the recorded mode with its
//! negative twin, the refusal diagnostics, an empty declaration, and the
//! and — since G7 — a rule SELECTING an entity by a sparse component and
//! writing its row, which is the G5 boundary pin replaced by its opposite.
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

/// Read a component's first field as an Etch `int`, which is an i64.
fn readI64(world: *World, entity: weld_core.ecs.EntityId, cid: ComponentId) i64 {
    const b = world.componentBytes(entity, cid).?;
    return std.mem.readInt(i64, b[0..8], .little);
}

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

test "a rule SELECTS an entity by a sparse component, and its body writes the row" {
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

    // THE G5 BOUNDARY PIN, REPLACED BY ITS OPPOSITE — the third time this
    // milestone flips a pinned limit rather than deleting it, after
    // `chunk.zig`'s "rejects empty component list" at G2 and G1's `@storage`
    // no-op at G3.
    //
    // What it asserted at G5: `3.0`, unchanged, because `when entity has
    // Burning` resolved through `World.queryDynamic`, which matches by
    // ARCHETYPE SIGNATURE — and since G3 a sparse component is in none, so the
    // rule selected nothing and its body never ran. Measured, not predicted.
    //
    // What it asserts now: `2.0`. The selection goes through the mixed planner,
    // which elects `Burning` as the driver — the only member, so smallest by
    // default — walks its dense array, and hands each position to the shared
    // per-entity body whose four guards take a storage-agnostic locator. The
    // write `b.remaining -= 1.0` then lands in the sparse ROW through the
    // bimodal `ComponentRef` G5 built.
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), readF64(&world, e, burning), 1e-9);
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

/// A disjunctive rule with a SPARSE term. The union must visit an entity
/// matching BOTH disjuncts exactly once — and the archetype-id merge cannot
/// provide that here, because a sparse-driven term has no archetype to order by.
const src_disjunct =
    \\@storage(.sparse)
    \\component Burning { remaining: float = 3.0 }
    \\component Wet { amount: float = 0.0 }
    \\
    \\rule douse(entity: Entity)
    \\    when entity has Burning or entity has Wet
    \\{
    \\    let seen = 1
    \\}
;

test "a disjunctive rule with a sparse term visits a both-matching entity ONCE" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    var pr = try weld_etch.parseSource(gpa, src_disjunct);
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
    try typeCheckClean(gpa, &pr.ast);
    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();

    const burning = world.registry.idOf("Burning").?;
    const wet = world.registry.idOf("Wet").?;

    _ = try world.spawnDynamic(gpa, &.{burning}); // first disjunct only
    _ = try world.spawnDynamic(gpa, &.{wet}); // second only
    _ = try world.spawnDynamic(gpa, &.{ burning, wet }); // BOTH — the dedup case

    var report: weld_etch.RuntimeReport = .{};
    try interp.stepOnce(&world, &report);

    // THREE, not four. The both-matching entity is the whole point: the
    // ascending-`archetype_id` merge de-duplicates by archetype, and one of
    // these terms is sparse-driven and keeps no archetype cache — so the union
    // switches to an ENTITY key. Without that switch the entity would be
    // visited twice and this would read 4.
    try std.testing.expectEqual(@as(u64, 3), report.entities_iterated);
}

/// `Changed<T>` on a TABLE member while the driver is SPARSE — the first of the
/// four paths the contract names as *"à vérifier et pas supposer"*: "le filtre
/// `Changed<T>` sur un membre table quand le driver est sparse (le tick se lit
/// par lookup, pas par scan)".
///
/// Shaped after the established table-only test (`query_filters_test.zig`,
/// "changed fires per-slot intra-archetype"): the change is produced INSIDE the
/// tick by another rule and counted in a field, rather than stamped from
/// outside before the first advance. A first version did the latter and failed
/// on tick 1 — `initial_tick` is 0 and a `changed` filter tests
/// `changedTick > last_run_tick`, so a stamp made before the clock moves is not
/// a change. My premise, not the code.
const src_changed_mixed =
    \\@storage(.sparse)
    \\component Burning { remaining: float = 3.0 }
    \\component Health { current: float = 100.0 }
    \\component Hits { n: int = 0 }
    \\
    \\rule touch(entity: Entity)
    \\    when entity has Health
    \\{
    \\    let h = entity.get_mut(Health)
    \\    h.current += 1.0
    \\}
    \\
    \\rule react(entity: Entity)
    \\    when entity has Burning and entity has Health changed and entity has Hits
    \\{
    \\    let c = entity.get_mut(Hits)
    \\    c.n += 1
    \\}
;

test "a change filter on a TABLE member holds when the driver is SPARSE" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    var pr = try weld_etch.parseSource(gpa, src_changed_mixed);
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
    try typeCheckClean(gpa, &pr.ast);
    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();

    const burning = world.registry.idOf("Burning").?;
    const health = world.registry.idOf("Health").?;
    const hits = world.registry.idOf("Hits").?;

    // `lit` carries the sparse driver; `cold` does not, so it is the negative
    // twin that shows the driver actually bounds the reacting rule.
    const lit = try world.spawnDynamic(gpa, &.{ burning, health, hits });
    const cold = try world.spawnDynamic(gpa, &.{ health, hits });

    _ = try interp.runFor(&world, 3);

    // `Burning` is sparse and the smallest member of `react`'s with-set, so it
    // DRIVES — and `Health`'s change tick is then read by lookup rather than by
    // a chunk scan, which is the path the contract says to verify. Three ticks,
    // three writes by `touch`, three reactions.
    try std.testing.expectEqual(@as(i64, 3), readI64(&world, lit, hits));
    // And the entity without the driver reacts NEVER, though `touch` changed
    // its `Health` on every tick — without this the count above would not
    // distinguish "the driver bounds the rule" from "the filter always passes".
    try std.testing.expectEqual(@as(i64, 0), readI64(&world, cold, hits));
}

// ─── M1.B / G8 — structural effects and observers under a SPARSE driver ─────

const src_sparse_driven_add =
    \\@storage(.sparse)
    \\component Burning { remaining: float = 3.0 }
    \\component Scorched { n: i32 = 0 }
    \\
    \\rule mark_scorched(entity: Entity)
    \\    when entity has Burning
    \\{
    \\    entity.add(Scorched { n: 1 })
    \\}
;

const AddSpy = struct {
    var fired: u32 = 0;
    var entities: [16]weld_core.ecs.EntityId = undefined;
    fn reset() void {
        fired = 0;
    }
    fn cb(
        ctx: ?*anyopaque,
        w: *World,
        entity: weld_core.ecs.EntityId,
        component_id: ?ComponentId,
        old_value: ?*const anyopaque,
        new_value: ?*const anyopaque,
        deferred: *weld_core.ecs.CommandBuffer,
    ) anyerror!void {
        _ = ctx;
        _ = w;
        _ = component_id;
        _ = old_value;
        _ = new_value;
        _ = deferred;
        if (fired < entities.len) entities[fired] = entity;
        fired += 1;
    }
};

test "G8: the planner elects SPARSE, and the effect applies exactly once per matching entity" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    var pr = try weld_etch.parseSource(gpa, src_sparse_driven_add);
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
    try typeCheckClean(gpa, &pr.ast);
    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    try interp.bindToWorld(&world);

    const burning = world.registry.idOf("Burning").?;
    const scorched = world.registry.idOf("Scorched").?;

    // Five matching entities plus one that does NOT carry the driver, so the
    // counts below are a discrimination and not a population.
    var matching: [5]weld_core.ecs.EntityId = undefined;
    for (&matching) |*e| e.* = try world.spawnDynamic(gpa, &.{burning});
    const bystander = try world.spawnDynamic(gpa, &.{});

    AddSpy.reset();
    try world.observer_registry.registerOnAdd(gpa, &world, scorched, null, &AddSpy.cb);

    // THE DISCRIMINATING HALF, and it exists because the correctness half below
    // does NOT discriminate. Measured: forcing `electDriver` to return `.table`
    // leaves every assertion below GREEN — with an all-sparse with-set the
    // table-driven arm's archetype filter is empty, matches every archetype,
    // and the per-entity membership test selects the same five. The answer is
    // driver-independent BY DESIGN; the cost is not. So the election is asserted
    // where it is decided, or this test's name would be a claim it cannot back.
    {
        try std.testing.expectEqual(@as(usize, 1), interp.rule_descs.len);
        const sel = interp.rule_descs[0].selection;
        try std.testing.expectEqual(@as(usize, 1), sel.len);
        try std.testing.expect(!sel[0].isTableDriven());
        try std.testing.expectEqual(burning, sel[0].sparse.driver);
    }

    var report: weld_etch.RuntimeReport = .{};
    try interp.stepOnce(&world, &report);

    // THE CORRECTNESS HALF — a multiplicity, never an order. The contract
    // makes the visit order deterministic, non-invariant and OUT OF CONTRACT,
    // so an oracle on the sequence would pin what the corpus refuses to
    // promise. What it does promise is EXACTLY ONCE per matching entity per
    // tick, and that survives the driver being a dense array.
    try std.testing.expectEqual(@as(u64, 5), report.entities_iterated);
    for (matching) |e| try std.testing.expect(world.hasComponentDyn(e, scorched));
    try std.testing.expect(!world.hasComponentDyn(bystander, scorched));

    // The observers fired once per applied command — five, not ten, and not
    // five-plus-the-bystander. `on_added` fires at the flush, so this is the
    // apply order following the RECORDING order, which follows the visit order.
    try std.testing.expectEqual(@as(u32, 5), AddSpy.fired);

    // Each observed entity is distinct and is one of the matching five: a
    // recording that emitted one entity twice would keep the count at five
    // while being wrong, so the SET is checked and not only its size.
    for (0..AddSpy.fired) |i| {
        const seen = AddSpy.entities[i];
        try std.testing.expect(std.mem.indexOfScalar(weld_core.ecs.EntityId, &matching, seen) != null);
        for (0..i) |j| try std.testing.expect(@as(u64, @bitCast(AddSpy.entities[j])) != @as(u64, @bitCast(seen)));
    }

    // A SECOND tick must not re-add: `Scorched` is now present, and the rule's
    // `when` still matches, so this is the add-on-present path reached from a
    // sparse-driven walk. It must not double the count.
    AddSpy.reset();
    var report2: weld_etch.RuntimeReport = .{};
    try interp.stepOnce(&world, &report2);
    try std.testing.expectEqual(@as(u64, 5), report2.entities_iterated);
    for (matching) |e| try std.testing.expect(world.hasComponentDyn(e, scorched));
}

// ─── M1.B / G9 — the counter is per TICK, on a `changed`-free program ───────

const src_requires_strip =
    \\component Transform { x: float = 0.0 }
    \\
    \\@requires(Transform)
    \\component Mesh { v: i32 = 0 }
    \\
    \\rule strip(entity: Entity)
    \\    when entity has Mesh
    \\{
    \\    entity.remove(Transform)
    \\}
;

test "G9: the skip counter resets per tick even with NO `changed` filter" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    var pr = try weld_etch.parseSource(gpa, src_requires_strip);
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
    try typeCheckClean(gpa, &pr.ast);
    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();
    try interp.bindToWorld(&world);

    // THE PREMISE, ASSERTED AND NOT ASSUMED. This program carries no `changed`
    // filter, so `stepOnce`'s `if (self.has_changed) world.beginFrame()` never
    // fires — which is exactly the regime the first version of the counter got
    // wrong. Without this assertion the test would pass on a program that DID
    // carry one, and would not distinguish the two regimes at all: the defect
    // caught in G8 by forcing `electDriver`, applied here before it can repeat.
    try std.testing.expect(!interp.has_changed);

    const transform = world.registry.idOf("Transform").?;
    const mesh = world.registry.idOf("Mesh").?;

    const e = try world.spawnDynamic(gpa, &.{});
    try world.addComponentDynamic(gpa, e, mesh, &[_]u8{0} ** 4);
    try std.testing.expect(world.hasComponentDyn(e, transform)); // the closure

    // Tick 1 — the rule asks to remove a still-required `Transform`.
    var r1: weld_etch.RuntimeReport = .{};
    try interp.stepOnce(&world, &r1);
    world.tickBoundary();
    // The skip HAPPENED during the tick; the boundary above cleared the count,
    // which is the contract `resources`' dirty flags already carry — read
    // during the tick, cleared at the boundary.
    try std.testing.expect(world.hasComponentDyn(e, transform));
    try std.testing.expectEqual(@as(u32, 0), world.requires_removals_skipped);

    // Tick 2 — and the count must be ONE again mid-tick, not two. Under the
    // defect nothing reset between the ticks, so this read returned 2 and the
    // field meant "since the run started".
    var r2: weld_etch.RuntimeReport = .{};
    try interp.stepOnce(&world, &r2);
    try std.testing.expectEqual(@as(u32, 1), world.requires_removals_skipped);
    try std.testing.expectEqual(transform, world.first_requires_skip.?);
    world.tickBoundary();
    try std.testing.expectEqual(@as(u32, 0), world.requires_removals_skipped);
    try std.testing.expect(world.first_requires_skip == null);

    // And the invariant held throughout: `Mesh` is present and so is its
    // closure, which is what "skipped" buys over "tolerated".
    try std.testing.expect(world.hasComponentDyn(e, mesh));
    try std.testing.expect(world.hasComponentDyn(e, transform));
}
