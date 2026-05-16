//! Emission primitives — small wrapper around `std.ArrayListUnmanaged(u8)`
//! that tracks indentation and offers a few `printf`-style helpers. The
//! codegen output is text Zig source; `zig fmt` will reformat trivia at
//! build time so we only need to keep the structural indentation roughly
//! right.

const std = @import("std");

pub const Writer = struct {
    buffer: *std.ArrayListUnmanaged(u8),
    gpa: std.mem.Allocator,
    indent: u32 = 0,

    pub fn init(gpa: std.mem.Allocator, buffer: *std.ArrayListUnmanaged(u8)) Writer {
        return .{ .buffer = buffer, .gpa = gpa };
    }

    pub fn indentBy(self: *Writer, delta: i32) void {
        const after: i64 = @as(i64, self.indent) + delta;
        std.debug.assert(after >= 0);
        self.indent = @intCast(after);
    }

    pub fn write(self: *Writer, s: []const u8) !void {
        try self.buffer.appendSlice(self.gpa, s);
    }

    pub fn writeIndent(self: *Writer) !void {
        var i: u32 = 0;
        while (i < self.indent) : (i += 1) {
            try self.buffer.appendSlice(self.gpa, "    ");
        }
    }

    /// Write a line — indentation first, the text, then a `\n`.
    pub fn line(self: *Writer, s: []const u8) !void {
        try self.writeIndent();
        try self.buffer.appendSlice(self.gpa, s);
        try self.buffer.append(self.gpa, '\n');
    }

    /// Write a printed line. Format string + args are forwarded to
    /// `std.fmt.allocPrint`; the resulting slice is appended then freed.
    pub fn printLine(self: *Writer, comptime fmt: []const u8, args: anytype) !void {
        try self.writeIndent();
        const tmp = try std.fmt.allocPrint(self.gpa, fmt, args);
        defer self.gpa.free(tmp);
        try self.buffer.appendSlice(self.gpa, tmp);
        try self.buffer.append(self.gpa, '\n');
    }

    /// Write an in-line (no newline) formatted snippet.
    pub fn print(self: *Writer, comptime fmt: []const u8, args: anytype) !void {
        const tmp = try std.fmt.allocPrint(self.gpa, fmt, args);
        defer self.gpa.free(tmp);
        try self.buffer.appendSlice(self.gpa, tmp);
    }

    pub fn blankLine(self: *Writer) !void {
        try self.buffer.append(self.gpa, '\n');
    }
};

test "Writer indents and emits lines" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    var w = Writer.init(gpa, &buf);

    try w.line("pub fn foo() void {");
    w.indentBy(1);
    try w.line("return;");
    w.indentBy(-1);
    try w.line("}");

    try std.testing.expectEqualStrings("pub fn foo() void {\n    return;\n}\n", buf.items);
}

test "Writer.printLine and print compose" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    var w = Writer.init(gpa, &buf);

    try w.printLine("const {s} = {d};", .{ "x", 42 });
    try w.write("// trailing comment\n");

    try std.testing.expectEqualStrings("const x = 42;\n// trailing comment\n", buf.items);
}
