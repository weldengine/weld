//! Minimal XML parser for vk.xml (and protocol XMLs).
//!
//! Throwaway code for S2. Handles only the subset of XML used by Khronos
//! registries and Wayland protocols: tags with double-quoted attributes,
//! mixed content, self-closing tags, comments, `<?xml ... ?>` declarations,
//! `&lt; &gt; &amp; &quot; &apos;` entity references. No CDATA (not used by
//! vk.xml or wayland-protocols), no namespaces, no DOCTYPE handling beyond
//! skipping.
//!
//! All output strings are owned by the Tree's arena.

const std = @import("std");

pub const Attr = struct {
    name: []const u8,
    value: []const u8,
};

pub const Element = struct {
    tag: []const u8,
    attrs: []const Attr,
    children: []const Child,

    pub fn attr(self: Element, name: []const u8) ?[]const u8 {
        for (self.attrs) |a| {
            if (std.mem.eql(u8, a.name, name)) return a.value;
        }
        return null;
    }

    pub fn firstChild(self: Element, tag: []const u8) ?*const Element {
        for (self.children) |*c| {
            if (c.* == .elem and std.mem.eql(u8, c.elem.tag, tag)) return &c.elem;
        }
        return null;
    }

    /// Concatenate all direct text children into a single arena-allocated
    /// string (whitespace preserved). Useful for inspecting `<name>X</name>`.
    pub fn directText(self: Element, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        for (self.children) |c| {
            if (c == .text) try out.appendSlice(gpa, c.text);
        }
        return out.toOwnedSlice(gpa);
    }
};

pub const Child = union(enum) {
    elem: Element,
    text: []const u8,
};

pub const Tree = struct {
    arena: std.heap.ArenaAllocator,
    root: Element,

    pub fn deinit(self: *Tree) void {
        self.arena.deinit();
    }
};

pub const ParseError = error{
    UnexpectedEof,
    UnexpectedChar,
    BadAttribute,
    UnterminatedTag,
    UnterminatedString,
    MismatchedClose,
    UnknownEntity,
} || std.mem.Allocator.Error;

pub fn parse(gpa: std.mem.Allocator, source: []const u8) ParseError!Tree {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const aalloc = arena.allocator();

    var p: Parser = .{ .src = source, .pos = 0, .arena = aalloc };

    // Skip leading prolog (XML decl, comments, whitespace, DOCTYPE).
    try p.skipProlog();

    // Root element.
    if (!p.match('<')) return error.UnexpectedChar;
    const root = try p.parseElement();

    return .{ .arena = arena, .root = root };
}

