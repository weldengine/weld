//! Differential corpus driver — runs every program of `corpus_facade` through
//! the tree-walking interpreter's `Runner` and compares the final world state
//! against each sidecar's `expected`.

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

test "the interpreter runner fails on a runtime error, its expected state reached or not" {
    const gpa = std.testing.allocator;
    const source =
        \\component Box { n: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has Box
        \\{
        \\  let acc = entity.get_mut(Box)
        \\  acc.n = 1
        \\  let mut xs: int[] = [1]
        \\  xs[3] = 0
        \\}
    ;
    const spec: driver.WorldSpec = .{ .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{.{ .name = "Box" }} },
    } };
    const expected: driver.ExpectedWorld = .{ .entities = &[_]driver.EntitySpec{
        .{ .components = &[_]driver.ComponentSpec{
            .{ .name = "Box", .fields = &[_]driver.FieldSpec{.{ .name = "n", .value = .{ .int_ = 1 } }} },
        } },
    } };
    try std.testing.expectError(error.InterpreterRuntimeError, driver.runProgram(gpa, runner_mod.Runner, "runtime_error", source, .{ .ticks = 1 }, spec, expected));
}
