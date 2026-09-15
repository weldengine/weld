//! Interpreter hot-reload — edit a rule body → AST swap → behaviour change,
//! measured under 500 ms (M0.8 E7).
//!
//! There is no in-place AST swap: the Interpreter borrows `*const AstArena`
//! and derives its compiled tables eagerly, so a reload re-parses the edited
//! source into a fresh AST and re-runs `Interpreter.compile` on the SAME
//! `World`. Live world state (entities, component bytes) survives because the
//! world is external to the interpreter and `compile` is idempotent w.r.t.
//! already-registered components (M0.8 E7 — reuse the existing id instead of
//! erroring `DuplicateComponent`). The reload contract is a rule-body edit with
//! the declarations unchanged; a layout-changing reload is Phase 2+.

const std = @import("std");
const weld_etch = @import("weld_etch");
const weld_core = @import("weld_core");

const World = weld_core.ecs.world.World;
const EntityId = weld_core.ecs.entity.EntityId;
const ComponentId = weld_core.ecs.registry.ComponentId;
const Interpreter = weld_etch.Interpreter;
const Diagnostic = weld_etch.Diagnostic;
const time = weld_core.platform.time;

// Source A and source B differ ONLY in the rule body (+= 1 vs += 5); the
// `Counter` declaration is byte-identical so the reload preserves its id.
const src_a =
    \\component Counter { value: int = 0 }
    \\rule tick(entity: Entity)
    \\  when entity has Counter
    \\{
    \\  entity.get_mut(Counter).value += 1
    \\}
;
const src_b =
    \\component Counter { value: int = 0 }
    \\rule tick(entity: Entity)
    \\  when entity has Counter
    \\{
    \\  entity.get_mut(Counter).value += 5
    \\}
;

fn typeCheckClean(gpa: std.mem.Allocator, arena: *weld_etch.Ast) !void {
    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try weld_etch.typeCheck(gpa, arena, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
}

/// Read `Counter.value` (an `int` → 8-byte i64) of entity 0 straight from the
/// archetype slot — the diff-runner read-back path.
fn readCounter(world: *World) i64 {
    const eid = EntityId{ .index = 0, .generation = 0 };
    const loc = world.dynamicLocation(eid).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const chunk = arch.chunks.items[loc.chunk_idx];
    const cid = world.registry.idOf("Counter").?;
    const idx = arch.componentIndex(cid).?;
    const slot = arch.componentSlot(chunk, idx, loc.slot);
    const fd = world.registry.findField(cid, "value").?;
    var v: i64 = 0;
    @memcpy(std.mem.asBytes(&v), slot[fd.offset .. fd.offset + 8]);
    return v;
}

test "interpreter hot-reload: edit rule body -> AST swap -> behaviour change < 500 ms" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // ── Running session on source A (+= 1 per tick).
    var pr_a = try weld_etch.parseSource(gpa, src_a);
    defer pr_a.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr_a.diagnostics.len);
    try typeCheckClean(gpa, &pr_a.ast);

    var interp_a = try Interpreter.compile(gpa, &pr_a.ast, &world);
    defer interp_a.deinit();

    // Component ids exist only after compile — spawn one entity carrying Counter.
    const cid = world.registry.idOf("Counter").?;
    _ = try world.spawnDynamic(gpa, &[_]ComponentId{cid});

    // Tick the live session 3 times: value 0 -> 3 under source A.
    _ = try interp_a.runFor(&world, 3);
    const v_a = readCounter(&world);
    try std.testing.expectEqual(@as(i64, 3), v_a);

    // ── HOT-RELOAD critical section: edit (source B) -> re-parse -> AST swap
    //    (re-compile on the SAME world) -> first tick under the new rule.
    const t0 = time.nowNanos();
    var pr_b = try weld_etch.parseSource(gpa, src_b);
    defer pr_b.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr_b.diagnostics.len);
    try typeCheckClean(gpa, &pr_b.ast);

    var interp_b = try Interpreter.compile(gpa, &pr_b.ast, &world);
    defer interp_b.deinit();
    _ = try interp_b.runFor(&world, 1);
    const elapsed_ns = time.nowNanos() - t0;

    // ── Behaviour change observed on the SAME entity / SAME live world:
    //    the new rule added 5, so 3 -> 8 (the old +=1 rule no longer runs).
    const v_b = readCounter(&world);
    try std.testing.expectEqual(@as(i64, 8), v_b);
    try std.testing.expect(v_b != v_a);

    std.debug.print(
        "[hot-reload] edit -> AST swap -> first new tick: {d} ns ({d:.3} ms)\n",
        .{ elapsed_ns, @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_ms },
    );
    try std.testing.expect(elapsed_ns < 500 * std.time.ns_per_ms);
}

