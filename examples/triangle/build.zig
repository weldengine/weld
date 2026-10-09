//! The triangle example.
//!
//! A standalone Zig sub-project consuming Weld through
//! `b.dependency("weld", …)`. It demonstrates the public GAL integration and
//! is the living architectural test of the API's external consumability: it
//! breaks the day the engine stops being consumable from outside.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The engine, by local path while the repo is monolithic. It becomes a url
    // plus hash the day separable extraction is validated (`ARCH-017`).
    const physics_f64 = b.option(bool, "physics_f64", "Build the engine's forge_3d in f64 precision") orelse false;
    const weld = b.dependency("weld", .{
        .target = target,
        .optimize = optimize,
        .physics_f64 = physics_f64,
    });

    const main_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    // The PUBLIC surface alone: `weld_render`'s GAL, plus Tier 0
    // `platform.window` through `weld_core` (`engine-platform.md` §4). Reaching
    // an internal from here would defeat the point of the sub-project.
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
