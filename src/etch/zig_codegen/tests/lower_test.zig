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
    try std.testing.expect(std.mem.indexOf(u8, out.items, "try world.event_bus.register(Damage, 256, .tick);") != null);
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
