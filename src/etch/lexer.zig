//! S3 Etch lexer — UTF-8 byte stream tokenizer producing the subset of
//! tokens listed in `briefs/S3-etch-parser-subset.md` Scope / Lexer.
//!
//! Behaviour summary:
//! - Identifiers and keywords are ASCII-only (per `etch-grammar.md` §1.2).
//! - String literals (simple-quote) accept arbitrary UTF-8 verbatim.
//! - Comments (`//`, `/* */`, `///`) are skipped; their byte spans are
//!   collected in `comment_spans` for future Phase 0.2 trivia attachment.
//! - Invalid UTF-8 emits an `error_utf8` token; the parser maps it to
//!   `E0001 ParseError`.
//! - Unknown Etch keywords outside the S3 subset are tokenised as
//!   `error_unknown_keyword`; parser raises `E0001` at the use site.

const std = @import("std");
const token = @import("token.zig");

const Token = token.Token;
const TokenKind = token.TokenKind;
const SourceSpan = token.SourceSpan;

/// Etch lexer — produces a stream of `Token`s and accumulates a
/// parallel slab of comment spans for the future `TriviaMap`
/// (Phase 0.2). Owns no heap memory beyond `comment_spans`.
pub const Lexer = struct {
    source: []const u8,
    pos: u32 = 0,
    /// Byte spans of every `//`, `/* */`, and `///` comment encountered.
    /// Not attached to AST nodes in S3 — kept as a parallel slab for
    /// Phase 0.2's `TriviaMap`.
    comment_spans: std.ArrayListUnmanaged(SourceSpan) = .empty,

    pub fn init(source: []const u8) Lexer {
        return .{ .source = source };
    }

    pub fn deinit(self: *Lexer, gpa: std.mem.Allocator) void {
        self.comment_spans.deinit(gpa);
    }

    /// Produce the next token. Comments and whitespace are skipped
    /// internally; `eof` is returned once the source is exhausted.
    pub fn next(self: *Lexer, gpa: std.mem.Allocator) !Token {
        while (true) {
            self.skipWhitespace();
            if (self.pos >= self.source.len) {
                return .{ .kind = .eof, .span = .{ .byte_start = @intCast(self.source.len), .byte_end = @intCast(self.source.len) } };
            }
            const start = self.pos;
            const c = self.source[self.pos];
            switch (c) {
                '/' => {
                    if (self.pos + 1 < self.source.len) {
                        const c2 = self.source[self.pos + 1];
                        if (c2 == '/') {
                            try self.skipLineComment(gpa);
                            continue;
                        }
                        if (c2 == '*') {
                            try self.skipBlockComment(gpa);
                            continue;
                        }
                    }
                    return self.singleOrCompound(start, .slash, .slash_eq);
                },
                '+' => return self.singleOrCompound(start, .plus, .plus_eq),
                '-' => return self.singleOrCompound(start, .minus, .minus_eq),
                '*' => return self.singleOrCompound(start, .star, .star_eq),
                '%' => return self.singleOrCompound(start, .percent, .percent_eq),
                '=' => return self.singleOrCompound(start, .eq, .eq_eq),
                '!' => {
                    self.pos += 1;
                    if (self.pos < self.source.len and self.source[self.pos] == '=') {
                        self.pos += 1;
                        return .{ .kind = .bang_eq, .span = .{ .byte_start = start, .byte_end = self.pos } };
                    }
                    // `!` postfix isn't in the S3 operator set — fall through to error.
                    return .{ .kind = .error_byte, .span = .{ .byte_start = start, .byte_end = self.pos } };
                },
                '<' => return self.singleOrCompound(start, .lt, .lt_eq),
                '>' => return self.singleOrCompound(start, .gt, .gt_eq),
                '(' => return self.consumeOne(.lparen),
                ')' => return self.consumeOne(.rparen),
                '{' => return self.consumeOne(.lbrace),
                '}' => return self.consumeOne(.rbrace),
                ':' => return self.consumeOne(.colon),
                ',' => return self.consumeOne(.comma),
                '.' => return self.consumeOne(.dot),
                '@' => return self.consumeOne(.at),
                '"' => return self.lexString(start),
                '0'...'9' => return self.lexNumber(start),
                'a'...'z', 'A'...'Z', '_' => return self.lexIdent(start),
                else => {
                    // Anything else is either invalid UTF-8 (continuation
                    // byte without leader, or malformed sequence) or a
                    // byte outside the S3 lexicon. Either way: error
                    // token covering exactly one byte (or the full bad
                    // UTF-8 run). The parser will surface `E0001`.
                    if (c < 0x80) {
                        self.pos += 1;
                        return .{ .kind = .error_byte, .span = .{ .byte_start = start, .byte_end = self.pos } };
                    }
                    return self.lexUtf8(start);
                },
            }
        }
    }

    fn consumeOne(self: *Lexer, kind: TokenKind) Token {
        const start = self.pos;
        self.pos += 1;
        return .{ .kind = kind, .span = .{ .byte_start = start, .byte_end = self.pos } };
    }

    fn singleOrCompound(self: *Lexer, start: u32, single: TokenKind, compound: TokenKind) Token {
        self.pos += 1;
        if (self.pos < self.source.len and self.source[self.pos] == '=') {
            self.pos += 1;
            return .{ .kind = compound, .span = .{ .byte_start = start, .byte_end = self.pos } };
        }
        return .{ .kind = single, .span = .{ .byte_start = start, .byte_end = self.pos } };
    }

    fn skipWhitespace(self: *Lexer) void {
        while (self.pos < self.source.len) : (self.pos += 1) {
            const c = self.source[self.pos];
            if (c != ' ' and c != '\t' and c != '\n' and c != '\r') return;
        }
    }

    fn skipLineComment(self: *Lexer, gpa: std.mem.Allocator) !void {
        const start = self.pos;
        // Either `//` or `///` (doc comment). The brief lexes `///` as a
        // regular comment in S3 (doc-comments map deferred Phase 0.2).
        self.pos += 2;
        while (self.pos < self.source.len and self.source[self.pos] != '\n') : (self.pos += 1) {}
        try self.comment_spans.append(gpa, .{ .byte_start = start, .byte_end = self.pos });
    }

    fn skipBlockComment(self: *Lexer, gpa: std.mem.Allocator) !void {
        const start = self.pos;
        self.pos += 2;
        while (self.pos + 1 < self.source.len) {
            if (self.source[self.pos] == '*' and self.source[self.pos + 1] == '/') {
                self.pos += 2;
                try self.comment_spans.append(gpa, .{ .byte_start = start, .byte_end = self.pos });
                return;
            }
            self.pos += 1;
        }
        // Unterminated — consume to EOF; parser will see the truncation
        // via the next non-whitespace token (typically `eof`).
        self.pos = @intCast(self.source.len);
        try self.comment_spans.append(gpa, .{ .byte_start = start, .byte_end = self.pos });
    }

    fn lexIdent(self: *Lexer, start: u32) Token {
        self.pos += 1;
        while (self.pos < self.source.len) : (self.pos += 1) {
            const c = self.source[self.pos];
            const is_alnum = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
            if (!is_alnum) break;
        }
        const lexeme = self.source[start..self.pos];
        const span: SourceSpan = .{ .byte_start = start, .byte_end = self.pos };

        // Keyword lookup (S3 subset first).
        for (token.s3_keywords) |kw| {
            if (std.mem.eql(u8, kw.lexeme, lexeme)) {
                return .{ .kind = kw.kind, .span = span };
            }
        }
        // Then the Etch keyword reserve list (yields `error_unknown_keyword`).
        for (token.non_s3_keywords) |kw| {
            if (std.mem.eql(u8, kw, lexeme)) {
                return .{ .kind = .error_unknown_keyword, .span = span };
            }
        }
        // Otherwise it's a regular identifier — case-disambiguated.
        const first = self.source[start];
        const kind: TokenKind = if (first >= 'A' and first <= 'Z') .type_ident else .ident;
        return .{ .kind = kind, .span = span };
    }

    fn lexNumber(self: *Lexer, start: u32) Token {
        // Consume integer part.
        while (self.pos < self.source.len) : (self.pos += 1) {
            const c = self.source[self.pos];
            if (!((c >= '0' and c <= '9') or c == '_')) break;
        }
        // Optional fractional part: only if `.` is followed by a digit.
        // `42.field` must lex as INT + DOT + IDENT, not FLOAT.
        var is_float = false;
        if (self.pos + 1 < self.source.len and self.source[self.pos] == '.') {
            const after_dot = self.source[self.pos + 1];
            if (after_dot >= '0' and after_dot <= '9') {
                is_float = true;
                self.pos += 1; // dot
                while (self.pos < self.source.len) : (self.pos += 1) {
                    const c = self.source[self.pos];
                    if (!((c >= '0' and c <= '9') or c == '_')) break;
                }
            }
        }
        return .{
            .kind = if (is_float) .float_literal else .int_literal,
            .span = .{ .byte_start = start, .byte_end = self.pos },
        };
    }

    fn lexString(self: *Lexer, start: u32) Token {
        self.pos += 1; // opening quote
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '"') {
                self.pos += 1;
                return .{ .kind = .string_literal, .span = .{ .byte_start = start, .byte_end = self.pos } };
            }
            if (c == '\\') {
                self.pos += 1;
                if (self.pos < self.source.len) self.pos += 1;
                continue;
            }
            if (c == '\n') break; // unterminated single-quote string
            // Validate UTF-8 byte-by-byte: arbitrary continuation bytes are
            // allowed inside the literal but a malformed sequence still
            // surfaces as an error token via lexUtf8 from the outer loop.
            // For S3 we accept all non-newline bytes verbatim inside the
            // string literal — explicit UTF-8 validation is only enforced
            // outside string literals (per brief).
            self.pos += 1;
        }
        // Unterminated string: surface as error_byte at the opening quote.
        return .{ .kind = .error_byte, .span = .{ .byte_start = start, .byte_end = self.pos } };
    }

    fn lexUtf8(self: *Lexer, start: u32) Token {
        const c = self.source[start];
        // Determine expected continuation count from leading byte.
        const expected_len: u8 = if ((c & 0b1110_0000) == 0b1100_0000) 2 else if ((c & 0b1111_0000) == 0b1110_0000) 3 else if ((c & 0b1111_1000) == 0b1111_0000) 4 else 0;
        if (expected_len == 0) {
            // Stray continuation byte or invalid leader.
            self.pos += 1;
            return .{ .kind = .error_utf8, .span = .{ .byte_start = start, .byte_end = self.pos } };
        }
        if (start + expected_len > self.source.len) {
            self.pos = @intCast(self.source.len);
            return .{ .kind = .error_utf8, .span = .{ .byte_start = start, .byte_end = self.pos } };
        }
        // Validate continuation bytes.
        var i: u8 = 1;
        while (i < expected_len) : (i += 1) {
            if ((self.source[start + i] & 0b1100_0000) != 0b1000_0000) {
                self.pos = start + i;
                return .{ .kind = .error_utf8, .span = .{ .byte_start = start, .byte_end = self.pos } };
            }
        }
        // UTF-8 outside an identifier / string literal isn't part of the
        // S3 lexicon (identifiers ASCII-only, no character literals). It's
        // an error token regardless.
        self.pos = start + expected_len;
        return .{ .kind = .error_utf8, .span = .{ .byte_start = start, .byte_end = self.pos } };
    }
};

