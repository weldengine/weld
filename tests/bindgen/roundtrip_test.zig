//! M0.2 / E5 — bindgen roundtrip gate.
//!
//! Non-negotiable mechanical criterion of the E5 brief: regenerate
//! the bindings and verify `git diff --quiet` returns 0 on
//! `bindings/generated/` + `src/core/platform/`. Any bit-for-bit
//! divergence fails the test (and therefore the merge in CI).
//!
//! Implementation: invoke `zig build bindgen-verify` in a
//! subprocess. The `bindgen-verify` step regenerates then runs
//! `git diff --quiet` (cf. `build.zig`). If the subprocess exits
//! with a non-zero code, either the regeneration diverged, or
//! the git tree was not clean (uncommitted local changes) — in
//! both cases the test blocks.

const std = @import("std");

test "regen Vulkan + Wayland produces no diff vs committed (bindgen-verify gate)" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

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
