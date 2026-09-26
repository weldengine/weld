//! A literal that overflows its type, and a constant whose folding overflows or
//! divides by zero, are refused when the program is checked.

const std = @import("std");
const weld_etch = @import("weld_etch");

/// Whether checking `src` reports a diagnostic whose message holds `needle`.
fn reports(src: []const u8, needle: []const u8) !bool {
    const gpa = std.testing.allocator;
    var pr = try weld_etch.parseSource(gpa, src);
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
    var diags: std.ArrayListUnmanaged(weld_etch.Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try weld_etch.typeCheck(gpa, &pr.ast, &diags);
    for (diags.items) |d| {
        if (std.mem.indexOf(u8, d.primary_message, needle) != null) return true;
    }
    return false;
}

/// The diagnostic count of checking `src`.
fn diagnosticCount(src: []const u8) !usize {
    const gpa = std.testing.allocator;
    var pr = try weld_etch.parseSource(gpa, src);
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
    var diags: std.ArrayListUnmanaged(weld_etch.Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try weld_etch.typeCheck(gpa, &pr.ast, &diags);
    for (diags.items) |d| std.debug.print("diagnostic: {s}\n", .{d.primary_message});
    return diags.items.len;
}

test "an int literal above int is refused wherever it sits" {
    try std.testing.expect(try reports(
        \\resource R { v: int = 0 }
        \\rule r() when resource R { let x = 9223372036854775808 }
    , "literal 9223372036854775808 does not fit in int"));
}

test "the int minimum fits written negated" {
    try std.testing.expectEqual(@as(usize, 0), try diagnosticCount(
        \\resource R { v: int = -9223372036854775808 }
    ));
}

test "an i32 default above i32 is refused" {
    try std.testing.expect(try reports("component C { v: i32 = 3000000000 }", "literal 3000000000 does not fit in i32"));
}

test "a u32 default below zero is refused" {
    try std.testing.expect(try reports("component C { v: u32 = -1 }", "literal -1 does not fit in u32"));
}

test "an f32 default above f32 is refused" {
    try std.testing.expect(try reports("component C { v: f32 = 1" ++ "0" ** 39 ++ ".0 }", "does not fit in f32"));
}

test "a float literal that is not finite is refused" {
    try std.testing.expect(try reports("component C { v: float = 1" ++ "0" ** 400 ++ ".0 }", "does not fit in float"));
}

test "each narrow type's bounds are accepted" {
    try std.testing.expectEqual(@as(usize, 0), try diagnosticCount(
        \\component C {
        \\  hi: i32 = 2147483647
        \\  lo: i32 = -2147483648
        \\  top: u32 = 4294967295
        \\  zero: u32 = 0
        \\  big: f32 = 340282346638528859811704183484516925440.0
        \\}
    ));
}

test "a default whose folding overflows is refused" {
    try std.testing.expect(try reports("component C { v: int = 9223372036854775807 + 1 }", "the constant overflows int"));
}

test "a default that divides by zero is refused" {
    try std.testing.expect(try reports("component C { v: int = 1 / 0 }", "the constant divides by zero"));
}

test "a const whose folding overflows is refused" {
    try std.testing.expect(try reports("const X: int = 9223372036854775807 * 2", "the constant overflows int"));
}

test "a float default whose folding is not finite is refused" {
    try std.testing.expect(try reports("component C { v: float = 1.0 / 0.0 }", "the constant is not a finite float"));
}

test "a default of logic over constants folds" {
    try std.testing.expectEqual(@as(usize, 0), try diagnosticCount("component C { flag: bool = true or false }"));
}

test "a default concatenating strings is not a constant" {
    try std.testing.expect(try reports("resource R { s: string = \"a\" + \"b\" }", "field default value must be a constant expression"));
}

test "a filter value outside its i32 field is refused" {
    try std.testing.expect(try reports(
        \\component C { v: i32 = 0 }
        \\rule r(entity: Entity) when entity has C { v == 3000000000 } {}
    , "literal 3000000000 does not fit in i32"));
}

test "an int literal filter on an i32 field is accepted" {
    try std.testing.expectEqual(@as(usize, 0), try diagnosticCount(
        \\component C { v: i32 = 0 }
        \\rule r(entity: Entity) when entity has C { v == 5 } {}
    ));
}

test "a filter value that is not a constant is refused" {
    try std.testing.expect(try reports(
        \\component C { v: int = 0 }
        \\rule r(entity: Entity) when entity has C { v == 1 / 0 } {}
    , "the constant divides by zero"));
}

test "a resource instance value outside its i32 field is refused" {
    try std.testing.expect(try reports(
        \\resource R { v: i32 = 0 }
        \\scene "S" {
        \\  resources { R { v: 3000000000 } }
        \\}
    , "literal 3000000000 does not fit in i32"));
}

test "an effect parameter default outside i32 is refused" {
    try std.testing.expect(try reports(
        \\effect Burst {
        \\  params { count: i32 = 3000000000 }
        \\  emitter spark { rate: 10.0 }
        \\}
    , "literal 3000000000 does not fit in i32"));
}

test "a negative array size is refused" {
    try std.testing.expect(try reports(
        \\resource R { v: int = 0 }
        \\rule r() when resource R { let xs: int[-1] = [0; 1] }
    , "array size must be a non-negative integer literal"));
}

test "an array fill count that is not a literal is refused" {
    try std.testing.expect(try reports(
        \\resource R { v: int = 0 }
        \\rule r() when resource R {
        \\  let n = 3
        \\  let xs = [0; n]
        \\}
    , "array fill count must be a non-negative integer literal"));
}

/// The Zig source the codegen emits for `src`, which must check clean.
fn lowered(gpa: std.mem.Allocator, src: []const u8, out: *std.ArrayListUnmanaged(u8)) !void {
    try std.testing.expectEqual(@as(usize, 0), try diagnosticCount(src));
    var pr = try weld_etch.parseSource(gpa, src);
    defer pr.deinit(gpa);
    var diags: std.ArrayListUnmanaged(weld_etch.Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try weld_etch.typeCheck(gpa, &pr.ast, &diags);
    _ = try weld_etch.codegen_zig.lower.generateFile(gpa, &pr.ast, "numeric_range_test.etch", out);
}

test "integer arithmetic lowers through the overflow helpers, float arithmetic does not" {
    const gpa = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    try lowered(gpa,
        \\component Acc { n: int = 0  x: float = 0.0 }
        \\rule r(entity: Entity) when entity has Acc {
        \\  let n = entity.get(Acc).n
        \\  let x = entity.get(Acc).x
        \\  entity.get_mut(Acc).n = n * 3
        \\  entity.get_mut(Acc).x = x * 3.0
        \\}
    , &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "__etchMul(i64, n, 3)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "(x * 3.0)") != null);
}

test "narrowing and float-to-int casts lower through their helpers" {
    const gpa = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    try lowered(gpa,
        \\component Acc { n: int = 0  x: float = 0.0  a: i32 = 0  b: i32 = 0 }
        \\rule r(entity: Entity) when entity has Acc {
        \\  let n = entity.get(Acc).n
        \\  let x = entity.get(Acc).x
        \\  entity.get_mut(Acc).a = n as i32
        \\  entity.get_mut(Acc).b = x as i32
        \\}
    , &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "__etchNarrow(i32, n)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "__etchIntFromFloat(i32, x)") != null);
}

test "an array element outside its declared i32 is refused" {
    try std.testing.expect(try reports(
        \\resource R { v: int = 0 }
        \\rule r() when resource R { let xs: i32[] = [1, 3000000000] }
    , "literal 3000000000 does not fit in i32"));
}

test "a map value outside its declared u32 is refused" {
    try std.testing.expect(try reports(
        \\resource R { v: int = 0 }
        \\rule r() when resource R { let m: [int: u32] = [1: -1] }
    , "literal -1 does not fit in u32"));
}

test "an array element of another type than declared is refused" {
    try std.testing.expect(try reports(
        \\resource R { v: int = 0 }
        \\rule r() when resource R { let xs: i32[] = [1.5] }
    , "collection element type does not match the declared element type"));
}

test "literal elements within their declared types are accepted" {
    try std.testing.expectEqual(@as(usize, 0), try diagnosticCount(
        \\resource R { v: int = 0 }
        \\rule r() when resource R {
        \\  let xs: i32[] = [1, -2147483648]
        \\  let ys: u32[2] = [0; 2]
        \\  let m: [int: f32] = [1: 2.5]
        \\}
    ));
}

test "a compound integer assignment lowers through its helper" {
    const gpa = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    try lowered(gpa,
        \\component Acc { n: int = 0 }
        \\rule r(entity: Entity) when entity has Acc {
        \\  let mut t = 1
        \\  t += 2
        \\  entity.get_mut(Acc).n = t
        \\}
    , &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "t = __etchAdd(i64, t, 2);") != null);
}

test "a constant default lowers as its folded value" {
    const gpa = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    try lowered(gpa,
        \\component Acc {
        \\  n: int = 1_000_
        \\  m: int = 2 * 3
        \\  lo: int = -9223372036854775808
        \\}
    , &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "n: i64 = 1000,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "m: i64 = 6,") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "lo: i64 = -9223372036854775808,") != null);
}

test "a runtime literal lowers without its separators" {
    const gpa = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);
    try lowered(gpa,
        \\component Acc { n: int = 0 }
        \\rule r(entity: Entity) when entity has Acc { entity.get_mut(Acc).n = 1_000_ }
    , &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "= 1000;") != null);
}
