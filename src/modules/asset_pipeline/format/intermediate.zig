//! FROZEN — see `engine-phase-0-criteria.md` C0.5.
//!
//! Intermediate `<type>.asset.etch` document model + a minimal Etch-syntax
//! reader/writer.
//!
//! The on-disk text is the frozen surface: a single top-level
//! `asset "<name>" { … }` construct holding the importer-extracted metadata
//! and the user-editable settings. The bulk bytes live in a separate hashed
//! blob; `extracted.blob` references it.
//!
//! Normative schema: `engine-asset-pipeline.md §3` — fixed fields `type`,
//! `version`, `source`, `source_hash`, then the four blocks
//! `import_settings`, `process_settings`, `cook_settings`, `extracted`, with
//! `extracted.blob` ("<32 hex>", BLAKE3-128) mandatory. Grammar of the
//! `asset` construct: `etch-grammar.md §21.4` (category-4,
//! pipeline-generated). The container (fixed fields + block list + value
//! grammar) is frozen; block *contents* are open per asset category.
//!
//! This ad-hoc reader/writer avoids a `weld_etch` dependency (the
//! full Etch parser lives elsewhere). The reader takes the §21.4 grammar with
//! the Etch lexical rules of §1 — comments, the string escapes and triple-quoted
//! strings, `_` digit separators — and the §3 schema. A field annotation
//! (`@unit(...)`) is parsed and not kept: the document model carries none, and
//! the writer emits none. The on-disk text is the frozen contract, not this
//! reader implementation.
//!
//! Ownership: `parseEtch` allocates every string/array/object into the
//! caller-supplied allocator (use an arena and free it in one shot). The
//! returned `AssetDoc` borrows nothing from the source text.

const std = @import("std");

/// A scalar or composite value in the `asset` document tree.
pub const Value = union(enum) {
    /// Integer literal (e.g. `version: 1`).
    int: i64,
    /// Floating-point literal (always emitted with a decimal point).
    float: f64,
    /// Boolean literal (`true` / `false`).
    boolean: bool,
    /// Quoted string, stored without the surrounding quotes.
    string: []const u8,
    /// Bare identifier (e.g. an asset class name `StaticMesh`).
    identifier: []const u8,
    /// Enum literal `.name`, stored without the leading dot.
    enum_literal: []const u8,
    /// Comma-separated array of values.
    array: []const Value,
    /// Nested `{ … }` block of `key: value` fields.
    object: []const Field,

    /// Deep structural equality.
    pub fn eql(a: Value, b: Value) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .int => |x| x == b.int,
            .float => |x| x == b.float,
            .boolean => |x| x == b.boolean,
            .string => |x| std.mem.eql(u8, x, b.string),
            .identifier => |x| std.mem.eql(u8, x, b.identifier),
            .enum_literal => |x| std.mem.eql(u8, x, b.enum_literal),
            .array => |x| blk: {
                if (x.len != b.array.len) break :blk false;
                for (x, b.array) |xa, ba| {
                    if (!Value.eql(xa, ba)) break :blk false;
                }
                break :blk true;
            },
            .object => |x| fieldsEql(x, b.object),
        };
    }
};

/// One `key: value` pair inside a block.
pub const Field = struct {
    /// Field name (a bare identifier).
    key: []const u8,
    /// Field value.
    value: Value,
};

/// Look up `key` in `fields` and return its integer value, or null if the
/// field is absent or not an int. (Used by cookers to read `extracted`.)
pub fn fieldInt(fields: []const Field, key: []const u8) ?i64 {
    for (fields) |f| {
        if (std.mem.eql(u8, f.key, key)) {
            return switch (f.value) {
                .int => |v| v,
                else => null,
            };
        }
    }
    return null;
}

/// Look up `key` in `fields` and return its string value, or null.
pub fn fieldStr(fields: []const Field, key: []const u8) ?[]const u8 {
    for (fields) |f| {
        if (std.mem.eql(u8, f.key, key)) {
            return switch (f.value) {
                .string => |v| v,
                else => null,
            };
        }
    }
    return null;
}

/// Deep equality over two ordered field lists.
pub fn fieldsEql(a: []const Field, b: []const Field) bool {
    if (a.len != b.len) return false;
    for (a, b) |fa, fb| {
        if (!std.mem.eql(u8, fa.key, fb.key)) return false;
        if (!Value.eql(fa.value, fb.value)) return false;
    }
    return true;
}

