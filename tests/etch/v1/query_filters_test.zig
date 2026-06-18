//! M1.0.0 — Interpreter ↔ filtered ECS queries.
//!
//! Exercises the interpreter's per-rule entity selection driven by the cached
//! matching-archetype set (brief AD-1): presence (`has`), exclusion
//! (`not has`), value field-filters (`{ field == value }` and the ordered
//! `{ field > value }` form), and full `and` / `or` / `not` composition. Each
//! fixture rule writes a marker (`hit += 1`) onto the components it matches, so
//! the test can assert WHICH entities were visited by reading the marker back,
//! plus the per-rule matched-entity count via the public observable accessors.
//!
//! Every test runs on `std.testing.allocator`, so the suite doubles as the
//! milestone's zero-leak gate: a missed `deinit` fails the test.

const std = @import("std");
const etch = @import("weld_etch");
const weld_core = @import("weld_core");

const World = weld_core.ecs.world.World;
const EntityId = weld_core.ecs.world.EntityId;
const ComponentId = weld_core.ecs.registry.ComponentId;

// ─── harness helpers ────────────────────────────────────────────────────────

/// Parse + type-check a fixture, asserting a clean front-end, then compile the
/// interpreter against `world`. The returned `ParseResult` and `Interpreter`
/// are owned by the caller (deinit in reverse order of return).
///
/// The `ParseResult` is **heap-allocated** so its `AstArena` keeps a stable
/// address: `Interpreter.compile` stores `&pr.ast`, and the interpreter
/// dereferences it on every tick. Returning the struct by value would move a
/// by-value `pr`, leaving `interp.ast` dangling at the dead frame — a latent
/// use-after-free that only the stable heap address avoids.
const Loaded = struct {
    pr: *etch.parser.ParseResult,
    interp: etch.Interpreter,

    fn deinit(self: *Loaded, gpa: std.mem.Allocator) void {
        self.interp.deinit();
        self.pr.deinit(gpa);
        gpa.destroy(self.pr);
    }
};

fn load(gpa: std.mem.Allocator, world: *World, source: []const u8) !Loaded {
    const pr = try gpa.create(etch.parser.ParseResult);
    errdefer gpa.destroy(pr);
    pr.* = try etch.parseSource(gpa, source);
    errdefer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);

    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try etch.typeCheck(gpa, &pr.ast, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);

    const interp = try etch.Interpreter.compile(gpa, &pr.ast, world);
    return .{ .pr = pr, .interp = interp };
}

/// Write an `int` component field of `eid` directly (test setup, bypassing the
/// interpreter) — used to seed field-filter inputs.
fn writeI64(world: *World, eid: EntityId, comp: []const u8, field: []const u8, val: i64) void {
    const comp_id = world.registry.idOf(comp).?;
    const fd = world.registry.findField(comp_id, field).?;
    const loc = world.dynamicLocation(eid).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const col = arch.componentIndex(comp_id).?;
    const chunk = arch.chunks.items[loc.chunk_idx];
    const slot = arch.componentSlot(chunk, col, loc.slot);
    const v: i64 = val;
    @memcpy(slot[fd.offset .. fd.offset + @sizeOf(i64)], std.mem.asBytes(&v));
}

/// Read an `int` component field of `eid` back as `i64`.
fn readI64(world: *World, eid: EntityId, comp: []const u8, field: []const u8) i64 {
    const comp_id = world.registry.idOf(comp).?;
    const fd = world.registry.findField(comp_id, field).?;
    const loc = world.dynamicLocation(eid).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const col = arch.componentIndex(comp_id).?;
    const chunk = arch.chunks.items[loc.chunk_idx];
    const slot = arch.componentSlot(chunk, col, loc.slot);
    var out: i64 = 0;
    @memcpy(std.mem.asBytes(&out), slot[fd.offset .. fd.offset + @sizeOf(i64)]);
    return out;
}

/// Per-rule matched-entity count for the rule named `name` (observable API).
fn matchedByName(interp: *const etch.Interpreter, name: []const u8) u64 {
    var i: usize = 0;
    while (i < interp.ruleCount()) : (i += 1) {
        if (std.mem.eql(u8, interp.ruleName(i), name)) return interp.ruleMatchedEntities(i);
    }
    return std.math.maxInt(u64); // unreachable in a well-formed fixture
}

fn cid(world: *World, name: []const u8) ComponentId {
    return world.registry.idOf(name).?;
}

