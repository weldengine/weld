//! M0.9 E2-B — cross-file scene/prefab validation. M0.8 delivered the
//! intra-file resolution (E1782/E1786/E1791 against per-file sets); this
//! exercises `etch.validateProject` over a minimal multi-file project graph:
//!   - E1786 PrefabRefNotFound — `instance of "X"` with X declared in NO file
//!     (a prefab declared in ANOTHER file must resolve, i.e. not error).
//!   - E1791 PrefabBaseNotFound — `prefab "Y" of "Z"` with Z in no file (a base
//!     declared in another file must resolve).
//!   - E1782 DuplicateUUID (cross-scene) — the same UUID in two scenes across
//!     files.
//! Plus a green-path multi-file project that resolves with zero diagnostics.

const std = @import("std");
const etch = @import("weld_etch");
const DiagnosticCode = etch.diagnostics.DiagnosticCode;

/// Run `validateProject` over `files`; the caller-owned list is filled and
/// the helper hands ownership back (each diagnostic owns its message).
fn validate(gpa: std.mem.Allocator, files: []const etch.ProjectFile, diags: *std.ArrayListUnmanaged(etch.Diagnostic)) !void {
    try etch.validateProject(gpa, files, diags);
}

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

test "E1786 cross-file prefab ref" {
    const gpa = std.testing.allocator;
    const files = [_]etch.ProjectFile{
        .{ .name = "prefabs.etch", .source =
        \\component Marker { id: int = 0 }
        \\prefab "WallTorch" {
        \\  entity "torch" { Marker { id: 1 } }
        \\}
        },
        .{ .name = "level.etch", .source =
        \\component Marker { id: int = 0 }
        \\scene "Level" {
        \\  instance of "WallTorch" "t1" { Marker { id: 2 } }
        \\  instance of "Ghost" "t2" { Marker { id: 3 } }
        \\}
        },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try validate(gpa, &files, &diags);
    // `WallTorch` resolves across files (no error); `Ghost` exists nowhere →
    // exactly one cross-file E1786.
    try std.testing.expectEqual(@as(usize, 1), countCode(diags.items, .prefab_ref_not_found));
}

test "E1791 cross-file prefab base" {
    const gpa = std.testing.allocator;
    const files = [_]etch.ProjectFile{
        .{ .name = "base.etch", .source =
        \\component Marker { id: int = 0 }
        \\prefab "Base" {
        \\  entity "e" { Marker { id: 0 } }
        \\}
        },
        .{ .name = "derived.etch", .source =
        \\component Marker { id: int = 0 }
        \\prefab "Derived" of "Base" {
        \\  entity "e" { Marker { id: 1 } }
        \\}
        \\prefab "Orphan" of "MissingBase" {
        \\  entity "e" { Marker { id: 2 } }
        \\}
        },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try validate(gpa, &files, &diags);
    // `Derived of Base` resolves across files; `Orphan of MissingBase` does not
    // → exactly one cross-file E1791.
    try std.testing.expectEqual(@as(usize, 1), countCode(diags.items, .prefab_base_not_found));
}

test "E1782 cross-scene duplicate uuid" {
    const gpa = std.testing.allocator;
    const files = [_]etch.ProjectFile{
        .{ .name = "scene_a.etch", .source =
        \\component Marker { id: int = 0 }
        \\scene "SceneA" {
        \\  entity "e1" {
        \\    uuid: "11111111-1111-1111-1111-111111111111"
        \\    Marker { id: 1 }
        \\  }
        \\}
        },
        .{ .name = "scene_b.etch", .source =
        \\component Marker { id: int = 0 }
        \\scene "SceneB" {
        \\  entity "e2" {
        \\    uuid: "11111111-1111-1111-1111-111111111111"
        \\    Marker { id: 2 }
        \\  }
        \\}
        },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try validate(gpa, &files, &diags);
    // Same UUID in two scenes across files → exactly one cross-scene E1782.
    try std.testing.expectEqual(@as(usize, 1), countCode(diags.items, .duplicate_uuid));
}

test "cross-file project green path resolves clean" {
    const gpa = std.testing.allocator;
    const files = [_]etch.ProjectFile{
        .{ .name = "prefabs.etch", .source =
        \\component Marker { id: int = 0 }
        \\prefab "WallTorch" {
        \\  entity "torch" { Marker { id: 1 } }
        \\}
        },
        .{ .name = "level.etch", .source =
        \\component Marker { id: int = 0 }
        \\scene "Level" {
        \\  entity "light" {
        \\    uuid: "aaaaaaaa-0000-0000-0000-000000000001"
        \\    Marker { id: 9 }
        \\  }
        \\  instance of "WallTorch" "t1" {
        \\    uuid: "aaaaaaaa-0000-0000-0000-000000000002"
        \\    Marker { id: 2 }
        \\  }
        \\}
        },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try validate(gpa, &files, &diags);
    // Prefab resolves cross-file, UUIDs unique, entities have components → no
    // diagnostic of any severity.
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
}