/// The frozen intermediate-format schema. The three settings/extracted
/// blocks are generic field lists so each asset category populates only
/// what it needs (texture / mesh / audio).
pub const AssetDoc = struct {
    /// Logical asset name (the `asset "<name>"` string).
    name: []const u8,
    /// Stable identity — UUIDv7 canonical string, the first body field
    /// (`uuid: "…"`). Generated once at first import and preserved across
    /// re-imports (rename/move-safe); distinct from `source_hash`, which
    /// changes with the source. Mirrors `entity "name" { uuid: … }` in
    /// `.scene.etch`.
    uuid: []const u8 = "",
    /// Asset class identifier (e.g. `Texture2D`, `StaticMesh`, `AudioClip`).
    type_name: []const u8,
    /// Schema version of this document.
    version: u16,
    /// Source file the asset was imported from.
    source: []const u8,
    /// Hex hash of the source bytes.
    source_hash: []const u8,
    /// User-editable import settings.
    import_settings: []const Field = &.{},
    /// User-editable process settings.
    process_settings: []const Field = &.{},
    /// User-editable cook settings (per-platform sub-blocks, e.g.
    /// `pc: { … }`). Emitted between `process_settings` and `extracted`.
    cook_settings: []const Field = &.{},
    /// Importer-extracted, machine-maintained facts. Always carries
    /// `blob: "<32 hex>"` (see `blobHash`).
    extracted: []const Field = &.{},

    /// Deep structural equality (used by the round-trip test).
    pub fn eql(a: AssetDoc, b: AssetDoc) bool {
        return std.mem.eql(u8, a.name, b.name) and
            std.mem.eql(u8, a.uuid, b.uuid) and
            std.mem.eql(u8, a.type_name, b.type_name) and
            a.version == b.version and
            std.mem.eql(u8, a.source, b.source) and
            std.mem.eql(u8, a.source_hash, b.source_hash) and
            fieldsEql(a.import_settings, b.import_settings) and
            fieldsEql(a.process_settings, b.process_settings) and
            fieldsEql(a.cook_settings, b.cook_settings) and
            fieldsEql(a.extracted, b.extracted);
    }

    /// Return the mandatory `extracted.blob` hash string, or null if absent.
    pub fn blobHash(self: AssetDoc) ?[]const u8 {
        for (self.extracted) |f| {
            if (std.mem.eql(u8, f.key, "blob")) {
                return switch (f.value) {
                    .string => |s| s,
                    else => null,
                };
            }
        }
        return null;
    }
};

/// Error set raised while writing. `std.Io.Writer.Error` already covers a
/// failed underlying drain (e.g. allocation failure on an allocating
/// writer).
pub const WriteError = std.Io.Writer.Error;

/// Serialize `doc` as `<type>.asset.etch` text into `out`.
pub fn writeEtch(doc: AssetDoc, out: *std.Io.Writer) WriteError!void {
    try out.writeAll("asset ");
    try writeString(out, doc.name);
    try out.writeAll(" {\n  uuid: ");
    try writeString(out, doc.uuid);
    try out.print("\n  type: {s}\n", .{doc.type_name});
    try out.print("  version: {d}\n", .{doc.version});
    try out.writeAll("  source: ");
    try writeString(out, doc.source);
    try out.writeAll("\n  source_hash: ");
    try writeString(out, doc.source_hash);
    try out.writeAll("\n");
    try writeBlock(out, "import_settings", doc.import_settings);
    try writeBlock(out, "process_settings", doc.process_settings);
    try writeBlock(out, "cook_settings", doc.cook_settings);
    try writeBlock(out, "extracted", doc.extracted);
    try out.writeAll("}\n");
}

