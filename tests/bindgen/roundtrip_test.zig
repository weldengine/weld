//! M0.2 / E5 — bindgen roundtrip gate.
//!
//! Non-negotiable mechanical criterion of the E5 brief: regenerate
//! the bindings and verify `git diff --quiet` returns 0 on
//! `bindings/generated/` + `src/core/platform/`. Any bit-for-bit
//! divergence fails the test (and therefore the merge in CI).
//!
//! Implementation: invoke `zig build bindgen-verify` in a
//! subprocess. The `bindgen-verify` step regenerates then runs
//! `git diff --quiet` (cf. `build.zig`).
//!
//! **A non-zero exit has THREE causes and this test used to name two.** The
//! regeneration diverged; the tree was not clean; or `git` could not run at
//! all — and the third was reported as `BindgenDriftDetected`, a divergence
//! verdict nothing had measured. It is not hypothetical: on macOS
//! `/usr/bin/git` is the Xcode shim, and an unaccepted licence makes EVERY
//! invocation exit 69, `git --version` included, so the gate goes red while
//! the bindings are byte-identical. Measured 2026-09-15; the condition lifted
//! with no code change and the same test passed, which is what established
//! that no drift had ever existed.
//!
//! So the tool is established to answer BEFORE its exit code is read as a
//! verdict — the known-good control this repository already applies elsewhere.
//! The third outcome fails under its own name and never as a drift.

const std = @import("std");

/// Does `git` answer at all?
///
/// The control is `git --version` and not a diff, because it shares every
/// failure mode that is ABOUT THE TOOL — missing binary, unaccepted Xcode
/// licence, broken PATH — and none that is about the tree. A control that could
/// itself fail for the reason under test would prove nothing.
fn gitAnswers(gpa: std.mem.Allocator, io: std.Io) bool {
    const r = std.process.run(gpa, io, .{ .argv = &.{ "git", "--version" } }) catch return false;
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    return switch (r.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

test "regen Vulkan + Wayland produces no diff vs committed (bindgen-verify gate)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // THE CONTROL, ahead of everything: without it the branch below cannot tell
    // a divergence from an unusable tool, and answers the first.
    if (!gitAnswers(gpa, io)) {
        std.debug.print(
            "roundtrip_test: `git --version` does not answer — the bindgen gate " ++
                "cannot be evaluated, and NO drift verdict is implied. On macOS this " ++
                "is usually an unaccepted Xcode licence (`sudo xcodebuild -license`).\n",
            .{},
        );
        return error.GitUnavailable;
    }

    // Resolve the project root by climbing from the test's cwd.
    // `zig build test` runs tests from the project root.
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, "zig");
    try argv.append(gpa, "build");
    try argv.append(gpa, "bindgen-verify");

    const result = std.process.run(gpa, io, .{ .argv = argv.items }) catch |err| {
        // `zig` not in PATH or another infra issue. Skip with a
        // soft error so the test surface stays portable.
        std.debug.print(
            "roundtrip_test: could not invoke `zig build bindgen-verify` ({s}). " ++
                "Skipping; the bindgen-verify CI step is the primary gate.\n",
            .{@errorName(err)},
        );
        return error.SkipZigTest;
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                // Re-check the tool AFTER the run: the build itself invokes
                // `git`, and an environment that degraded between the control
                // and here would otherwise land on the drift arm — the exact
                // substitution this control exists to prevent, one step later.
                if (!gitAnswers(gpa, io)) {
                    std.debug.print(
                        "roundtrip_test: `git` stopped answering during the run — " ++
                            "no drift verdict is implied.\n",
                        .{},
                    );
                    return error.GitUnavailable;
                }
                std.debug.print(
                    "roundtrip_test: bindgen-verify exited with code {d}.\n" ++
                        "stdout:\n{s}\nstderr:\n{s}\n",
                    .{ code, result.stdout, result.stderr },
                );
                return error.BindgenDriftDetected;
            }
        },
        else => {
            std.debug.print(
                "roundtrip_test: bindgen-verify terminated abnormally ({any}).\n" ++
                    "stdout:\n{s}\nstderr:\n{s}\n",
                .{ result.term, result.stdout, result.stderr },
            );
            return error.BindgenVerifyAbnormalExit;
        },
    }
}
