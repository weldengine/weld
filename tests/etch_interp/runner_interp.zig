//! S4 differential-test runner backed by the tree-walking interpreter.
//!
//! Implements the `Runner` contract consumed by `diff_runner.zig`:
//!   pub fn setup(gpa, world, source) !Runner
//!   pub fn step(self: *Runner, world) !void
//!   pub fn finalize(self: *Runner, gpa, world) void

const std = @import("std");
const weld_etch = @import("weld_etch");
const weld_core = @import("weld_core");

const Interpreter = weld_etch.Interpreter;
const World = weld_core.ecs.world.World;
const Diagnostic = weld_etch.Diagnostic;
const Ast = weld_etch.Ast;

pub const Runner = struct {
    /// Heap-allocated so the `*const Ast` pointer stored on the
    /// `Interpreter` remains valid after the Runner is moved/returned.
    /// The Interpreter would otherwise hold a dangling pointer to an
    /// `Ast` value that lived on `setup`'s stack frame.
    ast: *Ast,
    interp: Interpreter,
    report: weld_etch.RuntimeReport,

    pub fn setup(gpa: std.mem.Allocator, world: *World, name: []const u8, source: []const u8) !Runner {
        _ = name; // interpreter does not need program names — it compiles from source.
        var pr = try weld_etch.parser.parse(gpa, source);
        if (pr.diagnostic) |d| {
            var dd = d;
            std.debug.print("parse diagnostic: {s}\n", .{dd.primary_message});
            dd.deinit(gpa);
            pr.ast.deinit(gpa);
            return error.ParseFailed;
        }
        errdefer pr.ast.deinit(gpa);

        var diags: std.ArrayListUnmanaged(Diagnostic) = .empty;
        defer {
            for (diags.items) |*d| d.deinit(gpa);
            diags.deinit(gpa);
        }
        try weld_etch.TypeChecker.check(gpa, &pr.ast, &diags);
        if (diags.items.len > 0) {
            for (diags.items) |d| std.debug.print("type-check diagnostic {s}: {s}\n", .{ d.code.code(), d.primary_message });
            return error.TypeCheckFailed;
        }

        const ast_box = try gpa.create(Ast);
        errdefer gpa.destroy(ast_box);
        ast_box.* = pr.ast;
        // Ownership of `pr.ast`'s internals has moved to `ast_box`; do not
        // call `pr.ast.deinit` on the value-copied stack instance.

        const interp = try Interpreter.compile(gpa, ast_box, world);
        return .{ .ast = ast_box, .interp = interp, .report = .{} };
    }

    pub fn step(self: *Runner, world: *World) !void {
        try self.interp.stepOnce(world, &self.report);
        world.tickBoundary();
    }

    pub fn finalize(self: *Runner, gpa: std.mem.Allocator, world: *World) void {
        _ = world;
        self.interp.deinit();
        self.ast.deinit(gpa);
        gpa.destroy(self.ast);
    }
};