/// Serialize `doc` into a freshly allocated, caller-owned byte slice.
pub fn writeAlloc(gpa: std.mem.Allocator, doc: AssetDoc) error{OutOfMemory}![]u8 {
    var aw = std.Io.Writer.Allocating.init(gpa);
    errdefer aw.deinit();
    writeEtch(doc, &aw.writer) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

fn writeBlock(out: *std.Io.Writer, name: []const u8, fields: []const Field) WriteError!void {
    try out.print("  {s}: {{\n", .{name});
    for (fields) |f| {
        try out.print("    {s}: ", .{f.key});
        try writeValue(out, f.value, 2);
        try out.writeAll("\n");
    }
    try out.writeAll("  }\n");
}

fn writeIndent(out: *std.Io.Writer, depth: usize) WriteError!void {
    var i: usize = 0;
    while (i < depth) : (i += 1) try out.writeAll("  ");
}

fn writeValue(out: *std.Io.Writer, v: Value, depth: usize) WriteError!void {
    switch (v) {
        .int => |i| try out.print("{d}", .{i}),
        .float => |f| try writeFloat(out, f),
        .boolean => |b| try out.writeAll(if (b) "true" else "false"),
        .string => |s| try writeString(out, s),
        .identifier => |s| try out.writeAll(s),
        .enum_literal => |s| try out.print(".{s}", .{s}),
        .array => |items| {
            try out.writeAll("[");
            for (items, 0..) |it, i| {
                if (i != 0) try out.writeAll(", ");
                try writeValue(out, it, depth);
            }
            try out.writeAll("]");
        },
        .object => |fields| {
            try out.writeAll("{\n");
            for (fields) |f| {
                try writeIndent(out, depth + 1);
                try out.print("{s}: ", .{f.key});
                try writeValue(out, f.value, depth + 1);
                try out.writeAll("\n");
            }
            try writeIndent(out, depth);
            try out.writeAll("}");
        },
    }
}

/// Emit `s` as a string literal: `"`, `\\`, `{` and the line breaks escaped
/// (`etch-grammar.md` §1.4), so the reader returns the same bytes.
fn writeString(out: *std.Io.Writer, s: []const u8) WriteError!void {
    try out.writeAll("\"");
    for (s) |c| switch (c) {
        '"' => try out.writeAll("\\\""),
        '\\' => try out.writeAll("\\\\"),
        '{' => try out.writeAll("\\{"),
        '\n' => try out.writeAll("\\n"),
        '\t' => try out.writeAll("\\t"),
        '\r' => try out.writeAll("\\r"),
        else => try out.writeByte(c),
    };
    try out.writeAll("\"");
}

/// Emit a float with a guaranteed decimal point so the reader keeps it a
/// float (otherwise `1.0` would format as `1` and parse back as an int).
fn writeFloat(out: *std.Io.Writer, f: f64) WriteError!void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{f}) catch unreachable;
    try out.writeAll(s);
    // If the shortest form has no '.', exponent, or inf/nan letters, it
    // looks like an integer — append ".0" to preserve the float tag.
    if (std.mem.indexOfAny(u8, s, ".eEnN") == null) {
        try out.writeAll(".0");
    }
}

/// Error set raised while parsing.
pub const ParseError = error{
    /// Allocation failed.
    OutOfMemory,
    /// Hit end of input mid-construct.
    UnexpectedEnd,
    /// A character not valid at this position, or content after the construct.
    UnexpectedChar,
    /// The document does not start with the `asset` keyword.
    ExpectedAssetKeyword,
    /// A numeric literal failed to parse, overflows, or is not finite.
    InvalidNumber,
    /// The `version` field was absent, non-integer, or out of `u16` range.
    InvalidVersion,
    /// The document breaks the `engine-asset-pipeline.md` §3 schema: a fixed
    /// field or block missing, repeated, unknown or of the wrong kind, or a
    /// `uuid` / hash not in its canonical form.
    SchemaViolation,
};

/// Parse `<type>.asset.etch` text into an `AssetDoc`. Every owned slice is
/// allocated from `arena` (pass an arena and free it in one shot).
pub fn parseEtch(arena: std.mem.Allocator, src: []const u8) ParseError!AssetDoc {
    var p = Parser{ .src = src, .arena = arena };
    return p.parseDoc();
}

/// The `uuid` of an existing intermediate document, which a re-import keeps
/// (`engine-asset-pipeline.md` §3), or null when `text` is null: there is no
/// document yet. A document that does not parse is an error, never a reason to
/// mint another identity.
pub fn existingUuid(arena: std.mem.Allocator, text: ?[]const u8) ParseError!?[]const u8 {
    return (try parseEtch(arena, text orelse return null)).uuid;
}

