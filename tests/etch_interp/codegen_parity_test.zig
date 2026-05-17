//! S5 parity check: both runners against every corpus program must reach
//! the same expected post-tick state. The driver already asserts the
//! final world matches each sidecar's `expected`; running both backends
//! against that same expected establishes the parity transitively (if
//! both agree with `expected`, they agree with each other).

const std = @import("std");
const corpus = @import("corpus_facade");
const driver = @import("diff_runner");
const interp_runner = @import("runner_interp");
const codegen_runner = @import("runner_codegen");

test "codegen result matches interpreter result on all 20 corpus programs" {
    const gpa = std.testing.allocator;
    inline for (corpus.programs) |p| {
        driver.runProgram(gpa, interp_runner.Runner, p.name, p.source, p.config, p.initial, p.expected) catch |err| {
            std.debug.print("interp '{s}' failed: {s}\n", .{ p.name, @errorName(err) });
            return err;
        };
        driver.runProgram(gpa, codegen_runner.Runner, p.name, p.source, p.config, p.initial, p.expected) catch |err| {
            std.debug.print("codegen '{s}' failed: {s}\n", .{ p.name, @errorName(err) });
            return err;
        };
    }
}
