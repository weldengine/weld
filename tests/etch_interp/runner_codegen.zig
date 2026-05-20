//! S5 differential-test runner backed by the Zig codegen output.
//!
//! Setup looks up the program by name in the pre-cooked `corpus_codegen`
//! module (an `@import` of the consolidated `.zig` file produced by
//! `tools/etch_cook` at build time). On success the runner holds a
//! `Program` struct whose `register` and `tick` function pointers drive
//! the world.
//!
//! Implements the same `Runner` contract as `runner_interp.zig`:
//!   pub fn setup(gpa, world, name, source) !Runner
//!   pub fn step(self, world) !void
//!   pub fn finalize(self, gpa, world) void

const std = @import("std");
const weld_core = @import("weld_core");
const corpus_codegen = @import("corpus_codegen");

const World = weld_core.ecs.world.World;

/// S5 codegen-backed runner — drives `diff_runner.runProgram` by
/// dispatching into the consolidated `corpus_codegen` namespace
/// produced at build time by `tools/etch_cook`.
pub const Runner = struct {
    program: corpus_codegen.Program,

    pub fn setup(gpa: std.mem.Allocator, world: *World, name: []const u8, source: []const u8) !Runner {
        _ = source; // codegen runner ignores the source — it is statically compiled.
        // Zig identifiers cannot start with a digit, so the cooked
        // namespaces are prefixed with `p` (e.g. `01_arith_int_let` →
        // `p01_arith_int_let`). The transformation is hidden here so the
        // sidecar `name` field can keep its natural NN_<desc> shape.
        var name_buf: [128]u8 = undefined;
        if (name.len + 1 > name_buf.len) return error.NameTooLong;
        name_buf[0] = 'p';
        @memcpy(name_buf[1 .. 1 + name.len], name);
        const prefixed = name_buf[0 .. 1 + name.len];
        const program = corpus_codegen.lookupByName(prefixed) orelse {
            std.debug.print("runner_codegen: program '{s}' not in consolidated corpus\n", .{prefixed});
            return error.UnknownProgram;
        };
        try program.register(world, gpa);
        return .{ .program = program };
    }

    pub fn step(self: *Runner, world: *World) !void {
        self.program.tick(world);
    }

    pub fn finalize(self: *Runner, gpa: std.mem.Allocator, world: *World) void {
        _ = self;
        _ = gpa;
        _ = world;
    }
};