const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    arena: std.mem.Allocator,

    fn isWs(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r';
    }
    fn isIdentStart(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
    }
    fn isIdentChar(c: u8) bool {
        return isIdentStart(c) or isDigit(c);
    }
    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    /// Skip whitespace and comments: `// …` to the end of the line, `/* … */`
    /// unnested (`etch-grammar.md` §1).
    fn skipWs(self: *Parser) ParseError!void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (isWs(c)) {
                self.pos += 1;
            } else if (std.mem.startsWith(u8, self.src[self.pos..], "//")) {
                self.pos = std.mem.indexOfScalarPos(u8, self.src, self.pos, '\n') orelse self.src.len;
            } else if (std.mem.startsWith(u8, self.src[self.pos..], "/*")) {
                const close = std.mem.indexOfPos(u8, self.src, self.pos + 2, "*/") orelse return error.UnexpectedEnd;
                self.pos = close + 2;
            } else return;
        }
    }

    fn peekNonWs(self: *Parser) ParseError!u8 {
        try self.skipWs();
        if (self.pos >= self.src.len) return error.UnexpectedEnd;
        return self.src[self.pos];
    }

    fn expect(self: *Parser, ch: u8) ParseError!void {
        if (try self.peekNonWs() != ch) return error.UnexpectedChar;
        self.pos += 1;
    }

    /// An `IDENT`. `true` and `false` are boolean literals, never identifiers.
    fn parseIdent(self: *Parser) ParseError![]const u8 {
        try self.skipWs();
        const start = self.pos;
        if (self.pos >= self.src.len or !isIdentStart(self.src[self.pos])) return error.UnexpectedChar;
        self.pos += 1;
        while (self.pos < self.src.len and isIdentChar(self.src[self.pos])) : (self.pos += 1) {}
        const id = self.src[start..self.pos];
        if (std.mem.eql(u8, id, "true") or std.mem.eql(u8, id, "false")) return error.UnexpectedChar;
        return self.arena.dupe(u8, id);
    }

    /// A string literal, simple or triple-quoted (`etch-grammar.md` §1.4), with
    /// its escapes decoded. An unescaped `{` would open an interpolation, which
    /// a data value has no meaning for, and a simple string does not span lines.
    fn parseString(self: *Parser) ParseError![]const u8 {
        try self.expect('"');
        if (std.mem.startsWith(u8, self.src[self.pos..], "\"\"")) {
            self.pos += 2;
            return self.parseTripleString();
        }
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            if (self.pos >= self.src.len) return error.UnexpectedEnd;
            const c = self.src[self.pos];
            self.pos += 1;
            switch (c) {
                '"' => return out.toOwnedSlice(self.arena),
                '\\' => try out.append(self.arena, try self.escaped()),
                '{', '\n' => return error.UnexpectedChar,
                else => try out.append(self.arena, c),
            }
        }
    }

    /// The body of a `"""…"""` literal, after its opening fence: escapes
    /// decoded and the common indentation of its non-blank lines removed.
    fn parseTripleString(self: *Parser) ParseError![]const u8 {
        const body_start = self.pos;
        const close = std.mem.indexOfPos(u8, self.src, body_start, "\"\"\"") orelse return error.UnexpectedEnd;
        const body = self.src[body_start..close];
        self.pos = close + 3;
        const indent = commonIndentOf(body);
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        var skip_left = indent;
        while (i < body.len) {
            const c = body[i];
            if (skip_left > 0 and (c == ' ' or c == '\t')) {
                skip_left -= 1;
                i += 1;
                continue;
            }
            skip_left = 0;
            switch (c) {
                '\\' => {
                    if (i + 1 >= body.len) return error.UnexpectedChar;
                    try out.append(self.arena, try escapeByte(body[i + 1]));
                    i += 2;
                },
                '{' => return error.UnexpectedChar,
                '\n' => {
                    try out.append(self.arena, '\n');
                    i += 1;
                    skip_left = indent;
                },
                else => {
                    try out.append(self.arena, c);
                    i += 1;
                },
            }
        }
        return out.toOwnedSlice(self.arena);
    }

    /// The common leading indentation (spaces and tabs) of the non-blank lines
    /// of `body`, as `etch-grammar.md` §1.4 strips it.
    fn commonIndentOf(body: []const u8) usize {
        var min: ?usize = null;
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |line| {
            var ws: usize = 0;
            while (ws < line.len and (line[ws] == ' ' or line[ws] == '\t')) : (ws += 1) {}
            if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
            min = if (min) |m| @min(m, ws) else ws;
        }
        return min orelse 0;
    }

    fn escaped(self: *Parser) ParseError!u8 {
        if (self.pos >= self.src.len) return error.UnexpectedEnd;
        const b = try escapeByte(self.src[self.pos]);
        self.pos += 1;
        return b;
    }

    /// The byte an escape sequence `\\c` denotes; `etch-grammar.md` §1.4 admits
    /// exactly six.
    fn escapeByte(c: u8) ParseError!u8 {
        return switch (c) {
            '"' => '"',
            '\\' => '\\',
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            '{' => '{',
            else => error.UnexpectedChar,
        };
    }

    /// `INT_LITERAL` or `FLOAT_LITERAL` (`etch-grammar.md` §1.4): an optional
    /// `-`, a digit, digits and `_`, and a fraction only where `.` is followed by
    /// a digit. No `+`, no exponent.
    fn parseNumber(self: *Parser) ParseError!Value {
        try self.skipWs();
        const start = self.pos;
        if (self.pos < self.src.len and self.src[self.pos] == '-') self.pos += 1;
        if (self.pos >= self.src.len or !isDigit(self.src[self.pos])) return error.InvalidNumber;
        self.skipDigits();
        var is_float = false;
        if (self.pos + 1 < self.src.len and self.src[self.pos] == '.' and isDigit(self.src[self.pos + 1])) {
            is_float = true;
            self.pos += 1;
            self.skipDigits();
        }
        var digits: std.ArrayList(u8) = .empty;
        for (self.src[start..self.pos]) |c| if (c != '_') try digits.append(self.arena, c);
        if (is_float) {
            const f = std.fmt.parseFloat(f64, digits.items) catch return error.InvalidNumber;
            if (!std.math.isFinite(f)) return error.InvalidNumber;
            return .{ .float = f };
        }
        return .{ .int = std.fmt.parseInt(i64, digits.items, 10) catch return error.InvalidNumber };
    }

    fn skipDigits(self: *Parser) void {
        while (self.pos < self.src.len and (isDigit(self.src[self.pos]) or self.src[self.pos] == '_')) : (self.pos += 1) {}
    }

    fn parseArray(self: *Parser) ParseError!Value {
        try self.expect('[');
        var items: std.ArrayList(Value) = .empty;
        while (true) {
            const c = try self.peekNonWs();
            if (c == ']') {
                self.pos += 1;
                break;
            }
            try items.append(self.arena, try self.parseValue());
            const d = try self.peekNonWs();
            if (d == ',') {
                self.pos += 1;
                continue;
            }
            if (d == ']') {
                self.pos += 1;
                break;
            }
            return error.UnexpectedChar;
        }
        return .{ .array = try items.toOwnedSlice(self.arena) };
    }

    fn parseObject(self: *Parser) ParseError!Value {
        return .{ .object = try self.parseFields() };
    }

    /// Parse a `{ key: value … }` block and return its fields:
    /// `asset_field = [ annotation ] , IDENT , ":" , asset_value , [ "," ]`.
    fn parseFields(self: *Parser) ParseError![]const Field {
        try self.expect('{');
        var fields: std.ArrayList(Field) = .empty;
        while (true) {
            const c = try self.peekNonWs();
            if (c == '}') {
                self.pos += 1;
                break;
            }
            if (c == '@') try self.skipAnnotation();
            const key = try self.parseIdent();
            try self.expect(':');
            const value = try self.parseValue();
            try fields.append(self.arena, .{ .key = key, .value = value });
            if (try self.peekNonWs() == ',') self.pos += 1;
        }
        return fields.toOwnedSlice(self.arena);
    }

    /// `annotation = "@" , IDENT , [ "(" , [ annotation_args ] , ")" ]`, with each
    /// argument an asset value, optionally named.
    fn skipAnnotation(self: *Parser) ParseError!void {
        try self.expect('@');
        _ = try self.parseIdent();
        if (try self.peekNonWs() != '(') return;
        self.pos += 1;
        while (true) {
            if (try self.peekNonWs() == ')') {
                self.pos += 1;
                return;
            }
            if (isIdentStart(self.src[self.pos])) {
                const save = self.pos;
                const ident_ok = if (self.parseIdent()) |_| true else |err| switch (err) {
                    error.UnexpectedChar => false,
                    else => return err,
                };
                if (!(ident_ok and try self.peekNonWs() == ':')) self.pos = save else self.pos += 1;
            }
            _ = try self.parseValue();
            const d = try self.peekNonWs();
            if (d == ',') {
                self.pos += 1;
            } else if (d != ')') return error.UnexpectedChar;
        }
    }

    fn parseValue(self: *Parser) ParseError!Value {
        const c = try self.peekNonWs();
        switch (c) {
            '"' => return .{ .string = try self.parseString() },
            '[' => return self.parseArray(),
            '{' => return self.parseObject(),
            '.' => {
                self.pos += 1; // consume '.'
                return .{ .enum_literal = try self.parseIdent() };
            },
            '-', '0'...'9' => return self.parseNumber(),
            else => {
                if (!isIdentStart(c)) return error.UnexpectedChar;
                if (self.boolLiteral()) |b| return .{ .boolean = b };
                return .{ .identifier = try self.parseIdent() };
            },
        }
    }

    /// Consumes `true` or `false` when it stands as a whole identifier.
    fn boolLiteral(self: *Parser) ?bool {
        const rest = self.src[self.pos..];
        inline for (.{ .{ "true", true }, .{ "false", false } }) |lit| {
            if (std.mem.startsWith(u8, rest, lit[0]) and (rest.len == lit[0].len or !isIdentChar(rest[lit[0].len]))) {
                self.pos += lit[0].len;
                return lit[1];
            }
        }
        return null;
    }

    fn parseDoc(self: *Parser) ParseError!AssetDoc {
        const keyword = self.parseIdent() catch return error.ExpectedAssetKeyword;
        if (!std.mem.eql(u8, keyword, "asset")) return error.ExpectedAssetKeyword;
        const name = try self.parseString();
        const fields = try self.parseFields();
        try self.skipWs();
        if (self.pos != self.src.len) return error.UnexpectedChar;

        var doc = AssetDoc{
            .name = name,
            .uuid = "",
            .type_name = "",
            .version = 0,
            .source = "",
            .source_hash = "",
        };
        const Fixed = enum { uuid, type, version, source, source_hash, import_settings, process_settings, cook_settings, extracted };
        var seen = std.EnumSet(Fixed).initEmpty();
        for (fields) |f| {
            const which = std.meta.stringToEnum(Fixed, f.key) orelse return error.SchemaViolation;
            if (seen.contains(which)) return error.SchemaViolation;
            seen.insert(which);
            switch (which) {
                .uuid => doc.uuid = try canonical(stringOf(f.value), isUuid),
                .type => doc.type_name = switch (f.value) {
                    .identifier => |s| s,
                    else => return error.SchemaViolation,
                },
                .version => doc.version = switch (f.value) {
                    .int => |i| std.math.cast(u16, i) orelse return error.InvalidVersion,
                    else => return error.InvalidVersion,
                },
                .source => doc.source = stringOf(f.value) orelse return error.SchemaViolation,
                .source_hash => doc.source_hash = try canonical(stringOf(f.value), isHash128),
                .import_settings => doc.import_settings = try objectOf(f.value),
                .process_settings => doc.process_settings = try objectOf(f.value),
                .cook_settings => doc.cook_settings = try objectOf(f.value),
                .extracted => doc.extracted = try objectOf(f.value),
            }
        }
        if (!seen.eql(std.EnumSet(Fixed).initFull())) return error.SchemaViolation;
        _ = try canonical(doc.blobHash(), isHash128);
        return doc;
    }

    fn stringOf(v: Value) ?[]const u8 {
        return switch (v) {
            .string => |s| s,
            else => null,
        };
    }

    fn objectOf(v: Value) ParseError![]const Field {
        return switch (v) {
            .object => |o| o,
            else => error.SchemaViolation,
        };
    }

    /// `s` when present and of the canonical form `form` checks.
    fn canonical(s: ?[]const u8, comptime form: fn ([]const u8) bool) ParseError![]const u8 {
        const v = s orelse return error.SchemaViolation;
        if (!form(v)) return error.SchemaViolation;
        return v;
    }

    /// A UUID in its canonical `8-4-4-4-12` lowercase hexadecimal form.
    fn isUuid(s: []const u8) bool {
        if (s.len != 36) return false;
        for (s, 0..) |c, i| {
            const dash = i == 8 or i == 13 or i == 18 or i == 23;
            if (dash != (c == '-')) return false;
            if (!dash and !isLowerHex(c)) return false;
        }
        return true;
    }

    /// A 128-bit hash as 32 lowercase hexadecimal digits.
    fn isHash128(s: []const u8) bool {
        if (s.len != 32) return false;
        for (s) |c| if (!isLowerHex(c)) return false;
        return true;
    }

    fn isLowerHex(c: u8) bool {
        return isDigit(c) or (c >= 'a' and c <= 'f');
    }
};

