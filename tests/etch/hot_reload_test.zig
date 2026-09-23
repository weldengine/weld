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

/// Same width and NAMES as `src_tags_narrow`, order SWAPPED, which permutes
/// every `bit_index`.
const src_tags_reordered =
    \\tags {
    \\  a { t01, t00 }
    \\}
    \\component Counter { value: int = 0 }
    \\rule tick(entity: Entity)
    \\  when entity has Counter
    \\{
    \\  entity.get_mut(Counter).value += 1
    \\}
;

/// One MORE tag than `src_tags_narrow`, still inside the first word; every
/// existing tag keeps its `bit_index`.
const src_tags_appended =
    \\tags {
    \\  a { t00, t01, t02 }
    \\}
    \\component Counter { value: int = 0 }
    \\rule tick(entity: Entity)
    \\  when entity has Counter
    \\{
    \\  entity.get_mut(Counter).value += 1
    \\}
;

/// Same width as `src_tags_narrow`, different tag NAMES.
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

test "a reload renaming tags within one word is REFUSED" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    try reloadOn(gpa, &world, src_tags_narrow);

    const cid = world.registry.idOf("TagSet").?;

    try std.testing.expectError(error.SchemaChanged, reloadOn(gpa, &world, src_tags_renamed));
    try std.testing.expectEqual(@as(usize, 8), world.registry.componentSize(cid));
}

test "a reload reordering tags within one word is REFUSED" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    try reloadOn(gpa, &world, src_tags_narrow);

    const cid = world.registry.idOf("TagSet").?;

    // Catches a digest over the tag names that ignores their order, which the
    // rename refusal misses.
    try std.testing.expectError(error.SchemaChanged, reloadOn(gpa, &world, src_tags_reordered));
    try std.testing.expectEqual(@as(usize, 8), world.registry.componentSize(cid));
}

test "an identical tag reload is still accepted — the green twin" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    try reloadOn(gpa, &world, src_tags_narrow);

    // Catches a digest that refuses every tag reload, which both refusals miss.
    const cid = world.registry.idOf("TagSet").?;
    try reloadOn(gpa, &world, src_tags_narrow);
    try std.testing.expectEqual(cid, world.registry.idOf("TagSet").?);
    try std.testing.expectEqual(@as(usize, 8), world.registry.componentSize(cid));
}

test "appending a tag inside one word is refused — the MEASURED COST, not a defect" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    try reloadOn(gpa, &world, src_tags_narrow);

    // A false refusal: the reload is safe, but a whole-table digest cannot tell
    // a surviving prefix from a changed table.
    try std.testing.expectError(error.SchemaChanged, reloadOn(gpa, &world, src_tags_appended));
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

const OneShotFailing = weld_core.testing.alloc_counting.OneShotFailing;
test "OneShotFailing fails exactly the chosen allocation and none after it" {
    const gpa = std.testing.allocator;
    var failing: OneShotFailing = .{ .backing = gpa, .fail_at = 1 };
    const a = failing.allocator();
    const first = try a.alloc(u8, 4);
    defer a.free(first);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 4));
    const third = try a.alloc(u8, 4);
    defer a.free(third);
    try std.testing.expect(failing.failed);
    try std.testing.expectEqual(@as(usize, 3), failing.count);
    try std.testing.expect(!a.resize(third, 8));
}

// Reaches every world mutation of `compile` (a component with a requisite, a
// resource with a string and three collection fields, `TagSet`, the builtins),
// every rule-lowering path, a sparse selection, and a descriptor built after the
// rules.
const src_registration =
    \\tags {
    \\  a { t00, t01 }
    \\}
    \\component Transform { x: int = 0 }
    \\@requires(Transform)
    \\component Mesh { v: i32 = 0 }
    \\component Tag2 { k: int = 0 }
    \\@storage(.sparse)
    \\component Hot { h: int = 0 }
    \\@storage(.sparse)
    \\component Cold { c: int = 0 }
    \\struct Item { value: int }
    \\data Db: Item { a: { value: 1 }, b: { value: 2 } }
    \\resource Inventory { n: int = 0, items: string[] = ["a", "b"], label: string = "hi", counts: [string: int] = ["x": 1], seen: Set<int> }
    \\rule tick(entity: Entity)
    \\  when entity has Transform
    \\{
    \\  entity.get_mut(Transform).x += 1
    \\}
    \\rule either(entity: Entity)
    \\  when entity has Transform or entity has Tag2
    \\{
    \\  entity.get_mut(Transform).x += 1
    \\}
    \\rule filtered(entity: Entity)
    \\  when entity has Transform { x * 2 < 10 }
    \\{
    \\  entity.get_mut(Transform).x += 1
    \\}
    \\rule gated(entity: Entity)
    \\  when resource Inventory { n < 10 } and entity has Transform
    \\{
    \\  entity.get_mut(Transform).x += 1
    \\}
    \\rule tagged(entity: Entity)
    \\  when entity has_tag .a.t00 and entity has Transform
    \\{
    \\  entity.get_mut(Transform).x += 1
    \\}
    \\rule sparse(entity: Entity)
    \\  when entity has Hot and not entity has Cold
    \\{
    \\  entity.get_mut(Hot).h += 1
    \\}
    \\async rule waits(entity: Entity)
    \\  when entity has Mesh
    \\{
    \\  await wait(1.0s)
    \\}