/// Source A's `Counter`, one more field. Same name, different layout.
const src_widened =
    \\component Counter { value: int = 0, extra: int = 0 }
    \\rule tick(entity: Entity)
    \\  when entity has Counter
    \\{
    \\  entity.get_mut(Counter).value += 1
    \\}
;

/// Source A's `Counter` verbatim, with `@storage(.sparse)` added. §13's fourth
/// property: the mode is a property of the runtime registry and not of the
/// layout, so it changes no identity.
const src_mode_changed =
    \\@storage(.sparse)
    \\component Counter { value: int = 0 }
    \\rule tick(entity: Entity)
    \\  when entity has Counter
    \\{
    \\  entity.get_mut(Counter).value += 1
    \\}
;

/// Source A without the `Counter` declaration at all. §13 step 4: a type in the
/// active image and absent from the new program does not fail the reload.
const src_no_counter =
    \\component Other { n: int = 0 }
    \\rule noop(entity: Entity)
    \\  when entity has Other
    \\{
    \\  entity.get_mut(Other).n += 1
    \\}
;

/// Compile `src` on `world`, returning the error rather than the interpreter.
fn reloadOn(gpa: std.mem.Allocator, world: *World, src: []const u8) !void {
    var pr = try weld_etch.parseSource(gpa, src);
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
    try typeCheckClean(gpa, &pr.ast);
    var interp = try Interpreter.compile(gpa, &pr.ast, world);
    interp.deinit();
}

/// A live session on source A with one entity ticked to 3.
fn liveSessionAt3(gpa: std.mem.Allocator, world: *World) !void {
    var pr = try weld_etch.parseSource(gpa, src_a);
    defer pr.deinit(gpa);
    try typeCheckClean(gpa, &pr.ast);
    var interp = try Interpreter.compile(gpa, &pr.ast, world);
    defer interp.deinit();
    const cid = world.registry.idOf("Counter").?;
    _ = try world.spawnDynamic(gpa, &[_]ComponentId{cid});
    _ = try interp.runFor(world, 3);
    try std.testing.expectEqual(@as(i64, 3), readCounter(world));
}

test "a reload that widens a component is refused and the live image survives" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    try liveSessionAt3(gpa, &world);

    const cid = world.registry.idOf("Counter").?;
    const size_before = world.registry.componentSize(cid);

    try std.testing.expectError(error.SchemaChanged, reloadOn(gpa, &world, src_widened));

    try std.testing.expectEqual(cid, world.registry.idOf("Counter").?);
    try std.testing.expectEqual(size_before, world.registry.componentSize(cid));
    try std.testing.expectEqual(@as(i64, 3), readCounter(&world));
}

test "a reload that changes no layout still succeeds and keeps the live value" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    try liveSessionAt3(gpa, &world);

    try reloadOn(gpa, &world, src_b);
    try std.testing.expectEqual(@as(i64, 3), readCounter(&world));
}

test "a reload that changes only the storage mode is not a layout change" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    try liveSessionAt3(gpa, &world);

    try reloadOn(gpa, &world, src_mode_changed);
    try std.testing.expectEqual(@as(i64, 3), readCounter(&world));
}

test "a type absent from the new program does not fail the reload" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    try liveSessionAt3(gpa, &world);

    try reloadOn(gpa, &world, src_no_counter);
    try std.testing.expectEqual(@as(i64, 3), readCounter(&world));
}
