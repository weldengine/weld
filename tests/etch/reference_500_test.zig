//! `reference_500_lines.etch` — the M0.8 E7 full-grammar integration reference.
//!
//! One 500+ line file mixing EVERY v0.6 construct (Level-A foundations + the 17
//! E4-E6 domain constructs + Level-C scene/prefab + generics + async). It is the
//! at-scale integration proof:
//!   • PARSE the whole file < 50 ms (measured median, the headline gate);
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
const builtin = @import("builtin");
const weld_etch = @import("weld_etch");
const weld_core = @import("weld_core");

const World = weld_core.ecs.world.World;
const EntityId = weld_core.ecs.entity.EntityId;
const ComponentId = weld_core.ecs.registry.ComponentId;
const Interpreter = weld_etch.Interpreter;
const Diagnostic = weld_etch.Diagnostic;
const time = weld_core.platform.time;

const reference_src = @embedFile("reference_500_lines.etch");

fn countLines(s: []const u8) usize {
    var n: usize = 1;
    for (s) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

test "reference_500_lines: ≥500 lines, parses clean, type-checks clean, parse median < 50 ms" {
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

    // PARSE-TIME — median of K passes, gate < 50 ms (the brief's headline).
    const K = 50;
    var samples: [K]u64 = undefined;
    var k: usize = 0;
    while (k < K) : (k += 1) {
        const t0 = time.nowNanos();
        var p = try weld_etch.parseSource(gpa, reference_src);
        const dt = time.nowNanos() - t0;
        p.deinit(gpa);
        samples[k] = dt;
    }
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    const median = samples[K / 2];
    std.debug.print(
        "[ref500] parse median ({s}): {d} ns ({d:.4} ms) over {d} passes\n",
        .{ @tagName(builtin.mode), median, @as(f64, @floatFromInt(median)) / std.time.ns_per_ms, K },
    );
    // The brief's < 50 ms gate is a ReleaseSafe verdict (the S3 bench protocol —
    // parse-time verdicts are taken in ReleaseSafe, never Debug). A Debug build
    // walks the parser ~5-10× slower, so the strict gate is asserted only in a
    // release mode; in Debug we only guard against a pathological regression.
    // Guy's two-machine re-bench runs `zig build test-ref500 -Doptimize=ReleaseSafe`.
    if (builtin.mode == .Debug) {
        try std.testing.expect(median < 300 * std.time.ns_per_ms);
    } else {
        try std.testing.expect(median < 50 * std.time.ns_per_ms);
    }
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
