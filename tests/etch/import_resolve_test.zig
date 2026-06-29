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

test "selective import resolves a cross-file type" {
    const gpa = std.testing.allocator;
    // `main` imports the component `Health` from `lib` and uses it in a type
    // position (`type HA = Health`). The imported `TYPE_IDENT` must resolve —
    // no E0102 UndefinedSymbol (E6 applies the imported set to type resolution).
    const files = [_]etch.ProjectFile{
        .{ .name = "lib.etch", .source = "component Health { current: float = 100.0 }" },
        .{ .name = "main.etch", .source =
        \\import lib { Health }
        \\type HA = Health
        },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .undefined_symbol));
}

test "unknown export errors (E0104)" {
    const gpa = std.testing.allocator;
    // `lib` exports `Health`; `main` selectively imports `Nope`, which `lib` does
    // not export → exactly one E0104 (and Health is unaffected).
    const files = [_]etch.ProjectFile{
        .{ .name = "lib.etch", .source = "component Health { current: float = 100.0 }" },
        .{ .name = "main.etch", .source = "import lib { Nope }" },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 1), countCode(diags.items, .unknown_export));
}

test "valid selective import emits no import diagnostic (E5 binding)" {
    const gpa = std.testing.allocator;
    // `main` imports an item `lib` actually exports → the binding succeeds with no
    // E0103/E0104 (TYPE_IDENT application + the prefab unblock are E6).
    const files = [_]etch.ProjectFile{
        .{ .name = "lib.etch", .source = "component Health { current: float = 100.0 }" },
        .{ .name = "main.etch", .source = "import lib { Health }" },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .unknown_export));
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .not_a_module));
}

test "import of a missing module errors (E0103)" {
    const gpa = std.testing.allocator;
    // `main` imports `ghost`, which names no file in the set → exactly one E0103.
    const files = [_]etch.ProjectFile{
        .{ .name = "main.etch", .source = "import ghost" },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 1), countCode(diags.items, .not_a_module));
}