// ─── tests ──────────────────────────────────────────────────────────────────

test "filter has only" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    var loaded = try load(gpa, &world, @embedFile("fixtures/has_only.etch"));
    defer loaded.deinit(gpa);

    const tracked = cid(&world, "Tracked");
    const other = cid(&world, "Other");
    const e_t = try world.spawnDynamic(gpa, &[_]ComponentId{tracked});
    const e_to = try world.spawnDynamic(gpa, &[_]ComponentId{ tracked, other });
    const e_o = try world.spawnDynamic(gpa, &[_]ComponentId{other});

    const report = try loaded.interp.runFor(&world, 1);

    // Exactly the two Tracked-carriers are visited; the Other-only entity
    // never enters the walk.
    try std.testing.expectEqual(@as(u64, 2), report.entities_iterated);
    try std.testing.expectEqual(@as(u64, 2), matchedByName(&loaded.interp, "visit"));
    try std.testing.expectEqual(@as(i64, 1), readI64(&world, e_t, "Tracked", "hit"));
    try std.testing.expectEqual(@as(i64, 1), readI64(&world, e_to, "Tracked", "hit"));
    // e_o carries no Tracked component — nothing was written to it.
    _ = e_o;
}

test "filter not has" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    var loaded = try load(gpa, &world, @embedFile("fixtures/not_has.etch"));
    defer loaded.deinit(gpa);

    const a = cid(&world, "A");
    const b = cid(&world, "B");
    const e_a = try world.spawnDynamic(gpa, &[_]ComponentId{a});
    const e_ab = try world.spawnDynamic(gpa, &[_]ComponentId{ a, b });
    const e_b = try world.spawnDynamic(gpa, &[_]ComponentId{b});

    const report = try loaded.interp.runFor(&world, 1);

    // `A and not B` excludes the A+B carrier: only {A} matches. The B-only
    // entity lacks A and never enters the walk.
    try std.testing.expectEqual(@as(u64, 1), report.entities_iterated);
    try std.testing.expectEqual(@as(i64, 1), readI64(&world, e_a, "A", "hit"));
    try std.testing.expectEqual(@as(i64, 0), readI64(&world, e_ab, "A", "hit"));
    _ = e_b;
}

test "field filter eq" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    var loaded = try load(gpa, &world, @embedFile("fixtures/field_eq.etch"));
    defer loaded.deinit(gpa);

    const filt = cid(&world, "Filt");
    const e5a = try world.spawnDynamic(gpa, &[_]ComponentId{filt});
    const e3 = try world.spawnDynamic(gpa, &[_]ComponentId{filt});
    const e5b = try world.spawnDynamic(gpa, &[_]ComponentId{filt});
    writeI64(&world, e5a, "Filt", "level", 5);
    writeI64(&world, e3, "Filt", "level", 3);
    writeI64(&world, e5b, "Filt", "level", 5);

    const report = try loaded.interp.runFor(&world, 1);

    // Only `level == 5` entities are visited.
    try std.testing.expectEqual(@as(u64, 2), report.entities_iterated);
    try std.testing.expectEqual(@as(i64, 1), readI64(&world, e5a, "Filt", "hit"));
    try std.testing.expectEqual(@as(i64, 0), readI64(&world, e3, "Filt", "hit"));
    try std.testing.expectEqual(@as(i64, 1), readI64(&world, e5b, "Filt", "hit"));
}

test "field filter ordered" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    var loaded = try load(gpa, &world, @embedFile("fixtures/field_ordered.etch"));
    defer loaded.deinit(gpa);

    const filt = cid(&world, "Filt");
    const e3 = try world.spawnDynamic(gpa, &[_]ComponentId{filt});
    const e5 = try world.spawnDynamic(gpa, &[_]ComponentId{filt});
    const e7 = try world.spawnDynamic(gpa, &[_]ComponentId{filt});
    const e10 = try world.spawnDynamic(gpa, &[_]ComponentId{filt});
    writeI64(&world, e3, "Filt", "level", 3);
    writeI64(&world, e5, "Filt", "level", 5);
    writeI64(&world, e7, "Filt", "level", 7);
    writeI64(&world, e10, "Filt", "level", 10);

    const report = try loaded.interp.runFor(&world, 1);

    // `level > 5` matches 7 and 10 only (5 is not strictly greater).
    try std.testing.expectEqual(@as(u64, 2), report.entities_iterated);
    try std.testing.expectEqual(@as(i64, 0), readI64(&world, e3, "Filt", "hit"));
    try std.testing.expectEqual(@as(i64, 0), readI64(&world, e5, "Filt", "hit"));
    try std.testing.expectEqual(@as(i64, 1), readI64(&world, e7, "Filt", "hit"));
    try std.testing.expectEqual(@as(i64, 1), readI64(&world, e10, "Filt", "hit"));
}

