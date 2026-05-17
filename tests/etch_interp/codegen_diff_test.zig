//! S5 differential corpus driver against the Zig codegen runner. Same
//! shape as `corpus_test.zig` for the interpreter (S4), but plugs the
//! codegen-backed `Runner`. The driver and the corpus facade are unchanged
//! between S4 and S5 — only the runner module differs.

const std = @import("std");
const corpus = @import("corpus_facade");
const driver = @import("diff_runner");
const runner_mod = @import("runner_codegen");

test "codegen differential corpus — every program reaches its expected final state" {
    const gpa = std.testing.allocator;
    inline for (corpus.programs) |p| {
        driver.runProgram(
            gpa,
            runner_mod.Runner,
            p.name,
            p.source,
            p.config,
            p.initial,
            p.expected,
        ) catch |err| {
            std.debug.print("codegen program '{s}' failed: {s}\n", .{ p.name, @errorName(err) });
            return err;
        };
    }
}
