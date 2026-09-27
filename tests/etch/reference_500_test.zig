//! `reference_500_lines.etch` — the full-grammar integration reference.
//!
//! One 500+ line file mixing EVERY v0.6 construct: the Level-A foundations, the
//! seventeen domain constructs, Level-C scene/prefab, generics and async. It is
//! the at-scale integration proof:
//!   • PARSE the whole file clean — its < 50 ms is `bench/etch_reference.zig`'s;
//!   • TYPE-CHECK the whole file clean (every construct coexists in one unit);
//!   • INTERPRET the Level-A behaviour (a dedicated `RefProbe` rule ticks the
//!     live world — the byte-exact interp behaviour at scale).
//!
//! The file is NOT cooked (codegen): it carries async + generic fragments which
//! are `UnsupportedConstruct` in codegen (the milestone-long invariant), so a
//! whole-file cook would fail-loud. The byte-exact interp↔codegen proof and the
//! Level-B/C codegen-compiles proof are carried by the exhaustive per-construct
//! differential corpus (programs 01-83): 01-75 Level-A byte-exact both backends,
//! 76-83 Level-B/C codegen-compiles + serialized-IR byte-identical. This split
//! mirrors the established per-program world-state-vs-serialized-IR separation.

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