;
// A strict subset of `src_registration`, so a reload onto it adds types.
const src_registration_base =
    \\tags {
    \\  a { t00, t01 }
    \\}
    \\component Transform { x: int = 0 }
    \\rule tick(entity: Entity)
    \\  when entity has Transform
    \\{
    \\  entity.get_mut(Transform).x += 1
    \\}
;

const WorldShape = struct { components: usize, resources: u32, closures: u64 };

fn worldShape(world: *World) WorldShape {
    var h = std.hash.Wyhash.init(0);
    const n = world.registry.componentCount();
    for (0..n) |id| {
        const c = world.registry.requiresClosure(@intCast(id));
        h.update(std.mem.asBytes(&id));
        h.update(std.mem.asBytes(&c.len));
        h.update(std.mem.sliceAsBytes(c));
    }
    return .{ .components = n, .resources = world.resources.entries.count(), .closures = h.final() };
}

const Health = enum { healthy, missing_store_entry, null_collection, unowned_string, missing_closure };

fn slotWord(bytes: []const u8, offset: u16) u64 {
    return std.mem.bytesToValue(u64, bytes[offset..][0..8]);
}

/// What `src_registration` leaves in a world once compiled.
fn registrationHealth(world: *World) Health {
    for ([_][]const u8{ "GameTime", "UnscaledTime", "RealTime", "Inventory" }) |name| {
        const id = world.registry.idOf(name) orelse return .missing_store_entry;
        if (world.resources.getResource(id) == null) return .missing_store_entry;
    }
    const inv = world.registry.idOf("Inventory").?;
    const bytes = world.resources.getResource(inv).?;
    for ([_][]const u8{ "items", "counts", "seen" }) |field| {
        if (slotWord(bytes, world.registry.findField(inv, field).?.offset) == 0) return .null_collection;
    }
    const label = world.registry.findField(inv, "label").?;
    const ptr = slotWord(bytes, label.offset);
    const len = std.mem.bytesToValue(u32, bytes[label.offset + 8 ..][0..4]);
    const owned = for (world.registry.ownedBlocks(inv)) |b| {
        if (@intFromPtr(b) == ptr) break true;
    } else false;
    if (!owned or len != 2) return .unowned_string;
    if (!std.mem.eql(u8, @as([*]const u8, @ptrFromInt(ptr))[0..len], "hi")) return .unowned_string;
    const mesh = world.registry.idOf("Mesh") orelse return .missing_closure;
    if (!world.registry.isRequiredBy(world.registry.idOf("Transform").?, mesh)) return .missing_closure;
    return .healthy;
}

/// Fail every allocation of one `compile` in turn, onto a world `base` left live.
/// Each failure must surface as `OutOfMemory` and leave the world as it found it
/// or exactly as a successful compile would, and a retry on that world must
/// produce a healthy one. Returns the number of allocations swept.
fn sweepCompile(gpa: std.mem.Allocator, base: ?[]const u8, src: []const u8) !usize {
    var pr = try weld_etch.parseSource(gpa, src);
    defer pr.deinit(gpa);
    try typeCheckClean(gpa, &pr.ast);
    var base_ast = if (base) |b| try weld_etch.parseSource(gpa, b) else null;
    defer if (base_ast) |*p| p.deinit(gpa);
    if (base_ast) |*p| try typeCheckClean(gpa, &p.ast);

    // CONTROLS, same apparatus, same execution: a clean compile reads healthy,
    // and the same world with a store entry removed does not.
    const committed = blk: {
        var world = World.init();
        defer world.deinit(gpa);
        var live = if (base_ast) |*p| try Interpreter.compile(gpa, &p.ast, &world) else null;
        defer if (live) |*l| l.deinit();
        var it = try Interpreter.compile(gpa, &pr.ast, &world);
        defer it.deinit();
        try std.testing.expectEqual(Health.healthy, registrationHealth(&world));
        const inv = world.registry.idOf("Inventory").?;
        const kept = world.resources.entries.fetchRemove(inv).?;
        try std.testing.expectEqual(Health.missing_store_entry, registrationHealth(&world));
        world.resources.entries.putAssumeCapacity(inv, kept.value);
        break :blk worldShape(&world);
    };

    var k: usize = 0;
    while (true) : (k += 1) {
        var world = World.init();
        defer world.deinit(gpa);
        var live = if (base_ast) |*p| try Interpreter.compile(gpa, &p.ast, &world) else null;
        defer if (live) |*l| l.deinit();
        const before = worldShape(&world);

        var failing: OneShotFailing = .{ .backing = gpa, .fail_at = k };
        if (Interpreter.compile(failing.allocator(), &pr.ast, &world)) |compiled| {
            var it = compiled;
            it.deinit();
            // Success after an injected failure means an OutOfMemory was swallowed.
            try std.testing.expect(!failing.failed);
            return k;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            const after = worldShape(&world);
            try std.testing.expect(std.meta.eql(after, before) or std.meta.eql(after, committed));
        }
        var retried = try Interpreter.compile(gpa, &pr.ast, &world);
        defer retried.deinit();
        try std.testing.expectEqual(Health.healthy, registrationHealth(&world));
    }
}

