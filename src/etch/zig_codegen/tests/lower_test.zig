//! Unit tests for the S5 AST → Zig source lowering. The test names mirror
//! the list under `briefs/S5-etch-codegen-zig.md` Acceptance criteria /
//! Tests so the brief and the suite are in lock-step.

const std = @import("std");
const parser = @import("../../parser.zig");
const types = @import("../../types.zig");
const diag = @import("../../diagnostics.zig");
const root = @import("../root.zig");
const lower = root.lower;

fn parseTypeCheckGen(gpa: std.mem.Allocator, source: []const u8, out: *std.ArrayListUnmanaged(u8)) !lower.GenerateStats {
    var pr = try parser.parse(gpa, source);
    defer pr.deinit(gpa);
    try std.testing.expect(pr.diagnostics.len == 0);
    var diags: std.ArrayListUnmanaged(diag.Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try types.TypeChecker.check(gpa, &pr.ast, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    return try root.generateToBuffer(gpa, &pr.ast, "<test>", out);
}

test "lowers component declaration to extern struct" {
    const gpa = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    const stats = try parseTypeCheckGen(gpa,
        \\component Health { current: float = 100.0 max: float = 100.0 }
    , &out);
    try std.testing.expectEqual(@as(u32, 1), stats.components);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "pub const Health = extern struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "current: f64 = 100.0,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "max: f64 = 100.0,") != null);
}

test "lowers resource declaration to extern struct + singleton spawn" {
    const gpa = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    const stats = try parseTypeCheckGen(gpa,
        \\resource GameMode { running: bool = true }
    , &out);
    try std.testing.expectEqual(@as(u32, 1), stats.resources);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "pub const GameMode = extern struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "world.addResource(gpa, GameMode_id, std.mem.asBytes(&default));") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "registerComponentRaw(gpa, .{") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, ".name = \"GameMode\",") != null);
}

test "lowers rule with single component when clause" {
    const gpa = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    _ = try parseTypeCheckGen(gpa,
        \\component Counter { value: int = 0 }
        \\rule update(entity: Entity)
        \\  when entity has Counter
        \\{
        \\  entity.get_mut(Counter).value = 5
        \\}
    , &out);
    // Comptime query path — the brief's "world.query(.{T1, T2, ...})" shape
    // (gate 4 reports one monomorphisation per distinct tuple).
    try std.testing.expect(std.mem.indexOf(u8, out.items, "pub fn rule_update(world: *World) void {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "comptime_query.query(world, .{Counter})") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "while (__it.next()) |__row|") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "__row[0].value = 5") != null);
    // Archetype walk syntax must NOT appear on the AND-only path — that
    // would mean the codegen reverted to the manual fallback.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "for (world.archetypes.items)") == null);
}

test "lowers rule with multi-component when clause and arithmetic body" {
    const gpa = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    _ = try parseTypeCheckGen(gpa,
        \\component Position { x: float = 0.0 }
        \\component Velocity { dx: float = 1.0 }
        \\rule move(entity: Entity)
        \\  when entity has Position and entity has Velocity
        \\{
        \\  entity.get_mut(Position).x += entity.get(Velocity).dx
        \\}
    , &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "comptime_query.query(world, .{Position, Velocity})") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "__row[0].x += __row[1].dx") != null);
}

test "lowers get and get_mut accessors" {
    const gpa = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    _ = try parseTypeCheckGen(gpa,
        \\component Counter { value: int = 0 }
        \\rule heal(entity: Entity)
        \\  when entity has Counter
        \\{
        \\  let h = entity.get_mut(Counter)
        \\  h.value += 1
        \\}
    , &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "__row[0].value += 1") != null);
}

test "register emits a Zig-type alias for each component" {
    const gpa = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    _ = try parseTypeCheckGen(gpa,
        \\component Counter { value: int = 0 }
    , &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "world.registry.registerAlias(gpa, @typeName(Counter), Counter_id)") != null);
}