// ──────────────────────────── tests ─────────────────────────────────────

test "lexer tokenizes minimal component declaration" {
    const gpa = std.testing.allocator;
    var lex = Lexer.init("component Health { current: float }");
    defer lex.deinit(gpa);

    try expectKind(&lex, gpa, .kw_component);
    try expectKind(&lex, gpa, .type_ident); // Health
    try expectKind(&lex, gpa, .lbrace);
    try expectKind(&lex, gpa, .ident); // current
    try expectKind(&lex, gpa, .colon);
    try expectKind(&lex, gpa, .kw_float);
    try expectKind(&lex, gpa, .rbrace);
    try expectKind(&lex, gpa, .eof);
}

test "lexer skips line and block comments, records spans in comment_spans" {
    const gpa = std.testing.allocator;
    const src = "// header\nlet x = 1 /* inline */ // trailing\n";
    var lex = Lexer.init(src);
    defer lex.deinit(gpa);

    try expectKind(&lex, gpa, .kw_let);
    try expectKind(&lex, gpa, .ident);
    try expectKind(&lex, gpa, .eq);
    try expectKind(&lex, gpa, .int_literal);
    try expectKind(&lex, gpa, .eof);
    try std.testing.expectEqual(@as(usize, 3), lex.comment_spans.items.len);
    // First comment: spans the `// header` exactly.
    try std.testing.expectEqualStrings("// header", src[lex.comment_spans.items[0].byte_start..lex.comment_spans.items[0].byte_end]);
}

