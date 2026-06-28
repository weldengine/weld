//! M1.0.7 — cross-file `import` resolution under `validateProject`.
//!
//! E4 scope (this file, initial): the module dependency graph + topological
//! order + cycle detection (`E0108 ImportCycle`). E5/E6 extend it with the
//! selective-import resolution tests (cross-file type/const, `E0104`).
//!
//! D-B reminder: the cycle code is `E0108`, NOT `E0101` (which is
//! `DuplicateSymbol`, shipped since M0.x).

const std = @import("std");
const etch = @import("weld_etch");
const DiagnosticCode = etch.diagnostics.DiagnosticCode;

fn countCode(diags: []const etch.Diagnostic, code: DiagnosticCode) usize {
    var n: usize = 0;
    for (diags) |d| {
        if (d.code == code) n += 1;
    }
    return n;
}

fn deinitDiags(gpa: std.mem.Allocator, diags: *std.ArrayListUnmanaged(etch.Diagnostic)) void {
    for (diags.items) |*d| d.deinit(gpa);
    diags.deinit(gpa);
}

test "import cycle errors" {
    const gpa = std.testing.allocator;
    // module `a` imports `b`, module `b` imports `a` → a 2-cycle closes on the
    // back-edge → exactly one E0108.
    const files = [_]etch.ProjectFile{
        .{ .name = "a.etch", .source = "import b" },
        .{ .name = "b.etch", .source = "import a" },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 1), countCode(diags.items, .import_cycle));
}

test "linear import is not a cycle" {
    const gpa = std.testing.allocator;
    // `a` imports `b`, `b` imports nothing → acyclic, no E0108 (guards the DFS
    // against over-reporting a forward edge as a back-edge).
    const files = [_]etch.ProjectFile{
        .{ .name = "a.etch", .source = "import b" },
        .{ .name = "b.etch", .source = "component Marker { id: int = 0 }" },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .import_cycle));
}
