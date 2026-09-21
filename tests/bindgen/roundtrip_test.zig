//! Bindgen round-trip gate: a regen must produce no diff against the committed
//! output. A non-zero exit has three causes — a real diff, an unclean tree, or a
//! `git` that cannot run — and the third must not be reported as the first.
const std = @import("std");

/// Does `git` answer at all? `git --version` and not a diff, because it shares
/// every failure mode that is ABOUT THE TOOL and none about the tree — a control
/// able to fail for the reason under test proves nothing.
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
