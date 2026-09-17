//! Cross-file `import` resolution under `validateProject`: the module
//! dependency graph, its topological order and cycle detection, then the
//! selective-import resolution — cross-file type and const, and the codes that
//! refuse.
//!
//! The cycle code is `E0108` and NOT `E0101`, which is `DuplicateSymbol`.

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
    // position (`type HA = Health`). The imported `TYPE_IDENT` must resolve, so
    // no E0102 UndefinedSymbol — the imported set reaches type resolution.
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

test "valid selective import emits no import diagnostic (binding)" {
    const gpa = std.testing.allocator;
    // `main` imports an item `lib` actually exports → the binding succeeds with no
    // E0103/E0104.
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

test "selective import resolves a cross-file const" {
    const gpa = std.testing.allocator;
    // `lib` declares a top-level `const`; `main` selectively imports it. The
    // const is exported (public) and resolvable → no E0104 / E0107 / E0103.
    const files = [_]etch.ProjectFile{
        .{ .name = "lib.etch", .source = "const ROOM_CAP: int = 8" },
        .{ .name = "main.etch", .source = "import lib { ROOM_CAP }" },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .unknown_export));
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .import_private_item));
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .not_a_module));
}

test "import of a private item errors (E0107, activation)" {
    const gpa = std.testing.allocator;
    // `lib` declares a `private component`; `main` selectively imports it. The
    // item is in `lib`'s exports flagged `.private` → exactly one E0107.
    const files = [_]etch.ProjectFile{
        .{ .name = "lib.etch", .source = "private component Secret { hash: u32 = 0 }" },
        .{ .name = "main.etch", .source = "import lib { Secret }" },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 1), countCode(diags.items, .import_private_item));
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .unknown_export));
}

test "a public declaration alongside a private one stays importable" {
    const gpa = std.testing.allocator;
    // Visibility is per-declaration: `Public` imports clean, `Secret` is E0107.
    const files = [_]etch.ProjectFile{
        .{ .name = "lib.etch", .source =
        \\private component Secret { hash: u32 = 0 }
        \\component Public { value: int = 0 }
        },
        .{ .name = "main.etch", .source =
        \\import lib { Public }
        \\import lib { Secret }
        },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 1), countCode(diags.items, .import_private_item));
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .unknown_export));
}

test "a test block is not exported (E0104 on import)" {
    const gpa = std.testing.allocator;
    // `lib` declares a `test` block; it is registered intra-module but never
    // exported → selectively importing its name is E0104 UnknownExport.
    const files = [_]etch.ProjectFile{
        .{ .name = "lib.etch", .source = "test \"secret_test\" { }" },
        .{ .name = "main.etch", .source = "import lib { secret_test }" },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 1), countCode(diags.items, .unknown_export));
}
