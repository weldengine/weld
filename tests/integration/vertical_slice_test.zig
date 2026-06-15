//! M0.9 vertical slice — integration test.
//!
//! E3 facets:
//!  1. Headless simulation — boot a World, spawn EXACTLY 100 entities, tick the
//!     five cooked Etch rules 120× at fixed 60 Hz, assert count + that the
//!     simulation ran (per-entity Counter == ticks).
//!  2. Cross-file scene/prefab validation (E2-B) over the authored typed-ext
//!     files: E1786/E1791/E1782 resolve; the two prefab `Health` refs are E1793
//!     (cross-file type-import is the Phase 1 resolver — brief Blockers #2), so
//!     the test asserts E2-B BEHAVIOUR, not diags == 0.
//!
//! E4 facets:
//!  3. Asset cook + load — the slice's `slice_albedo.png` imports + cooks
//!     through the real M0.6 pipeline to a `.texture.bin` whose header +
//!     metadata + payload are exactly an 8×8 RGBA8 texture.
//!  4. Input → sim effect — a synthesized SPACE key edge toggles the host
//!     pause `Control`, and `stepIfRunning` gates the simulation on it (the
//!     observable M0.3 input effect).
//!
//! The render itself is not asserted here: the renderer fills buffers via
//! `mapBuffer`, which the Null backend leaves `Unsupported`, so no slice-render
//! path runs headless. Render coverage = compile-checked on every platform
//! (incl. the `copyBufferToTexture` upload call) + the lavapipe `--smoke-test`
//! CI job + hardware validation (see render.zig).

const std = @import("std");
const weld_core = @import("weld_core");
const etch = @import("weld_etch");
const assets = @import("weld_asset_pipeline");
const slice = @import("slice");

const sim = slice.sim;
const ipc_loop = slice.ipc_loop;

const World = weld_core.ecs.world.World;
const EntityId = weld_core.ecs.entity.EntityId;
const window = weld_core.platform.window;
const raw_state = weld_core.platform.input.raw_state;
const InputRawState = raw_state.InputRawState;
const DiagnosticCode = etch.diagnostics.DiagnosticCode;

const test_ticks: u32 = 120;

test "vertical slice headless: 100 entities, 120 ticks at fixed 60 Hz" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    try sim.bootAndSpawn(&world, gpa);

    // Exactly 100 entities: indices 0..99 exist, index 100 does not.
    var i: u32 = 0;
    while (i < sim.entity_count) : (i += 1) {
        try std.testing.expect(world.dynamicLocation(.{ .index = i, .generation = 0 }) != null);
    }
    try std.testing.expect(world.dynamicLocation(.{ .index = sim.entity_count, .generation = 0 }) == null);

    var t: u32 = 0;
    while (t < test_ticks) : (t += 1) sim.step(&world, gpa);

    // The simulation ran: `advance_clock` incremented Counter once per tick.
    try std.testing.expectEqual(@as(i64, test_ticks), readCounterTicks(&world, 0));
    try std.testing.expectEqual(@as(i64, test_ticks), readCounterTicks(&world, sim.entity_count - 1));
}

/// Read entity `index`'s `Counter.ticks` via the registry + archetype layout.
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
        .{ .name = "mob.prefab.etch", .source = sim.mob_prefab_etch },
        .{ .name = "elite.prefab.etch", .source = sim.elite_prefab_etch },
        .{ .name = "world.scene.etch", .source = sim.scene_etch },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try etch.validateProject(gpa, &files, &diags);

    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .prefab_ref_not_found)); // E1786
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .prefab_base_not_found)); // E1791
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .duplicate_uuid)); // E1782
    // Phase-0 boundary (brief Blockers #2): each prefab's `Health` ref is E1793.
    try std.testing.expectEqual(@as(usize, 2), countCode(diags.items, .prefab_component_type_unknown));
    try std.testing.expectEqual(@as(usize, 2), diags.items.len);
}

test "vertical slice asset: PNG import → cook → .texture.bin (M0.6)" {
    const gpa = std.testing.allocator;
    const uuid = "0190b3f0-1c2d-7e4a-8b6c-5117ce0a1be0";

    var imp = try assets.importers.png.import(gpa, "slice_albedo.png", sim.albedo_png, uuid);
    defer imp.deinit(gpa);
    try std.testing.expectEqualStrings("Texture2D", imp.doc.type_name);

    const bin = try assets.cookers.cookTexture(gpa, imp.doc, imp.blob);
    defer gpa.free(bin);

    const header = try assets.RuntimeHeader.read(bin);
    try std.testing.expectEqual(assets.AssetType.texture, header.assetType().?);

    const meta = bin[header.metadata_offset..][0..header.metadata_size];
    try std.testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, meta[0..4], .little)); // width
    try std.testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, meta[4..8], .little)); // height

    const payload = bin[header.data_offset..][0..header.data_size];
    try std.testing.expectEqual(@as(usize, 8 * 8 * 4), payload.len);
}

test "vertical slice input: SPACE toggles pause, gating the sim (M0.3)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    try sim.bootAndSpawn(&world, gpa);

    // M0.3 raw pipeline: pumping a window key event populates InputRawState
    // (the keyboard array is scancode-indexed; SPACE = scancode 57 on evdev +
    // win32).
    var raw = InputRawState{};
    raw_state.beginFrame(&raw);
    const space = window.Event{ .key_down = .{ .code = .space, .scancode = 57, .repeat = false } };
    raw_state.applyEvent(&raw, space);
    try std.testing.expect(raw.keyboard.pressed[57]);
    try std.testing.expect(raw.keyboard.pressed_this_frame[57]);

    // Control reacts to the normalized KeyCode → toggles pause → gates the sim.
    var control = sim.Control{};
    control.applyEvent(space); // pause ON
    try std.testing.expect(control.paused);
    control.stepIfRunning(&world, gpa);
    try std.testing.expectEqual(@as(i64, 0), readCounterTicks(&world, 0)); // frozen

    control.applyEvent(space); // pause OFF
    try std.testing.expect(!control.paused);
    control.stepIfRunning(&world, gpa);
    try std.testing.expectEqual(@as(i64, 1), readCounterTicks(&world, 0)); // advanced
}

test "vertical slice IPC: ModifyComponent over M0.7 applies to the live world (C0.8)" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    try sim.bootAndSpawn(&world, gpa);

    const before = sim.readPosition(&world, 0);
    const new_x: f32 = before[0] + 7.5;
    const msg = ipc_loop.buildF32Edit(&world, 0, "Position", "x", new_x).?;

    // The editor-stub sends a real ModifyComponent over the real M0.7 transport
    // (AF_UNIX socket + framing); the slice's runtime-side decodes it and
    // applies it to the LIVE World via the diff_runner write path. This is the
    // C0.8 semantic loop end-to-end — assertable headless on every platform
    // (socket-only; the visual reflection is the lavapipe smoke + hardware).
    try ipc_loop.runOneEdit(gpa, &world, msg);

    const after = sim.readPosition(&world, 0);
    try std.testing.expectApproxEqAbs(new_x, after[0], 1e-6); // edited field changed
    try std.testing.expectApproxEqAbs(before[1], after[1], 1e-6); // sibling field untouched
}