test "compose and or not" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    var loaded = try load(gpa, &world, @embedFile("fixtures/compose.etch"));
    defer loaded.deinit(gpa);

    const core = cid(&world, "Core");
    const a = cid(&world, "A");
    const b = cid(&world, "B");
    const bad = cid(&world, "Bad");

    // when: Core and (A or B) and not Bad
    const e_ca = try world.spawnDynamic(gpa, &[_]ComponentId{ core, a }); // match
    const e_cb = try world.spawnDynamic(gpa, &[_]ComponentId{ core, b }); // match
    const e_cab = try world.spawnDynamic(gpa, &[_]ComponentId{ core, a, b }); // match
    const e_c = try world.spawnDynamic(gpa, &[_]ComponentId{core}); // no (A or B) false
    const e_cabad = try world.spawnDynamic(gpa, &[_]ComponentId{ core, a, bad }); // no Bad excludes
    const e_ab = try world.spawnDynamic(gpa, &[_]ComponentId{ a, b }); // no Core absent

    const report = try loaded.interp.runFor(&world, 1);

    // Hand-computed matched set: {Core,A}, {Core,B}, {Core,A,B} = 3.
    try std.testing.expectEqual(@as(u64, 3), report.entities_iterated);
    try std.testing.expectEqual(@as(u64, 3), matchedByName(&loaded.interp, "visit"));
    try std.testing.expectEqual(@as(i64, 1), readI64(&world, e_ca, "Core", "hit"));
    try std.testing.expectEqual(@as(i64, 1), readI64(&world, e_cb, "Core", "hit"));
    try std.testing.expectEqual(@as(i64, 1), readI64(&world, e_cab, "Core", "hit"));
    try std.testing.expectEqual(@as(i64, 0), readI64(&world, e_c, "Core", "hit"));
    try std.testing.expectEqual(@as(i64, 0), readI64(&world, e_cabad, "Core", "hit"));
    _ = e_ab;
}

test "compose or union" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    var loaded = try load(gpa, &world, @embedFile("fixtures/or_union.etch"));
    defer loaded.deinit(gpa);

    const mark = cid(&world, "Mark");
    const a = cid(&world, "A");
    const b = cid(&world, "B");

    // when: Mark and (A or B) — two DNF terms {Mark,A}, {Mark,B}.
    const e_ma = try world.spawnDynamic(gpa, &[_]ComponentId{ mark, a }); // term 1
    const e_mb = try world.spawnDynamic(gpa, &[_]ComponentId{ mark, b }); // term 2
    const e_mab = try world.spawnDynamic(gpa, &[_]ComponentId{ mark, a, b }); // both terms
    const e_m = try world.spawnDynamic(gpa, &[_]ComponentId{mark}); // neither → no match
    const e_ab = try world.spawnDynamic(gpa, &[_]ComponentId{ a, b }); // no Mark → no match

    const report = try loaded.interp.runFor(&world, 1);

    // Hand-computed union: {Mark,A}, {Mark,B}, {Mark,A,B} = 3 distinct entities.
    // The {Mark,A,B} entity satisfies BOTH disjuncts but is dispatched ONCE —
    // hit == 1, not 2 (the union's k-way merge collapses the duplicate).
    try std.testing.expectEqual(@as(u64, 3), report.entities_iterated);
    try std.testing.expectEqual(@as(u64, 3), matchedByName(&loaded.interp, "visit"));
    try std.testing.expectEqual(@as(i64, 1), readI64(&world, e_ma, "Mark", "hit"));
    try std.testing.expectEqual(@as(i64, 1), readI64(&world, e_mb, "Mark", "hit"));
    try std.testing.expectEqual(@as(i64, 1), readI64(&world, e_mab, "Mark", "hit"));
    try std.testing.expectEqual(@as(i64, 0), readI64(&world, e_m, "Mark", "hit"));
    _ = e_ab;
}

