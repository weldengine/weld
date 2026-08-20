//! `CodegenError` path tests (S5).

const std = @import("std");
const ast_mod = @import("../../ast.zig");
const root = @import("../root.zig");
// `SourceSpan` is private in `ast.zig` and `pub` in `token.zig`, which declares
// it. The test reaches its owner rather than widening a production surface.
const token_mod = @import("../../token.zig");

test "UnsupportedConstruct surfaced for out-of-subset input" {
    // Build an AST with a let whose value is a `path` ExprKind (out of the
    // S3 subset accepted by the codegen) and feed it through the lowering
    // pipeline. The S3 parser cannot produce this on real source — the
    // test bypasses the parser specifically to exercise the codegen's
    // defensive error path.
    const gpa = std.testing.allocator;
    var arena = try ast_mod.AstArena.init(gpa);
    defer arena.deinit(gpa);

    const span: token_mod.SourceSpan = .{ .byte_start = 0, .byte_end = 0 };
    const rule_name = try arena.strings.intern(gpa, "bad");
    const path_expr = try arena.addExpr(gpa, .path, 0, span);
    const let_id = try arena.addLetStmt(gpa, .{
        .name = try arena.strings.intern(gpa, "x"),
        .is_mut = false,
        .type_annotation = ast_mod.NodeId.none,
        .value = path_expr,
    }, span);

    const body_start: u32 = @intCast(arena.extra.items.len);
    try arena.extra.append(gpa, let_id.raw());

    const rule_idx: u32 = @intCast(arena.rule_decls.items.len);
    try arena.rule_decls.append(gpa, .{
        .name = rule_name,
        .params_start = 0,
        .params_len = 0,
        .when_root = ast_mod.RuleDecl.none_when,
        .body_start = body_start,
        .body_len = 1,
        .annotations_extra = 0,
        .annotations_len = 0,
    });
    _ = try arena.addItem(gpa, .rule_decl, rule_idx, span);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    try std.testing.expectError(root.errors.CodegenError.UnsupportedConstruct, root.generateToBuffer(gpa, &arena, "<unit>", &out));
}

test "NonPodComponent surfaced before codegen entry" {
    // A component whose field references a type the S5 type-map does not
    // know would normally be rejected by the S3 type-checker. The codegen
    // includes a defensive path so a malformed AST surfaces a typed error
    // rather than panicking.
    const gpa = std.testing.allocator;
    var arena = try ast_mod.AstArena.init(gpa);
    defer arena.deinit(gpa);

    const span: token_mod.SourceSpan = .{ .byte_start = 0, .byte_end = 0 };
    const comp_name = try arena.strings.intern(gpa, "Bad");
    const field_name = try arena.strings.intern(gpa, "x");
    const type_name = try arena.strings.intern(gpa, "NotABuiltin");
    const type_node = try arena.addNamedType(gpa, type_name, span);

    const fields_start: u32 = @intCast(arena.fields.items.len);
    try arena.fields.append(gpa, .{
        .name = field_name,
        .type_node = type_node,
        .default_value = ast_mod.NodeId.none,
        .annotations_extra = 0,
        .annotations_len = 0,
    });

    const comp_idx: u32 = @intCast(arena.component_decls.items.len);
    try arena.component_decls.append(gpa, .{
        .name = comp_name,
        .fields_start = fields_start,
        .fields_len = 1,
        .annotations_extra = 0,
        .annotations_len = 0,
    });
    _ = try arena.addItem(gpa, .component_decl, comp_idx, span);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    try std.testing.expectError(root.errors.CodegenError.NonPodComponent, root.generateToBuffer(gpa, &arena, "<unit>", &out));
}
