//! Standalone build for the declared-access counter-proof corpus.
//!
//! A sub-project on the `bench/fixtures/synth_100` idiom: it consumes the
//! parent engine through the `weld` path dependency, which is what gives the
//! fixtures a correctly wired `weld_core` without this file re-deriving the
//! parent's module graph.
//!
//! **Why a sub-project and not four objects in the parent build.** Three of the
//! four fixtures must FAIL to compile. A compile step that fails inside the
//! parent graph fails the parent build, so the failures have to be driven as
//! subprocesses — and a subprocess that re-enters the parent's own `build.zig`
//! would contend with it for the build cache. Each case therefore gets its own
//! named step here, and the parent runs `zig build <step>` in this directory.
//!
//! `zig build` with no argument builds ONLY the control, so the default is the
//! case that must succeed.

const std = @import("std");

/// Every fixture: its step name, its source file, and whether it must compile.
const Case = struct {
    step: []const u8,
    file: []const u8,
    must_compile: bool,
    description: []const u8,
};

const cases = [_]Case{
    .{
        .step = "control",
        .file = "control.zig",
        .must_compile = true,
        .description = "declared read, declared write, read through a write — must compile",
    },
    .{
        .step = "case-undeclared",
        .file = "case_undeclared.zig",
        .must_compile = false,
        .description = "reads a component the declaration does not name — must NOT compile",
    },
    .{
        .step = "case-mutable-on-read",
        .file = "case_mutable_on_read.zig",
        .must_compile = false,
        .description = "writes a component declared read-only — must NOT compile",
    },
    .{
        .step = "case-missing-accesses",
        .file = "case_missing_accesses.zig",
        .must_compile = false,
        .description = "registers without a declared set — must NOT compile",
    },
    .{
        .step = "case-view-promotion",
        .file = "case_view_promotion.zig",
        .must_compile = false,
        .description = "rebuilds a wider view over a narrower one's pointer — must NOT compile",
    },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const weld = b.dependency("weld", .{
        .target = target,
        .optimize = optimize,
    });

    for (cases) |case| {
        const mod = b.createModule(.{
            .root_source_file = b.path(case.file),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("weld_core", weld.module("weld_core"));

        const obj = b.addObject(.{
            .name = case.step,
            .root_module = mod,
        });

        const step = b.step(case.step, case.description);
        step.dependOn(&obj.step);

        // The control is the only case in the default step: `zig build` here
        // must succeed, and it does so by building exactly the fixture that is
        // supposed to.
        if (case.must_compile) b.getInstallStep().dependOn(&obj.step);
    }
}
