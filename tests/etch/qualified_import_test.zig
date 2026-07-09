//! M1.0.16 — qualified `m.Type` resolution under `validateProject`.
//!
//! Gate E1: a whole-module import alias (`import lib as m`, or the implicit
//! last-segment alias of a bare `import lib`) makes `m.Type` resolve as a
//! type-name at exact parity with the selective import form — proven at the
//! type-alias target position (`type HA = m.Health`, the M1.0.7 surface). The
//! whole-module import names no members, so `E0104` (absent) / `E0107`
//! (private) fire at the qualified USE site, not at the `import` binding.
//!
//! Gate E2 (visibility inheritance §10.2 + `W0902 PrivateTypeInPublicImpl`):
//! a private type's inherent impl is not surfaced as public (structurally — an
//! impl is never exported and a private type is unnameable cross-module), and a
//! PUBLIC trait implemented for a PRIVATE target type warns `W0902`.

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

test "qualified type via aliased module resolves in a type-alias target" {
    const gpa = std.testing.allocator;
    // `import lib as m` + `type HA = m.Health` — the qualified twin of the
    // M1.0.7 `type HA = Health` selective test. The alias resolves, `Health`
    // is a public component export → zero resolution diagnostics.
    const files = [_]etch.ProjectFile{
        .{ .name = "lib.etch", .source = "component Health { current: float = 100.0 }" },
        .{ .name = "main.etch", .source =
        \\import lib as m
        \\type HA = m.Health
        },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .undefined_symbol));
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .unknown_export));
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .import_private_item));
}

test "bare whole-module import qualified access resolves" {
    const gpa = std.testing.allocator;
    // A bare `import lib` binds the implicit last-segment alias `lib`; `lib.Health`
    // then resolves through it → zero diagnostics.
    const files = [_]etch.ProjectFile{
        .{ .name = "lib.etch", .source = "component Health { current: float = 100.0 }" },
        .{ .name = "main.etch", .source =
        \\import lib
        \\type HA = lib.Health
        },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .undefined_symbol));
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .unknown_export));
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .import_private_item));
}

test "qualified unknown member is E0104 at the use site" {
    const gpa = std.testing.allocator;
    // `lib` exports no `Nope`; the qualified use `m.Nope` is the site the whole
    // module can be diagnosed at (it names no members at the import) → E0104.
    const files = [_]etch.ProjectFile{
        .{ .name = "lib.etch", .source = "component Health { current: float = 100.0 }" },
        .{ .name = "main.etch", .source =
        \\import lib as m
        \\type X = m.Nope
        },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 1), countCode(diags.items, .unknown_export));
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .import_private_item));
}

test "qualified private member is E0107 at the use site" {
    const gpa = std.testing.allocator;
    // `Secret` is present but `private`; the qualified use is E0107 (the
    // whole-module import could not have diagnosed it — it names no members).
    const files = [_]etch.ProjectFile{
        .{ .name = "lib.etch", .source = "private component Secret { hash: u32 = 0 }" },
        .{ .name = "main.etch", .source =
        \\import lib as m
        \\type X = m.Secret
        },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 1), countCode(diags.items, .import_private_item));
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .unknown_export));
}

test "unresolved alias receiver is E0102" {
    const gpa = std.testing.allocator;
    // `n` is neither a whole-module alias nor a local → the qualified receiver
    // does not resolve → exactly one E0102 (no E0104/E0107 — there is no target
    // module to look a member up in).
    const files = [_]etch.ProjectFile{
        .{ .name = "lib.etch", .source = "component Health { current: float = 100.0 }" },
        .{ .name = "main.etch", .source =
        \\import lib as m
        \\type X = n.Health
        },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 1), countCode(diags.items, .undefined_symbol));
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .unknown_export));
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .import_private_item));
}

test "non-alias receiver is unaffected (selective + local resolution, no regression)" {
    const gpa = std.testing.allocator;
    // The alias machinery must not disturb the paths that already work: a
    // selective import resolved as a bare type-name (`type HA = Health`, M1.0.7)
    // and a local alias to a builtin (`type Score = int`) both stay clean. This
    // guards the disambiguation order — a non-`.path` type node never enters the
    // qualified branch.
    const files = [_]etch.ProjectFile{
        .{ .name = "lib.etch", .source = "component Health { current: float = 100.0 }" },
        .{ .name = "main.etch", .source =
        \\import lib { Health }
        \\type HA = Health
        \\type Score = int
        },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .undefined_symbol));
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .unknown_export));
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .import_private_item));
}

test "private type inherent impl is not leaked (E2, §10.2 inheritance)" {
    const gpa = std.testing.allocator;
    // `lib` declares a private component `X` and an inherent impl on it — the
    // impl is not a public surface (impls are never exported; the private type
    // is unnameable cross-module), so `lib` validates with no false E0107 and no
    // W0902 (inherent, not a trait impl). `main` naming `m.X` (private) is E0107
    // at the use site — inheritance holds: the private type stays unnameable.
    const files = [_]etch.ProjectFile{
        .{ .name = "lib.etch", .source =
        \\private component X { hash: u32 = 0 }
        \\impl X { fn f(self) { } }
        },
        .{ .name = "main.etch", .source =
        \\import lib as m
        \\type A = m.X
        },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 1), countCode(diags.items, .import_private_item));
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .private_type_in_public_impl));
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .undefined_symbol));
}

test "public trait impl for private type is W0902 (E2)" {
    const gpa = std.testing.allocator;
    // A public trait `T` implemented for a PRIVATE component `X` exposes the
    // private type through a public interface → exactly one W0902 (warning, not
    // error — legitimate for internal use). No import, so no E0107.
    const files = [_]etch.ProjectFile{
        .{ .name = "main.etch", .source =
        \\private component X { hash: u32 = 0 }
        \\trait T { fn f(self) }
        \\impl T for X { fn f(self) { } }
        },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 1), countCode(diags.items, .private_type_in_public_impl));
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .import_private_item));
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .undefined_symbol));
}

test "public trait impl for public type is not W0902 (E2, over-report guard)" {
    const gpa = std.testing.allocator;
    // Same trait, but a PUBLIC target type → no leak, no W0902. Guards the
    // detection against firing on every public trait impl.
    const files = [_]etch.ProjectFile{
        .{ .name = "main.etch", .source =
        \\component X { hash: u32 = 0 }
        \\trait T { fn f(self) }
        \\impl T for X { fn f(self) { } }
        },
    };
    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer deinitDiags(gpa, &diags);
    try etch.validateProject(gpa, &files, &diags);
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .private_type_in_public_impl));
    try std.testing.expectEqual(@as(usize, 0), countCode(diags.items, .undefined_symbol));
}
