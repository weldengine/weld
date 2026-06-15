//! FROZEN — see engine-phase-0-criteria.md C0.5 (M0.9)
//!
//! Intermediate `<type>.asset.etch` document model + a minimal Etch-syntax
//! reader/writer.
//!
//! The on-disk text is the frozen surface (M0.6): a single top-level
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
//! This ad-hoc reader/writer avoids a `weld_etch` dependency in M0.6 (the
//! full Etch parser is M0.8). It covers exactly the §21.4 value grammar
//! minus `@unit(...)` annotations, which the writer does not emit in M0.6
//! (additive Phase 1). The on-disk text is the frozen contract, not this
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
/// what it needs (M0.6: texture / mesh / audio).
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
    try out.print("asset \"{s}\" {{\n", .{doc.name});
    try out.print("  uuid: \"{s}\"\n", .{doc.uuid});
    try out.print("  type: {s}\n", .{doc.type_name});
    try out.print("  version: {d}\n", .{doc.version});
    try out.print("  source: \"{s}\"\n", .{doc.source});
    try out.print("  source_hash: \"{s}\"\n", .{doc.source_hash});
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
        .string => |s| try out.print("\"{s}\"", .{s}),
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
    /// A character not valid at this position.
    UnexpectedChar,
    /// The document does not start with the `asset` keyword.
    ExpectedAssetKeyword,
    /// A numeric literal failed to parse.
    InvalidNumber,
    /// The `version` field was absent, non-integer, or out of `u16` range.
    InvalidVersion,
};