test "intermediate doc round-trips through etch text" {
    const gpa = std.testing.allocator;

    const min_arr = [_]Value{ .{ .float = -1.0 }, .{ .float = -1.0 }, .{ .float = -1.0 } };
    const max_arr = [_]Value{ .{ .float = 1.0 }, .{ .float = 1.0 }, .{ .float = 1.0 } };
    const bounds = [_]Field{
        .{ .key = "min", .value = .{ .array = &min_arr } },
        .{ .key = "max", .value = .{ .array = &max_arr } },
    };
    const materials = [_]Value{ .{ .string = "body" }, .{ .string = "trim" } };

    const import_settings = [_]Field{
        .{ .key = "scale", .value = .{ .float = 1.0 } },
        .{ .key = "axis_conversion", .value = .{ .enum_literal = "gltf_to_weld" } },
    };
    const process_settings = [_]Field{
        .{ .key = "generate_lods", .value = .{ .boolean = false } },
    };
    const pc_cook = [_]Field{
        .{ .key = "vertex_format", .value = .{ .enum_literal = "compressed" } },
    };
    const cook_settings = [_]Field{
        .{ .key = "pc", .value = .{ .object = &pc_cook } }, // per-platform sub-block
    };
    const extracted = [_]Field{
        .{ .key = "vertex_count", .value = .{ .int = 24 } },
        .{ .key = "bounds", .value = .{ .object = &bounds } },
        .{ .key = "materials", .value = .{ .array = &materials } },
        .{ .key = "blob", .value = .{ .string = "a3f2b1c98d0011223344556677889900" } }, // mandatory
    };

    const original = AssetDoc{
        .name = "cube_mesh",
        .uuid = "0190b3f0-1c2d-7e4a-8b6c-0123456789ab",
        .type_name = "StaticMesh",
        .version = 1,
        .source = "cube.gltf",
        .source_hash = "abc12300112233445566778899aabbcc",
        .import_settings = &import_settings,
        .process_settings = &process_settings,
        .cook_settings = &cook_settings,
        .extracted = &extracted,
    };

    const text = try writeAlloc(gpa, original);
    defer gpa.free(text);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const parsed = try parseEtch(arena.allocator(), text);

    try std.testing.expect(original.eql(parsed));
    try std.testing.expectEqualStrings("0190b3f0-1c2d-7e4a-8b6c-0123456789ab", parsed.uuid);
    try std.testing.expectEqualStrings("StaticMesh", parsed.type_name);
    try std.testing.expectEqual(@as(u16, 1), parsed.version);
    try std.testing.expectEqual(@as(usize, 4), parsed.extracted.len);
    try std.testing.expectEqual(@as(usize, 1), parsed.cook_settings.len);
    try std.testing.expectEqualStrings("a3f2b1c98d0011223344556677889900", original.blobHash().?);
    try std.testing.expectEqualStrings("a3f2b1c98d0011223344556677889900", parsed.blobHash().?);
    // Field accessors used by the cookers.
    try std.testing.expectEqual(@as(i64, 24), fieldInt(parsed.extracted, "vertex_count").?);
    try std.testing.expectEqualStrings("a3f2b1c98d0011223344556677889900", fieldStr(parsed.extracted, "blob").?);
    try std.testing.expectEqual(@as(?i64, null), fieldInt(parsed.extracted, "bounds")); // not an int
}