const Parser = struct {
    src: []const u8,
    pos: usize,
    arena: std.mem.Allocator,

    fn peek(self: Parser) ?u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }

    fn advance(self: *Parser) ?u8 {
        if (self.pos >= self.src.len) return null;
        const c = self.src[self.pos];
        self.pos += 1;
        return c;
    }

    fn match(self: *Parser, c: u8) bool {
        if (self.peek() != c) return false;
        self.pos += 1;
        return true;
    }

    fn matchSlice(self: *Parser, s: []const u8) bool {
        if (self.pos + s.len > self.src.len) return false;
        if (!std.mem.eql(u8, self.src[self.pos .. self.pos + s.len], s)) return false;
        self.pos += s.len;
        return true;
    }

    fn skipWs(self: *Parser) void {
        while (self.peek()) |c| {
            switch (c) {
                ' ', '\t', '\r', '\n' => self.pos += 1,
                else => break,
            }
        }
    }

    fn skipProlog(self: *Parser) ParseError!void {
        while (true) {
            self.skipWs();
            if (self.matchSlice("<?")) {
                // <?xml ... ?>
                while (self.advance()) |c| {
                    if (c == '?' and self.peek() == '>') {
                        self.pos += 1;
                        break;
                    }
                } else return error.UnterminatedTag;
                continue;
            }
            if (self.matchSlice("<!--")) {
                while (self.pos + 3 <= self.src.len) {
                    if (std.mem.eql(u8, self.src[self.pos .. self.pos + 3], "-->")) {
                        self.pos += 3;
                        break;
                    }
                    self.pos += 1;
                } else return error.UnterminatedTag;
                continue;
            }
            if (self.matchSlice("<!DOCTYPE")) {
                // Skip up to matching '>'. Naive — vk.xml's DOCTYPE is one-liner if any.
                var depth: i32 = 1;
                while (depth > 0) {
                    const c = self.advance() orelse return error.UnterminatedTag;
                    if (c == '<') depth += 1;
                    if (c == '>') depth -= 1;
                }
                continue;
            }
            return;
        }
    }

    /// Called immediately after the leading '<' has been consumed.
    fn parseElement(self: *Parser) ParseError!Element {
        // Tag name.
        const start = self.pos;
        while (self.peek()) |c| {
            switch (c) {
                ' ', '\t', '\r', '\n', '/', '>' => break,
                else => self.pos += 1,
            }
        }
        if (self.pos == start) return error.UnexpectedChar;
        const tag = self.src[start..self.pos];

        // Attributes.
        var attrs: std.ArrayList(Attr) = .empty;
        defer attrs.deinit(self.arena);
        while (true) {
            self.skipWs();
            const c = self.peek() orelse return error.UnterminatedTag;
            if (c == '/' or c == '>') break;
            const a = try self.parseAttr();
            try attrs.append(self.arena, a);
        }

        // Self-closing or end of opening tag.
        const self_closing = self.match('/');
        if (!self.match('>')) return error.UnterminatedTag;

        if (self_closing) {
            return .{
                .tag = try self.arena.dupe(u8, tag),
                .attrs = try attrs.toOwnedSlice(self.arena),
                .children = &.{},
            };
        }

        // Children: parse until matching </tag>.
        var children: std.ArrayList(Child) = .empty;
        defer children.deinit(self.arena);
        var text_buf: std.ArrayList(u8) = .empty;
        defer text_buf.deinit(self.arena);

        while (true) {
            const c = self.peek() orelse return error.UnexpectedEof;
            if (c == '<') {
                // Flush accumulated text.
                if (text_buf.items.len > 0) {
                    try children.append(self.arena, .{ .text = try self.arena.dupe(u8, text_buf.items) });
                    text_buf.clearRetainingCapacity();
                }
                self.pos += 1;
                if (self.peek() == '/') {
                    self.pos += 1;
                    // Closing tag.
                    const close_start = self.pos;
                    while (self.peek()) |cc| {
                        if (cc == '>' or cc == ' ' or cc == '\t' or cc == '\r' or cc == '\n') break;
                        self.pos += 1;
                    }
                    const close_tag = self.src[close_start..self.pos];
                    if (!std.mem.eql(u8, close_tag, tag)) return error.MismatchedClose;
                    self.skipWs();
                    if (!self.match('>')) return error.UnterminatedTag;
                    return .{
                        .tag = try self.arena.dupe(u8, tag),
                        .attrs = try attrs.toOwnedSlice(self.arena),
                        .children = try children.toOwnedSlice(self.arena),
                    };
                }
                if (self.matchSlice("!--")) {
                    // Comment — skip.
                    while (self.pos + 3 <= self.src.len) {
                        if (std.mem.eql(u8, self.src[self.pos .. self.pos + 3], "-->")) {
                            self.pos += 3;
                            break;
                        }
                        self.pos += 1;
                    } else return error.UnterminatedTag;
                    continue;
                }
                // Nested element.
                const child = try self.parseElement();
                try children.append(self.arena, .{ .elem = child });
            } else if (c == '&') {
                self.pos += 1;
                const ent = try self.parseEntity();
                try text_buf.append(self.arena, ent);
            } else {
                try text_buf.append(self.arena, c);
                self.pos += 1;
            }
        }
    }

    fn parseAttr(self: *Parser) ParseError!Attr {
        // Name.
        const ns = self.pos;
        while (self.peek()) |c| {
            switch (c) {
                '=', ' ', '\t', '\r', '\n', '/', '>' => break,
                else => self.pos += 1,
            }
        }
        if (self.pos == ns) return error.BadAttribute;
        const name = self.src[ns..self.pos];

        self.skipWs();
        if (!self.match('=')) return error.BadAttribute;
        self.skipWs();

        const quote = self.advance() orelse return error.BadAttribute;
        if (quote != '"' and quote != '\'') return error.BadAttribute;

        var value_buf: std.ArrayList(u8) = .empty;
        defer value_buf.deinit(self.arena);
        while (true) {
            const c = self.peek() orelse return error.UnterminatedString;
            if (c == quote) {
                self.pos += 1;
                break;
            }
            if (c == '&') {
                self.pos += 1;
                const e = try self.parseEntity();
                try value_buf.append(self.arena, e);
                continue;
            }
            try value_buf.append(self.arena, c);
            self.pos += 1;
        }

        return .{
            .name = try self.arena.dupe(u8, name),
            .value = try self.arena.dupe(u8, value_buf.items),
        };
    }

    fn parseEntity(self: *Parser) ParseError!u8 {
        // Standard 5 entities + numeric (&#NN; or &#xNN;) — the registry
        // uses these only sparingly, but we must handle them.
        if (self.matchSlice("lt;")) return '<';
        if (self.matchSlice("gt;")) return '>';
        if (self.matchSlice("amp;")) return '&';
        if (self.matchSlice("quot;")) return '"';
        if (self.matchSlice("apos;")) return '\'';
        if (self.match('#')) {
            // Numeric. Read digits up to ';'.
            const hex = self.match('x') or self.match('X');
            var n: u32 = 0;
            while (self.peek()) |c| {
                if (c == ';') {
                    self.pos += 1;
                    if (n > 0x7F) return error.UnknownEntity; // ASCII only here
                    return @intCast(n);
                }
                const d: u32 = if (hex) blk: {
                    break :blk if (c >= '0' and c <= '9') @as(u32, c - '0') else if (c >= 'a' and c <= 'f') @as(u32, c - 'a' + 10) else if (c >= 'A' and c <= 'F') @as(u32, c - 'A' + 10) else return error.UnknownEntity;
                } else if (c >= '0' and c <= '9') @as(u32, c - '0') else return error.UnknownEntity;
                n = n * @as(u32, if (hex) 16 else 10) + d;
                self.pos += 1;
            }
            return error.UnknownEntity;
        }
        return error.UnknownEntity;
    }
};

