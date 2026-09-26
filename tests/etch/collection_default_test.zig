//! A resource collection field's default is checked against the field's
//! element type, as a scalar field's default is against its type.

const std = @import("std");
const weld_etch = @import("weld_etch");

/// The primary messages of checking `src`.
fn messages(gpa: std.mem.Allocator, src: []const u8, out: *std.ArrayListUnmanaged([]const u8)) !void {
    var pr = try weld_etch.parseSource(gpa, src);
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
    var diags: std.ArrayListUnmanaged(weld_etch.Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try weld_etch.typeCheck(gpa, &pr.ast, &diags);
    for (diags.items) |d| try out.append(gpa, try gpa.dupe(u8, d.primary_message));
}

/// Whether checking `src` reports exactly one diagnostic, and it holds `needle`.
fn reportsOnly(src: []const u8, needle: []const u8) !bool {
    const gpa = std.testing.allocator;
    var msgs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (msgs.items) |m| gpa.free(m);
        msgs.deinit(gpa);
    }
    try messages(gpa, src, &msgs);
    for (msgs.items) |m| std.debug.print("diagnostic: {s}\n", .{m});
    return msgs.items.len == 1 and std.mem.indexOf(u8, msgs.items[0], needle) != null;
}

const mode_enum = "enum Mode { a, b }\n";

test "a scalar default on an array field is refused" {
    try std.testing.expect(try reportsOnly("resource R { xs: int[] = 5 }", "an array field default must be an array literal"));
}

test "a string default on an array field is refused" {
    try std.testing.expect(try reportsOnly("resource R { xs: int[] = \"no\" }", "an array field default must be an array literal"));
}

test "a map literal default on an array field is refused" {
    try std.testing.expect(try reportsOnly("resource R { xs: int[] = [:] }", "an array field default must be an array literal"));
}

test "an array literal default on a map field is refused" {
    try std.testing.expect(try reportsOnly("resource R { m: [string: int] = [] }", "a map field default must be a map literal"));
}

test "an array literal default on a set field is refused" {
    try std.testing.expect(try reportsOnly("resource R { s: Set<int> = [] }", "a set field default must be `Set.new()`"));
}

test "a set built from an array is not a constant default" {
    try std.testing.expect(try reportsOnly("resource R { s: Set<int> = Set.from([1]) }", "field default value must be a constant expression"));
}

test "an array element of another type is refused" {
    try std.testing.expect(try reportsOnly("resource R { xs: int[] = [\"a\"] }", "collection element type does not match the declared element type"));
}

test "a string array element that is not a string literal is refused" {
    try std.testing.expect(try reportsOnly("resource R { xs: string[] = [1] }", "a string element must be a string literal"));
}

test "an array element outside its i32 element is refused" {
    try std.testing.expect(try reportsOnly("resource R { xs: i32[] = [3000000000] }", "literal 3000000000 does not fit in i32"));
}

test "a map value of another type is refused" {
    try std.testing.expect(try reportsOnly("resource R { m: [string: int] = [\"a\": \"b\"] }", "collection element type does not match the declared element type"));
}

test "an unknown variant in an enum array default is refused" {
    try std.testing.expect(try reportsOnly(mode_enum ++ "resource R { xs: Mode[] = [.nope] }", "enum 'Mode' has no variant 'nope'"));
}

test "an element that is not a constant is refused" {
    try std.testing.expect(try reportsOnly("resource R { xs: int[] = [1 / 0] }", "the constant divides by zero"));
}

test "a default on an invalid element type is not checked a second time" {
    try std.testing.expect(try reportsOnly(
        \\component Health { hp: int = 0 }
        \\resource R { xs: Health[] = ["x"] }
    , "resource collection element type 'Health' is not supported"));
}

test "a Vec3 element is refused" {
    try std.testing.expect(try reportsOnly("resource R { xs: Vec3[] }", "resource collection element type 'Vec3' is not supported"));
}

test "a float map key is refused by the Hash bound" {
    try std.testing.expect(try reportsOnly("resource R { m: [float: int] }", "map key type does not satisfy the 'K: Hash' bound"));
}

test "a float set element is refused by the Hash bound" {
    try std.testing.expect(try reportsOnly("resource R { s: Set<f32> }", "set element type does not satisfy the 'T: Hash' bound"));
}

test "an unknown variant as an enum field default is refused" {
    try std.testing.expect(try reportsOnly(mode_enum ++ "resource R { m: Mode = .nope }", "enum 'Mode' has no variant 'nope'"));
}

test "a number as an enum field default is refused" {
    try std.testing.expect(try reportsOnly(mode_enum ++ "resource R { m: Mode = 5 }", "an enum field default must be a variant of that enum"));
}

test "well-typed collection defaults are accepted" {
    const gpa = std.testing.allocator;
    var msgs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (msgs.items) |m| gpa.free(m);
        msgs.deinit(gpa);
    }
    try messages(gpa, mode_enum ++
        \\resource R {
        \\  xs: int[] = [1, -2]
        \\  fill: int[] = [7; 3]
        \\  names: string[] = ["a"]
        \\  modes: Mode[] = [.a, .b]
        \\  m: [string: int] = ["a": 1]
        \\  empty: [string: int] = [:]
        \\  s: Set<int> = Set.new()
        \\  mode: Mode = .b
        \\}
    , &msgs);
    for (msgs.items) |m| std.debug.print("diagnostic: {s}\n", .{m});
    try std.testing.expectEqual(@as(usize, 0), msgs.items.len);
}