test "non-structural predicate" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    var loaded = try load(gpa, &world, @embedFile("fixtures/non_structural.etch"));
    defer loaded.deinit(gpa);

    const lvl = cid(&world, "Lvl");
    // Three entities in the SAME {Lvl} archetype, differing only in `v`.
    const e3 = try world.spawnDynamic(gpa, &[_]ComponentId{lvl});
    const e7 = try world.spawnDynamic(gpa, &[_]ComponentId{lvl});
    const e20 = try world.spawnDynamic(gpa, &[_]ComponentId{lvl});
    writeI64(&world, e3, "Lvl", "v", 3);
    writeI64(&world, e7, "Lvl", "v", 7);
    writeI64(&world, e20, "Lvl", "v", 20);

    const report = try loaded.interp.runFor(&world, 1);

    // `has Lvl` selects the {Lvl} archetype; the bare `entity.get(Lvl).v > 5`
    // narrows per-entity. The three entities share an archetype, so the bare
    // condition CANNOT be an archetype filter — only the per-entity evaluation
    // can differentiate v=3 (out) from v=7, v=20 (in).
    try std.testing.expectEqual(@as(u64, 2), report.entities_iterated);
    try std.testing.expectEqual(@as(i64, 0), readI64(&world, e3, "Lvl", "hit"));
    try std.testing.expectEqual(@as(i64, 1), readI64(&world, e7, "Lvl", "hit"));
    try std.testing.expectEqual(@as(i64, 1), readI64(&world, e20, "Lvl", "hit"));
}

test "dynamic archetype appears" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    var loaded = try load(gpa, &world, @embedFile("fixtures/never_matches.etch"));
    defer loaded.deinit(gpa);

    const rare = cid(&world, "Rare");
    const common = cid(&world, "Common");

    // No archetype carries Rare at compile / first ticks → zero matches, even
    // though the rule is live.
    _ = try world.spawnDynamic(gpa, &[_]ComponentId{common});
    const r0 = try loaded.interp.runFor(&world, 2);
    try std.testing.expectEqual(@as(u64, 0), r0.entities_iterated);

    // A matching archetype appears dynamically — the dynamic query's lazy tail
    // rescan (option β) picks it up and the new entity matches.
    const e_rare = try world.spawnDynamic(gpa, &[_]ComponentId{rare});
    const r1 = try loaded.interp.runFor(&world, 1);
    try std.testing.expectEqual(@as(u64, 1), r1.entities_iterated);
    try std.testing.expectEqual(@as(i64, 1), readI64(&world, e_rare, "Rare", "hit"));
}

test "observable per-rule matched counts over mixed-filter rules" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    var loaded = try load(gpa, &world, @embedFile("fixtures/observable.etch"));
    defer loaded.deinit(gpa);

    const core = cid(&world, "Core");
    const flag = cid(&world, "Flag");
    const lvl = cid(&world, "Lvl");

    _ = try world.spawnDynamic(gpa, &[_]ComponentId{core}); // e1
    _ = try world.spawnDynamic(gpa, &[_]ComponentId{ core, flag }); // e2
    const e3 = try world.spawnDynamic(gpa, &[_]ComponentId{lvl}); // e3 v=5
    const e4 = try world.spawnDynamic(gpa, &[_]ComponentId{lvl}); // e4 v=20
    const e5 = try world.spawnDynamic(gpa, &[_]ComponentId{ core, lvl }); // e5 v=20
    writeI64(&world, e3, "Lvl", "v", 5);
    writeI64(&world, e4, "Lvl", "v", 20);
    writeI64(&world, e5, "Lvl", "v", 20);

    _ = try loaded.interp.runFor(&world, 1);

    // Emit the per-rule matched-entity breakdown to the log (observable
    // behaviour), then assert it against the hand-computed expectation.
    var i: usize = 0;
    while (i < loaded.interp.ruleCount()) : (i += 1) {
        std.debug.print("rule {s}: matched {d}\n", .{
            loaded.interp.ruleName(i),
            loaded.interp.ruleMatchedEntities(i),
        });
    }

    try std.testing.expectEqual(@as(u64, 3), matchedByName(&loaded.interp, "r_has")); // e1,e2,e5
    try std.testing.expectEqual(@as(u64, 2), matchedByName(&loaded.interp, "r_not")); // e1,e5
    try std.testing.expectEqual(@as(u64, 2), matchedByName(&loaded.interp, "r_field")); // e4,e5
    try std.testing.expectEqual(@as(u64, 2), matchedByName(&loaded.interp, "r_or")); // e2,e5
    try std.testing.expectEqual(@as(u64, 2), matchedByName(&loaded.interp, "r_expr")); // e4,e5
}
