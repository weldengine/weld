//! Cross-file scene/prefab validation: the intra-file resolution of E1782 /
//! E1786 / E1791 runs against per-file sets, and this exercises
//! `etch.validateProject` over a minimal multi-file project graph:
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

/// `diags` holds `n` diagnostics, every one `code`.
fn expectOnly(diags: []const etch.Diagnostic, code: DiagnosticCode, n: usize) !void {
    try std.testing.expectEqual(n, diags.len);
    try std.testing.expectEqual(n, countCode(diags, code));
}

test "E1786 cross-file prefab ref" {
    const gpa = std.testing.allocator;
    const files = [_]etch.ProjectFile{
        .{ .name = "markers.etch", .source = "component Marker { id: int = 0 }" },
        .{ .name = "wall_torch.prefab.etch", .source =
        \\import markers { Marker }
        \\prefab "WallTorch" {
        \\  entity "torch" { Marker { id: 1 } }
        \\}
        },
        .{ .name = "level.scene.etch", .source =
        \\import markers { Marker }
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
    try expectOnly(diags.items, .prefab_ref_not_found, 1);
}

test "E1791 cross-file prefab base" {
    const gpa = std.testing.allocator;
    const files = [_]etch.ProjectFile{
        .{ .name = "markers.etch", .source = "component Marker { id: int = 0 }" },
        .{ .name = "base.prefab.etch", .source =
        \\import markers { Marker }
        \\prefab "Base" {
        \\  entity "e" { Marker { id: 0 } }
        \\}
        },
        .{ .name = "derived.prefab.etch", .source =
        \\import markers { Marker }
        \\prefab "Derived" of "Base" {
        \\  entity "e" { Marker { id: 1 } }
        \\}
        },
        .{ .name = "orphan.prefab.etch", .source =
        \\import markers { Marker }
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
    try expectOnly(diags.items, .prefab_base_not_found, 1);
}

test "E1782 cross-scene duplicate uuid" {
    const gpa = std.testing.allocator;
    const files = [_]etch.ProjectFile{
        .{ .name = "markers.etch", .source = "component Marker { id: int = 0 }" },
        .{ .name = "scene_a.scene.etch", .source =
        \\import markers { Marker }
        \\scene "SceneA" {
        \\  entity "e1" {
        \\    uuid: "11111111-1111-1111-1111-111111111111"
        \\    Marker { id: 1 }
        \\  }
        \\}
        },
        .{ .name = "scene_b.scene.etch", .source =
        \\import markers { Marker }
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
    try expectOnly(diags.items, .duplicate_uuid, 1);
}

test "cross-file project green path resolves clean" {
    const gpa = std.testing.allocator;
    const files = [_]etch.ProjectFile{
        .{ .name = "markers.etch", .source = "component Marker { id: int = 0 }" },
        .{ .name = "wall_torch.prefab.etch", .source =
        \\import markers { Marker }
        \\prefab "WallTorch" {
        \\  entity "torch" { Marker { id: 1 } }
        \\}
        },
        .{ .name = "level.scene.etch", .source =
        \\import markers { Marker }
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

/// The E0858 count of `files`, which carry no other diagnostic.
fn e0858Count(files: []const etch.ProjectFile) !usize {
    const gpa = std.testing.allocator;
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try validate(gpa, files, &diags);
    const n = countCode(diags.items, .typed_extension_mismatch);
    try std.testing.expectEqual(n, diags.items.len);
    return n;
}

test "E0858 on a type declared in a scene file" {
    try std.testing.expectEqual(@as(usize, 1), try e0858Count(&.{
        .{ .name = "src/level.scene.etch", .source =
        \\component Marker { id: int = 0 }
        \\scene "Level" { entity "e" { Marker { id: 1 } } }
        },
    }));
}

test "E0858 on a scene in a plain source file" {
    try std.testing.expectEqual(@as(usize, 1), try e0858Count(&.{
        .{ .name = "src/combat.etch", .source =
        \\component Marker { id: int = 0 }
        \\scene "Level" { entity "e" { Marker { id: 1 } } }
        },
    }));
}

test "E0858 on two prefabs in one prefab file" {
    try std.testing.expectEqual(@as(usize, 1), try e0858Count(&.{
        .{ .name = "src/marker.etch", .source = "component Marker { id: int = 0 }" },
        .{ .name = "src/two.prefab.etch", .source =
        \\import marker { Marker }
        \\prefab "A" { entity "e" { Marker { id: 1 } } }
        \\prefab "B" { entity "e" { Marker { id: 2 } } }
        },
    }));
}

test "E0858 on a scene file holding no scene" {
    try std.testing.expectEqual(@as(usize, 1), try e0858Count(&.{
        .{ .name = "src/marker.etch", .source = "component Marker { id: int = 0 }" },
        .{ .name = "src/empty.scene.etch", .source = "import marker { Marker }" },
    }));
}

test "no E0858 on a scene file holding one scene and its imports" {
    try std.testing.expectEqual(@as(usize, 0), try e0858Count(&.{
        .{ .name = "src/marker.etch", .source = "component Marker { id: int = 0 }" },
        .{ .name = "src/level.scene.etch", .source =
        \\import marker { Marker }
        \\scene "Level" { entity "e" { Marker { id: 1 } } }
        },
    }));
}

/// Check `files`, requiring exactly one diagnostic: E0840.
fn expectOnlyE0840(files: []const etch.ProjectFile) !void {
    const gpa = std.testing.allocator;
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try validate(gpa, files, &diags);
    try expectOnly(diags.items, .construct_not_implemented, 1);
}

test "E0840 on a layer file holding its layer" {
    try expectOnlyE0840(&.{.{ .name = "src/gameplay.layer.etch", .source = "layer \"Gameplay\" { }" }});
}

test "E0840 on a manifest file holding its world" {
    try expectOnlyE0840(&.{.{ .name = "src/village.manifest.etch", .source = "world \"Village\" { }" }});
}

test "E0840 on a layer file holding a component" {
    try expectOnlyE0840(&.{.{ .name = "src/gameplay.layer.etch", .source = "component Marker { id: int = 0 }" }});
}

test "E0840 on an empty manifest file" {
    try expectOnlyE0840(&.{.{ .name = "src/village.manifest.etch", .source = "" }});
}
