//! M1.0.7 / E3 — `import` directive parsing. `import` graduated from
//! `non_s3_keywords` to `kw_import` (E1) with an `ImportDecl` AST node (E2);
//! this exercises `parseImportDecl` over the four grammar forms (§5.2):
//!   import a.b              (whole module)
//!   import a.b { X, Y }     (selective)
//!   import a.b as m         (whole module, aliased)
//!   import a.b { X as Y }   (selective, per-item alias)
//! plus D-D (items accept IDENT and TYPE_IDENT) and recovery (a malformed
//! import resyncs at the next top-level keyword — no UnsupportedConstructInS3).

const std = @import("std");
const etch = @import("weld_etch");

/// `module_path` segment `i` of `decl` as a string slice.
fn seg(result: anytype, decl: anytype, i: usize) []const u8 {
    return result.ast.strings.slice(result.ast.import_path_segs.items[decl.path_start + i]);
}

test "all four import forms parse" {
    const gpa = std.testing.allocator;

    // Form 1: whole module, no alias, no items.
    {
        var result = try etch.parseSource(gpa, "import a.b");
        defer result.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
        try std.testing.expectEqual(@as(usize, 1), result.ast.import_decls.items.len);
        const d = result.ast.import_decls.items[0];
        try std.testing.expectEqual(@as(u32, 2), d.path_len);
        try std.testing.expectEqualStrings("a", seg(result, d, 0));
        try std.testing.expectEqualStrings("b", seg(result, d, 1));
        try std.testing.expectEqual(@as(etch.StringId, 0), d.module_alias);
        try std.testing.expectEqual(@as(u32, 0), d.items_len);
    }

    // Form 2: selective import of two items.
    {
        var result = try etch.parseSource(gpa, "import a.b { X, Y }");
        defer result.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
        const d = result.ast.import_decls.items[0];
        try std.testing.expectEqual(@as(u32, 2), d.path_len);
        try std.testing.expectEqual(@as(etch.StringId, 0), d.module_alias);
        try std.testing.expectEqual(@as(u32, 2), d.items_len);
        const x = result.ast.import_items.items[d.items_start];
        const y = result.ast.import_items.items[d.items_start + 1];
        try std.testing.expectEqualStrings("X", result.ast.strings.slice(x.name));
        try std.testing.expectEqual(@as(etch.StringId, 0), x.alias);
        try std.testing.expectEqualStrings("Y", result.ast.strings.slice(y.name));
        try std.testing.expectEqual(@as(etch.StringId, 0), y.alias);
    }

    // Form 3: whole module with explicit alias.
    {
        var result = try etch.parseSource(gpa, "import a.b as m");
        defer result.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
        const d = result.ast.import_decls.items[0];
        try std.testing.expectEqual(@as(u32, 2), d.path_len);
        try std.testing.expect(d.module_alias != 0);
        try std.testing.expectEqualStrings("m", result.ast.strings.slice(d.module_alias));
        try std.testing.expectEqual(@as(u32, 0), d.items_len);
    }

    // Form 4: selective import with a per-item alias.
    {
        var result = try etch.parseSource(gpa, "import a.b { X as Y }");
        defer result.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
        const d = result.ast.import_decls.items[0];
        try std.testing.expectEqual(@as(etch.StringId, 0), d.module_alias);
        try std.testing.expectEqual(@as(u32, 1), d.items_len);
        const item = result.ast.import_items.items[d.items_start];
        try std.testing.expectEqualStrings("X", result.ast.strings.slice(item.name));
        try std.testing.expect(item.alias != 0);
        try std.testing.expectEqualStrings("Y", result.ast.strings.slice(item.alias));
    }
}

test "import accepts TYPE_IDENT and IDENT items" {
    const gpa = std.testing.allocator;
    // `Health` is a TYPE_IDENT, `gravity` is an IDENT — both legal items (D-D).
    var result = try etch.parseSource(gpa, "import a.b { Health, gravity }");
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    const d = result.ast.import_decls.items[0];
    try std.testing.expectEqual(@as(u32, 2), d.items_len);
    const health = result.ast.import_items.items[d.items_start];
    const gravity = result.ast.import_items.items[d.items_start + 1];
    try std.testing.expectEqualStrings("Health", result.ast.strings.slice(health.name));
    try std.testing.expectEqualStrings("gravity", result.ast.strings.slice(gravity.name));
}

test "malformed import recovers" {
    const gpa = std.testing.allocator;
    // `import 123` is malformed (a module path segment must be an identifier).
    // The parser must record a diagnostic, resync at the next top-level keyword,
    // and still parse the following `component` — and the diagnostic must NOT be
    // the legacy `UnsupportedConstructInS3` (import is no longer a reserved word).
    var result = try etch.parseSource(gpa,
        \\import 123
        \\component Alpha { a: int = 1 }
    );
    defer result.deinit(gpa);

    try std.testing.expect(result.diagnostics.len >= 1);
    for (result.diagnostics) |dgn| {
        try std.testing.expect(std.mem.indexOf(u8, dgn.primary_message, "UnsupportedConstructInS3") == null);
    }

    // The malformed import produced no ImportDecl; `Alpha` still landed.
    try std.testing.expectEqual(@as(usize, 0), result.ast.import_decls.items.len);
    var saw_alpha = false;
    for (result.ast.component_decls.items) |cd| {
        if (std.mem.eql(u8, result.ast.strings.slice(cd.name), "Alpha")) saw_alpha = true;
    }
    try std.testing.expect(saw_alpha);
}
