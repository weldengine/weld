//! The file is not cooked: its async and generic fragments are
//! `UnsupportedConstruct` in codegen.

const std = @import("std");
const weld_etch = @import("weld_etch");
const weld_core = @import("weld_core");

const World = weld_core.ecs.world.World;
const EntityId = weld_core.ecs.entity.EntityId;
const ComponentId = weld_core.ecs.registry.ComponentId;
const Interpreter = weld_etch.Interpreter;
const Diagnostic = weld_etch.Diagnostic;

const reference_src = @embedFile("reference_500_lines.etch");

fn countLines(s: []const u8) usize {
    var n: usize = 1;
    for (s) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

test "reference_500_lines: ≥500 lines, parses clean, type-checks clean" {
    const gpa = std.testing.allocator;

    const lines = countLines(reference_src);
    std.debug.print("[ref500] source lines: {d}\n", .{lines});
    try std.testing.expect(lines >= 500);

    // PARSE clean — dump every diagnostic on failure for fast iteration.
    var pr = try weld_etch.parseSource(gpa, reference_src);
    defer pr.deinit(gpa);
    if (pr.diagnostics.len > 0) {
        for (pr.diagnostics) |d| {
            std.debug.print("[ref500] PARSE {s}: {s}\n", .{ d.code.code(), d.primary_message });
        }
    }
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);

    // TYPE-CHECK clean — dump every diagnostic on failure.
    var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try weld_etch.typeCheck(gpa, &pr.ast, &diags);
    if (diags.items.len > 0) {
        for (diags.items) |d| {
            std.debug.print("[ref500] TYPECHECK {s}: {s}\n", .{ d.code.code(), d.primary_message });
        }
    }
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
}

test "reference_500_lines: Level-A interpret — the RefProbe rule ticks the live world" {
    const gpa = std.testing.allocator;

    var pr = try weld_etch.parseSource(gpa, reference_src);
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);

    var world = World.init();
    defer world.deinit(gpa);
    var interp = try Interpreter.compile(gpa, &pr.ast, &world);
    defer interp.deinit();

    // Seed ONE entity carrying only RefProbe: every other iterative rule's
    // `when entity has X` fails to match it, so the assertion is isolated to
    // the dedicated `rule ref_probe_tick` (+= 1 / tick).
    const cid = world.registry.idOf("RefProbe").?;
    _ = try world.spawnDynamic(gpa, &[_]ComponentId{cid});

    _ = try interp.runFor(&world, 7);

    const eid = EntityId{ .index = 0, .generation = 0 };
    const loc = world.dynamicLocation(eid).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const chunk = arch.chunks.items[loc.chunk_idx];
    const idx = arch.componentIndex(cid).?;
    const slot = arch.componentSlot(chunk, idx, loc.slot);
    const fd = world.registry.findField(cid, "ticks").?;
    var v: i64 = 0;
    @memcpy(std.mem.asBytes(&v), slot[fd.offset .. fd.offset + 8]);
    try std.testing.expectEqual(@as(i64, 7), v);
}
