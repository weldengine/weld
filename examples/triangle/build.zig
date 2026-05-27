//! Examples / triangle — Phase 0 / M0.4.
//!
//! Sous-projet Zig standalone qui consomme Weld via `b.dependency("weld", ...)`.
//! Démontre l'intégration publique de la GAL — test architectural vivant de
//! la consommabilité externe de l'API (brief §Scope + §Notes décision 12).

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dépendance vers le moteur Weld (path local dans le repo monolithique
    // Phase 0). Phase 5+ : potentiellement url + hash si extraction
    // séparable validée (cf. engine-spec.md §3.5).
    const weld = b.dependency("weld", .{
        .target = target,
        .optimize = optimize,
    });

    const main_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Surface publique du module `weld_render` (GAL Phase 0 surface) +
    // Tier 0 `platform.window` via `weld_core` (canonical Tier 0 public
    // API per engine-platform.md §4). Aucun import d'internals au-delà
    // (brief §Notes pièges connus).
    main_module.addImport("weld_render", weld.module("weld_render"));
    main_module.addImport("weld_core", weld.module("weld_core"));
    // Pre-compiled SPIR-V (triangle.vert/frag + viewport_blit) — shared
    // facade exposed by the engine so callers do not have to escape their
    // own package root with `@embedFile`.
    main_module.addImport("shaders", weld.module("shaders"));

    const exe = b.addExecutable(.{
        .name = "triangle",
        .root_module = main_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the triangle example");
    run_step.dependOn(&run_cmd.step);
}
