//! AST stable interface — Level 1 guard test (M0.8 E7).
//!
//! The COMPILATION of this file is the invariant (`etch-parser.md` §10.3.1 /
//! the contract block in `src/etch/root.zig`). It exercises ≥20 distinct
//! Level-1 public entry points of the frozen AST surface, reached through the
//! `weld_etch` module boundary only — never an internal path. A Phase 1 / S0
//! change (recursive-descent → LR) that removes or renames any of these breaks
//! this file at compile time and blocks the LR transition until an explicit
//! AST-API semver bump.
//!
//! The delivered AST is a tabular SoA (not the §10.3.1 idealized tagged-union
//! prose): four per-category kind enums + a `NodeId` handle + parallel
//! kind/data/span accessors. This test pins that real surface.

const std = @import("std");
const weld_etch = @import("weld_etch");

// ── A reference program that yields ≥1 node in every category (item, stmt,
//    expr, type_node) so the index-0 accessors below are all valid at runtime.
const reference_src =
    \\component Health { current: float = 100.0 }
    \\rule heal(entity: Entity)
    \\  when entity has Health
    \\{
    \\  let step = 1.0
    \\  entity.get_mut(Health).current += step
    \\}
;

test "AST Level-1 frozen surface: ≥20 distinct public entry points compile + resolve" {
    const gpa = std.testing.allocator;

    // ── Entry points 1-8: the eight frozen discrimination enums. Referencing a
    //    variant pins both the enum's existence AND that the named variant
    //    survives. (Compilation is the invariant.)
    const ek_1: weld_etch.ItemKind = .rule_decl; // (1)
    const ek_2: weld_etch.StmtKind = .let_stmt; // (2)
    const ek_3: weld_etch.ExprKind = .int_lit; // (3)
    const ek_4: weld_etch.TypeNodeKind = .named; // (4)
    const ek_5: weld_etch.BinaryOp = .add; // (5)
    const ek_6: weld_etch.UnaryOp = .neg; // (6)
    const ek_7: weld_etch.AssignOp = .add_assign; // (7)
    const ek_8: weld_etch.NodeCategory = .expr; // (8)
    std.mem.doNotOptimizeAway(.{ ek_1, ek_2, ek_3, ek_4, ek_5, ek_6, ek_7, ek_8 });

    // ── Entry point 9: NodeId handle — packed u32, plus none/isNone/raw.
    try std.testing.expect(weld_etch.NodeId.none.isNone()); // (9: NodeId.none + .isNone)
    const built_id: weld_etch.NodeId = .{ .category = .expr, .index = 0 };
    try std.testing.expect(!built_id.isNone());
    try std.testing.expectEqual(@as(u32, 4), @sizeOf(weld_etch.NodeId)); // packed struct(u32)
    _ = built_id.raw(); // (10: NodeId.raw)

    // ── Entry point 11: StringId is the opaque intern handle (= u32).
    const sid_zero: weld_etch.StringId = 0; // (11)
    std.mem.doNotOptimizeAway(sid_zero);

    // ── Entry point 12: SourceSpan value type + its frozen fields.
    const span: weld_etch.SourceSpan = .{ .byte_start = 0, .byte_end = 4 };
    try std.testing.expectEqual(@as(u32, 0), span.byte_start); // (12: SourceSpan.byte_start)
    try std.testing.expectEqual(@as(u32, 4), span.byte_end); // SourceSpan.byte_end

    // ── Entry point 13: parseSource → ParseResult { ast, diagnostics }.
    var result = try weld_etch.parseSource(gpa, reference_src); // (13)
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    const arena = &result.ast;

    // ── Entry point 14: Ast.isEmpty + the SoA column lengths (public fields).
    try std.testing.expect(!arena.isEmpty()); // (14: isEmpty)
    try std.testing.expect(arena.items.len >= 2); // SoA column `items`
    try std.testing.expect(arena.exprs.len >= 1); // SoA column `exprs`
    try std.testing.expect(arena.stmts.len >= 1); // SoA column `stmts`
    try std.testing.expect(arena.type_nodes.len >= 1); // SoA column `type_nodes`

    // ── Entry points 15-17: the item accessor triplet (kind/data/span).
    const item0: weld_etch.NodeId = .{ .category = .item, .index = 0 };
    const ik = arena.itemKind(item0); // (15: itemKind)
    try std.testing.expect(ik == .component_decl or ik == .rule_decl);
    _ = arena.itemData(item0); // (16: itemData)
    const isp = arena.itemSpan(item0); // (17: itemSpan)
    try std.testing.expect(isp.byte_end >= isp.byte_start);

    // ── Entry points 18-20: the expr accessor triplet.
    const expr0: weld_etch.NodeId = .{ .category = .expr, .index = 0 };
    _ = arena.exprKind(expr0); // (18: exprKind)
    _ = arena.exprData(expr0); // (19: exprData)
    const esp = arena.exprSpan(expr0); // (20: exprSpan)
    try std.testing.expect(esp.byte_end >= esp.byte_start);

    // ── Entry points 21-23: the stmt accessor triplet.
    const stmt0: weld_etch.NodeId = .{ .category = .stmt, .index = 0 };
    _ = arena.stmtKind(stmt0); // (21: stmtKind)
    _ = arena.stmtData(stmt0); // (22: stmtData)
    _ = arena.stmtSpan(stmt0); // (23: stmtSpan)

    // ── Entry points 24-26: the type-node accessor triplet.
    const type0: weld_etch.NodeId = .{ .category = .type_node, .index = 0 };
    _ = arena.typeNodeKind(type0); // (24: typeNodeKind)
    _ = arena.typeNodeData(type0); // (25: typeNodeData)
    _ = arena.typeNodeSpan(type0); // (26: typeNodeSpan)

    // ── Entry points 27-28: the string-intern pool — find + slice round-trip.
    const health_id = arena.strings.find("Health"); // (27: strings.find)
    try std.testing.expect(health_id != null);
    try std.testing.expectEqualStrings("Health", arena.strings.slice(health_id.?)); // (28: strings.slice)

    // ── Entry points 29-30: trivia accessors (frozen for the LS).
    _ = arena.docCommentsOf(item0); // (29: docCommentsOf)
    _ = arena.leadingCommentsOf(item0); // (30: leadingCommentsOf)
}