test "lexer skips triple-slash doc comments like line comments" {
    const gpa = std.testing.allocator;
    var lex = Lexer.init("/// doc\nlet x = 1");
    defer lex.deinit(gpa);
    try expectKind(&lex, gpa, .kw_let);
    try expectKind(&lex, gpa, .ident);
    try expectKind(&lex, gpa, .eq);
    try expectKind(&lex, gpa, .int_literal);
    try expectKind(&lex, gpa, .eof);
    try std.testing.expectEqual(@as(usize, 1), lex.comment_spans.items.len);
}

test "lexer rejects invalid UTF-8 with error_utf8" {
    const gpa = std.testing.allocator;
    // 0xC3 0x28 — invalid two-byte sequence (continuation byte missing).
    const src = [_]u8{ 0xC3, 0x28 };
    var lex = Lexer.init(&src);
    defer lex.deinit(gpa);
    const t = try lex.next(gpa);
    try std.testing.expectEqual(TokenKind.error_utf8, t.kind);
}

test "lexer disambiguates integer vs float literal" {
    const gpa = std.testing.allocator;
    var lex = Lexer.init("42 42.0 4.2 0.5");
    defer lex.deinit(gpa);
    try expectKind(&lex, gpa, .int_literal);
    try expectKind(&lex, gpa, .float_literal);
    try expectKind(&lex, gpa, .float_literal);
    try expectKind(&lex, gpa, .float_literal);
    try expectKind(&lex, gpa, .eof);
}

