//! Differential corpus driver — runs every program in `corpus_facade` via
//! the S4 tree-walking interpreter `Runner` and compares the final world
//! state against each sidecar's `expected`.

const std = @import("std");
const corpus = @import("corpus_facade");
const driver = @import("diff_runner");
const runner_mod = @import("runner_interp");

test "differential corpus — every program reaches its expected final state" {
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
            std.debug.print("corpus program '{s}' failed: {s}\n", .{ p.name, @errorName(err) });
            return err;
        };
    }
}
