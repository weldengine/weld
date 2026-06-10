//! Dedicated D-S5-etchcook-inproc test (M0.8 E3-D): the consolidated cook
//! is a LIBRARY (`weld_etch.codegen_zig.consolidate`) consumable in-process
//! — the `etch_cook` CLI is a thin file-I/O shim over it and the bench
//! harness calls it directly, with no child process on the timed path.

const std = @import("std");
const weld_etch = @import("weld_etch");
const consolidate = weld_etch.codegen_zig.consolidate;

const program_a =
    \\component Acc { out: int = 0 }
    \\rule bump(entity: Entity)
    \\  when entity has Acc
    \\{
    \\  entity.get_mut(Acc).out += 1
    \\}
;

const program_b =
    \\component Score { value: int = 0 }
    \\component Tagged { on: int = 0 }
    \\rule score(entity: Entity)
    \\  when entity has Score and entity has Tagged
    \\{
    \\  entity.get_mut(Score).value += 2
    \\}
;

test "cookConsolidated renders namespaces, one header, and the programs table (D-S5-etchcook-inproc)" {
    const gpa = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);

    const inputs = [_]consolidate.NamedSource{
        .{ .name = "p_a", .source = program_a },
        .{ .name = "p_b", .source = program_b },
    };
    const stats = try consolidate.cookConsolidated(gpa, &inputs, &out);

    // Both program namespaces are present.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "pub const p_a = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "pub const p_b = struct {") != null);
    // Exactly ONE consolidated import header — the per-file imports are
    // stripped from every cooked body.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.items, "const weld_core = @import(\"weld_core\");"));
    // The programs table maps both names to (register, tick) pointers.
    try std.testing.expect(std.mem.indexOf(u8, out.items, ".{ .name = \"p_a\", .register = &p_a.register, .tick = &p_a.tick },") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, ".{ .name = \"p_b\", .register = &p_b.register, .tick = &p_b.tick },") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "pub fn lookupByName(") != null);
    // Aggregate stats: two rules, two distinct query signatures
    // ((Acc) vs (Score, Tagged)).
    try std.testing.expectEqual(@as(u32, 2), stats.rules);
    try std.testing.expectEqual(@as(u32, 2), stats.distinct_signatures);
    // The consolidated output is syntactically valid Zig.
    const sentinel = try gpa.dupeZ(u8, out.items);
    defer gpa.free(sentinel);
    var tree = try std.zig.Ast.parse(gpa, sentinel, .zig);
    defer tree.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
}

test "cookConsolidated propagates a failing input as a typed error (D-S5-etchcook-inproc)" {
    const gpa = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);

    const inputs = [_]consolidate.NamedSource{
        .{ .name = "broken", .source = "component { nope" },
    };
    try std.testing.expectError(error.ParseFailed, consolidate.cookConsolidated(gpa, &inputs, &out));
}