test "a compile failing at any allocation leaves the world whole, first compile" {
    try std.testing.expect(try sweepCompile(std.testing.allocator, null, src_registration) > 50);
}

test "a compile failing at any allocation leaves the world whole, reload adding types" {
    try std.testing.expect(try sweepCompile(std.testing.allocator, src_registration_base, src_registration) > 50);
}

test "a compile failing at any allocation leaves the world whole, reload of the same program" {
    try std.testing.expect(try sweepCompile(std.testing.allocator, src_registration, src_registration) > 50);
}

test "compiling B, then tearing A down, leaves B's session its resources" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    var pr = try weld_etch.parseSource(gpa, src_registration);
    defer pr.deinit(gpa);
    try typeCheckClean(gpa, &pr.ast);

    var a = try Interpreter.compile(gpa, &pr.ast, &world);
    var b = try Interpreter.compile(gpa, &pr.ast, &world);
    defer b.deinit();
    a.deinit();

    try std.testing.expectEqual(Health.healthy, registrationHealth(&world));
    _ = try b.runFor(&world, 1);
    try std.testing.expectEqual(Health.healthy, registrationHealth(&world));
}

test "an interpreter torn down before the next compile takes no resource with it" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    var pr = try weld_etch.parseSource(gpa, src_registration);
    defer pr.deinit(gpa);
    try typeCheckClean(gpa, &pr.ast);

    var a = try Interpreter.compile(gpa, &pr.ast, &world);
    a.deinit();
    var b = try Interpreter.compile(gpa, &pr.ast, &world);
    defer b.deinit();

    try std.testing.expectEqual(Health.healthy, registrationHealth(&world));
    _ = try b.runFor(&world, 1);
    try std.testing.expectEqual(Health.healthy, registrationHealth(&world));
}

/// Append `resource Big`, a declaration past the registry's 64 KiB.
fn appendOversized(gpa: std.mem.Allocator, src: *std.ArrayListUnmanaged(u8)) !void {
    try src.appendSlice(gpa, "resource Big { v0: int = 0");
    for (1..8200) |i| try src.print(gpa, ", v{d}: int = 0", .{i});
    try src.appendSlice(gpa, " }\n");
}

test "a declaration past 64 KiB is refused and registers nothing" {
    const gpa = std.testing.allocator;
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(gpa);
    // A declaration staged BEFORE the oversized one, so that a registration
    // committed per declaration would leave it behind.
    try src.appendSlice(gpa, "component Small { x: int = 0 }\n");
    try appendOversized(gpa, &src);

    var pr = try weld_etch.parseSource(gpa, src.items);
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
    try typeCheckClean(gpa, &pr.ast);
    var world = World.init();
    defer world.deinit(gpa);
    try std.testing.expectError(error.LayoutTooLarge, Interpreter.compile(gpa, &pr.ast, &world));
    try std.testing.expectEqual(@as(usize, 0), world.registry.componentCount());
}

const CountingAllocator = weld_core.testing.alloc_counting.CountingAllocator;
const src_counter = "component Counter { value: int = 0 }\n";

