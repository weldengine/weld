//! M1.0.7 / E6 — the E1793 unblock (the milestone's headline deliverable).
//!
//! A `.prefab.etch` cannot declare its own components (typed-extension cardinality
//! = exactly one `prefab`); it must `import` them. Before cross-file import, a
//! valid prefab's component references wrongly tripped `E1793
//! PrefabComponentTypeUnknown`. With E6's cross-arena component resolution, a
//! prefab that imports its component types validates clean, and E1793 fires only
//! for a genuinely-undeclared component.

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

test "prefab importing its components validates clean" {
    const gpa = std.testing.allocator;
    // `Transform` + `Health` are declared in `components.etch`; the prefab imports
    // them and instantiates them with valid fields → no E1793 (type), no E1794
    // (field), no E1795 (field type). This is the cross-arena resolution path.
    const files = [_]etch.ProjectFile{
        .{ .name = "components.etch", .source =
        \\component Transform { x: float = 0.0 }
        \\component Health { current: float = 100.0 }
        },
        .{ .name = "goblin.prefab.etch", .source =
        \\import components { Transform, Health }
        \\prefab "Goblin" {
        \\  entity "root" {
        \\    Transform { x: 1.0 }
        \\    Health { current: 50.0 }
        \\  }
        \\}
        },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .prefab_component_type_unknown));
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .prefab_component_field_unknown));
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .prefab_component_field_type_invalid));
}

test "prefab with an undeclared component still errors" {
    const gpa = std.testing.allocator;
    // `Transform` is imported (resolves); `Ghost` is declared nowhere → exactly
    // one E1793. Confirms the unblock did not blind the check.
    const files = [_]etch.ProjectFile{
        .{ .name = "components.etch", .source = "component Transform { x: float = 0.0 }" },
        .{ .name = "goblin.prefab.etch", .source =
        \\import components { Transform }
        \\prefab "Goblin" {
        \\  entity "root" {
        \\    Transform { x: 1.0 }
        \\    Ghost {}
        \\  }
        \\}
        },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 1), countCode(diags.items, .prefab_component_type_unknown));
}
