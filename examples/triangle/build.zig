//! Examples / triangle — Phase 0 / M0.4.
//!
//! Standalone Zig sub-project that consumes Weld via `b.dependency("weld", ...)`.
//! Demonstrates the public GAL integration — a living architectural test of
//! the API's external consumability (brief §Scope + §Notes decision 12).

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dependency on the Weld engine (local path in the Phase 0 monolithic
    // repo). Phase 5+: potentially url + hash if separable extraction
    // is validated (cf. engine-spec.md §3.5).
    const weld = b.dependency("weld", .{
        .target = target,
        .optimize = optimize,
    });

    const main_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Public surface of the `weld_render` module (GAL Phase 0 surface) +
    // Tier 0 `platform.window` via `weld_core` (canonical Tier 0 public
    // API per engine-platform.md §4). No import of internals beyond that
    // (brief §Notes known pitfalls).
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