test "intermediate writer emits a valid asset construct shape" {
    const gpa = std.testing.allocator;
    const import_settings = [_]Field{
        .{ .key = "srgb", .value = .{ .boolean = true } },
        .{ .key = "max_resolution", .value = .{ .int = 4096 } },
    };
    const doc = AssetDoc{
        .name = "hero_albedo",
        .type_name = "Texture2D",
        .version = 1,
        .source = "hero_albedo.png",
        .source_hash = "7b3e2f1a",
        .import_settings = &import_settings,
    };
    const text = try writeAlloc(gpa, doc);
    defer gpa.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "asset \"hero_albedo\" {") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "type: Texture2D") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "version: 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "srgb: true") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "max_resolution: 4096") != null);
}

test "intermediate float keeps its decimal point through a round-trip" {
    const gpa = std.testing.allocator;
    const import_settings = [_]Field{
        .{ .key = "scale", .value = .{ .float = 1.0 } },
    };
    const extracted = [_]Field{.{ .key = "blob", .value = .{ .string = "00112233445566778899aabbccddeeff" } }};
    const doc = AssetDoc{
        .name = "x",
        .uuid = "0190b3f0-1c2d-7e4a-8b6c-0123456789ab",
        .type_name = "Texture2D",
        .version = 1,
        .source = "x.png",
        .source_hash = "00112233445566778899aabbccddeeff",
        .import_settings = &import_settings,
        .extracted = &extracted,
    };
    const text = try writeAlloc(gpa, doc);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "scale: 1.0") != null);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const parsed = try parseEtch(arena.allocator(), text);
    try std.testing.expectEqual(Value{ .float = 1.0 }, parsed.import_settings[0].value);
}