test "fallback to manual archetype walk when when clause contains 'not'" {
    const gpa = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    _ = try parseTypeCheckGen(gpa,
        \\component A { v: int = 0 }
        \\component B { v: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has A and not entity has B
        \\{
        \\  entity.get_mut(A).v += 1
        \\}
    , &out);
    // `not` triggers the S4-debt manual walk path.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "for (world.archetypes.items) |arch|") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "comptime_query.query") == null);
}

test "lowers event declaration, bus registration, and emit (M0.8 E3)" {
    const gpa = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    const stats = try parseTypeCheckGen(gpa,
        \\event Damage { amount: int = 0, crit: bool = false }
        \\rule deal() { emit Damage { amount: 5, crit: true } }
    , &out);
    try std.testing.expectEqual(@as(u32, 1), stats.events);
    // The event is an `extern struct` (POD, ABI §3.1).
    try std.testing.expect(std.mem.indexOf(u8, out.items, "pub const Damage = extern struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "amount: i64 = 0,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "crit: bool = false,") != null);
    // Registered as a typed queue on the world's event bus (`.tick` lifetime).
    // `gpa` is the bus register's first runtime arg (the queue is heap-backed).
    try std.testing.expect(std.mem.indexOf(u8, out.items, "try world.event_bus.register(gpa, Damage, 256, .tick);") != null);
    // `emit` → a typed enqueue; `catch unreachable` (rule fns return void; the
    // event is always registered, so emit cannot fail).
    try std.testing.expect(std.mem.indexOf(u8, out.items, "world.event_bus.emit(Damage, Damage{") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, ".amount = 5,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "}) catch unreachable;") != null);
}

test "type mapping int=>i64 float=>f64 bool=>bool" {
    const gpa = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    _ = try parseTypeCheckGen(gpa,
        \\component Mix { i: int = 0 f: float = 0.0 b: bool = true }
    , &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "i: i64 = 0,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "f: f64 = 0.0,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "b: bool = true,") != null);
}

test "lowers an @on_event observer to the bus drain (subscribe + poll), valid Zig (M0.8 E3)" {
    const gpa = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    // A global producer emits A; the `@on_event(A)` observer (relay) drains A
    // and re-emits B carrying the payload field. The body uses only codegen-
    // sound constructs (emit + `event`-field access) — a world-state write
    // (resource) is deferred to the sub-slice-C codegen tranche, so the
    // byte-exact world-state event differential is interpreter-reference for
    // now; this test validates the engraved drain contract cooks to valid Zig.
    _ = try parseTypeCheckGen(gpa,
        \\event A { x: i32 = 0 }
        \\event B { y: i32 = 0 }
        \\rule prod() { emit A { x: 7 } }
        \\@on_event(A)
        \\rule relay() { emit B { y: event.x } }
    , &out);

    // The generated Zig is syntactically valid (Zig's own parser).
    const z = try gpa.dupeZ(u8, out.items);
    defer gpa.free(z);
    var tree = try std.zig.Ast.parse(gpa, z, .zig);
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) std.debug.print("generated zig parse errors:\n{s}\n", .{out.items});
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);

    // The engraved drain contract: clear the per-tick queue at the tick top,
    // subscribe the observer cursor at head=0 BEFORE any rule emits, the
    // observer fn polls the threaded cursor, and `event.field` lowers verbatim.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "world.event_bus.drainAtBoundary(.tick);") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "world.event_bus.subscribe(A) catch unreachable;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "pub fn rule_relay(world: *World, ev_cursor: *EventCursor) void {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "while (world.event_bus.poll(A, ev_cursor) catch null) |event| {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "rule_relay(world, &__evcur_") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "event.x") != null);
}

test "lowers `has T changed` to tick-based change-detection codegen (M0.8 E3)" {
    const gpa = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    // `damage` writes Health (marking it changed); `react` is gated on
    // `Health changed`. The byte-exact runtime behaviour is the `44_changed_filter`
    // differential; this test pins the engraved codegen contract — `beginFrame`
    // opens the tick, a component write `markChanged`s at `world.current_tick`,
    // and a `changed` rule keeps a per-rule `__last_run` it both reads (the
    // `changedTick > __last_run` guard) and advances at the fn end.
    _ = try parseTypeCheckGen(gpa,
        \\component Health { current: i32 = 10 }
        \\component Counter { value: i32 = 0 }
        \\component Marked { v: i32 = 0 }
        \\rule damage(entity: Entity)
        \\  when entity has Health and entity has Marked
        \\{
        \\  entity.get_mut(Health).current -= 1
        \\}
        \\rule react(entity: Entity)
        \\  when entity has Counter and entity has Health changed
        \\{
        \\  entity.get_mut(Counter).value += 1
        \\}
    , &out);

    const z = try gpa.dupeZ(u8, out.items);
    defer gpa.free(z);
    var tree = try std.zig.Ast.parse(gpa, z, .zig);
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) std.debug.print("generated zig parse errors:\n{s}\n", .{out.items});
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "world.beginFrame();") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "var __last_run_react: u32 = 0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "arch.markChanged(chunk, Health_idx, slot, world.current_tick);") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "if (!(arch.changedTick(chunk, Health_idx, slot) > __last_run_react)) continue;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "__last_run_react = world.current_tick;") != null);
}