// ---------------------------------------------------------------- Tests --

test "parse a tiny document" {
    const src =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<root>
        \\  <foo a="1" b="two">hello</foo>
        \\  <bar/>
        \\  <mixed>start <inner>middle</inner> end</mixed>
        \\</root>
    ;
    var tree = try parse(std.testing.allocator, src);
    defer tree.deinit();

    try std.testing.expectEqualStrings("root", tree.root.tag);
    try std.testing.expectEqual(@as(usize, 0), tree.root.attrs.len);

    // Children: text, elem(foo), text, elem(bar), text, elem(mixed), text
    var elems: usize = 0;
    for (tree.root.children) |c| if (c == .elem) {
        elems += 1;
    };
    try std.testing.expectEqual(@as(usize, 3), elems);

    const foo = tree.root.firstChild("foo").?;
    try std.testing.expectEqualStrings("1", foo.attr("a").?);
    try std.testing.expectEqualStrings("two", foo.attr("b").?);

    const mixed = tree.root.firstChild("mixed").?;
    // mixed should have text "start ", elem inner, text " end"
    var saw_text_start = false;
    var saw_inner = false;
    var saw_text_end = false;
    for (mixed.children) |c| switch (c) {
        .text => |t| {
            if (std.mem.indexOf(u8, t, "start") != null) saw_text_start = true;
            if (std.mem.indexOf(u8, t, "end") != null) saw_text_end = true;
        },
        .elem => |e| if (std.mem.eql(u8, e.tag, "inner")) {
            saw_inner = true;
        },
    };
    try std.testing.expect(saw_text_start);
    try std.testing.expect(saw_inner);
    try std.testing.expect(saw_text_end);
}

test "parse handles entity references" {
    const src =
        \\<root attr="a&amp;b">x &lt; y</root>
    ;
    var tree = try parse(std.testing.allocator, src);
    defer tree.deinit();
    try std.testing.expectEqualStrings("a&b", tree.root.attr("attr").?);
    var saw = false;
    for (tree.root.children) |c| switch (c) {
        .text => |t| if (std.mem.indexOf(u8, t, "x < y") != null) {
            saw = true;
        },
        .elem => {},
    };
    try std.testing.expect(saw);
}

test "parse a vk.xml-like member element" {
    const src =
        \\<member optional="true">const <type>void</type>* <name>pNext</name></member>
    ;
    var tree = try parse(std.testing.allocator, src);
    defer tree.deinit();
    const m = tree.root;
    try std.testing.expectEqualStrings("member", m.tag);
    try std.testing.expectEqualStrings("true", m.attr("optional").?);
    const ty = m.firstChild("type").?;
    const name = m.firstChild("name").?;
    const ty_text = try ty.directText(std.testing.allocator);
    defer std.testing.allocator.free(ty_text);
    const name_text = try name.directText(std.testing.allocator);
    defer std.testing.allocator.free(name_text);
    try std.testing.expectEqualStrings("void", ty_text);
    try std.testing.expectEqualStrings("pNext", name_text);
}
