//! Interpreter hot-reload — edit a rule body → AST swap → behaviour change,
//! measured under 500 ms.
//!
//! There is no in-place AST swap: the Interpreter borrows `*const AstArena`
//! and derives its compiled tables eagerly, so a reload re-parses the edited
//! source into a fresh AST and re-runs `Interpreter.compile` on the SAME
//! `World`. Live world state (entities, component bytes) survives because the
//! world is external to the interpreter and `compile` is idempotent w.r.t.
//! already-registered components — it reuses the existing id rather than
//! erroring `DuplicateComponent`. The reload contract is a rule-body edit with
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

    // A running session on source A (+= 1 per tick).
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

    // The hot-reload critical section: edit to source B, re-parse, re-compile on
    // the SAME world, then the first tick under the new rule.
    const t0 = time.nowNanos();
    var pr_b = try weld_etch.parseSource(gpa, src_b);
    defer pr_b.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr_b.diagnostics.len);
    try typeCheckClean(gpa, &pr_b.ast);

    var interp_b = try Interpreter.compile(gpa, &pr_b.ast, &world);
    defer interp_b.deinit();
    _ = try interp_b.runFor(&world, 1);
    const elapsed_ns = time.nowNanos() - t0;

    // The behaviour changed on the SAME entity of the SAME live world: the new
    // rule adds 5, so 3 -> 8 and the old += 1 rule no longer runs.
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

const src_tags_narrow =
    \\tags {
    \\  a { t00, t01 }
    \\}
    \\component Counter { value: int = 0 }
    \\rule tick(entity: Entity)
    \\  when entity has Counter
    \\{
    \\  entity.get_mut(Counter).value += 1
    \\}
;
const src_tags_wide =
    \\tags {
    \\  a { t00, t01, t02, t03, t04, t05, t06, t07, t08, t09, t10, t11, t12, t13, t14, t15, t16, t17, t18, t19, t20, t21, t22, t23, t24, t25, t26, t27, t28, t29, t30, t31, t32, t33, t34, t35, t36, t37, t38, t39, t40, t41, t42, t43, t44, t45, t46, t47, t48, t49, t50, t51, t52, t53, t54, t55, t56, t57, t58, t59, t60, t61, t62, t63, t64 }
    \\}
    \\component Counter { value: int = 0 }
    \\rule tick(entity: Entity)
    \\  when entity has Counter
    \\{
    \\  entity.get_mut(Counter).value += 1
    \\}
;

/// Same width as `src_tags_narrow`, different tag NAMES. Feeds the adjacent
/// case pinned below.
const src_tags_renamed =
    \\tags {
    \\  a { u00, u01 }
    \\}
    \\component Counter { value: int = 0 }
    \\rule tick(entity: Entity)
    \\  when entity has Counter
    \\{
    \\  entity.get_mut(Counter).value += 1
    \\}
;

test "a reload widening TagSet past a word boundary is refused" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    try reloadOn(gpa, &world, src_tags_narrow);

    const cid = world.registry.idOf("TagSet").?;
    const size_before = world.registry.componentSize(cid);
    try std.testing.expectEqual(@as(usize, 8), size_before);

    // 65 tags need two words: 8 bytes -> 16. Before the fix the reuse arm took
    // the existing id with no confrontation, so the interpreter went on writing
    // 16 bytes into an 8-byte column.
    try std.testing.expectError(error.SchemaChanged, reloadOn(gpa, &world, src_tags_wide));
    try std.testing.expectEqual(size_before, world.registry.componentSize(cid));
}

test "a reload renaming tags within one word is accepted — the adjacent case" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    try reloadOn(gpa, &world, src_tags_narrow);

    const cid = world.registry.idOf("TagSet").?;

    // ADJACENT CASE, ACCEPTED AND OUT OF THE REFUSAL'S SCOPE. `schemaDigestOf`
    // hashes name, size, alignment and each FIELD's (name, kind, offset); the
    // `TagSet` descriptor carries `fields = &.{}` because it is a bitfield and
    // not a struct. So tag IDENTITY is not expressible in the digest at all:
    // renaming or reordering tags without crossing a word boundary keeps the
    // same size, hence the same digest, and the reload is accepted while the
    // bit assignment of live entities now denotes different tags.
    //
    // Refusing it needs a digest over the tag table's own content — a different
    // mechanism from the layout digest this test's sibling exercises, and NOT a
    // gap in it. Pinned as accepted so the boundary is observable rather than
    // asserted in prose.
    try reloadOn(gpa, &world, src_tags_renamed);
    try std.testing.expectEqual(@as(usize, 8), world.registry.componentSize(cid));
}

const src_r3_partial =
    \\component Extra { x: int = 0 }
    \\component Counter { value: int = 0, extra: int = 0 }
    \\rule tick(entity: Entity)
    \\  when entity has Counter
    \\{
    \\  entity.get_mut(Counter).value += 1
    \\}
;

test "a refused reload leaves no half-registered type behind" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    try liveSessionAt3(gpa, &world);

    // `Extra` is declared BEFORE `Counter`, so Pass A registers it and only then
    // meets `Counter`'s changed layout and refuses.
    try std.testing.expectError(error.SchemaChanged, reloadOn(gpa, &world, src_r3_partial));

    try std.testing.expect(world.registry.idOf("Extra") == null);
    try std.testing.expectEqual(@as(i64, 3), readCounter(&world));
}

const src_tags_live =
    \\tags {
    \\  a { t00, t01 }
    \\}
    \\component Counter { value: int = 0 }
    \\rule tick(entity: Entity)
    \\  when entity has Counter
    \\{
    \\  entity.get_mut(Counter).value += 1
    \\}
;
const src_tags_wide_plus_new =
    \\tags {
    \\  a { t00, t01, t02, t03, t04, t05, t06, t07, t08, t09, t10, t11, t12, t13, t14, t15, t16, t17, t18, t19, t20, t21, t22, t23, t24, t25, t26, t27, t28, t29, t30, t31, t32, t33, t34, t35, t36, t37, t38, t39, t40, t41, t42, t43, t44, t45, t46, t47, t48, t49, t50, t51, t52, t53, t54, t55, t56, t57, t58, t59, t60, t61, t62, t63, t64 }
    \\}
    \\component Extra { x: int = 0 }
    \\component Counter { value: int = 0 }
    \\rule tick(entity: Entity)
    \\  when entity has Counter
    \\{
    \\  entity.get_mut(Counter).value += 1
    \\}
;

test "a TagSet refusal leaves no half-registered type behind either" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    try reloadOn(gpa, &world, src_tags_live);

    // THE CASE A PER-SITE REFUSAL CANNOT REACH, and the reason the confrontation
    // is a pass rather than a check at each registration: `TagSet` registers AFTER
    // the whole declaration loop, so refusing it where it is met leaves every type
    // the program declared already in the world. Here nothing about `Counter`
    // changed and `Extra` is new — only the tag count crossed a word boundary.
    try std.testing.expectError(error.SchemaChanged, reloadOn(gpa, &world, src_tags_wide_plus_new));

    try std.testing.expect(world.registry.idOf("Extra") == null);
    try std.testing.expectEqual(@as(usize, 8), world.registry.componentSize(world.registry.idOf("TagSet").?));
}