test "intermediate parse rejects input without the asset keyword" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.ExpectedAssetKeyword, parseEtch(arena.allocator(), "widget \"x\" {}"));
}

/// A canonical document, one line per field, for the reader tests to vary.
const minimal_doc =
    \\asset "a" {
    \\  uuid: "0190b3f0-1c2d-7e4a-8b6c-0123456789ab"
    \\  type: StaticMesh
    \\  version: 1
    \\  source: "a.gltf"
    \\  source_hash: "00112233445566778899aabbccddeeff"
    \\  import_settings: { }
    \\  process_settings: { }
    \\  cook_settings: { }
    \\  extracted: { blob: "00112233445566778899aabbccddeeff" }
    \\}
    \\
;

/// Parses `src` into a fresh arena and returns the parse result.
fn parseText(arena: *std.heap.ArenaAllocator, src: []const u8) ParseError!AssetDoc {
    return parseEtch(arena.allocator(), src);
}

/// `minimal_doc` with the text of `old` replaced by `new`.
fn variant(arena: *std.heap.ArenaAllocator, old: []const u8, new: []const u8) ![]const u8 {
    const out = try std.mem.replaceOwned(u8, arena.allocator(), minimal_doc, old, new);
    try std.testing.expect(!std.mem.eql(u8, out, minimal_doc));
    return out;
}

