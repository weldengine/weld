//! A type node's name is read only when the node is `.named`: every other kind
//! gets its own decision, in the checker, the interpreter and the codegen.

const std = @import("std");
const weld_etch = @import("weld_etch");

const lower = weld_etch.codegen_zig.lower;

/// The diagnostics of `src`, as their primary messages.
fn checkMessages(gpa: std.mem.Allocator, src: []const u8, out: *std.ArrayListUnmanaged([]const u8)) !void {
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

fn freeMessages(gpa: std.mem.Allocator, list: *std.ArrayListUnmanaged([]const u8)) void {
    for (list.items) |m| gpa.free(m);
    list.deinit(gpa);
}

/// Whether type-checking `src` reports the rule-parameter refusal.
fn refusesRuleParam(gpa: std.mem.Allocator, src: []const u8) !bool {
    var msgs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer freeMessages(gpa, &msgs);
    try checkMessages(gpa, src, &msgs);
    for (msgs.items) |m| {
        if (std.mem.indexOf(u8, m, "rule parameters must be scalar or Entity") != null) return true;
    }
    return false;
}

/// Lowers `src`, type-checking it first unless `checked` is false.
fn lowerSource(gpa: std.mem.Allocator, src: []const u8, checked: bool) !void {
    var pr = try weld_etch.parseSource(gpa, src);
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
    if (checked) {
        var diags: std.ArrayListUnmanaged(weld_etch.Diagnostic) = .empty;
        defer {
            for (diags.items) |*d| d.deinit(gpa);
            diags.deinit(gpa);
        }
        try weld_etch.typeCheck(gpa, &pr.ast, &diags);
        for (diags.items) |d| std.debug.print("unexpected diagnostic: {s}\n", .{d.primary_message});
        try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    }
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    _ = try lower.generateFile(gpa, &pr.ast, "type_node_kind_test.etch", &buf);
}

test "a collection rule parameter is refused by the checker" {
    try std.testing.expect(try refusesRuleParam(std.testing.allocator, "rule r(entity: Entity, xs: int[]) {}"));
}

test "an optional rule parameter is refused by the checker" {
    try std.testing.expect(try refusesRuleParam(std.testing.allocator, "rule r(entity: Entity, x: int?) {}"));
}

test "a scalar rule parameter is accepted by the checker" {
    try std.testing.expect(!try refusesRuleParam(std.testing.allocator, "rule r(entity: Entity, dt: float) {}"));
}

test "the codegen refuses a non-named rule parameter, even unchecked" {
    try std.testing.expectError(
        error.UnsupportedConstruct,
        lowerSource(std.testing.allocator, "rule r(entity: Entity, xs: int[]) {}", false),
    );
}

test "the codegen refuses a resource array field" {
    try std.testing.expectError(error.UnsupportedConstruct, lowerSource(std.testing.allocator, "resource R { xs: int[] }", true));
}

test "the codegen refuses a resource map field" {
    try std.testing.expectError(error.UnsupportedConstruct, lowerSource(std.testing.allocator, "resource R { m: [int: int] }", true));
}

test "the codegen refuses a resource set field" {
    try std.testing.expectError(error.UnsupportedConstruct, lowerSource(std.testing.allocator, "resource R { s: Set<int> }", true));
}

test "the same resource with a scalar field lowers" {
    try lowerSource(std.testing.allocator, "resource R { xs: int }", true);
}

test "the codegen refuses a collection fn parameter" {
    try std.testing.expectError(
        error.UnsupportedConstruct,
        lowerSource(std.testing.allocator, "fn total(xs: int[]) -> int { 0 }", true),
    );
}

test "the codegen refuses an optional fn return" {
    try std.testing.expectError(
        error.UnsupportedConstruct,
        lowerSource(std.testing.allocator, "fn first() -> int? { none }", true),
    );
}

test "the same fn with scalar types lowers" {
    try lowerSource(std.testing.allocator, "fn total(xs: int) -> int { 0 }", true);
}
