//! Standalone build for the S5 synthetic 100-file corpus (M0.8 E3-D,
//! D-S5-synth100-proper — formerly a placeholder).
//!
//! A real Zig sub-project on the `examples/triangle` idiom: it consumes the
//! parent Weld engine via the `weld` path dependency (`build.zig.zon`),
//! drives the parent's installed `etch_cook` artifact over the committed
//! `scripts/000.etch … 099.etch` corpus, and compiles the consolidated cook
//! output against `weld.module("weld_core")` into an installable stub
//! executable (the bench-stub shape: every program namespace is
//! force-referenced so the Zig compiler builds each one end-to-end).
//!
//! `zig build` here is the proof artifact — the repo-root
//! `zig build verify-synth-100` step drives it. The S5 bench harness
//! (`zig build bench-etch-compile`) keeps its own direct `zig build-exe`
//! measurement path untouched: that incantation is the opposable bench
//! protocol, not this sub-project.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dependency on the Weld engine (local path in the Phase 0 monolithic
    // repo, three levels up — same rationale as `examples/triangle`).
    const weld = b.dependency("weld", .{
        .target = target,
        .optimize = optimize,
    });

    // Cook the committed corpus through the parent's installed `etch_cook`
    // CLI (the thin shim over the consolidated-cook library). The corpus
    // is the deterministic `000.etch … 099.etch` set the synth-100
    // generator contract guarantees; `addPrefixedFileArg` content-tracks
    // every input in the Run step's cache manifest.
    const cook = b.addRunArtifact(weld.artifact("etch_cook"));
    cook.addArg("--output");
    const cooked_path = cook.addOutputFileArg("cooked.zig");
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        cook.addPrefixedFileArg(
            b.fmt("p{d:0>3}=", .{i}),
            b.path(b.fmt("scripts/{d:0>3}.etch", .{i})),
        );
    }

    const cooked_module = b.createModule(.{
        .root_source_file = cooked_path,
        .target = target,
        .optimize = optimize,
    });
    cooked_module.addImport("weld_core", weld.module("weld_core"));

    // Tiny driver referencing every cooked program — the bench-stub shape
    // (`bench/etch_compile.zig` `writeStub`): `register`/`tick` are
    // referenced, never called, so the generated `tick(world, gpa)`
    // signature needs no runtime wiring here.
    const write_files = b.addWriteFiles();
    const stub_path = write_files.add("main.zig",
        \\const cooked = @import("cooked");
        \\
        \\pub fn main() void {
        \\    // Force-reference every program so the Zig compiler must
        \\    // compile each namespace end-to-end.
        \\    inline for (cooked.programs) |p| {
        \\        _ = p.register;
        \\        _ = p.tick;
        \\    }
        \\}
        \\
    );
    const main_module = b.createModule(.{
        .root_source_file = stub_path,
        .target = target,
        .optimize = optimize,
    });
    main_module.addImport("cooked", cooked_module);

    const exe = b.addExecutable(.{
        .name = "synth-100",
        .root_module = main_module,
    });
    b.installArtifact(exe);
}
