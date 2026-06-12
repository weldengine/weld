//! Level-B serialized-IR differential (M0.8 E4 — LEVEL-B PROOF CONTRACT,
//! brief journal 2026-06-10).
//!
//! For each Level-B program: the interpreter BUILDS the descriptors at
//! compile (`Interpreter.descriptors`, build-structure) and the cooked Zig
//! EMITS them as static structures (`Program.write_descriptors`,
//! emit-structure — Sema-compiled by the cook pipeline like every corpus
//! program). Both serialize through the shared canonical serializer
//! (`descriptor_types.zig`, single source compiled into both backends) and
//! the dumps must be byte-identical. No world-state diff: Level B never
//! executes against the world.

const std = @import("std");
const weld_core = @import("weld_core");
const weld_etch = @import("weld_etch");
const corpus_codegen = @import("corpus_codegen");

const World = weld_core.ecs.world.World;

const LevelBProgram = struct {
    /// Cooked namespace name (`pNN_…`) — the `corpus_codegen` lookup key.
    name: []const u8,
    source: []const u8,
};

/// Level-B differential programs. Registered here (serialized-IR diff) AND
/// in `codegen_corpus_build.zig` (cook + compile); deliberately absent from
/// the world-state corpus facade (no sidecar — nothing executes).
const programs = [_]LevelBProgram{
    .{ .name = "p62_data_table", .source = @embedFile("programs/62_data_table.etch") },
    .{ .name = "p63_routine_daily", .source = @embedFile("programs/63_routine_daily.etch") },
    .{ .name = "p67_behavior_tree", .source = @embedFile("programs/67_behavior_tree.etch") },
    .{ .name = "p68_quest_escort", .source = @embedFile("programs/68_quest_escort.etch") },
    .{ .name = "p69_dialogue_merchant", .source = @embedFile("programs/69_dialogue_merchant.etch") },
    .{ .name = "p70_ability_fireball", .source = @embedFile("programs/70_ability_fireball.etch") },
    // M0.8 E5 Level-B presentation.
    .{ .name = "p71_theme_dark", .source = @embedFile("programs/71_theme_dark.etch") },
    .{ .name = "p72_motion_ui", .source = @embedFile("programs/72_motion_ui.etch") },
    .{ .name = "p73_input_mapping", .source = @embedFile("programs/73_input_mapping.etch") },
    .{ .name = "p74_widget_panel", .source = @embedFile("programs/74_widget_panel.etch") },
    .{ .name = "p75_locale_en", .source = @embedFile("programs/75_locale_en.etch") },
    // M0.8 E6 Level-B render/animation/audio/cinematic.
    .{ .name = "p76_effect_explosion", .source = @embedFile("programs/76_effect_explosion.etch") },
    .{ .name = "p77_audio_graph_laser", .source = @embedFile("programs/77_audio_graph_laser.etch") },
    .{ .name = "p78_audio_score_exploration", .source = @embedFile("programs/78_audio_score_exploration.etch") },
    .{ .name = "p79_sequence_intro", .source = @embedFile("programs/79_sequence_intro.etch") },
};

test "level-b serialized IR: interpreter build == cooked emit, byte-identical" {
    const gpa = std.testing.allocator;
    for (programs) |p| {
        // Interpreter side — parse + type-check clean, then compile; the
        // descriptors are built by `Interpreter.compile` (build-structure).
        var pr = try weld_etch.parseSource(gpa, p.source);
        defer pr.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
        var diags: std.ArrayListUnmanaged(weld_etch.Diagnostic) = .empty;
        defer {
            for (diags.items) |*d| d.deinit(gpa);
            diags.deinit(gpa);
        }
        try weld_etch.typeCheck(gpa, &pr.ast, &diags);
        try std.testing.expectEqual(@as(usize, 0), diags.items.len);

        var world = World.init();
        defer world.deinit(gpa);
        var interp = try weld_etch.Interpreter.compile(gpa, &pr.ast, &world);
        defer interp.deinit();

        var interp_dump: std.ArrayListUnmanaged(u8) = .empty;
        defer interp_dump.deinit(gpa);
        try interp.descriptors.serialize(gpa, &interp_dump);

        // Codegen side — the cooked namespace's `writeDescriptors`.
        const program = corpus_codegen.lookupByName(p.name) orelse {
            std.debug.print("level-b program '{s}' not in the consolidated corpus\n", .{p.name});
            return error.UnknownProgram;
        };
        const write = program.write_descriptors orelse {
            std.debug.print("level-b program '{s}' has no write_descriptors entry point\n", .{p.name});
            return error.MissingDescriptorEntryPoint;
        };
        var cooked_dump: std.ArrayListUnmanaged(u8) = .empty;
        defer cooked_dump.deinit(gpa);
        try write(gpa, &cooked_dump);

        try std.testing.expect(interp_dump.items.len > 0);
        try std.testing.expectEqualStrings(interp_dump.items, cooked_dump.items);
    }
}
