//! Item 8 (M0.5): Etch identifiers that collide with Zig keywords.
//!
//! An Etch program may legitimately name a component / field / binding with a
//! word that is a Zig keyword (`align`, `var`, `error`, `comptime`, …) — these
//! are NOT Etch keywords, so the parser and interpreter accept them. The Zig
//! codegen must therefore not emit such names as bare Zig identifiers (which
//! would be uncompilable); it escapes them via `@"…"`.
//!
//! This test codegens such a program and parses the *generated Zig* with Zig's
//! own parser: a bare keyword in identifier position (e.g. `pub const align =
//! …`) is a parse error, so asserting zero parse errors enforces escaping
//! across every emission site the program exercises (component name, field
//! name, type reference, field access). RED before the fix, green after.

const std = @import("std");
const etch = @import("weld_etch");

fn codegenZig(gpa: std.mem.Allocator, src: []const u8, out: *std.ArrayListUnmanaged(u8)) !void {
    var pr = try etch.parseSource(gpa, src);
    defer pr.deinit(gpa);
    try std.testing.expect(pr.diagnostics.len == 0);

    var diags: std.ArrayListUnmanaged(etch.Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try etch.typeCheck(gpa, &pr.ast, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);

    _ = try etch.codegen_zig.generateToBuffer(gpa, &pr.ast, "keyword_ident", out);
}

test "etch idents that are zig keywords codegen to parseable zig" {
    const gpa = std.testing.allocator;
    // `var` is a Zig keyword but a valid Etch field name. (Component / type
    // names must be capitalized TYPE_IDENTs, so they can never be Zig
    // keywords; only lowercase value-idents — fields, bindings, params — can
    // collide.) The codegen must escape the field name at every site it
    // emits as a Zig identifier: the struct field declaration, the when-clause
    // field filter, and the field-access expression.
    const src =
        \\component Counter { var: int = 0 }
        \\rule bump(entity: Entity)
        \\  when entity has Counter { var == 0 }
        \\{
        \\  entity.get_mut(Counter).var += 1
        \\}
    ;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try codegenZig(gpa, src, &buf);

    // The generated Zig must be syntactically valid. Zig's parser rejects a
    // bare keyword in identifier position, so a missed escape surfaces here.
    const z = try gpa.dupeZ(u8, buf.items);
    defer gpa.free(z);
    var tree = try std.zig.Ast.parse(gpa, z, .zig);
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) {
        std.debug.print(
            "generated zig has {d} parse error(s):\n{s}\n",
            .{ tree.errors.len, buf.items },
        );
    }
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
}