test "emits the Error/ErrorCode prelude only when the program uses error handling (M0.8 E3-C tranche 2)" {
    const gpa = std.testing.allocator;

    // An error-free program keeps byte-identical output: no prelude, and the
    // synthetic builtin declarations injected by the type-checker are skipped.
    var plain: std.ArrayListUnmanaged(u8) = .empty;
    defer plain.deinit(gpa);
    _ = try parseTypeCheckGen(gpa,
        \\component Counter { value: int = 0 }
        \\rule update(entity: Entity)
        \\  when entity has Counter
        \\{
        \\  entity.get_mut(Counter).value = 5
        \\}
    , &plain);
    try std.testing.expect(std.mem.indexOf(u8, plain.items, "pub const Error") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain.items, "pub const ErrorCode") == null);

    // throw/try/catch force the prelude and the flag+branch desugar.
    var errful: std.ArrayListUnmanaged(u8) = .empty;
    defer errful.deinit(gpa);
    _ = try parseTypeCheckGen(gpa,
        \\component Counter { value: int = 0 }
        \\rule update(entity: Entity)
        \\  when entity has Counter
        \\{
        \\  try {
        \\    throw Error { message: "boom", code: ErrorCode.io_fail }
        \\  } catch err {
        \\    entity.get_mut(Counter).value = err.message.len()
        \\  }
        \\}
    , &errful);
    try std.testing.expect(std.mem.indexOf(u8, errful.items, "pub const Error = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, errful.items, "pub const ErrorCode = enum(i32) {") != null);
    try std.testing.expect(std.mem.indexOf(u8, errful.items, "var __thrown_0: ?Error = null;") != null);
    try std.testing.expect(std.mem.indexOf(u8, errful.items, "break :__try_0;") != null);
    try std.testing.expect(std.mem.indexOf(u8, errful.items, "if (__thrown_0) |err| {") != null);
}

test "lowers a throws fn to the hidden __err out-param and rejects unsanctioned call positions (M0.8 E3-C tranche 2)" {
    const gpa = std.testing.allocator;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    _ = try parseTypeCheckGen(gpa,
        \\component Counter { value: int = 0 }
        \\fn risky(n: int) throws -> int {
        \\  if n > 2 {
        \\    throw Error { message: "too big", code: ErrorCode.invalid_arg }
        \\  }
        \\  return n * 10
        \\}
        \\rule update(entity: Entity)
        \\  when entity has Counter
        \\{
        \\  try {
        \\    let v = risky(5)
        \\    entity.get_mut(Counter).value = v
        \\  } catch err {
        \\    entity.get_mut(Counter).value = err.message.len()
        \\  }
        \\}
    , &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "fn risky(n: i64, __err: *?Error) i64 {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "__err.* = Error{") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "const v = risky(5, &__terr_0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "if (__terr_0) |__e| { __thrown_0 = __e; break :__try_0; }") != null);

    // A throws call nested in an expression has no statement-level home for
    // the out-param check — fail loud (sanctioned positions: let / bare call).
    var pr = try parser.parse(gpa,
        \\component Counter { value: int = 0 }
        \\fn risky(n: int) throws -> int { return n }
        \\rule update(entity: Entity)
        \\  when entity has Counter
        \\{
        \\  try {
        \\    entity.get_mut(Counter).value = risky(5) + 1
        \\  } catch err {
        \\    entity.get_mut(Counter).value = err.message.len()
        \\  }
        \\}
    );
    defer pr.deinit(gpa);
    try std.testing.expect(pr.diagnostics.len == 0);
    var diags: std.ArrayListUnmanaged(diag.Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try types.TypeChecker.check(gpa, &pr.ast, &diags);
    var nested: std.ArrayListUnmanaged(u8) = .empty;
    defer nested.deinit(gpa);
    try std.testing.expectError(
        root.CodegenError.UnsupportedConstruct,
        root.generateToBuffer(gpa, &pr.ast, "<test>", &nested),
    );
}

test "lowers dynamic-array and map locals to frame-arena lists, gating the map-insert helper (M0.8 E3-C tranche 3)" {
    const gpa = std.testing.allocator;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    _ = try parseTypeCheckGen(gpa,
        \\component Acc { n: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  let mut xs: int[] = [1, 2]
        \\  xs.push(3)
        \\  let mut m = [1: 10]
        \\  m.insert(2, 20)
        \\  let mut s = 0
        \\  for k, v in m { s += k + v }
        \\  for x in xs { s += x }
        \\  entity.get_mut(Acc).n = s + xs.len() + m.len() + xs[0]
        \\}
    , &out);
    // Dynamic array: list decl + literal seed + arena push + items access.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "var xs: std.ArrayListUnmanaged(i64) = .empty;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "xs.appendSlice(fa, &[_]i64{ 1, 2 }) catch unreachable;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "(xs).append(fa, 3) catch unreachable") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "for ((xs).items) |x| {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "xs.items[@as(usize, @intCast(0))]") != null);
    // Map: insertion-ordered pair list + helper-seeded literal + kv loop.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "var m: std.ArrayListUnmanaged(struct { key: i64, value: i64 }) = .empty;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "fn __etchMapInsert(m: anytype, fa: std.mem.Allocator, k: anytype, v: anytype) void {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "__etchMapInsert(&m, fa, 1, 10);") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "__etchMapInsert(&(m), fa, 2, 20)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "for ((m).items) |__kv| {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "const k = __kv.key;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "const v = __kv.value;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "@as(i64, @intCast((m).items.len))") != null);

    // A map-free program never emits the helper (byte-identity belt).
    var plain: std.ArrayListUnmanaged(u8) = .empty;
    defer plain.deinit(gpa);
    _ = try parseTypeCheckGen(gpa,
        \\component Acc { n: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  entity.get_mut(Acc).n = 5
        \\}
    , &plain);
    try std.testing.expect(std.mem.indexOf(u8, plain.items, "__etchMapInsert") == null);
}

test "lowers Set locals to frame-arena element lists, gating the set helpers (M0.8 E3-C tranche 3bis)" {
    const gpa = std.testing.allocator;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    _ = try parseTypeCheckGen(gpa,
        \\component Acc { n: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  let e: Set<int> = Set.new()
        \\  let mut s = Set.from([1, 2, 2, 3])
        \\  s.insert(4)
        \\  let mut probe = 0
        \\  if s.contains(2) { probe += 1 }
        \\  entity.get_mut(Acc).n = s.len() + e.len() + probe
        \\}
    , &out);
    // Annotated `Set.new()`: a distinct single-field element list, no seed.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "const e: std.ArrayListUnmanaged(struct { item: i64 }) = .empty;") != null);
    // Un-annotated `Set.from`: element type inferred from the first element,
    // seeded element by element through the dedup helper (2 collapses).
    try std.testing.expect(std.mem.indexOf(u8, out.items, "var s: std.ArrayListUnmanaged(struct { item: i64 }) = .empty;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "fn __etchSetInsert(s: anytype, fa: std.mem.Allocator, item: anytype) void {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "fn __etchSetContains(s: anytype, item: anytype) bool {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "__etchSetInsert(&s, fa, 1);") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "__etchSetInsert(&(s), fa, 4)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "__etchSetContains(s, 2)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "@as(i64, @intCast((s).items.len))") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "@as(i64, @intCast((e).items.len))") != null);

    // A set-free program never emits the helpers (byte-identity belt).
    var plain: std.ArrayListUnmanaged(u8) = .empty;
    defer plain.deinit(gpa);
    _ = try parseTypeCheckGen(gpa,
        \\component Acc { n: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  entity.get_mut(Acc).n = 5
        \\}
    , &plain);
    try std.testing.expect(std.mem.indexOf(u8, plain.items, "__etchSet") == null);
}

test "lowers the Optional ops to orelse/.?/if-capture and gates the map-get helper (M0.8 E3-C tranche 4)" {
    const gpa = std.testing.allocator;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    _ = try parseTypeCheckGen(gpa,
        \\component Acc { n: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  let mut xs: int[] = [10, 20]
        \\  let a = xs.pop() ?? -1
        \\  let b = xs.pop()!
        \\  let mut m = [1: 100]
        \\  let c = m[1] ?? 0
        \\  let s: string? = some("hi")
        \\  let d = s?.len() ?? 0
        \\  let e = match m[2] { some(x) => x + 1, none => 0 }
        \\  entity.get_mut(Acc).n = a + b + c + d + e
        \\}
    , &out);
    // `pop` maps to the list's own `?T` pop; `??` → orelse; `!` → `.?`.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "((xs).pop() orelse -(1))") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "((xs).pop()).?") != null);
    // `m[k]` routes through the gated map-get helper.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "fn __etchMapGet(m: anytype, k: anytype) ?@FieldType(std.meta.Child(@TypeOf(m.items)), \"value\") {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "(__etchMapGet(m, 1) orelse 0)") != null);
    // `s?.len()` → if-capture short-circuiting to null; `string?` → ?[]const u8.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "const s: ?[]const u8 =") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "(if (s) |__opv| @as(?i64, @intCast(__opv.len)) else null)") != null);
    // Optional match → labeled block, capture arm + null arm, no catch-all.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "if (__m0) |x| break :blk0 (x + 1); if (__m0 == null) break :blk0 0; unreachable;") != null);

    // A map-free program never emits the get helper (same gate as insert).
    var plain: std.ArrayListUnmanaged(u8) = .empty;
    defer plain.deinit(gpa);
    _ = try parseTypeCheckGen(gpa,
        \\component Acc { n: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  entity.get_mut(Acc).n = 5
        \\}
    , &plain);
    try std.testing.expect(std.mem.indexOf(u8, plain.items, "__etchMapGet") == null);
}

test "lowers the enum shorthand in field-value position to the qualified variant (M0.8 E3-C tranche 4)" {
    const gpa = std.testing.allocator;
    // The part1 §10.2 canonical form: a bare `.variant` field value emits
    // qualified from the field's declared enum type.
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    _ = try parseTypeCheckGen(gpa,
        \\enum Faction { red, blue }
        \\struct Spec {
        \\  hp: int
        \\  faction: Faction
        \\}
        \\component Acc { n: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  let s = Spec { hp: 5, faction: .blue }
        \\  entity.get_mut(Acc).n = s.hp
        \\}
    , &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Spec{ .hp = 5, .faction = Faction.blue }") != null);
}

test "collection allocations require the frame arena: fn-body push fails loud (M0.8 E3-C tranche 3)" {
    const gpa = std.testing.allocator;
    // A fn body has no arena (§6.3 outparam model deferred) — a collection
    // allocation inside one fails loud, same policy as string concat.
    var pr = try parser.parse(gpa,
        \\component Acc { n: int = 0 }
        \\fn build() -> int {
        \\  let mut xs: int[] = [1]
        \\  xs.push(2)
        \\  return xs.len()
        \\}
        \\rule r(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  entity.get_mut(Acc).n = build()
        \\}
    );
    defer pr.deinit(gpa);
    try std.testing.expect(pr.diagnostics.len == 0);
    var diags: std.ArrayListUnmanaged(diag.Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try types.TypeChecker.check(gpa, &pr.ast, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    try std.testing.expectError(
        root.CodegenError.UnsupportedConstruct,
        root.generateToBuffer(gpa, &pr.ast, "<test>", &out),
    );
}

test "lowers mut-self methods to pointer receivers, mutation visible at the call site (M0.8 E3-C tranche 5)" {
    const gpa = std.testing.allocator;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    _ = try parseTypeCheckGen(gpa,
        \\struct Cnt { v: int = 0 }
        \\impl Cnt {
        \\  fn bump(mut self, by: int) { self.v += by }
        \\  fn peek(self) -> int { self.v }
        \\}
        \\component Acc { n: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  let mut c = Cnt { v: 1 }
        \\  c.bump(41)
        \\  entity.get_mut(Acc).n = c.peek()
        \\}
    , &out);
    // `mut self` → pointer receiver; plain `self` keeps the by-value shape.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "pub fn bump(self: *Cnt, by: i64) void {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "pub fn peek(self: Cnt) i64 {") != null);
    // The receiver is a `var` binding, auto-referenced by Zig at the call
    // site — the in-place mutation reaches the caller's `c`.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "var c = Cnt{ .v = 1 };") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "_ = c.bump(41);") != null);

    // The generated Zig is syntactically valid (Zig's own parser).
    const z = try gpa.dupeZ(u8, out.items);
    defer gpa.free(z);
    var tree = try std.zig.Ast.parse(gpa, z, .zig);
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) std.debug.print("generated zig parse errors:\n{s}\n", .{out.items});
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "lowers anonymous struct literals to qualified Zig literals from the expected type (M0.8 E3-C tranche 8)" {
    const gpa = std.testing.allocator;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    _ = try parseTypeCheckGen(gpa,
        \\component Acc { n: int = 0 }
        \\struct Pt { x: int y: int }
        \\struct Box { p: Pt k: int }
        \\rule r(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  let q: Pt = .{ x: 40, y: 2 }
        \\  let b = Box { p: .{ x: 7, y: 5 }, k: 30 }
        \\  entity.get_mut(Acc).n = q.x + q.y + b.p.x + b.k
        \\}
    , &out);
    // The let annotation qualifies the literal — byte-identical to the
    // explicit form's emission (un-annotated binding).
    try std.testing.expect(std.mem.indexOf(u8, out.items, "const q = Pt{ .x = 40, .y = 2 };") != null);
    // The declared field type qualifies the nested literal recursively.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "const b = Box{ .p = Pt{ .x = 7, .y = 5 }, .k = 30 };") != null);
    // The struct-typed struct field declares with a `.{}` default (never
    // observed — the resolver requires literal provision, E0208).
    try std.testing.expect(std.mem.indexOf(u8, out.items, "p: Pt = .{},") != null);

    // The generated Zig is syntactically valid (Zig's own parser).
    const z = try gpa.dupeZ(u8, out.items);
    defer gpa.free(z);
    var tree = try std.zig.Ast.parse(gpa, z, .zig);
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) std.debug.print("generated zig parse errors:\n{s}\n", .{out.items});
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "lowers capturing closures to struct-with-fields, snapshot at creation (M0.8 E3-C tranche 6)" {
    const gpa = std.testing.allocator;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    _ = try parseTypeCheckGen(gpa,
        \\component Acc { n: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  let mut factor = 40
        \\  let scale = |x: int| x + factor
        \\  let double = |x: int| x * 2
        \\  factor = 100
        \\  entity.get_mut(Acc).n = scale(2) + double(0)
        \\}
    , &out);
    // The capturing closure is an INSTANCE of a struct-with-fields: the
    // captured value is copied at creation (before `factor = 100`), and the
    // body reads it through the `__self` receiver — by-value capture at the
    // interpreter's exact logical point (its locals snapshot).
    try std.testing.expect(std.mem.indexOf(u8, out.items, "struct { factor: i64, fn call(__self: @This(), x: i64) i64 { return ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "__self.factor") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "}{ .factor = factor };") != null);
    // The capture-free closure keeps the bare TYPE shape (namespace call) —
    // byte-identical to the E1 emission.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "struct { fn call(x: i64) i64 { return ") != null);

    // The generated Zig is syntactically valid (Zig's own parser).
    const z = try gpa.dupeZ(u8, out.items);
    defer gpa.free(z);
    var tree = try std.zig.Ast.parse(gpa, z, .zig);
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) std.debug.print("generated zig parse errors:\n{s}\n", .{out.items});
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "closure captures are bounded to POD scalars: string capture fails loud (M0.8 E3-C tranche 6)" {
    const gpa = std.testing.allocator;
    // A string-typed capture is a §8.2 ref-capture — outside the M0.8
    // codegen subset (interpreter reference, fail loud).
    var pr = try parser.parse(gpa,
        \\component Acc { n: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has Acc
        \\{
        \\  let name = "weld"
        \\  let len_of = |x: int| x + name.len()
        \\  entity.get_mut(Acc).n = len_of(38)
        \\}
    );
    defer pr.deinit(gpa);
    try std.testing.expect(pr.diagnostics.len == 0);
    var diags: std.ArrayListUnmanaged(diag.Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try types.TypeChecker.check(gpa, &pr.ast, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    try std.testing.expectError(
        root.CodegenError.UnsupportedConstruct,
        root.generateToBuffer(gpa, &pr.ast, "<test>", &out),
    );
}