test "the canonical document parses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = try parseText(&arena, minimal_doc);
}

test "a comma between fields is accepted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = try variant(&arena, "  import_settings: { }", "  import_settings: { a: 1, b: 2, },");
    const doc = try parseText(&arena, src);
    try std.testing.expectEqual(@as(usize, 2), doc.import_settings.len);
}

test "an annotation on a field is accepted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = try variant(&arena, "  process_settings: { }", "  process_settings: { @unit(.meters) min_fragment_size: 0.05 }");
    const doc = try parseText(&arena, src);
    try std.testing.expectEqualStrings("min_fragment_size", doc.process_settings[0].key);
}

test "comments are accepted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = try variant(&arena, "  cook_settings: { }", "  // per platform\n  cook_settings: { /* none yet */ }");
    _ = try parseText(&arena, src);
}

test "a string with escapes round-trips through the writer" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const base = try parseText(&arena, minimal_doc);
    var doc = base;
    doc.source = "dir\\a \"b\" {c}\nd";
    const text = try writeAlloc(gpa, doc);
    defer gpa.free(text);
    const back = try parseText(&arena, text);
    try std.testing.expectEqualStrings(doc.source, back.source);
}

test "an unknown escape is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnexpectedChar, parseText(&arena, try variant(&arena, "\"a.gltf\"", "\"a\\q.gltf\"")));
}

test "an unescaped brace in a string is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnexpectedChar, parseText(&arena, try variant(&arena, "\"a.gltf\"", "\"a{1}.gltf\"")));
}

test "a triple-quoted string loses its common indentation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = try variant(&arena, "  import_settings: { }", "  import_settings: { note: \"\"\"\n    one\n      two\n    \"\"\" }");
    const doc = try parseText(&arena, src);
    try std.testing.expectEqualStrings("\none\n  two\n", doc.import_settings[0].value.string);
}

test "digit separators are accepted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try parseText(&arena, try variant(&arena, "  import_settings: { }", "  import_settings: { n: 1_000_, f: 1_0.2_5 }"));
    try std.testing.expectEqual(@as(i64, 1000), doc.import_settings[0].value.int);
    try std.testing.expectEqual(@as(f64, 10.25), doc.import_settings[1].value.float);
}

test "a numeric form outside the grammar is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "+5", "1e5", "1.", ".5x", "1" ++ "0" ** 400 ++ ".0", "9223372036854775808" }) |n| {
        const field = try std.fmt.allocPrint(arena.allocator(), "  import_settings: {{ n: {s} }}", .{n});
        if (parseText(&arena, try variant(&arena, "  import_settings: { }", field))) |_| {
            std.debug.print("accepted: {s}\n", .{n});
            return error.TestExpectedError;
        } else |_| {}
    }
}

test "content after the construct is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnexpectedChar, parseText(&arena, minimal_doc ++ "junk\n"));
}

test "a boolean literal is not a field name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnexpectedChar, parseText(&arena, try variant(&arena, "  import_settings: { }", "  import_settings: { true: 1 }")));
}

test "a string asset type is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.SchemaViolation, parseText(&arena, try variant(&arena, "type: StaticMesh", "type: \"StaticMesh\"")));
}

test "a missing fixed field is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.SchemaViolation, parseText(&arena, try variant(&arena, "  source: \"a.gltf\"\n", "")));
}

test "a repeated fixed field is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.SchemaViolation, parseText(&arena, try variant(&arena, "  source: \"a.gltf\"", "  source: \"a.gltf\"\n  source: \"b.gltf\"")));
}

test "an unknown top-level field is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.SchemaViolation, parseText(&arena, try variant(&arena, "  version: 1", "  version: 1\n  extra: 2")));
}

test "a uuid not in canonical form is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.SchemaViolation, parseText(&arena, try variant(&arena, "0190b3f0-1c2d-7e4a-8b6c-0123456789ab", "not-a-uuid")));
}

test "an extracted block without its blob is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.SchemaViolation, parseText(&arena, try variant(&arena, "extracted: { blob: \"00112233445566778899aabbccddeeff\" }", "extracted: { }")));
}

test "an existing document keeps its uuid, and none yields none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(?[]const u8, null), try existingUuid(arena.allocator(), null));
    try std.testing.expectEqualStrings("0190b3f0-1c2d-7e4a-8b6c-0123456789ab", (try existingUuid(arena.allocator(), minimal_doc)).?);
}

test "an existing document that does not parse is an error, not a new identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnexpectedChar, existingUuid(arena.allocator(), minimal_doc ++ "junk"));
}