/// Reload, onto a world running `src_counter`, a program declaring an oversized
/// resource and a widened `Counter`, in the order `oversized_first` gives.
fn reloadWithTwoFaults(gpa: std.mem.Allocator, oversized_first: bool) !void {
    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(gpa);
    if (oversized_first) try appendOversized(gpa, &src);
    try src.appendSlice(gpa, "component Counter { value: int = 0, extra: int = 0 }\n");
    if (!oversized_first) try appendOversized(gpa, &src);

    var base = try weld_etch.parseSource(gpa, src_counter);
    defer base.deinit(gpa);
    var pr = try weld_etch.parseSource(gpa, src.items);
    defer pr.deinit(gpa);
    try typeCheckClean(gpa, &pr.ast);
    var world = World.init();
    defer world.deinit(gpa);
    var live = try Interpreter.compile(gpa, &base.ast, &world);
    defer live.deinit();
    var it = try Interpreter.compile(gpa, &pr.ast, &world);
    it.deinit();
}

test "a reload with two refusals reports the first declaration's: the oversized one" {
    try std.testing.expectError(error.LayoutTooLarge, reloadWithTwoFaults(std.testing.allocator, true));
}

test "a reload with two refusals reports the first declaration's: the widened one" {
    try std.testing.expectError(error.SchemaChanged, reloadWithTwoFaults(std.testing.allocator, false));
}

/// Allocations `compile` makes for `src` onto a world already running `base`, or
/// onto a fresh world when `base` is null.
fn compileAllocations(gpa: std.mem.Allocator, base: ?[]const u8, src: []const u8) !u64 {
    var base_pr = if (base) |b| try weld_etch.parseSource(gpa, b) else null;
    defer if (base_pr) |*p| p.deinit(gpa);
    var pr = try weld_etch.parseSource(gpa, src);
    defer pr.deinit(gpa);
    try typeCheckClean(gpa, &pr.ast);
    var world = World.init();
    defer world.deinit(gpa);
    var live = if (base_pr) |*p| try Interpreter.compile(gpa, &p.ast, &world) else null;
    defer if (live) |*l| l.deinit();

    var counting = CountingAllocator.init(gpa);
    var it = try Interpreter.compile(counting.allocator(), &pr.ast, &world);
    const n = counting.snapshot().alloc_count;
    it.deinit();
    return n;
}

test "a reload evaluates none of the defaults of a type already registered" {
    const gpa = std.testing.allocator;
    const bare = "resource R { s: string }\n";
    const defaulted = "resource R { s: string = \"abc\" }\n";
    // Control: on a fresh world the same count sees the default being copied.
    try std.testing.expect(try compileAllocations(gpa, null, defaulted) > try compileAllocations(gpa, null, bare));
    try std.testing.expectEqual(try compileAllocations(gpa, bare, bare), try compileAllocations(gpa, bare, defaulted));
}

/// Compile `src` onto a world where a Zig component requiring `requisite` was
/// registered first, and report whether its closure reaches `requisite`.
fn zigRequisiteResolves(gpa: std.mem.Allocator, requisite: []const u8, src: []const u8) !bool {
    var pr = try weld_etch.parseSource(gpa, src);
    defer pr.deinit(gpa);
    try typeCheckClean(gpa, &pr.ast);
    var world = World.init();
    defer world.deinit(gpa);
    const requirer = try world.registry.registerComponentRaw(gpa, .{
        .name = "ZigRequirer",
        .size = 4,
        .alignment = 4,
        .default_bytes = &[_]u8{0} ** 4,
        .fields = &.{},
        .requires = &.{requisite},
    });
    var it = try Interpreter.compile(gpa, &pr.ast, &world);
    defer it.deinit();
    return world.registry.isRequiredBy(world.registry.idOf(requisite).?, requirer);
}

test "a Zig requisite on TagSet resolves at the first compile" {
    try std.testing.expect(try zigRequisiteResolves(std.testing.allocator, weld_etch.types.tagset_component_name, "tags {\n  a { t00 }\n}\n"));
}

test "a Zig requisite on a builtin time resource resolves at the first compile" {
    try std.testing.expect(try zigRequisiteResolves(std.testing.allocator, "GameTime", "component Plain { x: int = 0 }\n"));
}

test "every type a compile registers without the program declaring it has a reserved name" {
    const gpa = std.testing.allocator;
    var pr = try weld_etch.parseSource(gpa, "tags {\n  a { t00 }\n}\n");
    defer pr.deinit(gpa);
    try typeCheckClean(gpa, &pr.ast);
    var world = World.init();
    defer world.deinit(gpa);
    var it = try Interpreter.compile(gpa, &pr.ast, &world);
    defer it.deinit();

    const n = world.registry.componentCount();
    try std.testing.expectEqual(1 + weld_etch.types.builtin_resources.len, n);
    for (0..n) |id| {
        const name = world.registry.componentName(@intCast(id));
        if (!weld_etch.types.isReservedEngineTypeName(name)) {
            std.debug.print("registered and not reserved: {s}\n", .{name});
            return error.TestUnexpectedResult;
        }
    }
}
