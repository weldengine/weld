//! M0.9 vertical slice — headless integration test (E3).
//!
//! Two facets:
//!  1. Headless simulation — boot a World, spawn EXACTLY 100 entities via the
//!     slice host helpers (Option A host-spawn — brief Blockers #1), tick the
//!     five cooked Etch rules 120× at a fixed 60 Hz timestep, and assert the
//!     entity count + that the simulation actually ran (per-entity tick counter
//!     == ticks).
//!  2. Cross-file scene/prefab validation (E2-B) over the slice's authored
//!     `*.scene.etch` / `*.prefab.etch`: the cross-file scene→prefab (E1786) and
//!     prefab `of` base (E1791) references resolve, UUIDs are unique (E1782).
//!     The prefabs' `Health` references are E1793 — cross-file type-import is
//!     the Phase 1 resolver deliverable, so this is expected, documented
//!     Phase-0 behaviour (brief Blockers #2). The test asserts the E2-B code
//!     BEHAVIOUR, NOT diags == 0.

const std = @import("std");
const weld_core = @import("weld_core");
const etch = @import("weld_etch");
const slice = @import("slice");

const World = weld_core.ecs.world.World;
const EntityId = weld_core.ecs.entity.EntityId;
const DiagnosticCode = etch.diagnostics.DiagnosticCode;

const test_ticks: u32 = 120;

test "vertical slice headless: 100 entities, 120 ticks at fixed 60 Hz" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    try slice.bootAndSpawn(&world, gpa);

    // Exactly 100 entities: indices 0..99 exist (monotonic spawn, no despawn),
    // index 100 does not.
    var i: u32 = 0;
    while (i < slice.entity_count) : (i += 1) {
        try std.testing.expect(world.dynamicLocation(.{ .index = i, .generation = 0 }) != null);
    }
    try std.testing.expect(world.dynamicLocation(.{ .index = slice.entity_count, .generation = 0 }) == null);

    // Fixed-timestep simulation.
    var t: u32 = 0;
    while (t < test_ticks) : (t += 1) slice.step(&world, gpa);

    // The simulation ran: entity 0's `advance_clock` rule incremented Counter
    // once per tick.
    try std.testing.expectEqual(@as(i64, test_ticks), readCounterTicks(&world, 0));
    // And the last entity too (every entity carries the full archetype).
    try std.testing.expectEqual(@as(i64, test_ticks), readCounterTicks(&world, slice.entity_count - 1));
}

/// Read entity `index`'s `Counter.ticks` (an Etch `int` → i64) from the live
/// world via the registry + archetype layout (the `diff_runner` read path).
fn readCounterTicks(world: *World, index: u32) i64 {
    const eid = EntityId{ .index = index, .generation = 0 };
    const loc = world.dynamicLocation(eid).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const chunk = arch.chunks.items[loc.chunk_idx];
    const cid = world.registry.idOf("Counter").?;
    const cidx = arch.componentIndex(cid).?;
    const slot = arch.componentSlot(chunk, cidx, loc.slot);
    const fd = world.registry.findField(cid, "ticks").?;
    var ticks: i64 = 0;
    @memcpy(std.mem.asBytes(&ticks), slot[fd.offset..][0..8]);
    return ticks;
}

fn countCode(diags: []const etch.Diagnostic, code: DiagnosticCode) usize {
    var n: usize = 0;
    for (diags) |d| {
        if (d.code == code) n += 1;
    }
    return n;
}

test "vertical slice cross-file scene/prefab validation (E2-B)" {
    const gpa = std.testing.allocator;
    const files = [_]etch.ProjectFile{
        .{ .name = "mob.prefab.etch", .source = slice.mob_prefab_etch },
        .{ .name = "elite.prefab.etch", .source = slice.elite_prefab_etch },
        .{ .name = "world.scene.etch", .source = slice.scene_etch },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try etch.validateProject(gpa, &files, &diags);

    // E2-B cross-file resolution works on the slice's real content:
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .prefab_ref_not_found)); // E1786 scene→prefab
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .prefab_base_not_found)); // E1791 elite of mob
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .duplicate_uuid)); // E1782 unique uuids

    // Phase-0 boundary (brief Blockers #2): cross-file type-import resolution is
    // Phase 1, so each prefab's `Health` reference is E1793 — expected. The two
    // E1793 are the only diagnostics produced.
    try std.testing.expectEqual(@as(usize, 2), countCode(diags.items, .prefab_component_type_unknown));
    try std.testing.expectEqual(@as(usize, 2), diags.items.len);
}
