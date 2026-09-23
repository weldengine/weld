//! An annotation argument follows `etch-grammar.md` §1.5, and a reader that
//! takes a positional argument refuses a named one.

const std = @import("std");
const weld_etch = @import("weld_etch");

/// The diagnostic codes of checking `src`, which must parse clean.
fn codesOf(gpa: std.mem.Allocator, src: []const u8, out: *std.ArrayListUnmanaged([]const u8)) !void {
    var pr = try weld_etch.parseSource(gpa, src);
    defer pr.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), pr.diagnostics.len);
    var diags: std.ArrayListUnmanaged(weld_etch.Diagnostic) = .empty;
    defer {
        for (diags.items) |*d| d.deinit(gpa);
        diags.deinit(gpa);
    }
    try weld_etch.typeCheck(gpa, &pr.ast, &diags);
    for (diags.items) |d| try out.append(gpa, try gpa.dupe(u8, d.code.code()));
}

/// Whether checking `src` reports `code`.
fn reportsCode(src: []const u8, code: []const u8) !bool {
    const gpa = std.testing.allocator;
    var codes: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (codes.items) |c| gpa.free(c);
        codes.deinit(gpa);
    }
    try codesOf(gpa, src, &codes);
    for (codes.items) |c| {
        if (std.mem.eql(u8, c, code)) return true;
    }
    return false;
}

test "an event observer named argument is refused" {
    try std.testing.expect(try reportsCode(
        \\event Hit { amount: int = 0 }
        \\@on_event(e: Hit)
        \\rule r() {}
    , "E1203"));
}

test "a positional event observer argument is accepted" {
    try std.testing.expect(!try reportsCode(
        \\event Hit { amount: int = 0 }
        \\@on_event(Hit)
        \\rule r() {}
    , "E1203"));
}

test "a structural observer named argument is refused" {
    try std.testing.expect(try reportsCode(
        \\component Health { hp: int = 0 }
        \\@on_added(c: Health)
        \\rule r(entity: Entity, value: Health) {}
    , "E1209"));
}

test "a positional structural observer argument is accepted" {
    try std.testing.expect(!try reportsCode(
        \\component Health { hp: int = 0 }
        \\@on_added(Health)
        \\rule r(entity: Entity, value: Health) {}
    , "E1209"));
}
