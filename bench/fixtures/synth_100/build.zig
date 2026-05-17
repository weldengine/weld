//! Local build script for the S5 synthetic 100-file corpus.
//!
//! This file lives alongside the committed `scripts/000.etch … 099.etch`
//! corpus and `README.md`. It is **not** the build entry point used by
//! the main `zig build bench-etch-compile` flow — that flow lives in the
//! repo's root `build.zig` and drives the cook + Zig compile cycles
//! directly via `addRunArtifact` and `zig build-exe` invocations.
//!
//! This sub-project's `build.zig` is intentionally minimal: it documents
//! the layout and exposes a single `cook-and-compile` step that re-runs
//! the bench harness end-to-end. Direct invocation from this directory is
//! a convenience for manual debugging — the canonical entry point is
//! `zig build bench-etch-compile` from the repo root.
//!
//! Path escape constraint: Zig 0.16 forbids `b.path("../...")` so we
//! cannot reach `src/core/` or `tools/etch_cook/main.zig` from here. The
//! sub-project therefore does not declare modules itself — it only
//! advertises a top-level step that proxies to the parent build.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const step = b.step(
        "cook-and-compile",
        "Proxy to the repo-root `zig build bench-etch-compile` step",
    );
    const note = b.addSystemCommand(&.{
        "echo",
        "synth_100/build.zig is a placeholder — run `zig build bench-etch-compile` from the repo root",
    });
    step.dependOn(&note.step);
}