/// Parse `<type>.asset.etch` text into an `AssetDoc`. Every owned slice is
/// allocated from `arena` (pass an arena and free it in one shot).
pub fn parseEtch(arena: std.mem.Allocator, src: []const u8) ParseError!AssetDoc {
    var p = Parser{ .src = src, .arena = arena };
    return p.parseDoc();
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
        return isIdentStart(c) or (c >= '0' and c <= '9');
    }

    fn skipWs(self: *Parser) void {
        while (self.pos < self.src.len and isWs(self.src[self.pos])) : (self.pos += 1) {}
    }

    fn peekNonWs(self: *Parser) ParseError!u8 {
        self.skipWs();
        if (self.pos >= self.src.len) return error.UnexpectedEnd;
        return self.src[self.pos];
    }

    fn expect(self: *Parser, ch: u8) ParseError!void {
        self.skipWs();
        if (self.pos >= self.src.len) return error.UnexpectedEnd;
        if (self.src[self.pos] != ch) return error.UnexpectedChar;
        self.pos += 1;
    }

    fn parseIdent(self: *Parser) ParseError![]const u8 {
        self.skipWs();
        const start = self.pos;
        if (self.pos >= self.src.len or !isIdentStart(self.src[self.pos])) return error.UnexpectedChar;
        self.pos += 1;
        while (self.pos < self.src.len and isIdentChar(self.src[self.pos])) : (self.pos += 1) {}
        return self.arena.dupe(u8, self.src[start..self.pos]);
    }

    fn parseString(self: *Parser) ParseError![]const u8 {
        try self.expect('"');
        const start = self.pos;
        while (self.pos < self.src.len and self.src[self.pos] != '"') : (self.pos += 1) {}
        if (self.pos >= self.src.len) return error.UnexpectedEnd;
        const inner = self.src[start..self.pos];
        self.pos += 1; // consume closing quote
        return self.arena.dupe(u8, inner);
    }

    fn parseNumber(self: *Parser) ParseError!Value {
        self.skipWs();
        const start = self.pos;
        if (self.pos < self.src.len and (self.src[self.pos] == '-' or self.src[self.pos] == '+')) {
            self.pos += 1;
        }
        var is_float = false;
        while (self.pos < self.src.len) : (self.pos += 1) {
            const ch = self.src[self.pos];
            if (ch >= '0' and ch <= '9') continue;
            if (ch == '.' or ch == 'e' or ch == 'E') {
                is_float = true;
                continue;
            }
            if ((ch == '+' or ch == '-') and self.pos > start) {
                const prev = self.src[self.pos - 1];
                if (prev == 'e' or prev == 'E') continue;
            }
            break;
        }
        const slice = self.src[start..self.pos];
        if (slice.len == 0) return error.InvalidNumber;
        if (is_float) {
            const f = std.fmt.parseFloat(f64, slice) catch return error.InvalidNumber;
            return .{ .float = f };
        }
        const i = std.fmt.parseInt(i64, slice, 10) catch return error.InvalidNumber;
        return .{ .int = i };
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

    /// Parse a `{ key: value … }` block and return its fields.
    fn parseFields(self: *Parser) ParseError![]const Field {
        try self.expect('{');
        var fields: std.ArrayList(Field) = .empty;
        while (true) {
            const c = try self.peekNonWs();
            if (c == '}') {
                self.pos += 1;
                break;
            }
            const key = try self.parseIdent();
            try self.expect(':');
            const value = try self.parseValue();
            try fields.append(self.arena, .{ .key = key, .value = value });
        }
        return fields.toOwnedSlice(self.arena);
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
            '-', '+', '0'...'9' => return self.parseNumber(),
            else => {
                if (!isIdentStart(c)) return error.UnexpectedChar;
                const id = try self.parseIdent();
                if (std.mem.eql(u8, id, "true")) return .{ .boolean = true };
                if (std.mem.eql(u8, id, "false")) return .{ .boolean = false };
                return .{ .identifier = id };
            },
        }
    }

    fn parseDoc(self: *Parser) ParseError!AssetDoc {
        const keyword = self.parseIdent() catch return error.ExpectedAssetKeyword;
        if (!std.mem.eql(u8, keyword, "asset")) return error.ExpectedAssetKeyword;
        const name = try self.parseString();
        const fields = try self.parseFields();

        var doc = AssetDoc{
            .name = name,
            .uuid = "",
            .type_name = "",
            .version = 0,
            .source = "",
            .source_hash = "",
        };
        for (fields) |f| {
            if (std.mem.eql(u8, f.key, "uuid")) {
                doc.uuid = switch (f.value) {
                    .string => |s| s,
                    else => return error.UnexpectedChar,
                };
            } else if (std.mem.eql(u8, f.key, "type")) {
                doc.type_name = switch (f.value) {
                    .identifier => |s| s,
                    .string => |s| s,
                    else => return error.UnexpectedChar,
                };
            } else if (std.mem.eql(u8, f.key, "version")) {
                doc.version = switch (f.value) {
                    .int => |i| std.math.cast(u16, i) orelse return error.InvalidVersion,
                    else => return error.InvalidVersion,
                };
            } else if (std.mem.eql(u8, f.key, "source")) {
                doc.source = switch (f.value) {
                    .string => |s| s,
                    else => return error.UnexpectedChar,
                };
            } else if (std.mem.eql(u8, f.key, "source_hash")) {
                doc.source_hash = switch (f.value) {
                    .string => |s| s,
                    else => return error.UnexpectedChar,
                };
            } else if (std.mem.eql(u8, f.key, "import_settings")) {
                doc.import_settings = switch (f.value) {
                    .object => |o| o,
                    else => return error.UnexpectedChar,
                };
            } else if (std.mem.eql(u8, f.key, "process_settings")) {
                doc.process_settings = switch (f.value) {
                    .object => |o| o,
                    else => return error.UnexpectedChar,
                };
            } else if (std.mem.eql(u8, f.key, "cook_settings")) {
                doc.cook_settings = switch (f.value) {
                    .object => |o| o,
                    else => return error.UnexpectedChar,
                };
            } else if (std.mem.eql(u8, f.key, "extracted")) {
                doc.extracted = switch (f.value) {
                    .object => |o| o,
                    else => return error.UnexpectedChar,
                };
            }
            // Unknown top-level keys are ignored (forward-compatibility).
        }
        return doc;
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
        .{ .key = "blob", .value = .{ .string = "a3f2b1c98d" } }, // mandatory
    };

    const original = AssetDoc{
        .name = "cube_mesh",
        .uuid = "0190b3f0-1c2d-7e4a-8b6c-0123456789ab",
        .type_name = "StaticMesh",
        .version = 1,
        .source = "cube.gltf",
        .source_hash = "abc123",
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
    try std.testing.expectEqualStrings("a3f2b1c98d", original.blobHash().?);
    try std.testing.expectEqualStrings("a3f2b1c98d", parsed.blobHash().?);
    // Field accessors used by the cookers.
    try std.testing.expectEqual(@as(i64, 24), fieldInt(parsed.extracted, "vertex_count").?);
    try std.testing.expectEqualStrings("a3f2b1c98d", fieldStr(parsed.extracted, "blob").?);
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
    const doc = AssetDoc{
        .name = "x",
        .type_name = "Texture2D",
        .version = 1,
        .source = "x.png",
        .source_hash = "0",
        .import_settings = &import_settings,
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