test "lexer flags unknown Etch keyword from full grammar as error_unknown_keyword" {
    const gpa = std.testing.allocator;
    var lex = Lexer.init("fn enum behavior");
    defer lex.deinit(gpa);
    try expectKind(&lex, gpa, .error_unknown_keyword);
    try expectKind(&lex, gpa, .error_unknown_keyword);
    try expectKind(&lex, gpa, .error_unknown_keyword);
}

test "lexer handles compound operators and keywords" {
    const gpa = std.testing.allocator;
    var lex = Lexer.init("a += b == c <= d and e or f not g");
    defer lex.deinit(gpa);
    try expectKind(&lex, gpa, .ident);
    try expectKind(&lex, gpa, .plus_eq);
    try expectKind(&lex, gpa, .ident);
    try expectKind(&lex, gpa, .eq_eq);
    try expectKind(&lex, gpa, .ident);
    try expectKind(&lex, gpa, .lt_eq);
    try expectKind(&lex, gpa, .ident);
    try expectKind(&lex, gpa, .kw_and);
    try expectKind(&lex, gpa, .ident);
    try expectKind(&lex, gpa, .kw_or);
    try expectKind(&lex, gpa, .ident);
    try expectKind(&lex, gpa, .kw_not);
    try expectKind(&lex, gpa, .ident);
}

test "lexer disambiguates integer followed by dot-field-access" {
    const gpa = std.testing.allocator;
    var lex = Lexer.init("42.x");
    defer lex.deinit(gpa);
    try expectKind(&lex, gpa, .int_literal);
    try expectKind(&lex, gpa, .dot);
    try expectKind(&lex, gpa, .ident);
}

test "lexer accepts string literal with arbitrary UTF-8 inside" {
    const gpa = std.testing.allocator;
    // String contains a multi-byte UTF-8 codepoint (é = 0xC3 0xA9).
    const src = "\"café\"";
    var lex = Lexer.init(src);
    defer lex.deinit(gpa);
    const t = try lex.next(gpa);
    try std.testing.expectEqual(TokenKind.string_literal, t.kind);
    try expectKind(&lex, gpa, .eof);
}

fn expectKind(lex: *Lexer, gpa: std.mem.Allocator, kind: TokenKind) !void {
    const t = try lex.next(gpa);
    try std.testing.expectEqual(kind, t.kind);
}
