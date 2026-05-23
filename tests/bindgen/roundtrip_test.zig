//! M0.2 / E5 — bindgen roundtrip gate.
//!
//! Critère mécanique non-négociable du brief E5 : régénérer
//! les bindings et vérifier `git diff --quiet` retourne 0 sur
//! `bindings/generated/` + `src/core/platform/`. Toute divergence
//! bit-pour-bit échoue le test (et donc le merge en CI).
//!
//! Implémentation : invoke `zig build bindgen-verify` en
//! subprocess. Le step `bindgen-verify` regenère puis exécute
//! `git diff --quiet` (cf. `build.zig`). Si le subprocess exit
//! avec un code non-zéro, soit la régénération a divergé, soit
//! l'arbre git n'était pas propre (changements locaux non
//! commités) — dans les deux cas le test bloque.

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
