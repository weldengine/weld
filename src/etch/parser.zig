//! S3 Etch parser — recursive descent for declarations, statements and
//! `when` clauses; Pratt parsing for binary expressions using the
//! precedence table from `etch-grammar.md` §3.1 restricted to the S3
//! operator set (all left-associative).
//!
//! Produces an `AstArena` directly (no intermediate CST). On the first
//! parse error the parser stops; the returned AST contains a best-effort
//! partial result so subsequent type-checking can run on declarations
//! parsed before the error (cf. `briefs/S3-etch-parser-subset.md` Scope).

const std = @import("std");
const token_mod = @import("token.zig");
const ast_mod = @import("ast.zig");
const diag_mod = @import("diagnostics.zig");
const lexer_mod = @import("lexer.zig");

const Token = token_mod.Token;
const TokenKind = token_mod.TokenKind;
const SourceSpan = token_mod.SourceSpan;
const AstArena = ast_mod.AstArena;
const NodeId = ast_mod.NodeId;
const NodeCategory = ast_mod.NodeCategory;
const StringId = ast_mod.StringId;
const Diagnostic = diag_mod.Diagnostic;
const DiagnosticCode = diag_mod.DiagnosticCode;
const Lexer = lexer_mod.Lexer;

/// Returned by `parse` — `ParseError` is the recoverable variant
/// (the diagnostic is on the result struct), `OutOfMemory` is fatal
/// for the caller's arena.
pub const ParseError = error{ ParseError, OutOfMemory };

/// Container returned by `parse` — the populated arena plus the list of
/// diagnostics collected during the parse. With the M0.8 top-level
/// recovery sync-point the parser no longer stops at the first error:
/// after a diagnostic it advances to the next top-level keyword (or EOF)
/// and resumes, so a file with several broken constructs yields one
/// diagnostic per broken construct while the sane constructs still land
/// in the AST. An empty slice means a clean parse.
///
/// Ownership: the result owns both the arena and the diagnostics slice
/// (each `Diagnostic` owns its `primary_message`). Call `deinit` to free
/// everything, or move `ast` / `diagnostics` out and free them yourself.
pub const ParseResult = struct {
    ast: AstArena,
    diagnostics: []Diagnostic,

    /// Free the arena and every diagnostic plus the backing slice.
    pub fn deinit(self: *ParseResult, gpa: std.mem.Allocator) void {
        for (self.diagnostics) |*d| d.deinit(gpa);
        gpa.free(self.diagnostics);
        self.ast.deinit(gpa);
    }
};

/// Entry point for the Etch parser. Lexes `source`, builds the
/// tabular SoA `AstArena`, and returns it together with an optional
/// first-error `Diagnostic`. Caller owns the arena and must call
/// `result.ast.deinit(gpa)`.
pub fn parse(gpa: std.mem.Allocator, source: []const u8) !ParseResult {
    var lexer = Lexer.init(source);
    // Without this `errdefer`, an OOM coming from `lexer.next` or
    // `parser.parseFile` after the lexer has already appended a comment
    // span would leak the `Lexer.comment_spans` slab. The explicit
    // `lexer.deinit(gpa)` call on the value-return path still fires
    // (errdefer does not run on value returns).
    errdefer lexer.deinit(gpa);
    var arena = try AstArena.init(gpa);
    errdefer arena.deinit(gpa);

    const c0 = try lexer.next(gpa);
    const c1 = try lexer.next(gpa);
    const c2 = try lexer.next(gpa);
    var parser: Parser = .{
        .gpa = gpa,
        .source = source,
        .lexer = &lexer,
        .arena = &arena,
        .current = c0,
        .next_tok = c1,
        .next2_tok = c2,
    };
    // `parser.diagnostics` is not covered by the arena/lexer errdefers above;
    // arm its own cleanup so an OOM anywhere below (parseFile or the final
    // `toOwnedSlice`) frees the diagnostics collected so far. On the success
    // path `toOwnedSlice` empties the list, so this errdefer becomes a no-op.
    errdefer {
        for (parser.diagnostics.items) |*d| d.deinit(gpa);
        parser.diagnostics.deinit(gpa);
    }
    // The label stack is push/pop balanced on the success path and torn down
    // here on every path (an unwinding ParseError can leave entries behind).
    defer parser.active_labels.deinit(gpa);

    // With the top-level recovery sync-point, `parseFile` catches
    // `ParseError` per top-level item internally, records the diagnostic,
    // and resyncs — so the only error that escapes here is `OutOfMemory`.
    try parser.parseFile();

    // Transfer the lexer's source-ordered comment / doc-comment slabs into
    // the arena, then bucket them onto top-level items (M0.8 D-S3-trivia /
    // D-S3-doccomment). `lexer.deinit` is the LAST statement so the armed
    // `errdefer lexer.deinit` never double-frees: every fallible op (the
    // appendSlices, `attachTrivia`, `toOwnedSlice`) runs before the lexer is
    // explicitly torn down.
    try arena.comment_spans.appendSlice(gpa, lexer.comment_spans.items);
    try arena.doc_comment_spans.appendSlice(gpa, lexer.doc_comment_spans.items);
    try attachTrivia(&arena, gpa);
    const diags = try parser.diagnostics.toOwnedSlice(gpa);
    lexer.deinit(gpa);
    return .{ .ast = arena, .diagnostics = diags };
}

/// Bucket the arena's source-ordered comment / doc-comment slabs onto the
/// top-level items they precede (M0.8 D-S3-trivia / D-S3-doccomment).
///
/// Both slabs and `arena.items` are in source order, so two forward cursors
/// suffice. For each item, comments lying inside the *previous* item's span
/// are skipped (intra-body trivia is not attached at top-level granularity
/// in M0.8 — that is Phase 2 pretty-printer work); the remaining comments
/// up to the item's start become its leading trivia / doc comments.
fn attachTrivia(arena: *AstArena, gpa: std.mem.Allocator) ParseError!void {
    const item_spans = arena.items.items(.span);
    const comments = arena.comment_spans.items;
    const docs = arena.doc_comment_spans.items;

    var comment_cursor: u32 = 0;
    var doc_cursor: u32 = 0;
    var prev_end: u32 = 0;

    for (item_spans, 0..) |span, i| {
        const item_id: NodeId = .{ .category = .item, .index = @intCast(i) };

        // Plain comments: skip any inside the previous item, then take those
        // ending at or before this item's start.
        while (comment_cursor < comments.len and comments[comment_cursor].byte_start < prev_end) : (comment_cursor += 1) {}
        const c_start = comment_cursor;
        while (comment_cursor < comments.len and comments[comment_cursor].byte_end <= span.byte_start) : (comment_cursor += 1) {}
        if (comment_cursor > c_start) {
            try arena.leading_comments.put(gpa, item_id, .{ .start = c_start, .len = comment_cursor - c_start });
        }

        // Doc comments: same bucketing against the doc slab.
        while (doc_cursor < docs.len and docs[doc_cursor].byte_start < prev_end) : (doc_cursor += 1) {}
        const d_start = doc_cursor;
        while (doc_cursor < docs.len and docs[doc_cursor].byte_end <= span.byte_start) : (doc_cursor += 1) {}
        if (doc_cursor > d_start) {
            try arena.doc_comments.put(gpa, item_id, .{ .start = d_start, .len = doc_cursor - d_start });
        }

        prev_end = span.byte_end;
    }
}

/// Explicit parser state — exposed for callers that want to drive the
/// parse incrementally (Phase 0.2 / language-server use case).
/// `parse(gpa, source)` is the canonical batch entry point.
pub const Parser = struct {
    gpa: std.mem.Allocator,
    source: []const u8,
    lexer: *Lexer,
    arena: *AstArena,
    /// Current token plus a 2-token lookahead. The disambiguation
    /// between `entity has T { field == value }` (has-with-filter)
    /// and `entity has T { /* rule body */ }` requires peeking through
    /// `{` and the first token inside (which can be `IDENT == ...`
    /// for a filter or anything else for the rule body).
    current: Token,
    next_tok: Token,
    next2_tok: Token,
    /// Diagnostics collected across the whole file. The top-level recovery
    /// loop (`parseFile`) records one diagnostic per broken construct: a
    /// construct parse stops at its first error (the `ParseError` unwinds
    /// to `parseFile`), so each broken construct contributes exactly one
    /// entry before the parser resyncs to the next top-level keyword.
    diagnostics: std.ArrayListUnmanaged(Diagnostic) = .empty,
    /// Stack of loop labels currently in scope (M0.8 loop/break). `break IDENT`
    /// treats IDENT as a label only when it names an enclosing loop — this
    /// resolves the `break [IDENT] [expression]` ambiguity without a statement
    /// separator (an IDENT that is not an active label starts the break value).
    active_labels: std.ArrayListUnmanaged(StringId) = .empty,
    /// When true, a bare `TYPE_IDENT {` is NOT parsed as a struct literal (M0.8
    /// E2 block 3). Set while parsing the head expression of `if` / `while` /
    /// `for` / `match` (where the `{` opens the body / arms, not a struct
    /// literal — the classic struct-literal-vs-block ambiguity, resolved as in
    /// Rust). Reset inside delimited contexts (`( … )`, `[ … ]`, a `{ … }`
    /// block, a struct-literal field value) where a `{` is unambiguous again.
    no_struct_lit: bool = false,

    fn isActiveLabel(self: *const Parser, name: StringId) bool {
        for (self.active_labels.items) |l| {
            if (l == name) return true;
        }
        return false;
    }

    /// Whether `kind` can begin an expression — used to decide if an optional
    /// break value follows.
    fn canStartExpr(kind: TokenKind) bool {
        return switch (kind) {
            .int_literal, .float_literal, .bool_literal, .string_literal, .ident, .type_ident, .lparen, .lbracket, .pipe, .minus, .kw_not, .kw_match, .kw_loop, .kw_get, .kw_get_mut, .kw_event, .dot => true,
            else => false,
        };
    }

    // ─── Token stream helpers ────────────────────────────────────────────

    fn advance(self: *Parser) !Token {
        const t = self.current;
        self.current = self.next_tok;
        self.next_tok = self.next2_tok;
        self.next2_tok = try self.lexer.next(self.gpa);
        return t;
    }

    fn peek(self: *const Parser) TokenKind {
        return self.current.kind;
    }

    fn peekNext(self: *const Parser) TokenKind {
        return self.next_tok.kind;
    }

    fn peekNext2(self: *const Parser) TokenKind {
        return self.next2_tok.kind;
    }

    fn peekSpan(self: *const Parser) SourceSpan {
        return self.current.span;
    }

    fn expect(self: *Parser, kind: TokenKind, msg: []const u8) !Token {
        if (self.current.kind != kind) {
            return self.parseErr(self.current.span, msg);
        }
        return try self.advance();
    }

    fn match(self: *Parser, kind: TokenKind) !bool {
        if (self.current.kind == kind) {
            _ = try self.advance();
            return true;
        }
        return false;
    }

    // ─── Diagnostic ──────────────────────────────────────────────────────

    fn parseErr(self: *Parser, span: SourceSpan, message: []const u8) ParseError {
        const owned = self.gpa.dupe(u8, message) catch {
            return error.OutOfMemory;
        };
        self.diagnostics.append(self.gpa, .{
            .code = .parse_error,
            .severity = .error_,
            .primary_span = span,
            .primary_message = owned,
        }) catch {
            self.gpa.free(owned);
            return error.OutOfMemory;
        };
        return error.ParseError;
    }

    fn parseErrFmt(self: *Parser, span: SourceSpan, comptime fmt: []const u8, args: anytype) ParseError {
        const owned = std.fmt.allocPrint(self.gpa, fmt, args) catch {
            return error.OutOfMemory;
        };
        self.diagnostics.append(self.gpa, .{
            .code = .parse_error,
            .severity = .error_,
            .primary_span = span,
            .primary_message = owned,
        }) catch {
            self.gpa.free(owned);
            return error.OutOfMemory;
        };
        return error.ParseError;
    }

    // ─── Source slice helpers ────────────────────────────────────────────

    fn sliceOf(self: *const Parser, span: SourceSpan) []const u8 {
        return self.source[span.byte_start..span.byte_end];
    }

    fn internSlice(self: *Parser, span: SourceSpan) !StringId {
        return try self.arena.strings.intern(self.gpa, self.sliceOf(span));
    }

    fn internStringLiteral(self: *Parser, span: SourceSpan) !StringId {
        // Trim the surrounding quotes; S3 string literals are simple-quote.
        const raw = self.sliceOf(span);
        const body = if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"')
            raw[1 .. raw.len - 1]
        else
            raw;
        // Process the grammar's escape sequences (`etch-grammar.md` §1.4
        // `escape_seq`: \" \\ \n \t \r \{ — M0.8 E3-C tranche 1c; forced by
        // interpolation, where `\{` must NOT open an embedded expression).
        // Escape-free fast path interns the body bytes verbatim.
        if (std.mem.indexOfScalar(u8, body, '\\') == null) {
            return try self.arena.strings.intern(self.gpa, body);
        }
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(self.gpa);
        var i: usize = 0;
        while (i < body.len) {
            if (body[i] == '\\' and i + 1 < body.len) {
                try appendEscaped(self.gpa, &buf, body[i + 1]);
                i += 2;
            } else {
                try buf.append(self.gpa, body[i]);
                i += 1;
            }
        }
        return try self.arena.strings.intern(self.gpa, buf.items);
    }

    /// Append the byte an `escape_seq` denotes (`etch-grammar.md` §1.4:
    /// `\"`, `\\`, `\n`, `\t`, `\r`, `\{`). A backslash before any other
    /// byte is not a grammar escape — kept verbatim (lenient; strict
    /// rejection is a diagnostics refinement, Phase 1+).
    fn appendEscaped(gpa: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), c: u8) !void {
        switch (c) {
            '"' => try buf.append(gpa, '"'),
            '\\' => try buf.append(gpa, '\\'),
            'n' => try buf.append(gpa, '\n'),
            't' => try buf.append(gpa, '\t'),
            'r' => try buf.append(gpa, '\r'),
            '{' => try buf.append(gpa, '{'),
            else => {
                try buf.append(gpa, '\\');
                try buf.append(gpa, c);
            },
        }
    }

    /// Whether the (quote-trimmed) string body contains an unescaped `{` —
    /// i.e. the literal is interpolated (M0.8 E3-C tranche 1c).
    fn hasUnescapedBrace(body: []const u8) bool {
        var i: usize = 0;
        while (i < body.len) {
            if (body[i] == '\\') {
                i += 2;
                continue;
            }
            if (body[i] == '{') return true;
            i += 1;
        }
        return false;
    }

    /// Parse a `string_literal` token into either a plain `string_lit` or,
    /// when the body holds an unescaped `{`, a `string_interp` node (M0.8
    /// E3-C tranche 1c, `etch-grammar.md` §1.4 `simple_string = '"' {
    /// string_char | interpolation } '"'`). Approach (a) of the resume
    /// marker: the lexer keeps one token; the embedded `{expr}` spans are
    /// sub-parsed here, at parse time, into the same arena.
    fn parseStringLiteralExpr(self: *Parser, tok: Token) ParseError!NodeId {
        const raw = self.sliceOf(tok.span);
        // Degenerate unquoted form (error token recovery) and plain
        // literals take the existing path.
        if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') {
            const id = try self.internStringLiteral(tok.span);
            return try self.arena.addExpr(self.gpa, .string_lit, id, tok.span);
        }
        const body = raw[1 .. raw.len - 1];
        if (!hasUnescapedBrace(body)) {
            const id = try self.internStringLiteral(tok.span);
            return try self.arena.addExpr(self.gpa, .string_lit, id, tok.span);
        }

        // Interpolated: alternate escape-processed literal segments with
        // sub-parsed embedded expressions (segments = exprs + 1).
        var segs: std.ArrayListUnmanaged(u32) = .empty;
        defer segs.deinit(self.gpa);
        var exprs: std.ArrayListUnmanaged(u32) = .empty;
        defer exprs.deinit(self.gpa);
        var seg_bytes: std.ArrayListUnmanaged(u8) = .empty;
        defer seg_bytes.deinit(self.gpa);

        const body_abs: u32 = tok.span.byte_start + 1; // file offset of body[0]
        const limit: u32 = tok.span.byte_end - 1; // file offset of the closing '"'
        var i: u32 = 0;
        while (i < body.len) {
            const c = body[i];
            if (c == '\\' and i + 1 < body.len) {
                try appendEscaped(self.gpa, &seg_bytes, body[i + 1]);
                i += 2;
                continue;
            }
            if (c == '{') {
                const sid = try self.arena.strings.intern(self.gpa, seg_bytes.items);
                try segs.append(self.gpa, sid);
                seg_bytes.clearRetainingCapacity();
                const embedded = try self.parseEmbeddedExpr(body_abs + i + 1, limit);
                try exprs.append(self.gpa, embedded.node.raw());
                i = embedded.resume_at - body_abs; // just past the matching '}'
                continue;
            }
            try seg_bytes.append(self.gpa, c);
            i += 1;
        }
        const last_sid = try self.arena.strings.intern(self.gpa, seg_bytes.items);
        try segs.append(self.gpa, last_sid);

        const segs_start: u32 = @intCast(self.arena.extra.items.len);
        try self.arena.extra.appendSlice(self.gpa, segs.items);
        const exprs_start: u32 = @intCast(self.arena.extra.items.len);
        try self.arena.extra.appendSlice(self.gpa, exprs.items);
        const row: u32 = @intCast(self.arena.string_interps.items.len);
        try self.arena.string_interps.append(self.gpa, .{
            .segs_start = segs_start,
            .exprs_start = exprs_start,
            .n_exprs = @intCast(exprs.items.len),
        });
        return try self.arena.addExpr(self.gpa, .string_interp, row, tok.span);
    }

    const EmbeddedExpr = struct {
        node: NodeId,
        /// File offset just past the matching `}` — where the outer
        /// segment scan resumes.
        resume_at: u32,
    };

    /// Sub-parse one embedded interpolation expression starting at absolute
    /// file offset `abs_start` (just past the `{`). The parser is swapped
    /// onto a throwaway lexer primed at that offset in the SAME source, so
    /// every span and diagnostic stays file-relative; `parseExpr` stops
    /// naturally on the matching `}` (rbrace is not an infix operator).
    /// State is restored on every path. `limit` is the file offset of the
    /// string's closing quote: a `}` at or past it means the expression ran
    /// out of the literal (e.g. an embedded `"` ended the token early) —
    /// fail loud.
    fn parseEmbeddedExpr(self: *Parser, abs_start: u32, limit: u32) ParseError!EmbeddedExpr {
        const saved_lexer = self.lexer;
        const saved_cur = self.current;
        const saved_next = self.next_tok;
        const saved_next2 = self.next2_tok;
        const saved_nsl = self.no_struct_lit;
        var sub_lexer = Lexer.init(self.source);
        sub_lexer.pos = abs_start;
        defer sub_lexer.deinit(self.gpa);
        defer {
            self.lexer = saved_lexer;
            self.current = saved_cur;
            self.next_tok = saved_next;
            self.next2_tok = saved_next2;
            self.no_struct_lit = saved_nsl;
        }
        self.lexer = &sub_lexer;
        self.current = try sub_lexer.next(self.gpa);
        self.next_tok = try sub_lexer.next(self.gpa);
        self.next2_tok = try sub_lexer.next(self.gpa);
        self.no_struct_lit = false;

        const node = try self.parseExpr(0);
        if (self.peek() != .rbrace or self.current.span.byte_end > limit) {
            return self.parseErr(self.current.span, "expected '}' to close string interpolation");
        }
        return .{ .node = node, .resume_at = self.current.span.byte_end };
    }

    // ─── Top-level ───────────────────────────────────────────────────────

    pub fn parseFile(self: *Parser) ParseError!void {
        while (self.peek() != .eof) {
            self.parseOneTopLevel() catch |err| switch (err) {
                // OOM is fatal — propagate to the caller's arena cleanup.
                error.OutOfMemory => return error.OutOfMemory,
                // A construct failed to parse: its diagnostic is already
                // recorded (the unwind carried it here). Skip to the next
                // top-level keyword (or EOF) and resume so later constructs
                // still parse. This is the M0.8 top-level recovery sync-point
                // — not a full panic-mode cascade (Phase 1 / S2+).
                error.ParseError => try self.recoverToTopLevel(),
            };
        }
    }

    /// Parse one top-level item: surface any lexer error token, consume its
    /// leading annotations, then dispatch on the construct keyword.
    fn parseOneTopLevel(self: *Parser) ParseError!void {
        try self.surfaceTokenErrors();
        const annotations = try self.parseAnnotations();
        try self.parseTopLevel(annotations);
    }

    /// Recovery sync-point: advance past the offending token, then to the
    /// next top-level construct keyword or EOF. Guarantees forward progress
    /// (always consumes ≥1 token when not already at EOF) so `parseFile`
    /// cannot loop. The stop-set MUST list every top-level starter the
    /// parser accepts, in lockstep with `parseTopLevel` — otherwise a valid
    /// construct following a parse error is silently skipped. Current set:
    /// S3 (`component` / `resource` / `rule`) + `type` (M0.8 alias) + `fn` /
    /// `async` (M0.8 E2 call mechanism) + `struct` / `impl` (M0.8 E2 block 3
    /// declaration layer) + `enum` / `trait` (E2 block 3 tranches B/C) +
    /// `event` / `tags` (E3 ECS layer). Later milestones extend both sites
    /// together.
    fn recoverToTopLevel(self: *Parser) ParseError!void {
        if (self.peek() != .eof) _ = try self.advance();
        while (true) {
            switch (self.peek()) {
                .eof, .kw_component, .kw_resource, .kw_rule, .kw_type, .kw_fn, .kw_async, .kw_struct, .kw_impl, .kw_enum, .kw_trait, .kw_event, .kw_tags, .kw_data, .kw_routine => return,
                else => _ = try self.advance(),
            }
        }
    }

    fn surfaceTokenErrors(self: *Parser) ParseError!void {
        switch (self.peek()) {
            .error_byte => return self.parseErrFmt(self.peekSpan(), "unexpected byte '{s}'", .{self.sliceOf(self.peekSpan())}),
            .error_utf8 => return self.parseErr(self.peekSpan(), "invalid UTF-8 sequence"),
            .error_unknown_keyword => return self.parseErrFmt(self.peekSpan(), "Etch keyword '{s}' is not supported in S3 (UnsupportedConstructInS3)", .{self.sliceOf(self.peekSpan())}),
            else => {},
        }
    }

    fn parseTopLevel(self: *Parser, annotations: AnnotationRange) ParseError!void {
        switch (self.peek()) {
            .kw_component => try self.parseComponentDecl(annotations),
            .kw_resource => try self.parseResourceDecl(annotations),
            .kw_rule => try self.parseRuleDecl(annotations, false),
            .kw_type => try self.parseTypeAliasDecl(annotations),
            .kw_fn => try self.parseFnDecl(annotations, false),
            .kw_struct => try self.parseStructDecl(annotations),
            .kw_impl => try self.parseImplDecl(annotations),
            .kw_enum => try self.parseEnumDecl(annotations),
            .kw_trait => try self.parseTraitDecl(annotations),
            .kw_event => try self.parseEventDecl(annotations),
            .kw_tags => try self.parseTagsDecl(annotations),
            .kw_data => try self.parseDataDecl(annotations),
            .kw_routine => try self.parseRoutineDecl(annotations),
            .kw_async => {
                // `async fn` (M0.8 E2) and `async rule` (M0.8 E3 sub-slice B):
                // the two top-level `async` constructs. `kw_async` is already in
                // the `recoverToTopLevel` stop-set; `kw_rule`/`kw_fn` likewise —
                // so `async rule` adds no new stop-set member (LOCKSTEP no-op).
                const async_span = (try self.advance()).span;
                switch (self.peek()) {
                    .kw_fn => try self.parseFnDeclFrom(annotations, true, async_span),
                    .kw_rule => try self.parseRuleDecl(annotations, true),
                    else => return self.parseErrFmt(self.peekSpan(), "expected 'fn' or 'rule' after 'async', got '{s}'", .{self.sliceOf(self.peekSpan())}),
                }
            },
            .eof => {},
            else => return self.parseErrFmt(self.peekSpan(), "expected top-level declaration (component | resource | rule | type | fn | struct | impl | enum | trait | event | tags | data | routine), got '{s}'", .{self.sliceOf(self.peekSpan())}),
        }
    }

    /// Parse a top-level `type Name = Type` alias (M0.8 v0.6 foundations).
    /// `Name` is a PascalCase type identifier; `Type` is any type node. The
    /// `kw_type` starter is mirrored in `recoverToTopLevel`'s stop-set.
    fn parseTypeAliasDecl(self: *Parser, annotations: AnnotationRange) ParseError!void {
        _ = annotations; // type aliases carry no annotations in the v0.6 subset
        const kw_span = (try self.advance()).span; // 'type'
        const name_tok = try self.expect(.type_ident, "expected PascalCase alias name after 'type'");
        const name_id = try self.internSlice(name_tok.span);
        _ = try self.expect(.eq, "expected '=' in type alias declaration");
        const target = try self.parseType();
        const target_span = self.arena.typeNodeSpan(target);
        _ = try self.arena.addTypeAlias(self.gpa, name_id, target, .{
            .byte_start = kw_span.byte_start,
            .byte_end = target_span.byte_end,
        });
    }

    // ─── Annotations ─────────────────────────────────────────────────────

    pub const AnnotationRange = struct {
        start: u32,
        len: u32,
    };

    fn parseAnnotations(self: *Parser) ParseError!AnnotationRange {
        const start: u32 = @intCast(self.arena.annot_pool.items.len);
        while (self.peek() == .at) {
            const at_tok = try self.advance();
            const name_tok = if (self.peek() == .ident or self.peek() == .type_ident)
                try self.advance()
            else
                return self.parseErr(self.peekSpan(), "expected annotation name after '@'");

            const name_slice = self.sliceOf(name_tok.span);
            const name_id = try self.internSlice(name_tok.span);
            const kind = ast_mod.AnnotationKind.fromName(name_slice);

            const args_start: u32 = @intCast(self.arena.annot_args.items.len);
            var args_len: u32 = 0;
            if (self.peek() == .lparen) {
                _ = try self.advance();
                if (self.peek() != .rparen) {
                    while (true) {
                        const arg = try self.parseAnnotationArg();
                        try self.arena.annot_args.append(self.gpa, arg);
                        args_len += 1;
                        if (!try self.match(.comma)) break;
                    }
                }
                _ = try self.expect(.rparen, "expected ')' to close annotation args");
            }

            const end_span = self.current.span;
            const total_span: SourceSpan = .{
                .byte_start = at_tok.span.byte_start,
                .byte_end = end_span.byte_start,
            };
            try self.arena.annot_pool.append(self.gpa, .{
                .kind = kind,
                .name = name_id,
                .args_start = args_start,
                .args_len = args_len,
                .span = total_span,
            });
        }
        const len: u32 = @as(u32, @intCast(self.arena.annot_pool.items.len)) - start;
        return .{ .start = start, .len = len };
    }

    fn parseAnnotationArg(self: *Parser) ParseError!ast_mod.AnnotationArg {
        // Named arg if `ident ':' expr`.
        if (self.peek() == .ident) {
            // Lookahead: if next non-ident token is `:`, treat as named.
            // The lexer's one-token lookahead is `self.current`; we have
            // to commit to the ident and check the following token.
            const saved = self.current;
            _ = try self.advance();
            if (self.peek() == .colon) {
                _ = try self.advance();
                const name_id = try self.internSlice(saved.span);
                const value = try self.parseExpr(0);
                return .{ .name = name_id, .value = value };
            }
            // Not named: this was the start of a positional expression
            // beginning with an ident. Build the expr starting from here
            // by emitting an ident expr and continuing through Pratt.
            const ident_id = try self.internSlice(saved.span);
            const lhs = try self.arena.addExpr(self.gpa, .ident, ident_id, saved.span);
            // Route through the postfix chain first so `@requires(self.health)`
            // (ident + `.field`) parses; then the binary continuation
            // (D-S3-annot-field-access).
            const after_postfix = try self.continuePostfix(lhs);
            const continued = try self.continuePostfixAndBinary(after_postfix, 0);
            return .{ .name = 0, .value = continued };
        }
        // Positional: bare expression.
        const expr = try self.parseExpr(0);
        return .{ .name = 0, .value = expr };
    }

    // ─── Component / Resource ───────────────────────────────────────────

    fn parseComponentDecl(self: *Parser, annotations: AnnotationRange) ParseError!void {
        const kw_span = self.current.span;
        _ = try self.advance(); // 'component'
        const name_tok = try self.expect(.type_ident, "expected component name (TYPE_IDENT)");
        const name_id = try self.internSlice(name_tok.span);
        _ = try self.expect(.lbrace, "expected '{' to start component body");

        const fields_start: u32 = @intCast(self.arena.fields.items.len);
        while (self.peek() != .rbrace) {
            try self.surfaceTokenErrors();
            const field_annotations = try self.parseAnnotations();
            try self.parseField(field_annotations);
            // Field separator: optional comma between fields.
            _ = try self.match(.comma);
        }
        const closing = try self.expect(.rbrace, "expected '}' to close component body");
        const fields_len: u32 = @as(u32, @intCast(self.arena.fields.items.len)) - fields_start;

        const data_idx: u32 = @intCast(self.arena.component_decls.items.len);
        try self.arena.component_decls.append(self.gpa, .{
            .name = name_id,
            .fields_start = fields_start,
            .fields_len = fields_len,
            .annotations_extra = annotations.start,
            .annotations_len = annotations.len,
        });
        _ = try self.arena.addItem(self.gpa, .component_decl, data_idx, .{
            .byte_start = kw_span.byte_start,
            .byte_end = closing.span.byte_end,
        });
    }

    fn parseResourceDecl(self: *Parser, annotations: AnnotationRange) ParseError!void {
        const kw_span = self.current.span;
        _ = try self.advance(); // 'resource'
        const name_tok = try self.expect(.type_ident, "expected resource name (TYPE_IDENT)");
        const name_id = try self.internSlice(name_tok.span);
        _ = try self.expect(.lbrace, "expected '{' to start resource body");

        const fields_start: u32 = @intCast(self.arena.fields.items.len);
        while (self.peek() != .rbrace) {
            try self.surfaceTokenErrors();
            const field_annotations = try self.parseAnnotations();
            try self.parseField(field_annotations);
            _ = try self.match(.comma);
        }
        const closing = try self.expect(.rbrace, "expected '}' to close resource body");
        const fields_len: u32 = @as(u32, @intCast(self.arena.fields.items.len)) - fields_start;

        const data_idx: u32 = @intCast(self.arena.resource_decls.items.len);
        try self.arena.resource_decls.append(self.gpa, .{
            .name = name_id,
            .fields_start = fields_start,
            .fields_len = fields_len,
            .annotations_extra = annotations.start,
            .annotations_len = annotations.len,
        });
        _ = try self.arena.addItem(self.gpa, .resource_decl, data_idx, .{
            .byte_start = kw_span.byte_start,
            .byte_end = closing.span.byte_end,
        });
    }

    /// Parse `event TYPE_IDENT "{" {annotated_field} "}"` (M0.8 E3,
    /// `etch-grammar.md` §5.10). Same shape as `parseComponentDecl` /
    /// `parseResourceDecl` — an event is a POD struct of fields. `kw_event`
    /// is mirrored in `parseTopLevel` AND `recoverToTopLevel`'s stop-set.
    fn parseEventDecl(self: *Parser, annotations: AnnotationRange) ParseError!void {
        const kw_span = self.current.span;
        _ = try self.advance(); // 'event'
        const name_tok = try self.expect(.type_ident, "expected event name (TYPE_IDENT)");
        const name_id = try self.internSlice(name_tok.span);
        _ = try self.expect(.lbrace, "expected '{' to start event body");

        const fields_start: u32 = @intCast(self.arena.fields.items.len);
        while (self.peek() != .rbrace) {
            try self.surfaceTokenErrors();
            const field_annotations = try self.parseAnnotations();
            try self.parseField(field_annotations);
            _ = try self.match(.comma);
        }
        const closing = try self.expect(.rbrace, "expected '}' to close event body");
        const fields_len: u32 = @as(u32, @intCast(self.arena.fields.items.len)) - fields_start;

        const data_idx: u32 = @intCast(self.arena.event_decls.items.len);
        try self.arena.event_decls.append(self.gpa, .{
            .name = name_id,
            .fields_start = fields_start,
            .fields_len = fields_len,
            .annotations_extra = annotations.start,
            .annotations_len = annotations.len,
        });
        _ = try self.arena.addItem(self.gpa, .event_decl, data_idx, .{
            .byte_start = kw_span.byte_start,
            .byte_end = closing.span.byte_end,
        });
    }

    /// Parse `tags "{" { tag_namespace } "}"` (M0.8 E3, `etch-grammar.md`
    /// §5.11). The top-level body is zero-or-more `tag_namespace`s (leaves
    /// cannot sit directly under `tags`). Namespaces + leaves are appended to
    /// the shared `tag_namespaces` / `tag_leaves` slabs in pre-order (= the
    /// depth-first declaration order the global tag-table pass relies on); the
    /// `(start, len)` runs this block contributed are recorded on the item.
    /// `kw_tags` is mirrored in `parseTopLevel` AND `recoverToTopLevel`.
    fn parseTagsDecl(self: *Parser, annotations: AnnotationRange) ParseError!void {
        const kw_span = self.current.span;
        _ = try self.advance(); // 'tags'
        _ = try self.expect(.lbrace, "expected '{' to start tags body");

        const ns_start: u32 = @intCast(self.arena.tag_namespaces.items.len);
        const leaf_start: u32 = @intCast(self.arena.tag_leaves.items.len);
        // The top-level `tags { }` body is namespaces only (`tag_leaf` is not a
        // `declaration_body`); a bare leaf here surfaces as the `expected '{'`
        // mismatch inside `parseTagNamespace`.
        while (self.peek() == .ident) {
            try self.parseTagNamespace(ast_mod.TagNamespace.no_parent);
        }
        const closing = try self.expect(.rbrace, "expected '}' to close tags body");

        const data_idx: u32 = @intCast(self.arena.tags_decls.items.len);
        try self.arena.tags_decls.append(self.gpa, .{
            .ns_start = ns_start,
            .ns_len = @as(u32, @intCast(self.arena.tag_namespaces.items.len)) - ns_start,
            .leaf_start = leaf_start,
            .leaf_len = @as(u32, @intCast(self.arena.tag_leaves.items.len)) - leaf_start,
            .annotations_extra = annotations.start,
            .annotations_len = annotations.len,
        });
        _ = try self.arena.addItem(self.gpa, .tags_decl, data_idx, .{
            .byte_start = kw_span.byte_start,
            .byte_end = closing.span.byte_end,
        });
    }

    /// Parse one `tag_namespace = IDENT "{" tag_body "}"` (M0.8 E3,
    /// `etch-grammar.md` §5.11). The namespace node is appended BEFORE its
    /// children (pre-order), so its index is a stable parent handle passed
    /// down. `tag_body` is homogeneous — leaves OR sub-namespaces, never mixed
    /// — disambiguated by one-token lookahead: `IDENT "{"` starts a
    /// sub-namespace, `IDENT ("," | "}")` starts a leaf list. A mixed body
    /// surfaces as the trailing `expected '}'` mismatch.
    fn parseTagNamespace(self: *Parser, parent: u32) ParseError!void {
        const name_tok = try self.expect(.ident, "expected tag namespace name (identifier)");
        const name_id = try self.internSlice(name_tok.span);
        _ = try self.expect(.lbrace, "expected '{' to start tag namespace body");

        const my_idx: u32 = @intCast(self.arena.tag_namespaces.items.len);
        try self.arena.tag_namespaces.append(self.gpa, .{
            .name = name_id,
            .parent = parent,
            .span = name_tok.span,
        });

        if (self.peek() == .ident and self.peekNext() == .lbrace) {
            // Sub-namespace mode: `tag_namespace { tag_namespace }` (no separator).
            while (self.peek() == .ident) {
                try self.parseTagNamespace(my_idx);
            }
        } else {
            // Leaf mode: `tag_leaf { "," tag_leaf } [ "," ]`.
            while (self.peek() == .ident) {
                const leaf_tok = try self.advance();
                try self.arena.tag_leaves.append(self.gpa, .{
                    .name = try self.internSlice(leaf_tok.span),
                    .parent = my_idx,
                    .span = leaf_tok.span,
                });
                if (!try self.match(.comma)) break;
            }
        }
        _ = try self.expect(.rbrace, "expected '}' to close tag namespace body");
    }

    fn parseField(self: *Parser, annotations: AnnotationRange) ParseError!void {
        const name_tok = try self.expect(.ident, "expected field name (identifier)");
        const name_id = try self.internSlice(name_tok.span);
        _ = try self.expect(.colon, "expected ':' after field name");
        const type_node = try self.parseType();
        var default_value: NodeId = NodeId.none;
        if (try self.match(.eq)) {
            default_value = try self.parseExpr(0);
        }
        try self.arena.fields.append(self.gpa, .{
            .name = name_id,
            .type_node = type_node,
            .default_value = default_value,
            .annotations_extra = annotations.start,
            .annotations_len = annotations.len,
        });
    }

    // ─── Type ────────────────────────────────────────────────────────────

    fn parseType(self: *Parser) ParseError!NodeId {
        // Map sugar `[K : V]` (M0.8 collections, `etch-grammar.md` §278): a
        // type beginning with `[` is always a map type — array / slice are the
        // postfix `T[...]` form handled below.
        if (self.peek() == .lbracket) {
            return try self.parseMapTypeSugar();
        }
        var base = try self.parseBaseType();
        // Postfix `T[N]` (fixed) / `T[]` (dynamic slice) array types
        // (`etch-grammar.md` §264), left-associative so `T[2][3]` nests.
        while (self.peek() == .lbracket) {
            _ = try self.advance(); // '['
            var size: NodeId = NodeId.none;
            if (self.peek() != .rbracket) {
                size = try self.parseExpr(0);
            }
            const closing = try self.expect(.rbracket, "expected ']' to close array type");
            const base_span = self.arena.typeNodeSpan(base);
            base = try self.arena.addArrayType(self.gpa, base, size, .{
                .byte_start = base_span.byte_start,
                .byte_end = closing.span.byte_end,
            });
        }
        // Optional suffix `T?` (M0.8 E2 block 5, `etch-grammar.md` §267).
        if (self.peek() == .question) {
            const q = try self.advance();
            const base_span = self.arena.typeNodeSpan(base);
            base = try self.arena.addOptionalType(self.gpa, base, .{
                .byte_start = base_span.byte_start,
                .byte_end = q.span.byte_end,
            });
        }
        return base;
    }

    /// Parse a base type: a primitive / engine / user type identifier, with
    /// the `Set<T>` and `Map<K, V>` generic collection forms recognised
    /// specially (full generic parsing is E2; only these two builtin
    /// containers are accepted in E1, `etch-grammar.md` §270).
    fn parseBaseType(self: *Parser) ParseError!NodeId {
        switch (self.peek()) {
            .type_ident,
            .kw_int,
            .kw_float,
            .kw_bool,
            .kw_i32,
            .kw_u32,
            .kw_f32,
            .kw_f64,
            .ident,
            => {
                const tok = try self.advance();
                if (self.peek() == .lt) {
                    const name = self.sliceOf(tok.span);
                    if (std.mem.eql(u8, name, "Set")) return try self.parseSetGeneric(tok.span);
                    if (std.mem.eql(u8, name, "Map")) return try self.parseMapGeneric(tok.span);
                    // General `Name<T, …>` generic type (M0.8 E2 block 4,
                    // `etch-grammar.md` §270).
                    return try self.parseGenericTypeApp(try self.internSlice(tok.span), tok.span);
                }
                const name_id = try self.internSlice(tok.span);
                return try self.arena.addNamedType(self.gpa, name_id, tok.span);
            },
            else => return self.parseErrFmt(self.peekSpan(), "expected type, got '{s}'", .{self.sliceOf(self.peekSpan())}),
        }
    }

    /// `[ K : V ]` map type sugar. The caller has confirmed `peek() == [`.
    fn parseMapTypeSugar(self: *Parser) ParseError!NodeId {
        const open = try self.advance(); // '['
        const key = try self.parseType();
        _ = try self.expect(.colon, "expected ':' in map type '[K: V]'");
        const value = try self.parseType();
        const closing = try self.expect(.rbracket, "expected ']' to close map type");
        return try self.arena.addMapType(self.gpa, key, value, .{
            .byte_start = open.span.byte_start,
            .byte_end = closing.span.byte_end,
        });
    }

    /// `Set < T >`. The caller has consumed `Set` (span passed in) and
    /// confirmed `peek() == <`.
    fn parseSetGeneric(self: *Parser, set_span: SourceSpan) ParseError!NodeId {
        _ = try self.advance(); // '<'
        const elem = try self.parseType();
        const closing = try self.expect(.gt, "expected '>' to close Set<T>");
        return try self.arena.addSetType(self.gpa, elem, .{
            .byte_start = set_span.byte_start,
            .byte_end = closing.span.byte_end,
        });
    }

    /// `Map < K , V >` (generic alternative to the `[K: V]` sugar).
    fn parseMapGeneric(self: *Parser, map_span: SourceSpan) ParseError!NodeId {
        _ = try self.advance(); // '<'
        const key = try self.parseType();
        _ = try self.expect(.comma, "expected ',' between Map<K, V> arguments");
        const value = try self.parseType();
        const closing = try self.expect(.gt, "expected '>' to close Map<K, V>");
        return try self.arena.addMapType(self.gpa, key, value, .{
            .byte_start = map_span.byte_start,
            .byte_end = closing.span.byte_end,
        });
    }

    /// `Name < type , … >` — a generic type application in type position (M0.8
    /// E2 block 4, `etch-grammar.md` §270). The caller has consumed `Name`
    /// (span passed in) and confirmed `peek() == <`. `Set` / `Map` keep their
    /// dedicated nodes (handled by the caller before this).
    fn parseGenericTypeApp(self: *Parser, name_id: StringId, name_span: SourceSpan) ParseError!NodeId {
        _ = try self.advance(); // '<'
        var args: std.ArrayListUnmanaged(NodeId) = .empty;
        defer args.deinit(self.gpa);
        while (true) {
            try args.append(self.gpa, try self.parseType());
            if (!try self.match(.comma)) break;
        }
        const closing = try self.expect(.gt, "expected '>' to close generic type arguments");
        return try self.arena.addGenericType(self.gpa, name_id, args.items, .{
            .byte_start = name_span.byte_start,
            .byte_end = closing.span.byte_end,
        });
    }

    // ─── Generic parameters (M0.8 E2 block 4) ────────────────────────────────

    /// One type parameter being parsed; its bounds (inline `<T: A + B>` and/or
    /// `where`) accumulate here before being committed contiguously to the
    /// arena. `bounds` is freed by `commitGenerics`.
    const TempGenericParam = struct {
        name: StringId,
        bounds: std.ArrayListUnmanaged(ast_mod.GenericBound) = .empty,
    };

    /// A committed `(start, len)` run into `arena.generic_params`.
    const GenericsRange = struct { start: u32, len: u32 };

    /// Parse `< generic_param { "," generic_param } >` (`etch-grammar.md` §2.4)
    /// into a temp buffer (so a later `where` clause can extend a param's
    /// bounds before they are committed). The caller has confirmed `peek() == <`.
    fn parseGenericParamsBuffered(self: *Parser, out: *std.ArrayListUnmanaged(TempGenericParam)) ParseError!void {
        _ = try self.advance(); // '<'
        while (true) {
            const name_tok = try self.expect(.type_ident, "expected type parameter name (TYPE_IDENT) in generic parameters");
            var tp: TempGenericParam = .{ .name = try self.internSlice(name_tok.span) };
            if (try self.match(.colon)) {
                try self.parseBoundsInto(&tp.bounds);
            }
            try out.append(self.gpa, tp);
            if (!try self.match(.comma)) break;
        }
        _ = try self.expect(.gt, "expected '>' to close generic parameters");
    }

    /// Parse `trait_bound { "+" trait_bound }` (`etch-grammar.md` §2.4) into
    /// `bounds`.
    fn parseBoundsInto(self: *Parser, bounds: *std.ArrayListUnmanaged(ast_mod.GenericBound)) ParseError!void {
        while (true) {
            try bounds.append(self.gpa, try self.parseOneBound());
            if (!try self.match(.plus)) break;
        }
    }

    /// `TYPE_IDENT` (trait) | `component` | `resource`. The `event` generic
    /// bound (`T: event`) stays out of scope in the M0.8 event vertical — its
    /// satisfaction check needs events usable as type arguments (event-as-value
    /// plumbing), absent here; `kw_event` here errors as an unsupported bound.
    fn parseOneBound(self: *Parser) ParseError!ast_mod.GenericBound {
        switch (self.peek()) {
            .kw_component => {
                _ = try self.advance();
                return .{ .kind = .component };
            },
            .kw_resource => {
                _ = try self.advance();
                return .{ .kind = .resource };
            },
            .type_ident => {
                const t = try self.advance();
                return .{ .kind = .trait_, .trait_name = try self.internSlice(t.span) };
            },
            else => return self.parseErrFmt(self.peekSpan(), "expected a trait bound (TraitName / component / resource), got '{s}'", .{self.sliceOf(self.peekSpan())}),
        }
    }

    /// `where TYPE_IDENT ":" trait_bound { "+" trait_bound } { "," … }`
    /// (`etch-grammar.md` §2.4). `where` is a plain identifier (not a keyword),
    /// detected by lexeme by the caller. Each constraint extends the matching
    /// already-parsed param's bounds.
    fn parseWhereInto(self: *Parser, params: *std.ArrayListUnmanaged(TempGenericParam)) ParseError!void {
        _ = try self.advance(); // 'where'
        while (true) {
            const name_tok = try self.expect(.type_ident, "expected type parameter name in where clause");
            const name = try self.internSlice(name_tok.span);
            _ = try self.expect(.colon, "expected ':' in where constraint");
            var target: ?*TempGenericParam = null;
            for (params.items) |*p| {
                if (p.name == name) {
                    target = p;
                    break;
                }
            }
            if (target == null) {
                return self.parseErrFmt(name_tok.span, "where clause names unknown type parameter '{s}'", .{self.sliceOf(name_tok.span)});
            }
            try self.parseBoundsInto(&target.?.bounds);
            if (!try self.match(.comma)) break;
        }
    }

    /// Commit the buffered params + their bounds to the arena slabs. Returns the
    /// `(start, len)` run into `arena.generic_params`. The temp buffer is freed
    /// separately by `deinitTempGenerics` (a `defer` in the caller).
    fn commitGenerics(self: *Parser, params: *std.ArrayListUnmanaged(TempGenericParam)) ParseError!GenericsRange {
        const start: u32 = @intCast(self.arena.generic_params.items.len);
        for (params.items) |*p| {
            const b_start: u32 = @intCast(self.arena.generic_bounds.items.len);
            try self.arena.generic_bounds.appendSlice(self.gpa, p.bounds.items);
            try self.arena.generic_params.append(self.gpa, .{
                .name = p.name,
                .bounds_start = b_start,
                .bounds_len = @intCast(p.bounds.items.len),
            });
        }
        return .{ .start = start, .len = @intCast(params.items.len) };
    }

    /// Free a temp generic-param buffer (per-param bound lists + the list).
    fn deinitTempGenerics(self: *Parser, params: *std.ArrayListUnmanaged(TempGenericParam)) void {
        for (params.items) |*p| p.bounds.deinit(self.gpa);
        params.deinit(self.gpa);
    }

    /// `true` when the current token is the `where` keyword (a plain identifier).
    fn atWhere(self: *Parser) bool {
        return self.peek() == .ident and std.mem.eql(u8, self.sliceOf(self.current.span), "where");
    }

    // ─── Rule ────────────────────────────────────────────────────────────

    fn parseRuleDecl(self: *Parser, annotations: AnnotationRange, is_async: bool) ParseError!void {
        // On entry the current token is `rule` (an optional `async` was already
        // consumed by `parseTopLevel`). `is_async` marks an `async rule` whose
        // body may `await` (M0.8 E3 sub-slice B).
        const kw_span = self.current.span;
        _ = try self.advance(); // 'rule'
        const name_tok = try self.expect(.ident, "expected rule name (identifier)");
        const name_id = try self.internSlice(name_tok.span);

        _ = try self.expect(.lparen, "expected '(' to begin rule parameters");
        const params_start: u32 = @intCast(self.arena.rule_params.items.len);
        if (self.peek() != .rparen) {
            while (true) {
                const p_name = try self.expect(.ident, "expected parameter name");
                _ = try self.expect(.colon, "expected ':' after parameter name");
                const p_type = try self.parseType();
                try self.arena.rule_params.append(self.gpa, .{
                    .name = try self.internSlice(p_name.span),
                    .type_node = p_type,
                });
                if (!try self.match(.comma)) break;
            }
        }
        _ = try self.expect(.rparen, "expected ')' to close rule parameters");
        const params_len: u32 = @as(u32, @intCast(self.arena.rule_params.items.len)) - params_start;

        var when_root: u32 = ast_mod.RuleDecl.none_when;
        if (self.peek() == .kw_when) {
            _ = try self.advance();
            when_root = try self.parseWhenExpr();
        }

        _ = try self.expect(.lbrace, "expected '{' to start rule body");
        const body = try self.parseStmtRun();
        const closing = try self.expect(.rbrace, "expected '}' to close rule body");
        const body_extra_start = body.start;
        const body_len = body.len;

        const data_idx: u32 = @intCast(self.arena.rule_decls.items.len);
        try self.arena.rule_decls.append(self.gpa, .{
            .name = name_id,
            .params_start = params_start,
            .params_len = params_len,
            .when_root = when_root,
            .body_start = body_extra_start,
            .body_len = body_len,
            .annotations_extra = annotations.start,
            .annotations_len = annotations.len,
            .is_async = is_async,
        });
        _ = try self.arena.addItem(self.gpa, .rule_decl, data_idx, .{
            .byte_start = kw_span.byte_start,
            .byte_end = closing.span.byte_end,
        });
    }

    // ─── Functions (M0.8 E2 call mechanism) ──────────────────────────────

    /// Parse a top-level `fn` (no `async` prefix). `kw_fn` is the lockstep
    /// stop-set member added to `recoverToTopLevel` in the same commit.
    fn parseFnDecl(self: *Parser, annotations: AnnotationRange, is_async: bool) ParseError!void {
        return self.parseFnDeclFrom(annotations, is_async, self.current.span);
    }

    /// Parse a top-level `fn` and add it as a `.fn_decl` item (M0.8 E2 call
    /// mechanism). On entry the current token is `fn` (the optional `async` was
    /// already consumed by the caller, its span passed as `start_span`). Shares
    /// the signature/body machinery with `impl` methods via `parseFnLike`; a
    /// top-level `fn` takes no `self` receiver (`allow_self = false`).
    fn parseFnDeclFrom(self: *Parser, annotations: AnnotationRange, is_async: bool, start_span: SourceSpan) ParseError!void {
        const parsed = try self.parseFnLike(is_async, false, false, annotations);
        _ = try self.arena.addFnDecl(self.gpa, parsed.decl, .{
            .byte_start = start_span.byte_start,
            .byte_end = parsed.close_span.byte_end,
        });
    }

    const ParsedFn = struct { decl: ast_mod.FnDecl, close_span: SourceSpan };

    /// Parse `[async] fn IDENT "(" [self_param ,] [params] ")" [throws]
    /// ["->" type] block` and return the `FnDecl` value plus its closing brace
    /// span — without adding an item (`etch-grammar.md` §5.3). On entry the
    /// current token is `fn`. The body is a value-block: the trailing bare
    /// expression is the implicit return (`etch-grammar.md` §4.1 l.645).
    /// `allow_self` lets the first parameter be a `self` / `mut self` receiver
    /// (M0.8 E2 block 3 `impl` methods); a top-level `fn` passes `false`.
    /// Generics (`<...>`) + the `where` clause are E2 block 4 and rejected; the
    /// bodyless `.d.etch` form is out of scope. `async` is parsed (interp E3,
    /// codegen Phase 2); `throws` is parsed (codegen folds into the E3 gate).
    fn parseFnLike(self: *Parser, is_async: bool, allow_self: bool, allow_signature_only: bool, annotations: AnnotationRange) ParseError!ParsedFn {
        _ = try self.advance(); // 'fn'
        const name_tok = try self.expect(.ident, "expected function name (identifier) after 'fn'");
        const name_id = try self.internSlice(name_tok.span);

        // Generic parameters `<T: bound, …>` (M0.8 E2 block 4). Buffered so the
        // `where` clause (after the return type) can extend their bounds.
        var temp_generics: std.ArrayListUnmanaged(TempGenericParam) = .empty;
        defer self.deinitTempGenerics(&temp_generics);
        if (self.peek() == .lt) {
            try self.parseGenericParamsBuffered(&temp_generics);
        }

        _ = try self.expect(.lparen, "expected '(' to begin function parameters");
        const params_start: u32 = @intCast(self.arena.fn_params.items.len);
        var self_kind: ast_mod.SelfKind = .none;
        if (self.peek() != .rparen) {
            var first = true;
            while (true) {
                if (first and allow_self) {
                    self_kind = try self.tryParseSelfParam();
                    if (self_kind != .none) {
                        first = false;
                        if (!try self.match(.comma)) break;
                        continue;
                    }
                }
                const p_name = try self.expect(.ident, "expected parameter name");
                _ = try self.expect(.colon, "expected ':' after parameter name");
                const p_type = try self.parseType();
                try self.arena.fn_params.append(self.gpa, .{
                    .name = try self.internSlice(p_name.span),
                    .type_node = p_type,
                });
                first = false;
                if (!try self.match(.comma)) break;
            }
        }
        _ = try self.expect(.rparen, "expected ')' to close function parameters");
        const params_len: u32 = @as(u32, @intCast(self.arena.fn_params.items.len)) - params_start;

        const throws = try self.match(.kw_throws);

        var return_type: NodeId = NodeId.none;
        var sig_end_span = self.current.span; // last token of the signature so far (')')
        if (self.peek() == .arrow) {
            _ = try self.advance(); // '->'
            return_type = try self.parseType();
            sig_end_span = self.arena.typeNodeSpan(return_type);
        }

        // `where T: bound, …` (M0.8 E2 block 4) — `where` is a plain identifier,
        // detected by lexeme; it extends the buffered params' bounds.
        if (self.atWhere()) {
            try self.parseWhereInto(&temp_generics);
        }
        const generics = try self.commitGenerics(&temp_generics);

        // An abstract trait member (`function_signature`, M0.8 E2 block 3
        // tranche C) ends without a body. Outside a trait, a missing body is the
        // existing "expected '{'" error.
        if (allow_signature_only and self.peek() != .lbrace) {
            return .{
                .decl = .{
                    .name = name_id,
                    .params_start = params_start,
                    .params_len = params_len,
                    .return_type = return_type,
                    .is_async = is_async,
                    .throws = throws,
                    .body_start = 0,
                    .body_len = 0,
                    .value = NodeId.none,
                    .annotations_extra = annotations.start,
                    .annotations_len = annotations.len,
                    .self_kind = self_kind,
                    .has_body = false,
                    .generics_start = generics.start,
                    .generics_len = generics.len,
                },
                .close_span = sig_end_span,
            };
        }

        _ = try self.expect(.lbrace, "expected '{' to start function body");
        const body = try self.parseBlockBody();
        const closing = try self.expect(.rbrace, "expected '}' to close function body");

        return .{
            .decl = .{
                .name = name_id,
                .params_start = params_start,
                .params_len = params_len,
                .return_type = return_type,
                .is_async = is_async,
                .throws = throws,
                .body_start = body.start,
                .body_len = body.len,
                .value = body.value,
                .annotations_extra = annotations.start,
                .annotations_len = annotations.len,
                .self_kind = self_kind,
                .generics_start = generics.start,
                .generics_len = generics.len,
                .has_body = true,
            },
            .close_span = closing.span,
        };
    }

    /// Recognise and consume a leading `self` / `mut self` method receiver
    /// (M0.8 E2 block 3, `etch-grammar.md` §5.3 `self_param = [mut] self`).
    /// `self` is a plain identifier (not a keyword), so the receiver is detected
    /// by lexeme. Returns `.none` (consuming nothing) when the first parameter
    /// is an ordinary `IDENT : type`.
    fn tryParseSelfParam(self: *Parser) ParseError!ast_mod.SelfKind {
        if (self.peek() == .kw_mut and self.peekNext() == .ident and std.mem.eql(u8, self.sliceOf(self.next_tok.span), "self")) {
            _ = try self.advance(); // 'mut'
            _ = try self.advance(); // 'self'
            // Intern "self" so consumers holding only a *const arena (interp /
            // codegen) can resolve the receiver binding even when the body never
            // names `self` explicitly.
            _ = try self.arena.strings.intern(self.gpa, "self");
            return .by_mut;
        }
        if (self.peek() == .ident and std.mem.eql(u8, self.sliceOf(self.current.span), "self")) {
            _ = try self.advance(); // 'self'
            _ = try self.arena.strings.intern(self.gpa, "self");
            return .by_value;
        }
        return .none;
    }

    /// Parse `struct TYPE_IDENT "{" {annotated_field} "}"` (M0.8 E2 block 3,
    /// `etch-grammar.md` §5.7). Same field machinery as a component / resource;
    /// a struct is a by-value type (not registered with the world). Generics
    /// (`<...>`) are block 4 and rejected here.
    fn parseStructDecl(self: *Parser, annotations: AnnotationRange) ParseError!void {
        const kw_span = self.current.span;
        _ = try self.advance(); // 'struct'
        const name_tok = try self.expect(.type_ident, "expected struct name (TYPE_IDENT)");
        const name_id = try self.internSlice(name_tok.span);
        const generics = try self.parseOptionalGenerics();
        _ = try self.expect(.lbrace, "expected '{' to start struct body");
        const fields_start: u32 = @intCast(self.arena.fields.items.len);
        while (self.peek() != .rbrace) {
            try self.surfaceTokenErrors();
            const field_annotations = try self.parseAnnotations();
            try self.parseField(field_annotations);
            _ = try self.match(.comma);
        }
        const closing = try self.expect(.rbrace, "expected '}' to close struct body");
        const fields_len: u32 = @as(u32, @intCast(self.arena.fields.items.len)) - fields_start;
        _ = try self.arena.addStructDecl(self.gpa, .{
            .name = name_id,
            .fields_start = fields_start,
            .fields_len = fields_len,
            .annotations_extra = annotations.start,
            .annotations_len = annotations.len,
            .generics_start = generics.start,
            .generics_len = generics.len,
        }, .{ .byte_start = kw_span.byte_start, .byte_end = closing.span.byte_end });
    }

    /// Parse an optional `< generic_param, … >` (no `where` — only `fn`/methods
    /// have a where clause) and commit it, returning the `(start, len)` run.
    /// `(0, 0)` when there are no generic parameters (M0.8 E2 block 4).
    fn parseOptionalGenerics(self: *Parser) ParseError!GenericsRange {
        if (self.peek() != .lt) return .{ .start = 0, .len = 0 };
        var temp: std.ArrayListUnmanaged(TempGenericParam) = .empty;
        defer self.deinitTempGenerics(&temp);
        try self.parseGenericParamsBuffered(&temp);
        return try self.commitGenerics(&temp);
    }

    /// Parse `enum TYPE_IDENT "{" enum_variant {"," enum_variant} [","] "}"`
    /// (M0.8 E2 block 3 tranche B, `etch-grammar.md` §5.8). C-like variants
    /// (`easy`) are the supported end-to-end form; struct-like
    /// (`Physical { amount: float }`) and tuple-like (`ok(T)`) variants are
    /// parsed so the grammar is accepted, with their data recorded for a
    /// fail-loud downstream (construction / destructuring are deferred).
    /// Generics (`<...>`) are block 4 and rejected here, as for `struct`.
    fn parseEnumDecl(self: *Parser, annotations: AnnotationRange) ParseError!void {
        const kw_span = self.current.span;
        _ = try self.advance(); // 'enum'
        const name_tok = try self.expect(.type_ident, "expected enum name (TYPE_IDENT)");
        const name_id = try self.internSlice(name_tok.span);
        const generics = try self.parseOptionalGenerics();
        _ = try self.expect(.lbrace, "expected '{' to start enum body");
        const variants_start: u32 = @intCast(self.arena.enum_variants.items.len);
        while (self.peek() != .rbrace and self.peek() != .eof) {
            try self.surfaceTokenErrors();
            const variant_tok = try self.expect(.ident, "expected enum variant name (identifier)");
            const variant_name = try self.internSlice(variant_tok.span);
            var shape: ast_mod.EnumVariantShape = .c_like;
            var data_start: u32 = 0;
            var data_len: u32 = 0;
            switch (self.peek()) {
                .lbrace => {
                    // Struct-like variant `Name { annotated_field, ... }`.
                    _ = try self.advance(); // '{'
                    shape = .struct_like;
                    data_start = @intCast(self.arena.fields.items.len);
                    while (self.peek() != .rbrace and self.peek() != .eof) {
                        try self.surfaceTokenErrors();
                        const field_annotations = try self.parseAnnotations();
                        try self.parseField(field_annotations);
                        _ = try self.match(.comma);
                    }
                    _ = try self.expect(.rbrace, "expected '}' to close struct-like enum variant");
                    data_len = @as(u32, @intCast(self.arena.fields.items.len)) - data_start;
                },
                .lparen => {
                    // Tuple-like variant `Name ( type, ... )`. Types are stored
                    // as a run of type-`NodeId`s in `arena.extra`.
                    _ = try self.advance(); // '('
                    shape = .tuple_like;
                    data_start = @intCast(self.arena.extra.items.len);
                    if (self.peek() != .rparen) {
                        while (true) {
                            const t = try self.parseType();
                            try self.arena.extra.append(self.gpa, t.raw());
                            if (!try self.match(.comma)) break;
                        }
                    }
                    _ = try self.expect(.rparen, "expected ')' to close tuple-like enum variant");
                    data_len = @as(u32, @intCast(self.arena.extra.items.len)) - data_start;
                },
                else => {},
            }
            try self.arena.enum_variants.append(self.gpa, .{
                .name = variant_name,
                .shape = shape,
                .data_start = data_start,
                .data_len = data_len,
            });
            if (!try self.match(.comma)) break;
        }
        const closing = try self.expect(.rbrace, "expected '}' to close enum body");
        const variants_len: u32 = @as(u32, @intCast(self.arena.enum_variants.items.len)) - variants_start;
        _ = try self.arena.addEnumDecl(self.gpa, .{
            .name = name_id,
            .variants_start = variants_start,
            .variants_len = variants_len,
            .annotations_extra = annotations.start,
            .annotations_len = annotations.len,
            .generics_start = generics.start,
            .generics_len = generics.len,
        }, .{ .byte_start = kw_span.byte_start, .byte_end = closing.span.byte_end });
    }

    /// Parse `data TYPE_IDENT ":" TYPE_IDENT "{" {data_entry} "}"` (M0.8 E4
    /// Level B, `etch-grammar.md` §14). `data_entry = IDENT ":"
    /// struct_literal_body [","]` — the body reuses the §3.2 `field_init`
    /// forms INCLUDING the spread `".." expression` (l.491): the E2 spread
    /// deferral is homed here (data-table inheritance); general struct
    /// literals keep rejecting it. A TYPE_IDENT-shaped entry id is accepted
    /// at parse and flagged by validation (`E1768 IdInvalidFormat`). Each
    /// entry's fields are buffered locally and committed as a contiguous
    /// `struct_lit_fields` run AFTER its values are parsed — a value may
    /// itself contain a struct literal, whose nested run must not interleave
    /// with the entry's own.
    fn parseDataDecl(self: *Parser, annotations: AnnotationRange) ParseError!void {
        const kw_span = self.current.span;
        _ = try self.advance(); // 'data'
        const name_tok = try self.expect(.type_ident, "expected data table name (TYPE_IDENT)");
        const name_id = try self.internSlice(name_tok.span);
        _ = try self.expect(.colon, "expected ':' between the data table name and its entry type");
        const type_tok = try self.expect(.type_ident, "expected entry type (TYPE_IDENT) after ':'");
        const entry_type = try self.internSlice(type_tok.span);
        _ = try self.expect(.lbrace, "expected '{' to start the data table body");
        const entries_start: u32 = @intCast(self.arena.data_entries.items.len);
        while (self.peek() != .rbrace and self.peek() != .eof) {
            try self.surfaceTokenErrors();
            const id_tok = switch (self.peek()) {
                .ident, .type_ident => try self.advance(),
                else => return self.parseErr(self.peekSpan(), "expected data entry id (identifier)"),
            };
            const entry_id = try self.internSlice(id_tok.span);
            _ = try self.expect(.colon, "expected ':' after the data entry id");
            const body_close = try self.parseDataEntryBody();
            try self.arena.data_entries.append(self.gpa, .{
                .id = entry_id,
                .id_pascal = id_tok.kind == .type_ident,
                .fields_start = body_close.fields_start,
                .fields_len = body_close.fields_len,
                .span = .{ .byte_start = id_tok.span.byte_start, .byte_end = body_close.end_byte },
            });
            _ = try self.match(.comma);
        }
        const closing = try self.expect(.rbrace, "expected '}' to close the data table body");
        const entries_len: u32 = @as(u32, @intCast(self.arena.data_entries.items.len)) - entries_start;
        _ = try self.arena.addDataDecl(self.gpa, .{
            .name = name_id,
            .entry_type = entry_type,
            .entry_type_span = type_tok.span,
            .entries_start = entries_start,
            .entries_len = entries_len,
            .annotations_extra = annotations.start,
            .annotations_len = annotations.len,
        }, .{ .byte_start = kw_span.byte_start, .byte_end = closing.span.byte_end });
    }

    const DataEntryBody = struct {
        fields_start: u32,
        fields_len: u32,
        end_byte: u32,
    };

    /// Parse one data-entry `struct_literal_body` (`"{" [field_init {","
    /// field_init} [","]] "}"`, §3.2) buffering the field initializers and
    /// committing them as one contiguous `struct_lit_fields` run. Spread
    /// fields (`".." expression`) are stored with `name == 0`.
    fn parseDataEntryBody(self: *Parser) ParseError!DataEntryBody {
        _ = try self.expect(.lbrace, "expected '{' to start the data entry body");
        const saved = self.no_struct_lit;
        self.no_struct_lit = false;
        defer self.no_struct_lit = saved;
        var temp: std.ArrayListUnmanaged(ast_mod.StructLitField) = .empty;
        defer temp.deinit(self.gpa);
        while (self.peek() != .rbrace and self.peek() != .eof) {
            try self.surfaceTokenErrors();
            if (self.peek() == .dotdot) {
                _ = try self.advance(); // '..'
                const spread_value = try self.parseExpr(0);
                try temp.append(self.gpa, .{ .name = 0, .value = spread_value });
            } else {
                const fname = try self.expect(.ident, "expected field name in data entry body");
                _ = try self.expect(.colon, "expected ':' after data entry field name");
                const value = try self.parseExpr(0);
                try temp.append(self.gpa, .{ .name = try self.internSlice(fname.span), .value = value });
            }
            if (!try self.match(.comma)) break;
        }
        const closing = try self.expect(.rbrace, "expected '}' to close the data entry body");
        const fields_start: u32 = @intCast(self.arena.struct_lit_fields.items.len);
        try self.arena.struct_lit_fields.appendSlice(self.gpa, temp.items);
        return .{
            .fields_start = fields_start,
            .fields_len = @intCast(temp.items.len),
            .end_byte = closing.span.byte_end,
        };
    }

    /// Parse `routine TYPE_IDENT "{" {routine_element} "}"` (M0.8 E4 Level B,
    /// `etch-grammar.md` §8.2). Elements are segments (`segment Name { … }`)
    /// and interrupts (`on_xxx -> target`), dispatched on the head
    /// identifier: `segment` is a contextual keyword (the S3 sub-construct
    /// doctrine); an interrupt head is lexically one IDENT starting `on_`
    /// (the EBNF's `"on_" , IDENT` split is not lexable — E4 bound (f)).
    /// Interrupt targets accept `ident | type_ident` (behavior names are
    /// TYPE_IDENT-shaped — E4 bound (d)); `pause_segment` is matched by
    /// lexeme. Direct slab appends stay contiguous: routine slabs are only
    /// fed from routine context and routines do not nest.
    fn parseRoutineDecl(self: *Parser, annotations: AnnotationRange) ParseError!void {
        const kw_span = self.current.span;
        _ = try self.advance(); // 'routine'
        const name_tok = try self.expect(.type_ident, "expected routine name (TYPE_IDENT)");
        const name_id = try self.internSlice(name_tok.span);
        _ = try self.expect(.lbrace, "expected '{' to start routine body");
        const segments_start: u32 = @intCast(self.arena.routine_segments.items.len);
        const interrupts_start: u32 = @intCast(self.arena.routine_interrupts.items.len);
        while (self.peek() != .rbrace and self.peek() != .eof) {
            try self.surfaceTokenErrors();
            if (self.peek() != .ident) {
                return self.parseErrFmt(self.peekSpan(), "expected 'segment' or an 'on_…' interrupt in routine body, got '{s}'", .{self.sliceOf(self.peekSpan())});
            }
            const head = self.sliceOf(self.peekSpan());
            if (std.mem.eql(u8, head, "segment")) {
                try self.parseRoutineSegment();
            } else if (std.mem.startsWith(u8, head, "on_")) {
                const ev_tok = try self.advance();
                const ev_name = try self.internSlice(ev_tok.span);
                _ = try self.expect(.arrow, "expected '->' after the routine interrupt event");
                const target_tok = switch (self.peek()) {
                    .ident, .type_ident => try self.advance(),
                    else => return self.parseErr(self.peekSpan(), "expected an interrupt target (behavior name or 'pause_segment')"),
                };
                try self.arena.routine_interrupts.append(self.gpa, .{
                    .event_name = ev_name,
                    .target = try self.internSlice(target_tok.span),
                    .is_pause = std.mem.eql(u8, self.sliceOf(target_tok.span), "pause_segment"),
                    .span = .{ .byte_start = ev_tok.span.byte_start, .byte_end = target_tok.span.byte_end },
                });
            } else {
                return self.parseErrFmt(self.peekSpan(), "expected 'segment' or an 'on_…' interrupt in routine body, got '{s}'", .{head});
            }
        }
        const closing = try self.expect(.rbrace, "expected '}' to close routine body");
        _ = try self.arena.addRoutineDecl(self.gpa, .{
            .name = name_id,
            .segments_start = segments_start,
            .segments_len = @as(u32, @intCast(self.arena.routine_segments.items.len)) - segments_start,
            .interrupts_start = interrupts_start,
            .interrupts_len = @as(u32, @intCast(self.arena.routine_interrupts.items.len)) - interrupts_start,
            .annotations_extra = annotations.start,
            .annotations_len = annotations.len,
        }, .{ .byte_start = kw_span.byte_start, .byte_end = closing.span.byte_end });
    }

    /// Parse one `segment IDENT { trigger: … actions: … until: … }` (§8.2).
    /// The three clauses are mandatory and ordered (the EBNF fixes the
    /// order). Segment names accept `ident | type_ident` (the grammar's own
    /// examples are PascalCase — E4 bound (d)).
    fn parseRoutineSegment(self: *Parser) ParseError!void {
        const kw = try self.advance(); // 'segment' (contextual)
        const name_tok = switch (self.peek()) {
            .ident, .type_ident => try self.advance(),
            else => return self.parseErr(self.peekSpan(), "expected segment name after 'segment'"),
        };
        const name_id = try self.internSlice(name_tok.span);
        _ = try self.expect(.lbrace, "expected '{' to start segment body");
        try self.expectContextualKey("trigger");
        const triggers = try self.parseTriggerAlternatives();
        try self.expectContextualKey("actions");
        const actions = try self.parseRoutineActions();
        try self.expectContextualKey("until");
        const untils = try self.parseTriggerAlternatives();
        const closing = try self.expect(.rbrace, "expected '}' to close segment body");
        try self.arena.routine_segments.append(self.gpa, .{
            .name = name_id,
            .triggers_start = triggers.start,
            .triggers_len = triggers.len,
            .actions_start = actions.start,
            .actions_len = actions.len,
            .untils_start = untils.start,
            .untils_len = untils.len,
            .span = .{ .byte_start = kw.span.byte_start, .byte_end = closing.span.byte_end },
        });
    }

    /// Expect a contextual segment-clause key (`trigger` / `actions` /
    /// `until`) followed by its `:`.
    fn expectContextualKey(self: *Parser, comptime key: []const u8) ParseError!void {
        if (self.peek() != .ident or !std.mem.eql(u8, self.sliceOf(self.peekSpan()), key)) {
            return self.parseErrFmt(self.peekSpan(), "expected '" ++ key ++ ":' (segment clauses are ordered: trigger, actions, until), got '{s}'", .{self.sliceOf(self.peekSpan())});
        }
        _ = try self.advance();
        _ = try self.expect(.colon, "expected ':' after '" ++ key ++ "'");
    }

    const SlabRange = struct { start: u32, len: u32 };

    /// Parse a §8.2 `trigger_expr` `or`-chain into a flat run of
    /// `arena.routine_triggers` alternatives: `at TIME_LITERAL` /
    /// `after IDENT` / `on_event TYPE_IDENT`. `at` and `on_event` are
    /// contextual identifiers (`on_event` must stay an ident — graduating
    /// it would break the `@on_event(T)` annotation parse, E4 bound (g));
    /// `after` is the graduated `kw_after`.
    fn parseTriggerAlternatives(self: *Parser) ParseError!SlabRange {
        const start: u32 = @intCast(self.arena.routine_triggers.items.len);
        while (true) {
            switch (self.peek()) {
                .kw_after => {
                    const kw = try self.advance();
                    const seg_tok = switch (self.peek()) {
                        .ident, .type_ident => try self.advance(),
                        else => return self.parseErr(self.peekSpan(), "expected a segment name after 'after'"),
                    };
                    try self.arena.routine_triggers.append(self.gpa, .{
                        .kind = .after_segment,
                        .value = try self.internSlice(seg_tok.span),
                        .span = .{ .byte_start = kw.span.byte_start, .byte_end = seg_tok.span.byte_end },
                    });
                },
                .ident => {
                    const head = self.sliceOf(self.peekSpan());
                    if (std.mem.eql(u8, head, "at")) {
                        const kw = try self.advance();
                        const time_tok = try self.expect(.time_literal, "expected a DD:DD time literal after 'at'");
                        try self.arena.routine_triggers.append(self.gpa, .{
                            .kind = .at_time,
                            .value = try self.internSlice(time_tok.span),
                            .span = .{ .byte_start = kw.span.byte_start, .byte_end = time_tok.span.byte_end },
                        });
                    } else if (std.mem.eql(u8, head, "on_event")) {
                        const kw = try self.advance();
                        const ev_tok = try self.expect(.type_ident, "expected an event type (TYPE_IDENT) after 'on_event'");
                        try self.arena.routine_triggers.append(self.gpa, .{
                            .kind = .on_event,
                            .value = try self.internSlice(ev_tok.span),
                            .span = .{ .byte_start = kw.span.byte_start, .byte_end = ev_tok.span.byte_end },
                        });
                    } else {
                        return self.parseErrFmt(self.peekSpan(), "expected a trigger ('at DD:DD' | 'after Segment' | 'on_event EventType'), got '{s}'", .{head});
                    }
                },
                else => return self.parseErrFmt(self.peekSpan(), "expected a trigger ('at DD:DD' | 'after Segment' | 'on_event EventType'), got '{s}'", .{self.sliceOf(self.peekSpan())}),
            }
            if (self.peek() != .kw_or) break;
            _ = try self.advance(); // 'or'
        }
        return .{ .start = start, .len = @as(u32, @intCast(self.arena.routine_triggers.items.len)) - start };
    }

    /// Parse a §8.2 `routine_action_list` (`action { "then" action }`) into
    /// a run of expression `NodeId`s in `arena.extra`. Each action must be a
    /// call (`routine_action = IDENT "(" [arg_list] ")"`) — enforced on the
    /// parsed expression's kind. Buffered commit: parsing an action's
    /// arguments appends arg runs to `arena.extra`, which would interleave
    /// with this run.
    fn parseRoutineActions(self: *Parser) ParseError!SlabRange {
        var temp: std.ArrayListUnmanaged(u32) = .empty;
        defer temp.deinit(self.gpa);
        while (true) {
            if (self.peek() != .ident) {
                return self.parseErrFmt(self.peekSpan(), "expected a routine action call 'fn_name(args)', got '{s}'", .{self.sliceOf(self.peekSpan())});
            }
            const action = try self.parseExpr(0);
            if (self.arena.exprKind(action) != .fn_call) {
                return self.parseErr(self.arena.exprSpan(action), "a routine action must be a call 'fn_name(args)' (etch-grammar.md §8.2)");
            }
            try temp.append(self.gpa, action.raw());
            if (self.peek() == .ident and std.mem.eql(u8, self.sliceOf(self.peekSpan()), "then")) {
                _ = try self.advance(); // 'then'
                continue;
            }
            break;
        }
        const start: u32 = @intCast(self.arena.extra.items.len);
        try self.arena.extra.appendSlice(self.gpa, temp.items);
        return .{ .start = start, .len = @intCast(temp.items.len) };
    }

    /// Parse `trait TYPE_IDENT "{" {trait_member} "}"` (M0.8 E2 block 3 tranche
    /// C, `etch-grammar.md` §5.9). `trait_member = function_signature` (abstract
    /// — no body, `has_body = false`) `| function_decl` (default body). Members
    /// reuse `parseFnLike` (`allow_self = true`, `allow_signature_only = true`)
    /// and are stored in `arena.impl_methods`. Generics (`<...>`) are block 4.
    fn parseTraitDecl(self: *Parser, annotations: AnnotationRange) ParseError!void {
        const kw_span = self.current.span;
        _ = try self.advance(); // 'trait'
        const name_tok = try self.expect(.type_ident, "expected trait name (TYPE_IDENT)");
        const name_id = try self.internSlice(name_tok.span);
        const generics = try self.parseOptionalGenerics();
        _ = try self.expect(.lbrace, "expected '{' to start trait body");
        const methods_start: u32 = @intCast(self.arena.impl_methods.items.len);
        while (self.peek() != .rbrace and self.peek() != .eof) {
            try self.surfaceTokenErrors();
            const member_annotations = try self.parseAnnotations();
            var is_async = false;
            if (self.peek() == .kw_async) {
                _ = try self.advance();
                is_async = true;
            }
            if (self.peek() != .kw_fn) {
                return self.parseErrFmt(self.peekSpan(), "expected 'fn' to start a trait member, got '{s}'", .{self.sliceOf(self.peekSpan())});
            }
            const parsed = try self.parseFnLike(is_async, true, true, member_annotations);
            try self.arena.impl_methods.append(self.gpa, parsed.decl);
        }
        const closing = try self.expect(.rbrace, "expected '}' to close trait body");
        const methods_len: u32 = @as(u32, @intCast(self.arena.impl_methods.items.len)) - methods_start;
        _ = try self.arena.addTraitDecl(self.gpa, .{
            .name = name_id,
            .methods_start = methods_start,
            .methods_len = methods_len,
            .annotations_extra = annotations.start,
            .annotations_len = annotations.len,
            .generics_start = generics.start,
            .generics_len = generics.len,
        }, .{ .byte_start = kw_span.byte_start, .byte_end = closing.span.byte_end });
    }

    /// Parse `impl TYPE_IDENT [when_clause] "{" {fn_method} "}"` — an inherent
    /// impl (M0.8 E2 block 3 tranche A, `etch-grammar.md` §5.9). The trait form
    /// `impl Trait for Type` lands in tranche C; a `for` after the first type
    /// name is rejected with a clear pointer. Methods reuse `parseFnLike` with
    /// `allow_self = true` and are stored in `arena.impl_methods`.
    fn parseImplDecl(self: *Parser, annotations: AnnotationRange) ParseError!void {
        _ = annotations; // inherent impl carries no annotations in this subset
        const kw_span = self.current.span;
        _ = try self.advance(); // 'impl'
        // Optional impl-level generic params `impl<T> …` (M0.8 E2 block 4); in
        // scope for every method body.
        const impl_generics = try self.parseOptionalGenerics();
        const first_tok = try self.expect(.type_ident, "expected type or trait name (TYPE_IDENT) after 'impl'");
        const first_name = try self.internSlice(first_tok.span);
        // An optional `<type_list>` after the first name: the trait's generic
        // args in `impl Trait<T> for Type` (EBNF `impl_trait_for_type`) OR the
        // inherent target's args in `impl<T> Range<T>` (EBNF `generic_type`
        // target, §891 patch). Either way the args are erased in M0.8 (no
        // monomorphisation codegen — the impl-level `<T>` carries the params).
        _ = try self.skipGenericArgs();
        // `impl Trait for Type` (trait impl) vs `impl [Type | Type<…>]` (inherent).
        // For the trait form the first name is the trait; the target follows `for`.
        var trait_name: StringId = 0;
        var type_name = first_name;
        if (self.peek() == .kw_for) {
            _ = try self.advance(); // 'for'
            trait_name = first_name;
            const target_tok = try self.expect(.type_ident, "expected target type (TYPE_IDENT) after 'for'");
            type_name = try self.internSlice(target_tok.span);
            // The trait-form target is a bare TYPE_IDENT (`impl_trait_for_type`);
            // a generic target there (`impl T for Bar<U>`) is not in the EBNF.
            if (self.peek() == .lt) {
                return self.parseErr(self.peekSpan(), "generic type arguments on a trait-impl target are not in the EBNF v0.6 (the target is a bare TYPE_IDENT; use impl-level generics 'impl<T> …')");
            }
        }

        var when_root: u32 = ast_mod.RuleDecl.none_when;
        if (self.peek() == .kw_when) {
            _ = try self.advance();
            when_root = try self.parseWhenExpr();
        }

        _ = try self.expect(.lbrace, "expected '{' to start impl body");
        const methods_start: u32 = @intCast(self.arena.impl_methods.items.len);
        while (self.peek() != .rbrace and self.peek() != .eof) {
            try self.surfaceTokenErrors();
            const method_annotations = try self.parseAnnotations();
            var is_async = false;
            if (self.peek() == .kw_async) {
                _ = try self.advance();
                is_async = true;
            }
            if (self.peek() != .kw_fn) {
                return self.parseErrFmt(self.peekSpan(), "expected 'fn' to start an impl method, got '{s}'", .{self.sliceOf(self.peekSpan())});
            }
            const parsed = try self.parseFnLike(is_async, true, false, method_annotations);
            try self.arena.impl_methods.append(self.gpa, parsed.decl);
        }
        const closing = try self.expect(.rbrace, "expected '}' to close impl body");
        const methods_len: u32 = @as(u32, @intCast(self.arena.impl_methods.items.len)) - methods_start;
        _ = try self.arena.addImplDecl(self.gpa, .{
            .type_name = type_name,
            .trait_name = trait_name,
            .when_root = when_root,
            .methods_start = methods_start,
            .methods_len = methods_len,
            .generics_start = impl_generics.start,
            .generics_len = impl_generics.len,
        }, .{ .byte_start = kw_span.byte_start, .byte_end = closing.span.byte_end });
    }

    /// Consume an optional `< type { "," type } >` generic-argument list,
    /// returning whether one was present (M0.8 E2 block 4). The arguments are
    /// parsed (and land in the arena) but erased — M0.8 has no monomorphisation
    /// codegen, so trait-arg / type-arg tracking is Phase 2.
    fn skipGenericArgs(self: *Parser) ParseError!bool {
        if (self.peek() != .lt) return false;
        _ = try self.advance(); // '<'
        while (true) {
            _ = try self.parseType();
            if (!try self.match(.comma)) break;
        }
        _ = try self.expect(.gt, "expected '>' to close generic type arguments");
        return true;
    }

    // ─── When clause ─────────────────────────────────────────────────────

    fn parseWhenExpr(self: *Parser) ParseError!u32 {
        return try self.parseWhenOr();
    }

    fn parseWhenOr(self: *Parser) ParseError!u32 {
        var lhs = try self.parseWhenAnd();
        while (self.peek() == .kw_or) {
            const op_span = (try self.advance()).span;
            const rhs = try self.parseWhenAnd();
            const lhs_span = self.arena.when_nodes.items[lhs].span;
            const rhs_span = self.arena.when_nodes.items[rhs].span;
            const node = ast_mod.WhenNode{
                .kind = .logical_or,
                .entity_name = 0,
                .type_name = 0,
                .field_name = 0,
                .filter_value = NodeId.none,
                .lhs = lhs,
                .rhs = rhs,
                .span = .{
                    .byte_start = @min(lhs_span.byte_start, op_span.byte_start),
                    .byte_end = rhs_span.byte_end,
                },
            };
            const idx: u32 = @intCast(self.arena.when_nodes.items.len);
            try self.arena.when_nodes.append(self.gpa, node);
            lhs = idx;
        }
        return lhs;
    }

    fn parseWhenAnd(self: *Parser) ParseError!u32 {
        var lhs = try self.parseWhenNot();
        while (self.peek() == .kw_and) {
            const op_span = (try self.advance()).span;
            const rhs = try self.parseWhenNot();
            const lhs_span = self.arena.when_nodes.items[lhs].span;
            const rhs_span = self.arena.when_nodes.items[rhs].span;
            const node = ast_mod.WhenNode{
                .kind = .logical_and,
                .entity_name = 0,
                .type_name = 0,
                .field_name = 0,
                .filter_value = NodeId.none,
                .lhs = lhs,
                .rhs = rhs,
                .span = .{
                    .byte_start = @min(lhs_span.byte_start, op_span.byte_start),
                    .byte_end = rhs_span.byte_end,
                },
            };
            const idx: u32 = @intCast(self.arena.when_nodes.items.len);
            try self.arena.when_nodes.append(self.gpa, node);
            lhs = idx;
        }
        return lhs;
    }

    fn parseWhenNot(self: *Parser) ParseError!u32 {
        if (self.peek() == .kw_not) {
            const op_span = (try self.advance()).span;
            const child = try self.parseWhenPrimary();
            const child_span = self.arena.when_nodes.items[child].span;
            const node = ast_mod.WhenNode{
                .kind = .logical_not,
                .entity_name = 0,
                .type_name = 0,
                .field_name = 0,
                .filter_value = NodeId.none,
                .lhs = child,
                .rhs = ast_mod.WhenNode.no_child,
                .span = .{
                    .byte_start = op_span.byte_start,
                    .byte_end = child_span.byte_end,
                },
            };
            const idx: u32 = @intCast(self.arena.when_nodes.items.len);
            try self.arena.when_nodes.append(self.gpa, node);
            return idx;
        }
        return try self.parseWhenPrimary();
    }

    fn parseWhenPrimary(self: *Parser) ParseError!u32 {
        if (self.peek() == .lparen) {
            _ = try self.advance();
            const inner = try self.parseWhenOr();
            _ = try self.expect(.rparen, "expected ')' to close grouped when expression");
            return inner;
        }
        if (self.peek() == .kw_resource) {
            const start_span = self.current.span;
            _ = try self.advance();
            const type_tok = try self.expect(.type_ident, "expected resource type after 'resource'");
            const type_name = try self.internSlice(type_tok.span);
            var kind = ast_mod.WhenNodeKind.resource;
            var filter_value = NodeId.none;
            var end_byte = type_tok.span.byte_end;
            if (self.peek() == .kw_changed) {
                const changed_tok = try self.advance();
                kind = .resource_changed;
                end_byte = changed_tok.span.byte_end;
            } else if (self.peek() == .lbrace and self.braceOpensWhenFilter()) {
                // `resource T { expression }` (M0.8 E4 — §6 general resource
                // filter; mutually exclusive with `changed`, like `has`). The
                // resource's fields are in scope inside the braces. The
                // brace-vs-body ambiguity is resolved by the matching-brace
                // scan (`braceOpensWhenFilter`).
                _ = try self.advance(); // '{'
                filter_value = try self.parseExpr(0);
                const closing = try self.expect(.rbrace, "expected '}' to close resource filter");
                end_byte = closing.span.byte_end;
                kind = .resource_filter;
            }
            const node = ast_mod.WhenNode{
                .kind = kind,
                .entity_name = 0,
                .type_name = type_name,
                .field_name = 0,
                .filter_value = filter_value,
                .lhs = ast_mod.WhenNode.no_child,
                .rhs = ast_mod.WhenNode.no_child,
                .span = .{ .byte_start = start_span.byte_start, .byte_end = end_byte },
            };
            const idx: u32 = @intCast(self.arena.when_nodes.items.len);
            try self.arena.when_nodes.append(self.gpa, node);
            return idx;
        }
        // §6 last arm: a bare boolean expression condition (M0.8 E4). The
        // structured `entity has …` / `entity tag_op …` arms are gated by
        // lookahead — anything else (including an identifier followed by a
        // postfix chain, a literal, `get(R)`, a paren that is not a when
        // group, …) parses as an expression CAPPED below the logical
        // operators (lbp(and)=3), so when-level `and`/`or` keep composing
        // conditions (semantically identical for bool operands).
        if (self.peek() != .ident or (self.peekNext() != .kw_has and !isTagOp(self.peekNext()))) {
            const expr = try self.parseExpr(5);
            const span = self.arena.exprSpan(expr);
            const node = ast_mod.WhenNode{
                .kind = .expr_cond,
                .entity_name = 0,
                .type_name = 0,
                .field_name = 0,
                .filter_value = expr,
                .lhs = ast_mod.WhenNode.no_child,
                .rhs = ast_mod.WhenNode.no_child,
                .span = span,
            };
            const idx: u32 = @intCast(self.arena.when_nodes.items.len);
            try self.arena.when_nodes.append(self.gpa, node);
            return idx;
        }
        // `entity has T [{ filter }]` or `entity tag_op tag_operand`.
        const entity_tok = try self.expect(.ident, "expected entity binding in when clause");
        const entity_name = try self.internSlice(entity_tok.span);
        // `entity has_tag .path` / `entity has_any_tag [.a, .b]` (M0.8 E3 tag
        // filter, `etch-grammar.md` §6 l.945). The tag op stands where `has`
        // would; dispatch before the `has` path.
        if (isTagOp(self.peek())) {
            return try self.parseTagFilterWhen(entity_name, entity_tok.span);
        }
        _ = try self.expect(.kw_has, "expected 'has' in when clause");
        const type_tok = try self.expect(.type_ident, "expected component type after 'has'");
        const type_name = try self.internSlice(type_tok.span);

        var kind = ast_mod.WhenNodeKind.has;
        var field_name: StringId = 0;
        var filter_value: NodeId = NodeId.none;
        var end_byte = type_tok.span.byte_end;
        // `entity has T changed` (M0.8 E3) — change-detection filter, the exact
        // mirror of `resource T changed` (`etch-grammar.md` §6, patched). Tested
        // before the `{ filter }` form: the two are mutually exclusive (the EBNF
        // `has T changed` carries no field filter).
        if (self.peek() == .kw_changed) {
            const changed_tok = try self.advance();
            kind = .has_changed;
            end_byte = changed_tok.span.byte_end;
        } else if (self.peek() == .lbrace and self.peekNext() == .ident and self.peekNext2() == .eq_eq) {
            _ = try self.advance(); // '{'
            const field_tok = try self.advance(); // IDENT
            field_name = try self.internSlice(field_tok.span);
            _ = try self.advance(); // '=='
            filter_value = try self.parseExpr(0);
            const closing = try self.expect(.rbrace, "expected '}' to close has-with-filter");
            end_byte = closing.span.byte_end;
            kind = .has_with_filter;
        } else if (self.peek() == .lbrace and self.braceOpensWhenFilter()) {
            // `has T { expression }` (M0.8 E4 — §6 general field filter; the
            // narrow `{ field == value }` fast path above keeps the delivered
            // E3 representation byte-for-byte). T's fields are in scope
            // inside the braces. The brace-vs-body ambiguity is resolved by
            // the matching-brace scan (`braceOpensWhenFilter`).
            _ = try self.advance(); // '{'
            filter_value = try self.parseExpr(0);
            const closing = try self.expect(.rbrace, "expected '}' to close has filter expression");
            end_byte = closing.span.byte_end;
            kind = .has_expr_filter;
        }
        const node = ast_mod.WhenNode{
            .kind = kind,
            .entity_name = entity_name,
            .type_name = type_name,
            .field_name = field_name,
            .filter_value = filter_value,
            .lhs = ast_mod.WhenNode.no_child,
            .rhs = ast_mod.WhenNode.no_child,
            .span = .{ .byte_start = entity_tok.span.byte_start, .byte_end = end_byte },
        };
        const idx: u32 = @intCast(self.arena.when_nodes.items.len);
        try self.arena.when_nodes.append(self.gpa, node);
        return idx;
    }

    /// Whether the `{` at the current token opens a §6 when-filter
    /// expression rather than the construct body that follows the when
    /// clause (M0.8 E4). Disambiguated by scanning a SCRATCH lexer from the
    /// brace to its matching `}` and checking the next token: a filter
    /// brace is always followed by `{` (the body / a composite's children),
    /// `and`, or `or`; a body brace is followed by anything else (next
    /// top-level construct, EOF, …). The scratch lexer's trivia side-lists
    /// are throwaway — the main token stream is untouched.
    fn braceOpensWhenFilter(self: *Parser) bool {
        std.debug.assert(self.peek() == .lbrace);
        var scratch = lexer_mod.Lexer.init(self.source);
        scratch.pos = self.peekSpan().byte_start;
        defer scratch.deinit(self.gpa);
        var depth: u32 = 0;
        while (true) {
            const tok = scratch.next(self.gpa) catch return false;
            switch (tok.kind) {
                .lbrace => depth += 1,
                .rbrace => {
                    if (depth == 0) return false; // unbalanced — not a filter
                    depth -= 1;
                    if (depth == 0) {
                        const after = scratch.next(self.gpa) catch return false;
                        return after.kind == .lbrace or after.kind == .kw_and or after.kind == .kw_or;
                    }
                },
                .eof => return false,
                else => {},
            }
        }
    }

    /// True when `k` is one of the five tag query operator keywords (M0.8 E3).
    fn isTagOp(k: token_mod.TokenKind) bool {
        return switch (k) {
            .kw_has_tag, .kw_has_no_tag, .kw_has_any_tag, .kw_has_all_tags, .kw_has_no_tags => true,
            else => false,
        };
    }

    fn tagOpFromToken(k: token_mod.TokenKind) ast_mod.TagOp {
        return switch (k) {
            .kw_has_tag => .has_tag,
            .kw_has_no_tag => .has_no_tag,
            .kw_has_any_tag => .has_any_tag,
            .kw_has_all_tags => .has_all_tags,
            .kw_has_no_tags => .has_no_tags,
            else => unreachable,
        };
    }

    /// Parse a `TAG_PATH = "." IDENT {"." IDENT}` (M0.8 E3, `etch-grammar.md`
    /// §1.3) into a `tag_path` expression. Parsed only in tag-operand position,
    /// so the leading `.` never collides with the `.variant` enum shorthand.
    fn parseTagPathExpr(self: *Parser) ParseError!NodeId {
        const dot = try self.expect(.dot, "expected '.' to start a tag path");
        var segs: std.ArrayListUnmanaged(StringId) = .empty;
        defer segs.deinit(self.gpa);
        const first = try self.expect(.ident, "expected tag segment after '.'");
        try segs.append(self.gpa, try self.internSlice(first.span));
        var end_byte = first.span.byte_end;
        while (self.peek() == .dot) {
            _ = try self.advance();
            const seg = try self.expect(.ident, "expected tag segment after '.'");
            try segs.append(self.gpa, try self.internSlice(seg.span));
            end_byte = seg.span.byte_end;
        }
        return try self.arena.addTagPath(self.gpa, segs.items, .{ .byte_start = dot.span.byte_start, .byte_end = end_byte });
    }

    /// Parse the operand of a tag op into a `(start, len)` run of `tag_path`
    /// node ids in `arena.tag_operands`: a single `.path`, or a bracketed list
    /// `[.a, .b]` (`etch-grammar.md` §3.2 `tag_operand`). The bare-`TYPE_IDENT`
    /// category operand form is deferred (a dotted path resolving to a namespace
    /// already expresses a category).
    fn parseTagOperandRun(self: *Parser) ParseError!struct { start: u32, len: u32 } {
        const start: u32 = @intCast(self.arena.tag_operands.items.len);
        if (self.peek() == .lbracket) {
            _ = try self.advance(); // '['
            while (self.peek() != .rbracket and self.peek() != .eof) {
                const p = try self.parseTagPathExpr();
                try self.arena.tag_operands.append(self.gpa, p);
                if (!try self.match(.comma)) break;
            }
            _ = try self.expect(.rbracket, "expected ']' to close the tag list");
        } else {
            const p = try self.parseTagPathExpr();
            try self.arena.tag_operands.append(self.gpa, p);
        }
        return .{ .start = start, .len = @as(u32, @intCast(self.arena.tag_operands.items.len)) - start };
    }

    /// Parse `entity tag_op tag_operand` into a `.tag_filter` when-node (M0.8
    /// E3). The receiver `entity` ident is already consumed; the current token
    /// is the tag op.
    fn parseTagFilterWhen(self: *Parser, entity_name: StringId, entity_span: token_mod.SourceSpan) ParseError!u32 {
        const op_tok = try self.advance(); // the tag op keyword
        const op = tagOpFromToken(op_tok.kind);
        const operand = try self.parseTagOperandRun();
        const filter_idx: u32 = @intCast(self.arena.tag_filters.items.len);
        try self.arena.tag_filters.append(self.gpa, .{
            .op = op,
            .operand_start = operand.start,
            .operand_len = operand.len,
        });
        const end_byte = if (operand.len > 0)
            self.arena.exprSpan(self.arena.tag_operands.items[operand.start + operand.len - 1]).byte_end
        else
            op_tok.span.byte_end;
        const node = ast_mod.WhenNode{
            .kind = .tag_filter,
            .entity_name = entity_name,
            .type_name = 0,
            .field_name = 0,
            .filter_value = NodeId.none,
            .lhs = ast_mod.WhenNode.no_child,
            .rhs = ast_mod.WhenNode.no_child,
            .aux = filter_idx,
            .span = .{ .byte_start = entity_span.byte_start, .byte_end = end_byte },
        };
        const idx: u32 = @intCast(self.arena.when_nodes.items.len);
        try self.arena.when_nodes.append(self.gpa, node);
        return idx;
    }

    /// Parse the tail of a `tag_mutation_stmt` (`expression "."
    /// ("add_tag"|"remove_tag") "(" TAG_PATH ")"`, M0.8 E3, `etch-grammar.md`
    /// §4.4 l.697). The `receiver` and the `add_tag`/`remove_tag` keyword are
    /// already consumed; the current token is `(`. Produces a `.stmt`-category
    /// `tag_mutation_stmt` node — a mutation has no value, so it is a statement,
    /// not an expression. The bare-`TYPE_IDENT` category operand is deferred (a
    /// dotted namespace path already expresses a category), consistent with the
    /// query-operand parser.
    fn parseTagMutation(self: *Parser, receiver: NodeId, kind: ast_mod.TagMutationKind) ParseError!NodeId {
        _ = try self.expect(.lparen, "expected '(' after add_tag/remove_tag");
        const path = try self.parseTagPathExpr();
        const closing = try self.expect(.rparen, "expected ')' to close add_tag/remove_tag");
        const recv_span = self.arena.exprSpan(receiver);
        return try self.arena.addTagMutationStmt(self.gpa, .{
            .receiver = receiver,
            .kind = kind,
            .path = path,
        }, .{ .byte_start = recv_span.byte_start, .byte_end = closing.span.byte_end });
    }

    // ─── Statements ──────────────────────────────────────────────────────

    /// Collect `statement*` until `}` / EOF (without consuming the brace)
    /// into a contiguous run of statement ids in `arena.extra`, returning
    /// `(start, len)`. Statements are gathered in a temp list and bulk-
    /// appended only after the whole run is parsed, so a nested block (a
    /// `for` body inside a rule body) finalizes its own run first and the two
    /// ranges never interleave in `extra`.
    fn parseStmtRun(self: *Parser) ParseError!struct { start: u32, len: u32 } {
        var stmts: std.ArrayListUnmanaged(u32) = .empty;
        defer stmts.deinit(self.gpa);
        while (self.peek() != .rbrace and self.peek() != .eof) {
            try self.surfaceTokenErrors();
            try stmts.append(self.gpa, (try self.parseStmt()).raw());
        }
        const start: u32 = @intCast(self.arena.extra.items.len);
        try self.arena.extra.appendSlice(self.gpa, stmts.items);
        return .{ .start = start, .len = @intCast(stmts.items.len) };
    }

    /// True when the current token starts a keyword-led statement that can
    /// never be a block's trailing value (`let` / `assert` / `for` / `while` /
    /// `break` / `continue` / `throw` / `try`, plus the `IDENT ":" loop`
    /// labeled-loop form). Mirrors the keyword dispatch in `parseStmt`; used by
    /// `parseBlockBody` to route those to `parseStmt` while keeping the
    /// expression-led path open for trailing-value detection.
    fn startsKeywordStmt(self: *const Parser) bool {
        return switch (self.peek()) {
            .kw_let, .kw_assert, .kw_for, .kw_while, .kw_break, .kw_continue, .kw_throw, .kw_try, .kw_return, .kw_emit => true,
            .ident => self.peekNext() == .colon, // labeled loop `outer:`
            else => false,
        };
    }

    /// Parse a value-block body `{ statement } [ expression ]` (M0.8 control
    /// flow, `etch-grammar.md` §4.1 l.645). Returns the statement run plus the
    /// trailing expression that is the block's value (`NodeId.none` when
    /// value-less). Etch has no statement separator, so the last expression-led
    /// item immediately before `}` — not an assignment, not a keyword statement
    /// — is the block value (reference §6.11/§6.12). Distinct from
    /// `parseStmtRun` (rule / `loop` / `for` / `while` / `try` bodies, which are
    /// statement-only and never extract a trailing value).
    fn parseBlockBody(self: *Parser) ParseError!struct { start: u32, len: u32, value: NodeId } {
        var stmts: std.ArrayListUnmanaged(u32) = .empty;
        defer stmts.deinit(self.gpa);
        var value: NodeId = NodeId.none;
        while (self.peek() != .rbrace and self.peek() != .eof) {
            try self.surfaceTokenErrors();
            if (self.startsKeywordStmt()) {
                try stmts.append(self.gpa, (try self.parseStmt()).raw());
                continue;
            }
            // Expression-led: an assignment statement, an expression statement,
            // or the trailing block value.
            const expr_start = self.current.span;
            const expr = try self.parseExpr(0);
            // A `tag_mutation_stmt` (`entity.add_tag(.x)`) parses as a
            // `.stmt`-category node inside `continuePostfix` (M0.8 E3); it is a
            // statement, never a block's trailing value.
            if (expr.category == .stmt) {
                try stmts.append(self.gpa, expr.raw());
                continue;
            }
            if (isAssignOp(self.peek())) {
                const op_tok = try self.advance();
                const op = assignOpFromKind(op_tok.kind);
                const rhs = try self.parseExpr(0);
                const span: SourceSpan = .{ .byte_start = expr_start.byte_start, .byte_end = self.arena.exprSpan(rhs).byte_end };
                try stmts.append(self.gpa, (try self.arena.addAssignStmt(self.gpa, .{ .target = expr, .op = op, .value = rhs }, span)).raw());
            } else if (self.peek() == .rbrace) {
                value = expr; // last bare expression before `}` is the block value
            } else {
                const span: SourceSpan = .{ .byte_start = expr_start.byte_start, .byte_end = self.arena.exprSpan(expr).byte_end };
                try stmts.append(self.gpa, (try self.arena.addExprStmt(self.gpa, expr, span)).raw());
            }
        }
        const start: u32 = @intCast(self.arena.extra.items.len);
        try self.arena.extra.appendSlice(self.gpa, stmts.items);
        return .{ .start = start, .len = @intCast(stmts.items.len), .value = value };
    }

    /// Parse a block expression `{ ... }` in expression position (M0.8 control
    /// flow, `etch-grammar.md` §3.2 l.520 — `block_expr = block`). The block's
    /// value is its trailing expression (or `unit` when value-less). Used
    /// directly (`let x = { ...; v }`), as `if` / `match` arm bodies, and as
    /// closure bodies.
    fn parseBlockExpr(self: *Parser) ParseError!NodeId {
        const open = try self.expect(.lbrace, "expected '{' to start block expression");
        const body = try self.parseBlockBody();
        const closing = try self.expect(.rbrace, "expected '}' to close block expression");
        return try self.arena.addBlockExpr(self.gpa, body.start, body.len, body.value, .{
            .byte_start = open.span.byte_start,
            .byte_end = closing.span.byte_end,
        });
    }

    /// Parse `if cond block {else if cond block} [else block]` (M0.8 control
    /// flow, `etch-grammar.md` §3.2 l.500 / §4.1 l.618). Parsed as an
    /// if-expression in `parsePrimary`; in statement position it is wrapped as
    /// an expr-statement (mirroring `loop`). The condition is an ordinary
    /// expression — it stops before the then-block's `{` (a `{` is not a
    /// postfix / infix continuation). The else-if chain recurses through
    /// `else_branch` (a nested `if_expr`); a final `else { }` is a `block_expr`.
    fn parseIf(self: *Parser) ParseError!NodeId {
        const kw_span = (try self.advance()).span; // 'if'
        // `if let <name> = <optional> { … } [else { … }]` (M0.8 E2 block 5,
        // `etch-grammar.md` §501) — unwraps an optional, binding `<name>` to its
        // payload in the then-block.
        var let_binding: StringId = 0;
        if (self.peek() == .kw_let) {
            _ = try self.advance(); // 'let'
            const target = try self.expect(.ident, "expected binding name after 'if let'");
            let_binding = try self.internSlice(target.span);
            _ = try self.expect(.eq, "expected '=' in 'if let' binding");
        }
        const cond = try self.parseExprNoStruct(0);
        const then_block = try self.parseBlockExpr();
        var else_branch: NodeId = NodeId.none;
        if (self.peek() == .kw_else) {
            _ = try self.advance(); // 'else'
            else_branch = if (self.peek() == .kw_if)
                try self.parseIf()
            else
                try self.parseBlockExpr();
        }
        const end = if (else_branch.isNone()) self.arena.exprSpan(then_block) else self.arena.exprSpan(else_branch);
        return try self.arena.addIfExpr(self.gpa, cond, then_block, else_branch, let_binding, .{
            .byte_start = kw_span.byte_start,
            .byte_end = end.byte_end,
        });
    }

    /// Parse `for IDENT [, IDENT] in iterable { body }` (M0.8 v0.6
    /// foundations, `etch-grammar.md` §621). E1 iterates ranges; array / map
    /// iterables arrive with collections.
    fn parseForStmt(self: *Parser) ParseError!NodeId {
        const for_span = (try self.advance()).span; // 'for'
        const var_tok = try self.expect(.ident, "expected loop variable after 'for'");
        const var_name = try self.internSlice(var_tok.span);
        var index_name: StringId = 0;
        if (self.peek() == .comma) {
            _ = try self.advance();
            const idx_tok = try self.expect(.ident, "expected second binding after ',' in for");
            index_name = try self.internSlice(idx_tok.span);
        }
        _ = try self.expect(.kw_in, "expected 'in' in for loop");
        const iterable = try self.parseExprNoStruct(0);
        _ = try self.expect(.lbrace, "expected '{' to open for body");
        const body = try self.parseStmtRun();
        const closing = try self.expect(.rbrace, "expected '}' to close for body");
        return try self.arena.addForStmt(self.gpa, .{
            .var_name = var_name,
            .index_name = index_name,
            .iterable = iterable,
            .body_start = body.start,
            .body_len = body.len,
        }, .{ .byte_start = for_span.byte_start, .byte_end = closing.span.byte_end });
    }

    /// Parse `while cond block` (M0.8 control flow, `etch-grammar.md` §4.1
    /// l.622). The condition is an ordinary expression (it stops before the
    /// body's `{`); the body is a statement run (no value, like a loop body).
    /// `break` / `continue` inside target this loop (unlabeled in M0.8); the
    /// `while let` Optional-destructuring form lands with the Optional tranche.
    fn parseWhileStmt(self: *Parser) ParseError!NodeId {
        const kw_span = (try self.advance()).span; // 'while'
        // `while let <name> = <optional> { … }` (M0.8 E2 block 5,
        // `etch-grammar.md` §623) — re-evaluates the optional each iteration,
        // binding `<name>` to its payload in the body; stops on `none`.
        var let_binding: StringId = 0;
        if (self.peek() == .kw_let) {
            _ = try self.advance(); // 'let'
            const target = try self.expect(.ident, "expected binding name after 'while let'");
            let_binding = try self.internSlice(target.span);
            _ = try self.expect(.eq, "expected '=' in 'while let' binding");
        }
        const cond = try self.parseExprNoStruct(0);
        _ = try self.expect(.lbrace, "expected '{' to start the while body");
        const body = try self.parseStmtRun();
        const closing = try self.expect(.rbrace, "expected '}' to close the while body");
        return try self.arena.addWhileStmt(self.gpa, .{
            .cond = cond,
            .body_start = body.start,
            .body_len = body.len,
            .let_binding = let_binding,
        }, .{ .byte_start = kw_span.byte_start, .byte_end = closing.span.byte_end });
    }

    /// Parse `loop { body }` (M0.8 loop/break, `etch-grammar.md` §522/§624).
    /// `label` is `0` for an unlabeled loop; a labeled loop pushes its label so
    /// nested `break`/`continue` can target it.
    fn parseLoop(self: *Parser, label: StringId) ParseError!NodeId {
        const kw_span = (try self.advance()).span; // 'loop'
        _ = try self.expect(.lbrace, "expected '{' to start loop body");
        if (label != 0) try self.active_labels.append(self.gpa, label);
        const body = try self.parseStmtRun();
        if (label != 0) _ = self.active_labels.pop();
        const closing = try self.expect(.rbrace, "expected '}' to close loop body");
        return try self.arena.addLoopExpr(self.gpa, label, body.start, body.len, .{
            .byte_start = kw_span.byte_start,
            .byte_end = closing.span.byte_end,
        });
    }

    /// Parse `IDENT ":" loop { ... }` (M0.8 loop/break). Only `loop` can be
    /// labeled in E1 (labeled `for` is a later refinement).
    fn parseLabeledLoop(self: *Parser) ParseError!NodeId {
        const label_tok = try self.advance(); // IDENT
        const label = try self.internSlice(label_tok.span);
        _ = try self.expect(.colon, "expected ':' after loop label");
        if (self.peek() != .kw_loop) {
            return self.parseErrFmt(self.peekSpan(), "only 'loop' can be labeled in E1, got '{s}'", .{self.sliceOf(self.peekSpan())});
        }
        // A labeled loop appears in statement position — wrap the loop
        // expression as an expr-statement (matching the bare-`loop` statement
        // path, which goes through `parseExpr` + `addExprStmt`).
        const loop_node = try self.parseLoop(label);
        return try self.arena.addExprStmt(self.gpa, loop_node, self.arena.exprSpan(loop_node));
    }

    /// Parse `break [label] [value]` (M0.8 loop/break, `etch-grammar.md` §632).
    /// A leading IDENT is the label only when it names an active loop label
    /// (else it begins the value expression).
    fn parseBreakStmt(self: *Parser) ParseError!NodeId {
        const kw = try self.advance(); // 'break'
        var label: StringId = 0;
        var value: NodeId = NodeId.none;
        var end_byte = kw.span.byte_end;
        if (self.peek() == .ident) {
            const cand = try self.internSlice(self.current.span);
            if (self.isActiveLabel(cand)) {
                const lt = try self.advance();
                label = cand;
                end_byte = lt.span.byte_end;
            }
        }
        if (canStartExpr(self.peek())) {
            value = try self.parseExpr(0);
            end_byte = self.arena.exprSpan(value).byte_end;
        }
        return try self.arena.addBreakStmt(self.gpa, label, value, .{ .byte_start = kw.span.byte_start, .byte_end = end_byte });
    }

    /// Parse `continue [label]` (M0.8 loop/break, `etch-grammar.md` §633).
    fn parseContinueStmt(self: *Parser) ParseError!NodeId {
        const kw = try self.advance(); // 'continue'
        var label: StringId = 0;
        var end_byte = kw.span.byte_end;
        if (self.peek() == .ident) {
            const cand = try self.internSlice(self.current.span);
            if (self.isActiveLabel(cand)) {
                const lt = try self.advance();
                label = cand;
                end_byte = lt.span.byte_end;
            }
        }
        return try self.arena.addContinueStmt(self.gpa, label, .{ .byte_start = kw.span.byte_start, .byte_end = end_byte });
    }

    /// Parse `throw expression` (M0.8 error handling, `etch-grammar.md` §641).
    fn parseThrowStmt(self: *Parser) ParseError!NodeId {
        const kw = try self.advance(); // 'throw'
        const value = try self.parseExpr(0);
        return try self.arena.addThrowStmt(self.gpa, value, .{
            .byte_start = kw.span.byte_start,
            .byte_end = self.arena.exprSpan(value).byte_end,
        });
    }

    /// Parse `return [expression]` (M0.8 E2 call mechanism, `etch-grammar.md`
    /// §4.1 l.630). Etch has no statement separator, so a `return` immediately
    /// before `}` (or EOF) is a bare/void return; otherwise the following
    /// expression is the return value. Dead-code `return` mid-block (followed by
    /// more statements) is not in the block-2 surface.
    fn parseReturnStmt(self: *Parser) ParseError!NodeId {
        const kw = try self.advance(); // 'return'
        if (self.peek() == .rbrace or self.peek() == .eof) {
            return try self.arena.addReturnStmt(self.gpa, NodeId.none, kw.span);
        }
        const value = try self.parseExpr(0);
        return try self.arena.addReturnStmt(self.gpa, value, .{
            .byte_start = kw.span.byte_start,
            .byte_end = self.arena.exprSpan(value).byte_end,
        });
    }

    /// Parse `try { ... } catch IDENT { ... }` (M0.8 error handling,
    /// `etch-grammar.md` §640). Both bodies are statement runs.
    fn parseTryCatchStmt(self: *Parser) ParseError!NodeId {
        const kw = try self.advance(); // 'try'
        _ = try self.expect(.lbrace, "expected '{' to open try block");
        const try_body = try self.parseStmtRun();
        _ = try self.expect(.rbrace, "expected '}' to close try block");
        _ = try self.expect(.kw_catch, "expected 'catch' after the try block");
        const name_tok = try self.expect(.ident, "expected catch binding name");
        const catch_name = try self.internSlice(name_tok.span);
        _ = try self.expect(.lbrace, "expected '{' to open catch block");
        const catch_body = try self.parseStmtRun();
        const closing = try self.expect(.rbrace, "expected '}' to close catch block");
        return try self.arena.addTryCatchStmt(self.gpa, .{
            .try_start = try_body.start,
            .try_len = try_body.len,
            .catch_name = catch_name,
            .catch_start = catch_body.start,
            .catch_len = catch_body.len,
        }, .{ .byte_start = kw.span.byte_start, .byte_end = closing.span.byte_end });
    }

    /// Parse `emit TYPE_IDENT "{" {field_init} "}"` (M0.8 E3, `etch-grammar.md`
    /// §4.1 `emit_stmt` + §5.10). `field_init = IDENT ":" expression`; the
    /// field-init loop mirrors `parseStructLiteral` (an event is a POD struct).
    /// The spread form `..base` is rejected. Field initializers are stored in a
    /// `(start, len)` run of `arena.struct_lit_fields`.
    fn parseEmitStmt(self: *Parser) ParseError!NodeId {
        const kw = try self.advance(); // 'emit'
        const name_tok = try self.expect(.type_ident, "expected event type (TYPE_IDENT) after 'emit'");
        const event_type = try self.internSlice(name_tok.span);
        _ = try self.expect(.lbrace, "expected '{' to start the emitted event body");
        const saved = self.no_struct_lit;
        self.no_struct_lit = false;
        defer self.no_struct_lit = saved;
        const fields_start: u32 = @intCast(self.arena.struct_lit_fields.items.len);
        while (self.peek() != .rbrace and self.peek() != .eof) {
            if (self.peek() == .dotdot) {
                return self.parseErr(self.peekSpan(), "emit-body spread '..base' is not supported in M0.8 (data-table feature, E4)");
            }
            const fname = try self.expect(.ident, "expected field name in emit body");
            _ = try self.expect(.colon, "expected ':' after emit-body field name");
            const value = try self.parseExpr(0);
            try self.arena.struct_lit_fields.append(self.gpa, .{ .name = try self.internSlice(fname.span), .value = value });
            if (!try self.match(.comma)) break;
        }
        const closing = try self.expect(.rbrace, "expected '}' to close the emitted event body");
        const fields_len: u32 = @as(u32, @intCast(self.arena.struct_lit_fields.items.len)) - fields_start;
        return try self.arena.addEmitStmt(self.gpa, .{
            .event_type = event_type,
            .fields_start = fields_start,
            .fields_len = fields_len,
        }, .{ .byte_start = kw.span.byte_start, .byte_end = closing.span.byte_end });
    }

    fn parseStmt(self: *Parser) ParseError!NodeId {
        if (self.peek() == .kw_after) {
            // `after` graduated to a keyword for routine triggers (M0.8 E4);
            // the §4.3 timer statement it also heads stays out of M0.8 —
            // keep the fail-loud explicit (it lexed `error_unknown_keyword`
            // before the graduation).
            return self.parseErr(self.peekSpan(), "timer statements ('after ...') are not in M0.8 scope (Phase 2)");
        }
        if (self.peek() == .kw_let) {
            return try self.parseLetStmt();
        }
        if (self.peek() == .kw_assert) {
            return try self.parseAssertStmt();
        }
        if (self.peek() == .kw_for) {
            return try self.parseForStmt();
        }
        if (self.peek() == .kw_while) {
            return try self.parseWhileStmt();
        }
        if (self.peek() == .kw_break) {
            return try self.parseBreakStmt();
        }
        if (self.peek() == .kw_continue) {
            return try self.parseContinueStmt();
        }
        if (self.peek() == .kw_throw) {
            return try self.parseThrowStmt();
        }
        if (self.peek() == .kw_try) {
            return try self.parseTryCatchStmt();
        }
        if (self.peek() == .kw_return) {
            return try self.parseReturnStmt();
        }
        if (self.peek() == .kw_emit) {
            return try self.parseEmitStmt();
        }
        // Labeled loop: `IDENT ":" loop { ... }` (M0.8 loop/break).
        if (self.peek() == .ident and self.peekNext() == .colon) {
            return try self.parseLabeledLoop();
        }
        // Either an assignment (lvalue followed by =/+=/etc.) or an expr stmt.
        const expr_start = self.current.span;
        const expr = try self.parseExpr(0);
        // `entity.add_tag(.x)` / `entity.remove_tag(.x)` parse as a complete
        // statement inside `continuePostfix` (M0.8 E3) — a `.stmt`-category
        // node. Return it directly; it is neither an assignment target nor an
        // expression statement to be wrapped.
        if (expr.category == .stmt) return expr;
        if (isAssignOp(self.peek())) {
            const op_tok = try self.advance();
            const op = assignOpFromKind(op_tok.kind);
            const value = try self.parseExpr(0);
            const span: SourceSpan = .{
                .byte_start = expr_start.byte_start,
                .byte_end = self.arena.exprSpan(value).byte_end,
            };
            return try self.arena.addAssignStmt(self.gpa, .{
                .target = expr,
                .op = op,
                .value = value,
            }, span);
        }
        const span: SourceSpan = .{
            .byte_start = expr_start.byte_start,
            .byte_end = self.arena.exprSpan(expr).byte_end,
        };
        return try self.arena.addExprStmt(self.gpa, expr, span);
    }

    fn parseLetStmt(self: *Parser) ParseError!NodeId {
        const let_span = self.current.span;
        _ = try self.advance();
        const is_mut = try self.match(.kw_mut);
        const name_tok = try self.expect(.ident, "expected name after 'let'");
        const name_id = try self.internSlice(name_tok.span);
        var type_annotation: NodeId = NodeId.none;
        if (try self.match(.colon)) {
            type_annotation = try self.parseType();
        }
        _ = try self.expect(.eq, "expected '=' in let binding");
        const value = try self.parseExpr(0);
        const span: SourceSpan = .{
            .byte_start = let_span.byte_start,
            .byte_end = self.arena.exprSpan(value).byte_end,
        };
        return try self.arena.addLetStmt(self.gpa, .{
            .name = name_id,
            .is_mut = is_mut,
            .type_annotation = type_annotation,
            .value = value,
        }, span);
    }

    /// Parse `assert ( cond [, "message"] )` (M0.8 v0.6 foundations,
    /// `etch-reference-part1.md` §10.3). The optional message is a string
    /// literal dev diagnostic; the condition is checked to be `bool` by the
    /// type-checker.
    fn parseAssertStmt(self: *Parser) ParseError!NodeId {
        const kw_span = (try self.advance()).span; // 'assert'
        _ = try self.expect(.lparen, "expected '(' after 'assert'");
        const cond = try self.parseExpr(0);
        var message: StringId = 0;
        if (self.peek() == .comma) {
            _ = try self.advance();
            const msg_tok = try self.expect(.string_literal, "expected a string-literal message after ',' in assert");
            message = try self.internStringLiteral(msg_tok.span);
        }
        const closing = try self.expect(.rparen, "expected ')' to close assert");
        return try self.arena.addAssertStmt(self.gpa, .{ .cond = cond, .message = message }, .{
            .byte_start = kw_span.byte_start,
            .byte_end = closing.span.byte_end,
        });
    }

    fn isAssignOp(kind: TokenKind) bool {
        return switch (kind) {
            .eq, .plus_eq, .minus_eq, .star_eq, .slash_eq, .percent_eq => true,
            else => false,
        };
    }

    fn assignOpFromKind(kind: TokenKind) ast_mod.AssignOp {
        return switch (kind) {
            .eq => .assign,
            .plus_eq => .add_assign,
            .minus_eq => .sub_assign,
            .star_eq => .mul_assign,
            .slash_eq => .div_assign,
            .percent_eq => .rem_assign,
            else => unreachable,
        };
    }

    // ─── Expressions (Pratt) ─────────────────────────────────────────────

    pub fn parseExpr(self: *Parser, min_bp: u8) ParseError!NodeId {
        const lhs = try self.parseUnary();
        return try self.continuePostfixAndBinary(lhs, min_bp);
    }

    /// Parse an expression with struct literals suppressed at the top level
    /// (M0.8 E2 block 3) — used for `if` / `while` / `for` / `match` head
    /// expressions, where a trailing `{` opens the body, not a `TYPE_IDENT {`
    /// struct literal. Delimited sub-contexts re-enable struct literals.
    fn parseExprNoStruct(self: *Parser, min_bp: u8) ParseError!NodeId {
        const saved = self.no_struct_lit;
        self.no_struct_lit = true;
        defer self.no_struct_lit = saved;
        return try self.parseExpr(min_bp);
    }

    // Range binds weaker than additive (lbp 7) but stronger than comparison
    // (lbp 5), per `etch-grammar.md` §410 (range_expr = additive [op additive]).
    const range_lbp: u8 = 6;

    fn continuePostfixAndBinary(self: *Parser, lhs_in: NodeId, min_bp: u8) ParseError!NodeId {
        var lhs = lhs_in;
        while (true) {
            const rk = self.peek();
            if (rk == .dotdot or rk == .dotdot_eq) {
                if (range_lbp < min_bp) break;
                _ = try self.advance();
                // Additive (rbp 7) binds into each bound; ranges don't chain.
                const rhs = try self.parseExpr(7);
                const lhs_span = self.arena.exprSpan(lhs);
                const rhs_span = self.arena.exprSpan(rhs);
                lhs = try self.arena.addRange(self.gpa, lhs, rhs, rk == .dotdot_eq, .{
                    .byte_start = lhs_span.byte_start,
                    .byte_end = rhs_span.byte_end,
                });
                break;
            }
            const info = infixBindingPower(self.peek()) orelse break;
            if (info.lbp < min_bp) break;
            const op_tok = try self.advance();
            const op = binaryOpFromKind(op_tok.kind);
            const rhs = try self.parseExpr(info.rbp);
            const lhs_span = self.arena.exprSpan(lhs);
            const rhs_span = self.arena.exprSpan(rhs);
            const span: SourceSpan = .{
                .byte_start = lhs_span.byte_start,
                .byte_end = rhs_span.byte_end,
            };
            lhs = try self.arena.addBinary(self.gpa, op, lhs, rhs, span);
        }
        return lhs;
    }

    fn parseUnary(self: *Parser) ParseError!NodeId {
        switch (self.peek()) {
            .minus => {
                const op_span = (try self.advance()).span;
                const operand = try self.parseUnary();
                const operand_span = self.arena.exprSpan(operand);
                return try self.arena.addUnary(self.gpa, .neg, operand, .{
                    .byte_start = op_span.byte_start,
                    .byte_end = operand_span.byte_end,
                });
            },
            .kw_not => {
                const op_span = (try self.advance()).span;
                const operand = try self.parseUnary();
                const operand_span = self.arena.exprSpan(operand);
                return try self.arena.addUnary(self.gpa, .logical_not, operand, .{
                    .byte_start = op_span.byte_start,
                    .byte_end = operand_span.byte_end,
                });
            },
            else => return try self.parsePostfix(),
        }
    }

    fn parsePostfix(self: *Parser) ParseError!NodeId {
        const expr = try self.parsePrimary();
        const after_postfix = try self.continuePostfix(expr);
        return self.continueCast(after_postfix);
    }

    /// Continue a left-associative `expr as Type` cast chain (M0.8 v0.6
    /// foundations). `as` binds tighter than the binary operators and
    /// looser than the `.field` / `.get` postfix chain, so `a.b as f32 + c`
    /// parses as `((a.b) as f32) + c`.
    fn continueCast(self: *Parser, expr_in: NodeId) ParseError!NodeId {
        var expr = expr_in;
        while (self.peek() == .kw_as) {
            _ = try self.advance();
            const type_node = try self.parseType();
            const operand_span = self.arena.exprSpan(expr);
            const type_span = self.arena.typeNodeSpan(type_node);
            expr = try self.arena.addCast(self.gpa, expr, type_node, .{
                .byte_start = operand_span.byte_start,
                .byte_end = type_span.byte_end,
            });
        }
        return expr;
    }

    /// Continue a postfix `.field` / `.get(T)` / `.get_mut(T)` chain on an
    /// already-parsed receiver. Extracted from `parsePostfix` so annotation
    /// arguments that begin with an identifier (`@requires(self.health)`)
    /// also pick up the postfix chain (D-S3-annot-field-access): the
    /// named-arg lookahead in `parseAnnotationArg` consumes the leading
    /// ident before the normal `parsePrimary` postfix path can run, so the
    /// ident must be threaded back through this helper.
    fn continuePostfix(self: *Parser, expr_in: NodeId) ParseError!NodeId {
        var expr = expr_in;
        while (true) {
            switch (self.peek()) {
                .dot => {
                    _ = try self.advance();
                    // After `.`: either a method `get(T)` / `get_mut(T)`, or a field.
                    switch (self.peek()) {
                        .kw_get => {
                            _ = try self.advance();
                            expr = try self.parseGetCall(expr, .method_get);
                        },
                        .kw_get_mut => {
                            _ = try self.advance();
                            expr = try self.parseGetCall(expr, .method_get_mut);
                        },
                        // `entity.add_tag(.path)` / `entity.remove_tag(.path)`
                        // (M0.8 E3, `etch-grammar.md` §4.4 l.697). These are
                        // keywords, not idents, so they never form a
                        // `method_call`; the whole form is a `tag_mutation_stmt`
                        // (a statement, not an expression — it has no value). The
                        // node is returned with `.stmt` category and the
                        // statement formers (`parseStmt` / `parseBlockBody`)
                        // detect it and use it directly. Terminates the postfix
                        // chain (a mutation is a complete statement).
                        .kw_add_tag => {
                            _ = try self.advance();
                            return try self.parseTagMutation(expr, .add);
                        },
                        .kw_remove_tag => {
                            _ = try self.advance();
                            return try self.parseTagMutation(expr, .remove);
                        },
                        .ident => {
                            // `recv.method(args)` → the reserved `method_call`
                            // kind (M0.8 E2 call mechanism, `etch-grammar.md`
                            // postfix_op §421); `recv.field` (no `(`) stays a
                            // field access. The 4-kind method dispatch
                            // (`etch-resolver-types.md §5`) is exercised in block
                            // 3 once `impl` provides methods — block 2 only
                            // produces the node.
                            if (self.peekNext() == .lparen) {
                                expr = try self.parseMethodCall(expr);
                            } else {
                                const field_tok = try self.advance();
                                const field_id = try self.internSlice(field_tok.span);
                                const recv_span = self.arena.exprSpan(expr);
                                expr = try self.arena.addFieldAccess(self.gpa, expr, field_id, .{
                                    .byte_start = recv_span.byte_start,
                                    .byte_end = field_tok.span.byte_end,
                                });
                            }
                        },
                        else => return self.parseErrFmt(self.peekSpan(), "expected field name or 'get'/'get_mut' after '.', got '{s}'", .{self.sliceOf(self.peekSpan())}),
                    }
                },
                // Index / slice access `receiver[index]` (M0.8 collections,
                // `etch-grammar.md` postfix_op §425). A range index expression
                // (`arr[0..3]`) lowers to a slice; any other index to a single
                // element — disambiguated downstream from the index expr kind.
                .lbracket => {
                    _ = try self.advance(); // '['
                    // A bracketed index re-enables struct literals (M0.8 E2
                    // block 3) even inside an `if`/`while`/`for`/`match` head.
                    const saved = self.no_struct_lit;
                    self.no_struct_lit = false;
                    const index = try self.parseExpr(0);
                    self.no_struct_lit = saved;
                    const closing = try self.expect(.rbracket, "expected ']' to close index access");
                    const recv_span = self.arena.exprSpan(expr);
                    expr = try self.arena.addIndex(self.gpa, expr, index, .{
                        .byte_start = recv_span.byte_start,
                        .byte_end = closing.span.byte_end,
                    });
                },
                // Call `callee(args)` (M0.8 closures, `etch-grammar.md`
                // postfix_op §424). E1 resolves calls on closure-typed locals;
                // positional args only (named args arrive with default-valued
                // functions in E2).
                .lparen => {
                    _ = try self.advance(); // '('
                    // Call arguments re-enable struct literals (M0.8 E2 block 3)
                    // even inside an `if`/`while`/`for`/`match` head.
                    const saved = self.no_struct_lit;
                    self.no_struct_lit = false;
                    defer self.no_struct_lit = saved;
                    var args: std.ArrayListUnmanaged(u32) = .empty;
                    defer args.deinit(self.gpa);
                    if (self.peek() != .rparen) {
                        while (true) {
                            const a = try self.parseExpr(0);
                            try args.append(self.gpa, a.raw());
                            if (!try self.match(.comma)) break;
                        }
                    }
                    const closing = try self.expect(.rparen, "expected ')' to close call arguments");
                    const recv_span = self.arena.exprSpan(expr);
                    expr = try self.arena.addCall(self.gpa, expr, args.items, .{
                        .byte_start = recv_span.byte_start,
                        .byte_end = closing.span.byte_end,
                    });
                },
                // `recv?.method(args)` / `recv?.field` — optional chain (M0.8
                // E3-C tranche 4, part1 §6.6): `none` short-circuits, `some`
                // dispatches on the payload. `?.get` / `?.get_mut` (optional
                // ECS access) are out of the M0.8 subset — fail loud at parse.
                .question_dot => {
                    _ = try self.advance();
                    switch (self.peek()) {
                        .ident => {
                            if (self.peekNext() == .lparen) {
                                expr = try self.parseMethodCall(expr);
                                self.arena.method_calls.items[self.arena.exprData(expr)].opt_chain = true;
                            } else {
                                const field_tok = try self.advance();
                                const field_id = try self.internSlice(field_tok.span);
                                const recv_span = self.arena.exprSpan(expr);
                                expr = try self.arena.addFieldAccess(self.gpa, expr, field_id, .{
                                    .byte_start = recv_span.byte_start,
                                    .byte_end = field_tok.span.byte_end,
                                });
                                self.arena.field_accesses.items[self.arena.exprData(expr)].opt_chain = true;
                            }
                        },
                        else => return self.parseErrFmt(self.peekSpan(), "expected a method or field name after '?.' ('?.get'/'?.get_mut' are not in the M0.8 minimal subset)", .{}),
                    }
                },
                // Postfix `!` — force unwrap, panic on `none` (M0.8 E3-C
                // tranche 4, part1 §6.6). `!=` lexes as one token (maximal
                // munch), so this never splits a comparison.
                .bang => {
                    const bang_tok = try self.advance();
                    const recv_span = self.arena.exprSpan(expr);
                    expr = try self.arena.addUnary(self.gpa, .force_unwrap, expr, .{
                        .byte_start = recv_span.byte_start,
                        .byte_end = bang_tok.span.byte_end,
                    });
                },
                else => break,
            }
        }
        return expr;
    }

    fn parseGetCall(self: *Parser, receiver: NodeId, kind: ast_mod.ExprKind) ParseError!NodeId {
        _ = try self.expect(.lparen, "expected '(' after get/get_mut");
        const type_tok = try self.expect(.type_ident, "expected component type inside get(T)");
        const type_name = try self.internSlice(type_tok.span);
        const closing = try self.expect(.rparen, "expected ')' to close get/get_mut call");
        const recv_span = self.arena.exprSpan(receiver);
        return try self.arena.addMethodGet(self.gpa, kind, receiver, type_name, .{
            .byte_start = recv_span.byte_start,
            .byte_end = closing.span.byte_end,
        });
    }

    /// Parse `receiver.method(args)` into the reserved `method_call` kind (M0.8
    /// E2 call mechanism, `etch-grammar.md` postfix_op §421). On entry the
    /// current token is the method-name identifier and the next is `(`.
    /// Positional args only (named args are an E2 refinement). The dispatch
    /// (`etch-resolver-types.md §5`) lands in block 3 with `impl`.
    fn parseMethodCall(self: *Parser, receiver: NodeId) ParseError!NodeId {
        const name_tok = try self.advance(); // method name
        const method_name = try self.internSlice(name_tok.span);
        _ = try self.advance(); // '('
        // Method-call arguments re-enable struct literals (M0.8 E2 block 3).
        const saved = self.no_struct_lit;
        self.no_struct_lit = false;
        defer self.no_struct_lit = saved;
        var args: std.ArrayListUnmanaged(u32) = .empty;
        defer args.deinit(self.gpa);
        if (self.peek() != .rparen) {
            while (true) {
                const a = try self.parseExpr(0);
                try args.append(self.gpa, a.raw());
                if (!try self.match(.comma)) break;
            }
        }
        const closing = try self.expect(.rparen, "expected ')' to close method-call arguments");
        const recv_span = self.arena.exprSpan(receiver);
        return try self.arena.addMethodCall(self.gpa, receiver, method_name, args.items, .{
            .byte_start = recv_span.byte_start,
            .byte_end = closing.span.byte_end,
        });
    }

    /// Parse a receiver-less `get(T)` / `get_mut(T)` resource accessor
    /// (D-S3-resource-receiver). Stored as a `method_get` / `method_get_mut`
    /// expression with `receiver == NodeId.none`; the type-checker resolves
    /// `T` as a resource (E0301 if `T` names a component) and the
    /// interpreter / codegen dispatch on the absent receiver. The span
    /// starts at the `get` / `get_mut` keyword since there is no receiver.
    fn parseResourceGetCall(self: *Parser, kind: ast_mod.ExprKind, get_span: SourceSpan) ParseError!NodeId {
        _ = try self.expect(.lparen, "expected '(' after get/get_mut");
        const type_tok = try self.expect(.type_ident, "expected resource type inside get(T)");
        const type_name = try self.internSlice(type_tok.span);
        const closing = try self.expect(.rparen, "expected ')' to close get/get_mut call");
        return try self.arena.addMethodGet(self.gpa, kind, NodeId.none, type_name, .{
            .byte_start = get_span.byte_start,
            .byte_end = closing.span.byte_end,
        });
    }

    const ParsedPattern = struct { kind: ast_mod.PatternKind, payload: u32 };

    /// Parse the E1 pattern subset (`etch-grammar.md` §pattern): `_`
    /// (wildcard), a literal, or an `IDENT` binding. Enum-variant, optional,
    /// tuple, and struct-destructure patterns arrive with their types later.
    fn parsePattern(self: *Parser) ParseError!ParsedPattern {
        switch (self.peek()) {
            .ident => {
                // `none` / `some(v)` optional patterns (M0.8 E3-C tranche 4,
                // part1 §7.6). Like the literals, `some` / `none` are detected
                // by lexeme (not keywords); a bare `some` with no `(` stays an
                // ordinary binding.
                const lexeme = self.sliceOf(self.peekSpan());
                if (std.mem.eql(u8, lexeme, "none")) {
                    _ = try self.advance();
                    return .{ .kind = .optional_none, .payload = 0 };
                }
                if (std.mem.eql(u8, lexeme, "some") and self.peekNext() == .lparen) {
                    _ = try self.advance(); // 'some'
                    _ = try self.advance(); // '('
                    const bind_tok = try self.expect(.ident, "expected a binding name inside a some(...) pattern");
                    const bind = try self.internSlice(bind_tok.span);
                    _ = try self.expect(.rparen, "expected ')' to close a some(...) pattern");
                    return .{ .kind = .optional_some, .payload = bind };
                }
                const tok = try self.advance();
                if (std.mem.eql(u8, self.sliceOf(tok.span), "_")) {
                    return .{ .kind = .wildcard, .payload = 0 };
                }
                return .{ .kind = .binding, .payload = try self.internSlice(tok.span) };
            },
            .int_literal, .float_literal, .bool_literal, .string_literal => {
                const lit = try self.parsePrimary();
                return .{ .kind = .literal, .payload = lit.raw() };
            },
            .minus => {
                // Negative numeric literal pattern (`-5 => ...`).
                const lit = try self.parseUnary();
                return .{ .kind = .literal, .payload = lit.raw() };
            },
            .dot => {
                // Enum-variant shorthand pattern `.variant` (M0.8 E2 block 3
                // tranche B, `etch-grammar.md` §3.2 l.510). Type-driven from the
                // scrutinee enum at resolve time (`type_name = 0`).
                _ = try self.advance(); // '.'
                const variant_tok = try self.expect(.ident, "expected enum variant name after '.'");
                const variant = try self.internSlice(variant_tok.span);
                const idx: u32 = @intCast(self.arena.enum_pattern_payloads.items.len);
                try self.arena.enum_pattern_payloads.append(self.gpa, .{ .type_name = 0, .variant = variant });
                return .{ .kind = .enum_variant, .payload = idx };
            },
            .type_ident => {
                // Qualified enum-variant pattern `Difficulty.easy` (M0.8 E2 block
                // 3 tranche B, `etch-grammar.md` §3.2 l.511). A `TYPE_IDENT "{"`
                // struct-destructure pattern (l.512) and a bare `TYPE_IDENT` are
                // the post-Phase-1 advanced pattern set — rejected with a pointer.
                const type_tok = try self.advance();
                const type_name = try self.internSlice(type_tok.span);
                if (self.peek() != .dot) {
                    return self.parseErrFmt(self.peekSpan(), "struct-destructuring and bare type patterns are deferred (post-Phase-1 advanced patterns); write an enum-variant pattern 'Type.variant'", .{});
                }
                _ = try self.advance(); // '.'
                const variant_tok = try self.expect(.ident, "expected enum variant name after 'Type.'");
                const variant = try self.internSlice(variant_tok.span);
                const idx: u32 = @intCast(self.arena.enum_pattern_payloads.items.len);
                try self.arena.enum_pattern_payloads.append(self.gpa, .{ .type_name = type_name, .variant = variant });
                return .{ .kind = .enum_variant, .payload = idx };
            },
            else => return self.parseErrFmt(self.peekSpan(), "unsupported match pattern (supported: '_', literals, bindings, enum variants '.v' / 'Type.v'), got '{s}'", .{self.sliceOf(self.peekSpan())}),
        }
    }

    fn parseMatchArm(self: *Parser) ParseError!ast_mod.MatchArm {
        const pat = try self.parsePattern();
        _ = try self.expect(.fat_arrow, "expected '=>' after match pattern");
        const body = try self.parseExpr(0);
        return .{ .pattern_kind = pat.kind, .pattern_payload = pat.payload, .body = body };
    }

    /// Parse `match scrutinee { pattern => expr, ... }` (M0.8 v0.6
    /// foundations). Arm bodies are expressions in the E1 subset.
    fn parseMatch(self: *Parser) ParseError!NodeId {
        const kw_span = (try self.advance()).span; // 'match'
        const scrutinee = try self.parseExprNoStruct(0);
        _ = try self.expect(.lbrace, "expected '{' to open match arms");
        var arms: std.ArrayListUnmanaged(ast_mod.MatchArm) = .empty;
        defer arms.deinit(self.gpa);
        while (self.peek() != .rbrace and self.peek() != .eof) {
            try arms.append(self.gpa, try self.parseMatchArm());
            if (self.peek() == .comma) {
                _ = try self.advance();
            } else {
                break;
            }
        }
        const closing = try self.expect(.rbrace, "expected '}' to close match");
        return try self.arena.addMatch(self.gpa, scrutinee, arms.items, .{
            .byte_start = kw_span.byte_start,
            .byte_end = closing.span.byte_end,
        });
    }

    /// Parse `[ ... ]` in expression position — disambiguated into an array
    /// literal or a map literal (M0.8 collections, `etch-grammar.md`
    /// §493-498). `[]` is an empty array; `[:]` an empty map; a first
    /// expression followed by `:` is a map, by `;` a fill array, otherwise a
    /// comma array.
    fn parseArrayOrMapLiteral(self: *Parser) ParseError!NodeId {
        const open = try self.advance(); // '['
        // Array / map elements re-enable struct literals (M0.8 E2 block 3).
        const saved_nsl = self.no_struct_lit;
        self.no_struct_lit = false;
        defer self.no_struct_lit = saved_nsl;
        // `[]` — empty array.
        if (self.peek() == .rbracket) {
            const closing = try self.advance();
            return try self.arena.addArrayLit(self.gpa, &.{}, false, NodeId.none, .{ .byte_start = open.span.byte_start, .byte_end = closing.span.byte_end });
        }
        // `[:]` — empty map.
        if (self.peek() == .colon and self.peekNext() == .rbracket) {
            _ = try self.advance(); // ':'
            const closing = try self.advance(); // ']'
            return try self.arena.addMapLit(self.gpa, &.{}, .{ .byte_start = open.span.byte_start, .byte_end = closing.span.byte_end });
        }
        const first = try self.parseExpr(0);
        // Map literal: `[ k : v , ... ]`.
        if (self.peek() == .colon) {
            _ = try self.advance(); // ':'
            const first_val = try self.parseExpr(0);
            var entries: std.ArrayListUnmanaged(ast_mod.MapEntry) = .empty;
            defer entries.deinit(self.gpa);
            try entries.append(self.gpa, .{ .key = first, .value = first_val });
            while (try self.match(.comma)) {
                if (self.peek() == .rbracket) break; // trailing comma
                const k = try self.parseExpr(0);
                _ = try self.expect(.colon, "expected ':' in map entry");
                const v = try self.parseExpr(0);
                try entries.append(self.gpa, .{ .key = k, .value = v });
            }
            const closing = try self.expect(.rbracket, "expected ']' to close map literal");
            return try self.arena.addMapLit(self.gpa, entries.items, .{ .byte_start = open.span.byte_start, .byte_end = closing.span.byte_end });
        }
        // Fill array: `[ v ; n ]`.
        if (self.peek() == .semicolon) {
            _ = try self.advance(); // ';'
            const count = try self.parseExpr(0);
            const closing = try self.expect(.rbracket, "expected ']' to close fill array literal");
            const elems = [_]u32{first.raw()};
            return try self.arena.addArrayLit(self.gpa, &elems, true, count, .{ .byte_start = open.span.byte_start, .byte_end = closing.span.byte_end });
        }
        // Comma array: `[ a , b , c ]`.
        var elems: std.ArrayListUnmanaged(u32) = .empty;
        defer elems.deinit(self.gpa);
        try elems.append(self.gpa, first.raw());
        while (try self.match(.comma)) {
            if (self.peek() == .rbracket) break; // trailing comma
            const e = try self.parseExpr(0);
            try elems.append(self.gpa, e.raw());
        }
        const closing = try self.expect(.rbracket, "expected ']' to close array literal");
        return try self.arena.addArrayLit(self.gpa, elems.items, false, NodeId.none, .{ .byte_start = open.span.byte_start, .byte_end = closing.span.byte_end });
    }

    /// Parse `|a, b| expr` / `|| expr` closure (M0.8 closures, `etch-grammar.md`
    /// §524). E1 takes an expression body; a `{ block }` body arrives with
    /// block expressions (loop/break tranche).
    fn parseClosure(self: *Parser) ParseError!NodeId {
        const open = try self.advance(); // '|'
        var params: std.ArrayListUnmanaged(ast_mod.ClosureParam) = .empty;
        defer params.deinit(self.gpa);
        if (self.peek() != .pipe) {
            while (true) {
                const name_tok = try self.expect(.ident, "expected closure parameter name");
                var type_node: NodeId = NodeId.none;
                if (try self.match(.colon)) {
                    type_node = try self.parseType();
                }
                try params.append(self.gpa, .{ .name = try self.internSlice(name_tok.span), .type_node = type_node });
                if (!try self.match(.comma)) break;
            }
        }
        _ = try self.expect(.pipe, "expected '|' to close closure parameters");
        const body = try self.parseExpr(0);
        const body_span = self.arena.exprSpan(body);
        return try self.arena.addClosure(self.gpa, params.items, body, .{
            .byte_start = open.span.byte_start,
            .byte_end = body_span.byte_end,
        });
    }

    /// Parse the `{ field_init {"," field_init} [","] }` body of a struct
    /// literal `TYPE_IDENT { … }` (M0.8 E2 block 3, `etch-grammar.md` §3.2
    /// l.486). `field_init = IDENT ":" expression`. The spread form `..base`
    /// (data-table inheritance, E4) is rejected. The caller has consumed the
    /// type name and confirmed `peek() == {`. Field values re-enable struct
    /// literals (a `no_struct_lit` head context does not propagate inside).
    fn parseStructLiteral(self: *Parser, type_name: StringId, name_span: SourceSpan) ParseError!NodeId {
        _ = try self.advance(); // '{'
        const saved = self.no_struct_lit;
        self.no_struct_lit = false;
        defer self.no_struct_lit = saved;
        var fields: std.ArrayListUnmanaged(ast_mod.StructLitField) = .empty;
        defer fields.deinit(self.gpa);
        while (self.peek() != .rbrace and self.peek() != .eof) {
            if (self.peek() == .dotdot) {
                return self.parseErr(self.peekSpan(), "struct-literal spread '..base' is not supported in M0.8 (data-table feature, E4)");
            }
            const fname = try self.expect(.ident, "expected field name in struct literal");
            _ = try self.expect(.colon, "expected ':' after struct-literal field name");
            const value = try self.parseExpr(0);
            try fields.append(self.gpa, .{ .name = try self.internSlice(fname.span), .value = value });
            if (!try self.match(.comma)) break;
        }
        const closing = try self.expect(.rbrace, "expected '}' to close struct literal");
        return try self.arena.addStructLit(self.gpa, type_name, fields.items, .{
            .byte_start = name_span.byte_start,
            .byte_end = closing.span.byte_end,
        });
    }

    /// Parse `await <target>` (M0.8 E3 sub-slice B, `etch-grammar.md` §4.2
    /// `await_target`). `wait` / `wait_unscaled` / `entity_event` /
    /// `global_event` are contextual builtins recognised by lexeme when
    /// followed by `(` (they are NOT keywords); anything else is the
    /// fall-through `await <expression>` (Future) form. Produces one
    /// `.await_expr` node, used both as a bare statement (the canonical
    /// async-rule shape) and grammatically in value position. The interpreter
    /// bounds `await` to a top-level statement; value/nested await fails loud.
    fn parseAwaitExpr(self: *Parser) ParseError!NodeId {
        const kw_span = (try self.advance()).span; // 'await'
        if (self.peek() == .ident and self.peekNext() == .lparen) {
            const name = self.sliceOf(self.current.span);
            if (std.mem.eql(u8, name, "wait") or std.mem.eql(u8, name, "wait_unscaled")) {
                const unscaled = std.mem.eql(u8, name, "wait_unscaled");
                _ = try self.advance(); // 'wait' / 'wait_unscaled'
                _ = try self.advance(); // '('
                const arg = try self.parseExpr(0);
                const closing = try self.expect(.rparen, "expected ')' to close the await wait(...) argument");
                return try self.arena.addAwaitExpr(self.gpa, .{
                    .target_kind = if (unscaled) .wait_unscaled else .wait,
                    .arg_expr = arg,
                    .entity_expr = NodeId.none,
                    .event_type = 0,
                }, .{ .byte_start = kw_span.byte_start, .byte_end = closing.span.byte_end });
            }
            if (std.mem.eql(u8, name, "entity_event")) {
                _ = try self.advance(); // 'entity_event'
                _ = try self.advance(); // '('
                const entity = try self.parseExpr(0);
                _ = try self.expect(.comma, "expected ',' between entity and event type in entity_event(...)");
                const ty = try self.expect(.type_ident, "expected event type (TYPE_IDENT) in entity_event(...)");
                const event_type = try self.internSlice(ty.span);
                // The optional `entity_event(e, T { ... })` payload-filter body is
                // a post-Phase-0 feature — reject it rather than silently drop it.
                if (self.peek() == .lbrace) {
                    return self.parseErr(self.peekSpan(), "entity_event payload-filter body is not supported in M0.8 (T2 / Phase 2)");
                }
                const closing = try self.expect(.rparen, "expected ')' to close entity_event(...)");
                return try self.arena.addAwaitExpr(self.gpa, .{
                    .target_kind = .entity_event,
                    .arg_expr = NodeId.none,
                    .entity_expr = entity,
                    .event_type = event_type,
                }, .{ .byte_start = kw_span.byte_start, .byte_end = closing.span.byte_end });
            }
            if (std.mem.eql(u8, name, "global_event")) {
                _ = try self.advance(); // 'global_event'
                _ = try self.advance(); // '('
                const ty = try self.expect(.type_ident, "expected event type (TYPE_IDENT) in global_event(...)");
                const event_type = try self.internSlice(ty.span);
                const closing = try self.expect(.rparen, "expected ')' to close global_event(...)");
                return try self.arena.addAwaitExpr(self.gpa, .{
                    .target_kind = .global_event,
                    .arg_expr = NodeId.none,
                    .entity_expr = NodeId.none,
                    .event_type = event_type,
                }, .{ .byte_start = kw_span.byte_start, .byte_end = closing.span.byte_end });
            }
        }
        // Fall-through: `await <expression>` (Future) — interp-deferred to T2.
        const fut = try self.parseExpr(0);
        const fut_span = self.arena.exprSpan(fut);
        return try self.arena.addAwaitExpr(self.gpa, .{
            .target_kind = .future,
            .arg_expr = fut,
            .entity_expr = NodeId.none,
            .event_type = 0,
        }, .{ .byte_start = kw_span.byte_start, .byte_end = fut_span.byte_end });
    }

    fn parsePrimary(self: *Parser) ParseError!NodeId {
        try self.surfaceTokenErrors();
        switch (self.peek()) {
            .kw_match => return try self.parseMatch(),
            .kw_loop => return try self.parseLoop(0),
            .kw_if => return try self.parseIf(),
            .kw_await => return try self.parseAwaitExpr(),
            .lbrace => return try self.parseBlockExpr(),
            .lbracket => return try self.parseArrayOrMapLiteral(),
            .pipe => return try self.parseClosure(),
            .int_literal => {
                const tok = try self.advance();
                const id = try self.internSlice(tok.span);
                return try self.arena.addExpr(self.gpa, .int_lit, id, tok.span);
            },
            .float_literal => {
                const tok = try self.advance();
                const id = try self.internSlice(tok.span);
                return try self.arena.addExpr(self.gpa, .float_lit, id, tok.span);
            },
            .bool_literal => {
                const tok = try self.advance();
                const id = try self.internSlice(tok.span);
                return try self.arena.addExpr(self.gpa, .bool_lit, id, tok.span);
            },
            .string_literal => {
                const tok = try self.advance();
                return try self.parseStringLiteralExpr(tok);
            },
            .ident => {
                // `none` / `some(x)` optional literals (M0.8 E2 block 5,
                // `etch-grammar.md` §480-481). `none` / `some` are not keywords
                // (they appear in identifier positions in annotations) — detected
                // by lexeme. `some(` opens a some-literal; a bare `some` / `none`
                // identifier elsewhere stays a plain ident (`none` → `none_lit`).
                const lexeme = self.sliceOf(self.current.span);
                if (std.mem.eql(u8, lexeme, "none")) {
                    const tok = try self.advance();
                    return try self.arena.addExpr(self.gpa, .none_lit, 0, tok.span);
                }
                if (std.mem.eql(u8, lexeme, "some") and self.peekNext() == .lparen) {
                    const some_tok = try self.advance(); // 'some'
                    _ = try self.advance(); // '('
                    const inner = try self.parseExpr(0);
                    const closing = try self.expect(.rparen, "expected ')' to close some(...)");
                    return try self.arena.addExpr(self.gpa, .some_lit, inner.raw(), .{
                        .byte_start = some_tok.span.byte_start,
                        .byte_end = closing.span.byte_end,
                    });
                }
                const tok = try self.advance();
                const id = try self.internSlice(tok.span);
                return try self.arena.addExpr(self.gpa, .ident, id, tok.span);
            },
            .type_ident => {
                // A TYPE_IDENT in expression position is either a struct literal
                // `T { f: v }` (M0.8 E2 block 3) or a path-like value (an
                // associated-fn receiver `T.assoc()`, an enum scrutinee, an
                // annotation arg). The `{` lookahead picks the struct literal —
                // suppressed inside an `if`/`while`/`for`/`match` head, where the
                // `{` opens the body (`no_struct_lit`).
                const tok = try self.advance();
                const id = try self.internSlice(tok.span);
                if (self.peek() == .lbrace and !self.no_struct_lit) {
                    return try self.parseStructLiteral(id, tok.span);
                }
                return try self.arena.addExpr(self.gpa, .path, id, tok.span);
            },
            .lparen => {
                _ = try self.advance();
                // A parenthesized sub-expression re-enables struct literals even
                // inside an `if`/`while`/`for`/`match` head (M0.8 E2 block 3).
                const saved = self.no_struct_lit;
                self.no_struct_lit = false;
                const inner = try self.parseExpr(0);
                self.no_struct_lit = saved;
                _ = try self.expect(.rparen, "expected ')' to close parenthesized expression");
                return inner;
            },
            .dot => {
                // Enum variant shorthand `.foo` (e.g. annotation arg
                // `.update`). S3 stores it as a `tag_path` kind expression
                // with the bare identifier interned — the resolver in
                // Phase 0.2 disambiguates enum variant vs tag path from
                // the surrounding context. Tag path literals with
                // multiple segments (`.foo.bar`) remain out-of-scope.
                const dot_span = (try self.advance()).span;
                // Anonymous struct literal `.{ f: v, … }` (M0.8 E3-C tranche
                // 8, `etch-grammar.md` §3.2): `type_name == 0` is the anon
                // sentinel — the resolver supplies the type from the expected
                // context (check mode, resolver-types §4). The dot prefix
                // makes the form unambiguous in `if`/`while`/`for`/`match`
                // heads, so `no_struct_lit` does not apply.
                if (self.peek() == .lbrace) {
                    return try self.parseStructLiteral(0, dot_span);
                }
                if (self.peek() != .ident) {
                    return self.parseErrFmt(self.peekSpan(), "expected identifier after '.', got '{s}'", .{self.sliceOf(self.peekSpan())});
                }
                const ident_tok = try self.advance();
                const id = try self.internSlice(ident_tok.span);
                return try self.arena.addExpr(self.gpa, .tag_path, id, .{
                    .byte_start = dot_span.byte_start,
                    .byte_end = ident_tok.span.byte_end,
                });
            },
            .kw_event => {
                // `event` in expression position is the implicit event binding
                // of an `@on_event(T)` observer rule (M0.8 E3) — self-style, like
                // `self` in a method (resolver-types §12, the ruling: `event`
                // stays a keyword, the observer payload is an implicit binding
                // named `event`, NOT a declared param). Lex it as an `.ident`
                // expr with the interned name "event"; the resolver binds it to
                // the event type in the observer body, the interpreter injects it
                // self-style. Outside an observer body the resolver leaves it
                // unbound (an ordinary undefined-symbol error).
                const ev_tok = try self.advance();
                const id = try self.arena.strings.intern(self.gpa, "event");
                return try self.arena.addExpr(self.gpa, .ident, id, ev_tok.span);
            },
            .kw_get => {
                // Receiver-less `get(T)` — resource read (D-S3-resource-receiver).
                const get_span = (try self.advance()).span;
                return try self.parseResourceGetCall(.method_get, get_span);
            },
            .kw_get_mut => {
                // Receiver-less `get_mut(T)` — resource mutable access.
                const get_span = (try self.advance()).span;
                return try self.parseResourceGetCall(.method_get_mut, get_span);
            },
            else => return self.parseErrFmt(self.peekSpan(), "expected expression, got '{s}'", .{self.sliceOf(self.peekSpan())}),
        }
    }

    // Precedence table — values picked so that S3's left-associative
    // operators behave correctly via the `rbp = lbp + 1` trick.
    const InfixInfo = struct { lbp: u8, rbp: u8 };

    fn infixBindingPower(kind: TokenKind) ?InfixInfo {
        return switch (kind) {
            .kw_or => .{ .lbp = 1, .rbp = 2 },
            .kw_and => .{ .lbp = 3, .rbp = 4 },
            .eq_eq, .bang_eq, .lt, .gt, .lt_eq, .gt_eq => .{ .lbp = 5, .rbp = 6 },
            // `??` binds tighter than comparison, looser than additive
            // (part1 §6.1 level 6, M0.8 E3-C tranche 4).
            .question_question => .{ .lbp = 6, .rbp = 7 },
            .plus, .minus => .{ .lbp = 7, .rbp = 8 },
            .star, .slash, .percent => .{ .lbp = 9, .rbp = 10 },
            else => null,
        };
    }

    fn binaryOpFromKind(kind: TokenKind) ast_mod.BinaryOp {
        return switch (kind) {
            .plus => .add,
            .minus => .sub,
            .star => .mul,
            .slash => .div,
            .percent => .rem,
            .eq_eq => .eq,
            .bang_eq => .neq,
            .lt => .lt,
            .gt => .gt,
            .lt_eq => .le,
            .gt_eq => .ge,
            .kw_and => .logical_and,
            .kw_or => .logical_or,
            .question_question => .coalesce,
            else => unreachable,
        };
    }
};

// ─────────────────────────────── tests ──────────────────────────────────

test "parser builds ComponentDecl with two annotated fields" {
    const gpa = std.testing.allocator;
    var result = try parse(gpa,
        \\component Health {
        \\  @range(0, 100)
        \\  current: float = 100.0
        \\  @range(1, 100)
        \\  max: float = 100.0
        \\}
    );
    defer result.deinit(gpa);
    if (result.diagnostics.len > 0) {
        std.debug.print("unexpected parse diagnostic: {s}\n", .{result.diagnostics[0].primary_message});
        try std.testing.expect(false);
    }
    try std.testing.expectEqual(@as(usize, 1), result.ast.items.len);
    try std.testing.expectEqual(ast_mod.ItemKind.component_decl, result.ast.items.items(.kind)[0]);
    const cd = result.ast.component_decls.items[0];
    try std.testing.expectEqual(@as(u32, 2), cd.fields_len);
    try std.testing.expectEqualStrings("Health", result.ast.strings.slice(cd.name));
    const f0 = result.ast.fields.items[cd.fields_start];
    try std.testing.expectEqualStrings("current", result.ast.strings.slice(f0.name));
    try std.testing.expectEqual(@as(u32, 1), f0.annotations_len);
}

test "parser builds ResourceDecl with default value expression" {
    const gpa = std.testing.allocator;
    var result = try parse(gpa,
        \\resource GameMode {
        \\  max_players: int = 4
        \\}
    );
    defer result.deinit(gpa);
    try std.testing.expect(result.diagnostics.len == 0);
    try std.testing.expectEqual(@as(usize, 1), result.ast.items.len);
    try std.testing.expectEqual(ast_mod.ItemKind.resource_decl, result.ast.items.items(.kind)[0]);
    const rd = result.ast.resource_decls.items[0];
    const f = result.ast.fields.items[rd.fields_start];
    try std.testing.expect(!f.default_value.isNone());
    try std.testing.expectEqual(ast_mod.ExprKind.int_lit, result.ast.exprKind(f.default_value));
}

test "parser builds RuleDecl with when clause composition (and / or / not)" {
    const gpa = std.testing.allocator;
    var result = try parse(gpa,
        \\rule tick(entity: Entity, dt: float)
        \\  when entity has Health
        \\  and entity has Velocity
        \\  or not entity has Frozen
        \\{
        \\}
    );
    defer result.deinit(gpa);
    if (result.diagnostics.len > 0) {
        std.debug.print("unexpected parse diagnostic: {s}\n", .{result.diagnostics[0].primary_message});
        try std.testing.expect(false);
    }
    try std.testing.expectEqual(@as(usize, 1), result.ast.items.len);
    const rd = result.ast.rule_decls.items[0];
    try std.testing.expect(rd.when_root != ast_mod.RuleDecl.none_when);
    try std.testing.expectEqual(@as(u32, 2), rd.params_len);
    // Root must be a logical_or (lowest precedence in the chain).
    try std.testing.expectEqual(ast_mod.WhenNodeKind.logical_or, result.ast.when_nodes.items[rd.when_root].kind);
}

test "parser handles binary expression precedence per grammar subset" {
    const gpa = std.testing.allocator;
    var result = try parse(gpa,
        \\rule t() {
        \\  let x = 1 + 2 * 3
        \\}
    );
    defer result.deinit(gpa);
    try std.testing.expect(result.diagnostics.len == 0);
    const rd = result.ast.rule_decls.items[0];
    try std.testing.expectEqual(@as(u32, 1), rd.body_len);
    const stmt_raw = result.ast.extra.items[rd.body_start];
    const stmt_id: NodeId = @bitCast(stmt_raw);
    try std.testing.expectEqual(ast_mod.StmtKind.let_stmt, result.ast.stmtKind(stmt_id));
    const let = result.ast.let_stmts.items[result.ast.stmtData(stmt_id)];
    // Value should be (1 + (2 * 3)): top is binary `+`.
    try std.testing.expectEqual(ast_mod.ExprKind.binary, result.ast.exprKind(let.value));
    const top = result.ast.binary_exprs.items[result.ast.exprData(let.value)];
    try std.testing.expectEqual(ast_mod.BinaryOp.add, top.op);
    try std.testing.expectEqual(ast_mod.ExprKind.binary, result.ast.exprKind(top.rhs));
    const rhs = result.ast.binary_exprs.items[result.ast.exprData(top.rhs)];
    try std.testing.expectEqual(ast_mod.BinaryOp.mul, rhs.op);
}

test "parser rejects unsupported top-level construct with E0001" {
    const gpa = std.testing.allocator;
    // `behavior` is still out of scope (E4); `fn` graduated with the M0.8 E2
    // call mechanism, so it no longer rejects here.
    var result = try parse(gpa,
        \\behavior Foo {}
    );
    defer result.deinit(gpa);
    try std.testing.expect(result.diagnostics.len > 0);
    try std.testing.expectEqual(diag_mod.DiagnosticCode.parse_error, result.diagnostics[0].code);
}

test "parser recovers at top level and returns partial AST" {
    const gpa = std.testing.allocator;
    var result = try parse(gpa,
        \\component Health { current: float = 1.0 }
        \\@@@@invalid
    );
    defer result.deinit(gpa);
    try std.testing.expect(result.diagnostics.len > 0);
    // First component should be parsed; the trailing broken annotation is
    // recovered from at the top-level sync-point (M0.8) rather than
    // aborting the whole file.
    try std.testing.expectEqual(@as(usize, 1), result.ast.items.len);
    try std.testing.expectEqual(ast_mod.ItemKind.component_decl, result.ast.items.items(.kind)[0]);
}

test "parser accepts top-level declarations in any order" {
    const gpa = std.testing.allocator;
    var result = try parse(gpa,
        \\rule uses_health(entity: Entity)
        \\  when entity has Health
        \\{
        \\  let h = entity.get(Health)
        \\}
        \\component Health { current: float = 100.0 }
    );
    defer result.deinit(gpa);
    if (result.diagnostics.len > 0) {
        std.debug.print("unexpected diag: {s}\n", .{result.diagnostics[0].primary_message});
        try std.testing.expect(false);
    }
    try std.testing.expectEqual(@as(usize, 2), result.ast.items.len);
}

test "parser captures annotation kind and args" {
    const gpa = std.testing.allocator;
    var result = try parse(gpa,
        \\component Health {
        \\  @unit(.health_points)
        \\  @range(0, 100)
        \\  current: float = 100.0
        \\}
    );
    defer result.deinit(gpa);
    // We don't currently parse `.foo` patterns; for S3 we accept named or
    // bare expressions as annotation args. The brief notes annotation
    // applicability is deferred — only "kind + args reachable" is required.
    try std.testing.expect(result.diagnostics.len == 0);
    try std.testing.expectEqual(@as(usize, 1), result.ast.items.len);
}

test "D-S3-trivia: doc comments and leading comments attach to top-level items" {
    const gpa = std.testing.allocator;
    const src =
        "// leading plain comment\n" ++
        "/// doc line one\n" ++
        "/// doc line two\n" ++
        "component Alpha { a: int = 1 }\n" ++
        "/// bravo doc\n" ++
        "component Bravo { b: int = 2 }";
    var result = try parse(gpa, src);
    defer result.deinit(gpa);
    if (result.diagnostics.len > 0) {
        std.debug.print("unexpected diag: {s}\n", .{result.diagnostics[0].primary_message});
        try std.testing.expect(false);
    }
    try std.testing.expectEqual(@as(usize, 2), result.ast.items.len);

    const alpha_id: NodeId = .{ .category = .item, .index = 0 };
    const bravo_id: NodeId = .{ .category = .item, .index = 1 };

    // Alpha gets the two `///` doc lines plus the one plain `//` comment.
    try std.testing.expectEqual(@as(usize, 2), result.ast.docCommentsOf(alpha_id).len);
    try std.testing.expectEqual(@as(usize, 1), result.ast.leadingCommentsOf(alpha_id).len);
    // The doc text round-trips from the attached span.
    const d0 = result.ast.docCommentsOf(alpha_id)[0];
    try std.testing.expectEqualStrings("/// doc line one", src[d0.byte_start..d0.byte_end]);

    // Bravo's doc must attach to Bravo, not bleed into Alpha.
    try std.testing.expectEqual(@as(usize, 1), result.ast.docCommentsOf(bravo_id).len);
    try std.testing.expectEqual(@as(usize, 0), result.ast.leadingCommentsOf(bravo_id).len);
}

test "D-S3-annot-field-access: annotation arg accepts a field access expression" {
    const gpa = std.testing.allocator;
    // `@requires(self.health)` — annotation positional arg that is a field
    // access. Pre-fix, the annotation-arg path built the ident then called
    // the binary-only continuation, leaving `.health` unconsumed and
    // surfacing "expected ')'". Postfix routing now parses it cleanly.
    var result = try parse(gpa,
        \\@requires(self.health)
        \\component Inventory { gold: int = 0 }
    );
    defer result.deinit(gpa);
    if (result.diagnostics.len > 0) {
        std.debug.print("unexpected parse diagnostic: {s}\n", .{result.diagnostics[0].primary_message});
        try std.testing.expect(false);
    }
    try std.testing.expectEqual(@as(usize, 1), result.ast.items.len);
    const cd = result.ast.component_decls.items[0];
    try std.testing.expectEqual(@as(u32, 1), cd.annotations_len);
    const annot = result.ast.annot_pool.items[cd.annotations_extra];
    try std.testing.expectEqual(@as(u32, 1), annot.args_len);
    const arg = result.ast.annot_args.items[annot.args_start];
    try std.testing.expectEqual(ast_mod.ExprKind.field_access, result.ast.exprKind(arg.value));
}

test "parser builds array literals, fill, and index/slice access (M0.8 collections)" {
    const gpa = std.testing.allocator;
    var result = try parse(gpa,
        \\rule r() {
        \\  let a = [10, 20, 30]
        \\  let b = [0; 4]
        \\  let x = a[1]
        \\  let s = a[0..2]
        \\}
    );
    defer result.deinit(gpa);
    if (result.diagnostics.len > 0) {
        std.debug.print("unexpected parse diagnostic: {s}\n", .{result.diagnostics[0].primary_message});
        try std.testing.expect(false);
    }
    var saw_array = false;
    var saw_index = false;
    var fill_count: usize = 0;
    for (result.ast.exprs.items(.kind), 0..) |k, i| {
        if (k == .array_lit) {
            saw_array = true;
            if (result.ast.array_lits.items[result.ast.exprs.items(.data)[i]].is_fill) fill_count += 1;
        }
        if (k == .index) saw_index = true;
    }
    try std.testing.expect(saw_array);
    try std.testing.expect(saw_index);
    try std.testing.expectEqual(@as(usize, 1), fill_count); // exactly the `[0; 4]` literal
}

test "parser builds map type, map literal, and Set<T> type (M0.8 collections)" {
    const gpa = std.testing.allocator;
    var result = try parse(gpa,
        \\rule r() {
        \\  let m: [string: int] = ["a": 1, "b": 2]
        \\  let e: [int: int] = [:]
        \\  let s: Set<int> = [3]
        \\}
    );
    defer result.deinit(gpa);
    if (result.diagnostics.len > 0) {
        std.debug.print("unexpected parse diagnostic: {s}\n", .{result.diagnostics[0].primary_message});
        try std.testing.expect(false);
    }
    var saw_map = false;
    for (result.ast.exprs.items(.kind)) |k| {
        if (k == .map_lit) saw_map = true;
    }
    try std.testing.expect(saw_map);
    var saw_map_type = false;
    var saw_set_type = false;
    for (result.ast.type_nodes.items(.kind)) |k| {
        if (k == .map_type) saw_map_type = true;
        if (k == .set_type) saw_set_type = true;
    }
    try std.testing.expect(saw_map_type);
    try std.testing.expect(saw_set_type);
}

test "parser builds closures and calls (M0.8 closures)" {
    const gpa = std.testing.allocator;
    var result = try parse(gpa,
        \\rule r() {
        \\  let f = |x: int| x + 1
        \\  let g = |a, b| a
        \\  let h = || 7
        \\  let y = f(10)
        \\}
    );
    defer result.deinit(gpa);
    if (result.diagnostics.len > 0) {
        std.debug.print("unexpected parse diagnostic: {s}\n", .{result.diagnostics[0].primary_message});
        try std.testing.expect(false);
    }
    var closures: usize = 0;
    var calls: usize = 0;
    for (result.ast.exprs.items(.kind)) |k| {
        if (k == .closure) closures += 1;
        if (k == .fn_call) calls += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), closures); // f, g, h
    try std.testing.expectEqual(@as(usize, 1), calls); // f(10)
}

test "parser builds top-level fn declarations, free calls, and return (M0.8 E2)" {
    const gpa = std.testing.allocator;
    var result = try parse(gpa,
        \\fn double(x: int) -> int {
        \\  return x * 2
        \\}
        \\fn noop() {
        \\}
        \\async fn tick(n: int) -> int { n }
        \\fn caller(x: int) -> int {
        \\  double(x)
        \\}
    );
    defer result.deinit(gpa);
    if (result.diagnostics.len > 0) {
        std.debug.print("unexpected parse diagnostic: {s}\n", .{result.diagnostics[0].primary_message});
        try std.testing.expect(false);
    }
    // Four fn declarations, one async.
    try std.testing.expectEqual(@as(usize, 4), result.ast.fn_decls.items.len);
    var async_count: usize = 0;
    var double_ret: bool = false;
    var noop_void: bool = false;
    for (result.ast.fn_decls.items) |fd| {
        if (fd.is_async) async_count += 1;
        const name = result.ast.strings.slice(fd.name);
        if (std.mem.eql(u8, name, "double")) double_ret = !fd.return_type.isNone();
        if (std.mem.eql(u8, name, "noop")) noop_void = fd.return_type.isNone();
    }
    try std.testing.expectEqual(@as(usize, 1), async_count);
    try std.testing.expect(double_ret); // `-> int`
    try std.testing.expect(noop_void); // no `-> type`
    // The free call `double(x)` in `caller` is a fn_call expr; one return stmt.
    var calls: usize = 0;
    for (result.ast.exprs.items(.kind)) |k| {
        if (k == .fn_call) calls += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), calls);
    var returns: usize = 0;
    for (result.ast.stmts.items(.kind)) |k| {
        if (k == .return_stmt) returns += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), returns); // the `return x * 2`
}

test "parser builds method-call postfix into the reserved method_call kind (M0.8 E2)" {
    const gpa = std.testing.allocator;
    // `recv.method(args)` → method_call; `recv.field` (no parens) → field_access.
    // Parser-only: the 4-kind dispatch is block 3.
    var result = try parse(gpa,
        \\rule r(entity: Entity) {
        \\  let a = entity.normalize()
        \\  let b = entity.length
        \\  let c = weapon.calculate(target, 5)
        \\}
    );
    defer result.deinit(gpa);
    if (result.diagnostics.len > 0) {
        std.debug.print("unexpected parse diagnostic: {s}\n", .{result.diagnostics[0].primary_message});
        try std.testing.expect(false);
    }
    var method_calls: usize = 0;
    var field_accesses: usize = 0;
    var calculate_args: usize = 999;
    for (result.ast.exprs.items(.kind), 0..) |k, i| {
        if (k == .method_call) {
            method_calls += 1;
            const mc = result.ast.method_calls.items[result.ast.exprs.items(.data)[i]];
            if (std.mem.eql(u8, result.ast.strings.slice(mc.method_name), "calculate")) calculate_args = mc.args_len;
        }
        if (k == .field_access) field_accesses += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), method_calls); // normalize(), calculate(...)
    try std.testing.expectEqual(@as(usize, 1), field_accesses); // entity.length
    try std.testing.expectEqual(@as(usize, 2), calculate_args); // (target, 5)
}

test "parser builds loops, labels, break value, and continue (M0.8 loop/break)" {
    const gpa = std.testing.allocator;
    var result = try parse(gpa,
        \\rule r() {
        \\  let x = loop { break 42 }
        \\  outer: loop {
        \\    loop {
        \\      continue
        \\      break outer 1
        \\    }
        \\  }
        \\}
    );
    defer result.deinit(gpa);
    if (result.diagnostics.len > 0) {
        std.debug.print("unexpected parse diagnostic: {s}\n", .{result.diagnostics[0].primary_message});
        try std.testing.expect(false);
    }
    var loops: usize = 0;
    for (result.ast.exprs.items(.kind)) |k| {
        if (k == .loop_expr) loops += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), loops); // x's loop, outer, inner
    var breaks: usize = 0;
    var continues: usize = 0;
    for (result.ast.stmts.items(.kind)) |k| {
        if (k == .break_stmt) breaks += 1;
        if (k == .continue_stmt) continues += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), breaks); // break 42, break outer 1
    try std.testing.expectEqual(@as(usize, 1), continues);
    // The labeled break carries the `outer` label.
    var labeled: usize = 0;
    for (result.ast.break_stmts.items) |b| {
        if (b.label != 0) labeled += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), labeled);
}

test "parser builds throw and try/catch (M0.8 error handling)" {
    const gpa = std.testing.allocator;
    var result = try parse(gpa,
        \\rule r() {
        \\  try {
        \\    throw 99
        \\  } catch err {
        \\    let x = err
        \\  }
        \\}
    );
    defer result.deinit(gpa);
    if (result.diagnostics.len > 0) {
        std.debug.print("unexpected parse diagnostic: {s}\n", .{result.diagnostics[0].primary_message});
        try std.testing.expect(false);
    }
    var throws: usize = 0;
    var tries: usize = 0;
    for (result.ast.stmts.items(.kind)) |k| {
        if (k == .throw_stmt) throws += 1;
        if (k == .try_catch_stmt) tries += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), throws);
    try std.testing.expectEqual(@as(usize, 1), tries);
    try std.testing.expectEqual(@as(usize, 1), result.ast.try_catch_stmts.items.len);
    // The catch binding name round-trips.
    try std.testing.expectEqualStrings("err", result.ast.strings.slice(result.ast.try_catch_stmts.items[0].catch_name));
}

test "parser builds block expressions with a trailing value (M0.8 control flow)" {
    const gpa = std.testing.allocator;
    var result = try parse(gpa,
        \\rule r() {
        \\  let x = {
        \\    let a = 10
        \\    a + 1
        \\  }
        \\  let y = { let b = 2 }
        \\}
    );
    defer result.deinit(gpa);
    if (result.diagnostics.len > 0) {
        std.debug.print("unexpected parse diagnostic: {s}\n", .{result.diagnostics[0].primary_message});
        try std.testing.expect(false);
    }
    var blocks: usize = 0;
    var with_value: usize = 0;
    for (result.ast.exprs.items(.kind), 0..) |k, i| {
        if (k == .block_expr) {
            blocks += 1;
            if (!result.ast.block_exprs.items[result.ast.exprs.items(.data)[i]].value.isNone()) with_value += 1;
        }
    }
    // Two blocks: `x`'s block has a trailing value (`a + 1`); `y`'s block is
    // value-less (its only item is a `let`, so no trailing expression).
    try std.testing.expectEqual(@as(usize, 2), blocks);
    try std.testing.expectEqual(@as(usize, 1), with_value);
}

test "parser builds if/else with an else-if chain (M0.8 control flow)" {
    const gpa = std.testing.allocator;
    var result = try parse(gpa,
        \\rule r() {
        \\  let x = if 1 < 2 { 10 } else if 3 < 4 { 20 } else { 30 }
        \\  if x > 5 { let y = 1 }
        \\}
    );
    defer result.deinit(gpa);
    if (result.diagnostics.len > 0) {
        std.debug.print("unexpected parse diagnostic: {s}\n", .{result.diagnostics[0].primary_message});
        try std.testing.expect(false);
    }
    var ifs: usize = 0;
    var with_else: usize = 0;
    for (result.ast.exprs.items(.kind), 0..) |k, i| {
        if (k == .if_expr) {
            ifs += 1;
            if (!result.ast.if_exprs.items[result.ast.exprs.items(.data)[i]].else_branch.isNone()) with_else += 1;
        }
    }
    // Three if-expressions: the value `if`, its `else if`, and the statement
    // `if x > 5 { ... }`. The value `if` and its `else if` carry an else
    // branch; the statement `if` does not.
    try std.testing.expectEqual(@as(usize, 3), ifs);
    try std.testing.expectEqual(@as(usize, 2), with_else);
}

test "parser builds a while statement (M0.8 control flow)" {
    const gpa = std.testing.allocator;
    var result = try parse(gpa,
        \\rule r() {
        \\  let mut i = 0
        \\  while i < 3 {
        \\    i += 1
        \\  }
        \\}
    );
    defer result.deinit(gpa);
    if (result.diagnostics.len > 0) {
        std.debug.print("unexpected parse diagnostic: {s}\n", .{result.diagnostics[0].primary_message});
        try std.testing.expect(false);
    }
    var whiles: usize = 0;
    for (result.ast.stmts.items(.kind)) |k| {
        if (k == .while_stmt) whiles += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), whiles);
}

test "parser accepts block bodies in closures and match arms (M0.8 control flow)" {
    const gpa = std.testing.allocator;
    var result = try parse(gpa,
        \\rule r() {
        \\  let f = |x: int| {
        \\    let y = x
        \\    y + 1
        \\  }
        \\  let m = match 1 {
        \\    0 => { 10 },
        \\    _ => 20
        \\  }
        \\}
    );
    defer result.deinit(gpa);
    if (result.diagnostics.len > 0) {
        std.debug.print("unexpected parse diagnostic: {s}\n", .{result.diagnostics[0].primary_message});
        try std.testing.expect(false);
    }
    var closures: usize = 0;
    var blocks: usize = 0;
    for (result.ast.exprs.items(.kind)) |k| {
        if (k == .closure) closures += 1;
        if (k == .block_expr) blocks += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), closures);
    // Two block expressions: the closure body and the `0 =>` arm body (the
    // `_ => 20` arm body is a bare expression, not a block).
    try std.testing.expectEqual(@as(usize, 2), blocks);
}

test "parser builds struct + inherent impl + struct literal + method calls (M0.8 E2 block 3)" {
    const gpa = std.testing.allocator;
    var result = try parse(gpa,
        \\struct V2 { x: int = 0, y: int = 0 }
        \\impl V2 {
        \\  fn sum(self) -> int { self.x + self.y }
        \\  fn make(a: int, b: int) -> V2 { V2 { x: a, y: b } }
        \\}
        \\rule r(entity: Entity) when entity has Acc {
        \\  let v = V2.make(3, 4)
        \\  let s = v.sum()
        \\}
    );
    defer result.deinit(gpa);
    if (result.diagnostics.len > 0) {
        std.debug.print("unexpected parse diagnostic: {s}\n", .{result.diagnostics[0].primary_message});
        try std.testing.expect(false);
    }
    try std.testing.expectEqual(@as(usize, 1), result.ast.struct_decls.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.ast.impl_decls.items.len);
    const impl = result.ast.impl_decls.items[0];
    try std.testing.expectEqual(@as(u32, 2), impl.methods_len);
    try std.testing.expectEqual(@as(StringId, 0), impl.trait_name); // inherent
    // `sum` takes `self` (by value); `make` is an associated fn (no self).
    const sum_m = result.ast.impl_methods.items[impl.methods_start];
    const make_m = result.ast.impl_methods.items[impl.methods_start + 1];
    try std.testing.expectEqual(ast_mod.SelfKind.by_value, sum_m.self_kind);
    try std.testing.expectEqual(ast_mod.SelfKind.none, make_m.self_kind);
    try std.testing.expectEqual(@as(u32, 2), make_m.params_len); // a, b
    // A struct literal (in `make`) and two method calls (`V2.make`, `v.sum`).
    var struct_lits: usize = 0;
    var method_calls: usize = 0;
    for (result.ast.exprs.items(.kind)) |k| {
        if (k == .struct_lit) struct_lits += 1;
        if (k == .method_call) method_calls += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), struct_lits);
    try std.testing.expectEqual(@as(usize, 2), method_calls);
}

test "parser recovers and a valid struct/impl after a broken construct survives (M0.8 E2 block 3 lockstep)" {
    const gpa = std.testing.allocator;
    // A broken leading annotation forces the top-level resync; the `struct` and
    // `impl` that follow must still land in the AST (the lockstep stop-set now
    // lists `kw_struct` / `kw_impl`).
    var result = try parse(gpa,
        \\@@@bad
        \\struct V2 { x: int = 0 }
        \\impl V2 { fn id(self) -> int { self.x } }
    );
    defer result.deinit(gpa);
    try std.testing.expect(result.diagnostics.len > 0);
    try std.testing.expectEqual(@as(usize, 1), result.ast.struct_decls.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.ast.impl_decls.items.len);
}

test "parser suppresses struct literals in if/while/for/match heads (M0.8 E2 block 3)" {
    const gpa = std.testing.allocator;
    // `while Cond { … }` must parse `Cond` as a path (a value) and `{ … }` as
    // the loop body, NOT as a `Cond { … }` struct literal. With a struct
    // literal allowed in the head this would mis-parse and error.
    var result = try parse(gpa,
        \\rule r() {
        \\  let mut n = 0
        \\  while n < 3 { n += 1 }
        \\  if n > 0 { n += 1 }
        \\}
    );
    defer result.deinit(gpa);
    if (result.diagnostics.len > 0) {
        std.debug.print("unexpected parse diagnostic: {s}\n", .{result.diagnostics[0].primary_message});
        try std.testing.expect(false);
    }
    var struct_lits: usize = 0;
    for (result.ast.exprs.items(.kind)) |k| {
        if (k == .struct_lit) struct_lits += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), struct_lits);
}

test "parser accepts a trait impl (tranche C) and a generic struct (block 4) (M0.8 E2)" {
    const gpa = std.testing.allocator;
    // `impl Trait for T` parses in tranche C — the first name is the trait, the
    // post-`for` name the target type (trait existence is a resolver concern).
    {
        var result = try parse(gpa,
            \\trait Show { fn show(self) -> int }
            \\struct T { x: int = 0 }
            \\impl Show for T { fn show(self) -> int { self.x } }
        );
        defer result.deinit(gpa);
        if (result.diagnostics.len > 0) {
            std.debug.print("unexpected parse diagnostic: {s}\n", .{result.diagnostics[0].primary_message});
            try std.testing.expect(false);
        }
        try std.testing.expectEqual(@as(usize, 1), result.ast.trait_decls.items.len);
        // Two impl decls? No — one trait + one impl.
        try std.testing.expectEqual(@as(usize, 1), result.ast.impl_decls.items.len);
        const impl = result.ast.impl_decls.items[0];
        try std.testing.expect(impl.trait_name != 0); // trait impl
        // The trait's abstract member carries no body.
        const td = result.ast.trait_decls.items[0];
        try std.testing.expectEqual(@as(u32, 1), td.methods_len);
        try std.testing.expectEqual(false, result.ast.impl_methods.items[td.methods_start].has_body);
    }
    // Generic struct now parses (M0.8 E2 block 4) — `Box<T>` carries one param.
    {
        var result = try parse(gpa,
            \\struct Box<T> { value: int = 0 }
        );
        defer result.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
        try std.testing.expectEqual(@as(u32, 1), result.ast.struct_decls.items[0].generics_len);
    }
}

test "parser builds trait decl with abstract + default members + survives lockstep (M0.8 E2 block 3 tranche C)" {
    const gpa = std.testing.allocator;
    {
        var result = try parse(gpa,
            \\trait Damageable {
            \\  fn take_damage(mut self, amount: int)
            \\  fn is_dead(self) -> bool { false }
            \\}
        );
        defer result.deinit(gpa);
        if (result.diagnostics.len > 0) {
            std.debug.print("unexpected parse diagnostic: {s}\n", .{result.diagnostics[0].primary_message});
            try std.testing.expect(false);
        }
        const td = result.ast.trait_decls.items[0];
        try std.testing.expectEqual(@as(u32, 2), td.methods_len);
        const m0 = result.ast.impl_methods.items[td.methods_start];
        const m1 = result.ast.impl_methods.items[td.methods_start + 1];
        try std.testing.expectEqual(false, m0.has_body); // abstract signature
        try std.testing.expectEqual(ast_mod.SelfKind.by_mut, m0.self_kind);
        try std.testing.expectEqual(true, m1.has_body); // default body
    }
    // LOCKSTEP: a broken construct resyncs at the `trait` that follows.
    {
        var result = try parse(gpa,
            \\@@@bad
            \\trait Show { fn show(self) -> int }
        );
        defer result.deinit(gpa);
        try std.testing.expect(result.diagnostics.len > 0);
        try std.testing.expectEqual(@as(usize, 1), result.ast.trait_decls.items.len);
    }
}

test "parser builds optional type + none/some + if let / while let (M0.8 E2 block 5)" {
    const gpa = std.testing.allocator;
    var result = try parse(gpa,
        \\rule r(entity: Entity) when entity has Acc {
        \\  let a: int? = some(7)
        \\  let b: int? = none
        \\  let mut n = 0
        \\  entity.get_mut(Acc).out = if let x = a { x } else { 0 }
        \\  while let y = b { n += y }
        \\}
    );
    defer result.deinit(gpa);
    if (result.diagnostics.len > 0) {
        std.debug.print("unexpected parse diagnostic: {s}\n", .{result.diagnostics[0].primary_message});
        try std.testing.expect(false);
    }
    // Two optional type nodes (`int?` ×2), a some_lit, a none_lit, an if-let, a
    // while-let.
    var optional_types: usize = 0;
    for (result.ast.type_nodes.items(.kind)) |k| {
        if (k == .optional) optional_types += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), optional_types);
    var some_lits: usize = 0;
    var none_lits: usize = 0;
    for (result.ast.exprs.items(.kind)) |k| {
        if (k == .some_lit) some_lits += 1;
        if (k == .none_lit) none_lits += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), some_lits);
    try std.testing.expectEqual(@as(usize, 1), none_lits);
    // The if-let carries a binding; the while-let too.
    var if_let_bindings: usize = 0;
    for (result.ast.if_exprs.items) |ife| {
        if (ife.let_binding != 0) if_let_bindings += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), if_let_bindings);
    try std.testing.expect(result.ast.while_stmts.items[0].let_binding != 0);
}

test "parser builds generic params + bounds + where + generic type (M0.8 E2 block 4)" {
    const gpa = std.testing.allocator;
    var result = try parse(gpa,
        \\trait Comparable { fn cmp(self, other: int) -> int }
        \\fn largest<T: Comparable>(items: T) -> T { items }
        \\fn pair<A, B>(a: A, b: B) -> A where A: Comparable { a }
        \\struct Range<T> { min: T  max: T }
        \\enum Opt<T> { present, absent }
    );
    defer result.deinit(gpa);
    if (result.diagnostics.len > 0) {
        std.debug.print("unexpected parse diagnostic: {s}\n", .{result.diagnostics[0].primary_message});
        try std.testing.expect(false);
    }
    // `largest<T: Comparable>` — one param, one trait bound.
    try std.testing.expect(result.ast.generic_params.items.len >= 5);
    // The first fn decl is `largest`: 1 generic param with 1 bound.
    const largest = result.ast.fn_decls.items[0];
    try std.testing.expectEqual(@as(u32, 1), largest.generics_len);
    const lp = result.ast.generic_params.items[largest.generics_start];
    try std.testing.expectEqual(@as(u32, 1), lp.bounds_len);
    try std.testing.expectEqual(ast_mod.GenericBoundKind.trait_, result.ast.generic_bounds.items[lp.bounds_start].kind);
    // `pair<A, B> … where A: Comparable` — 2 params, A gains a bound from where.
    const pair = result.ast.fn_decls.items[1];
    try std.testing.expectEqual(@as(u32, 2), pair.generics_len);
    try std.testing.expectEqual(@as(u32, 1), result.ast.generic_params.items[pair.generics_start].bounds_len); // A: Comparable (from where)
    try std.testing.expectEqual(@as(u32, 0), result.ast.generic_params.items[pair.generics_start + 1].bounds_len); // B
    // Struct + enum carry their generic params.
    try std.testing.expectEqual(@as(u32, 1), result.ast.struct_decls.items[0].generics_len);
    try std.testing.expectEqual(@as(u32, 1), result.ast.enum_decls.items[0].generics_len);
}

test "parser accepts inherent impl generic + bare targets, rejects generic trait-impl target (§891, M0.8 E2)" {
    const gpa = std.testing.allocator;
    // `impl<T> Range<T>` — a generic-type inherent target, now grammatical
    // (`etch-grammar.md §891`: `impl_decl` target = impl_trait_for_type |
    // generic_type | TYPE_IDENT). The `<T>` target args are erased; the
    // impl-level `<T>` carries the param. `type_name` is the base `Range`.
    {
        var result = try parse(gpa,
            \\struct Range<T> { min: T  max: T }
            \\impl<T> Range<T> { fn lo(self) -> int { 0 } }
        );
        defer result.deinit(gpa);
        if (result.diagnostics.len > 0) {
            std.debug.print("unexpected parse diagnostic: {s}\n", .{result.diagnostics[0].primary_message});
            try std.testing.expect(false);
        }
        const impl = result.ast.impl_decls.items[0];
        try std.testing.expectEqual(@as(u32, 1), impl.generics_len);
        try std.testing.expectEqual(@as(StringId, 0), impl.trait_name); // inherent
        try std.testing.expectEqualStrings("Range", result.ast.strings.slice(impl.type_name));
    }
    // `impl<T> Range { … }` (bare inherent target) still parses.
    {
        var result = try parse(gpa,
            \\struct Range<T> { min: T  max: T }
            \\impl<T> Range { fn lo(self) -> int { 0 } }
        );
        defer result.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
        try std.testing.expectEqual(@as(u32, 1), result.ast.impl_decls.items[0].generics_len);
    }
    // A generic target in the *trait* form (`impl T for Bar<U>`) stays rejected —
    // `impl_trait_for_type`'s target is a bare TYPE_IDENT.
    {
        var result = try parse(gpa,
            \\trait Show { fn show(self) -> int }
            \\struct Bar<T> { v: T }
            \\impl Show for Bar<T> { fn show(self) -> int { 0 } }
        );
        defer result.deinit(gpa);
        try std.testing.expect(result.diagnostics.len > 0);
    }
}

test "parser builds enum decl + enum-variant match patterns (M0.8 E2 block 3 tranche B)" {
    const gpa = std.testing.allocator;
    var result = try parse(gpa,
        \\enum Difficulty { easy, normal, hard }
        \\rule r(entity: Entity) when entity has Acc {
        \\  let d = Difficulty.hard
        \\  let s = match d {
        \\    Difficulty.easy => 1,
        \\    .normal => 2,
        \\    Difficulty.hard => 3,
        \\  }
        \\}
    );
    defer result.deinit(gpa);
    if (result.diagnostics.len > 0) {
        std.debug.print("unexpected parse diagnostic: {s}\n", .{result.diagnostics[0].primary_message});
        try std.testing.expect(false);
    }
    try std.testing.expectEqual(@as(usize, 1), result.ast.enum_decls.items.len);
    const ed = result.ast.enum_decls.items[0];
    try std.testing.expectEqual(@as(u32, 3), ed.variants_len);
    try std.testing.expectEqual(ast_mod.EnumVariantShape.c_like, result.ast.enum_variants.items[ed.variants_start].shape);
    // Three enum-variant patterns: two qualified (`Difficulty.easy/hard`), one
    // shorthand (`.normal`). The shorthand stores `type_name = 0`.
    var enum_pats: usize = 0;
    for (result.ast.match_arms.items) |arm| {
        if (arm.pattern_kind == .enum_variant) enum_pats += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), enum_pats);
    try std.testing.expectEqual(@as(usize, 3), result.ast.enum_pattern_payloads.items.len);
    // The `.normal` shorthand payload carries no explicit type name.
    var shorthand: usize = 0;
    for (result.ast.enum_pattern_payloads.items) |p| {
        if (p.type_name == 0) shorthand += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), shorthand);
}

test "parser recovers and a valid enum after a broken construct survives (M0.8 E2 block 3 tranche B lockstep)" {
    const gpa = std.testing.allocator;
    // The lockstep stop-set now lists `kw_enum`: a broken leading construct
    // resyncs at the `enum` that follows, which lands in the AST.
    var result = try parse(gpa,
        \\@@@bad
        \\enum Color { red, green, blue }
    );
    defer result.deinit(gpa);
    try std.testing.expect(result.diagnostics.len > 0);
    try std.testing.expectEqual(@as(usize, 1), result.ast.enum_decls.items.len);
}

test "parser parses data-carrying + generic enum variants (M0.8 E2 block 3 tranche B / block 4)" {
    const gpa = std.testing.allocator;
    // Struct-like + tuple-like variant shapes parse (construction / patterns are
    // deferred; the grammar is accepted). Variant names are `IDENT` per
    // `etch-grammar.md` §5.8 (`enum_variant = IDENT [...]` for all three shapes).
    {
        var result = try parse(gpa,
            \\enum Shape { circle { r: float = 0.0 }, pair(int, int), empty }
        );
        defer result.deinit(gpa);
        if (result.diagnostics.len > 0) {
            std.debug.print("unexpected parse diagnostic: {s}\n", .{result.diagnostics[0].primary_message});
            try std.testing.expect(false);
        }
        const ed = result.ast.enum_decls.items[0];
        try std.testing.expectEqual(@as(u32, 3), ed.variants_len);
        try std.testing.expectEqual(ast_mod.EnumVariantShape.struct_like, result.ast.enum_variants.items[ed.variants_start].shape);
        try std.testing.expectEqual(ast_mod.EnumVariantShape.tuple_like, result.ast.enum_variants.items[ed.variants_start + 1].shape);
        try std.testing.expectEqual(ast_mod.EnumVariantShape.c_like, result.ast.enum_variants.items[ed.variants_start + 2].shape);
    }
    // Generic enum now parses (M0.8 E2 block 4) — `Opt<T>` carries one param.
    {
        var result = try parse(gpa,
            \\enum Opt<T> { some_, none_ }
        );
        defer result.deinit(gpa);
        try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
        try std.testing.expectEqual(@as(u32, 1), result.ast.enum_decls.items[0].generics_len);
    }
}

test "parser does not leak comment spans on OOM during init" {
    // FailingAllocator wraps std.testing.allocator (which itself flags any
    // leak as a test failure). Each `fail_index` from 1..N forces the Nth
    // allocation to fail; we walk the range so that every distinct
    // allocation site between the first byte read and the first parsed
    // token gets exercised. The success path (no OOM at all) is excluded
    // because that case is already covered by the rest of the test suite.
    const sources = [_][]const u8{
        "// header\ncomponent X { f: int }",
        "/* block */\ncomponent X { f: int }",
        "// header line\n/// doc line\ncomponent X { f: int = 1 }",
    };
    for (sources) |src| {
        var fail_index: usize = 1;
        while (fail_index < 64) : (fail_index += 1) {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
            const result = parse(failing.allocator(), src);
            if (result) |ok| {
                // No OOM happened at this fail index — the parser
                // ran to completion with a real allocator. Free and
                // move on; the test passes because no leak is reported.
                var ok_mut = ok;
                ok_mut.deinit(failing.allocator());
                break;
            } else |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                // std.testing.allocator under the failing wrapper will
                // detect any leak when the test scope ends; the inner
                // allocator is the testing allocator, so its leak
                // tracker fires if `parse` failed to free.
            }
        }
    }
}

test "parser builds event declaration + emit statement (M0.8 E3)" {
    const gpa = std.testing.allocator;
    var result = try parse(gpa,
        \\event Damage { amount: int, crit: bool }
        \\rule deal(entity: Entity) when entity has Health {
        \\  emit Damage { amount: 5, crit: true }
        \\}
    );
    defer result.deinit(gpa);
    if (result.diagnostics.len > 0) {
        std.debug.print("unexpected parse diagnostic: {s}\n", .{result.diagnostics[0].primary_message});
        try std.testing.expect(false);
    }
    try std.testing.expectEqual(@as(usize, 1), result.ast.event_decls.items.len);
    const ed = result.ast.event_decls.items[0];
    try std.testing.expectEqualStrings("Damage", result.ast.strings.slice(ed.name));
    try std.testing.expectEqual(@as(u32, 2), ed.fields_len);
    try std.testing.expectEqual(@as(usize, 1), result.ast.emit_stmts.items.len);
    const em = result.ast.emit_stmts.items[0];
    try std.testing.expectEqualStrings("Damage", result.ast.strings.slice(em.event_type));
    try std.testing.expectEqual(@as(u32, 2), em.fields_len);
}

test "parser builds an @on_event observer rule with the implicit `event` binding (M0.8 E3)" {
    const gpa = std.testing.allocator;
    // `event` is a keyword (the declaration); in expression position inside an
    // observer body it parses as the implicit `event` binding (self-style) — so
    // `event.amount` is a field access on an `.ident` named "event".
    var result = try parse(gpa,
        \\event Damage { amount: i32 = 0 }
        \\resource Tally { total: i32 = 0 }
        \\@on_event(Damage)
        \\rule absorb()
        \\  when resource Tally
        \\{
        \\  let t = get_mut(Tally)
        \\  t.total += event.amount
        \\}
    );
    defer result.deinit(gpa);
    if (result.diagnostics.len > 0) {
        std.debug.print("unexpected parse diagnostic: {s}\n", .{result.diagnostics[0].primary_message});
        try std.testing.expect(false);
    }
    // The observer rule carries the `@on_event(Damage)` annotation; the AST
    // helpers extract the event type the resolver/interpreter consume.
    try std.testing.expectEqual(@as(usize, 1), result.ast.rule_decls.items.len);
    const rule = result.ast.rule_decls.items[0];
    const annot = result.ast.onEventAnnotation(rule) orelse return error.OnEventAnnotationMissing;
    const ev_type = result.ast.onEventTypeName(annot) orelse return error.OnEventTypeMissing;
    try std.testing.expectEqualStrings("Damage", result.ast.strings.slice(ev_type));
}

test "parser builds `entity has T changed` change-detection filter (M0.8 E3)" {
    const gpa = std.testing.allocator;
    // `changed` is a reserved keyword; `has T changed` mirrors `resource T
    // changed` (`etch-grammar.md` §6, patched) and produces a `has_changed`
    // when-node — distinct from the `has T { f == v }` filter form.
    var result = try parse(gpa,
        \\component Health { current: i32 = 0 }
        \\rule react(entity: Entity) when entity has Health changed { }
    );
    defer result.deinit(gpa);
    if (result.diagnostics.len > 0) {
        std.debug.print("unexpected parse diagnostic: {s}\n", .{result.diagnostics[0].primary_message});
        try std.testing.expect(false);
    }
    var found = false;
    for (result.ast.when_nodes.items) |n| {
        if (n.kind == .has_changed) {
            try std.testing.expectEqualStrings("Health", result.ast.strings.slice(n.type_name));
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "parser recovers and a valid event after a broken construct survives (M0.8 E3 lockstep)" {
    const gpa = std.testing.allocator;
    // The lockstep stop-set now lists `kw_event`: a broken leading construct
    // resyncs at the `event` that follows, which lands in the AST.
    var result = try parse(gpa,
        \\@@@bad
        \\event Spawned { id: int }
    );
    defer result.deinit(gpa);
    try std.testing.expect(result.diagnostics.len > 0);
    try std.testing.expectEqual(@as(usize, 1), result.ast.event_decls.items.len);
}

test "parser builds a hierarchical tags declaration (M0.8 E3)" {
    const gpa = std.testing.allocator;
    var result = try parse(gpa,
        \\tags {
        \\  character {
        \\    status { alive, dead, stunned }
        \\    team { red, blue }
        \\  }
        \\  item {
        \\    rarity { common, rare }
        \\  }
        \\}
    );
    defer result.deinit(gpa);
    if (result.diagnostics.len > 0) {
        std.debug.print("unexpected parse diagnostic: {s}\n", .{result.diagnostics[0].primary_message});
        try std.testing.expect(false);
    }
    // One block; pre-order namespaces: character(0), status(1), team(2),
    // item(3), rarity(4); leaves in depth-first declaration order: alive, dead,
    // stunned, red, blue, common, rare.
    try std.testing.expectEqual(@as(usize, 1), result.ast.tags_decls.items.len);
    try std.testing.expectEqual(@as(usize, 5), result.ast.tag_namespaces.items.len);
    try std.testing.expectEqual(@as(usize, 7), result.ast.tag_leaves.items.len);

    const character = result.ast.tag_namespaces.items[0];
    try std.testing.expectEqualStrings("character", result.ast.strings.slice(character.name));
    try std.testing.expectEqual(ast_mod.TagNamespace.no_parent, character.parent);
    // `status` (index 1) and `team` (index 2) are children of `character` (0).
    try std.testing.expectEqual(@as(u32, 0), result.ast.tag_namespaces.items[1].parent);
    try std.testing.expectEqual(@as(u32, 0), result.ast.tag_namespaces.items[2].parent);
    // `rarity` (index 4) is a child of `item` (index 3).
    try std.testing.expectEqual(@as(u32, 3), result.ast.tag_namespaces.items[4].parent);

    // Leaf order == bit_index order; first leaf is `alive` under `status` (1).
    try std.testing.expectEqualStrings("alive", result.ast.strings.slice(result.ast.tag_leaves.items[0].name));
    try std.testing.expectEqual(@as(u32, 1), result.ast.tag_leaves.items[0].parent);
    // Last leaf is `rare` under `rarity` (4).
    try std.testing.expectEqualStrings("rare", result.ast.strings.slice(result.ast.tag_leaves.items[6].name));
    try std.testing.expectEqual(@as(u32, 4), result.ast.tag_leaves.items[6].parent);

    const td = result.ast.tags_decls.items[0];
    try std.testing.expectEqual(@as(u32, 5), td.ns_len);
    try std.testing.expectEqual(@as(u32, 7), td.leaf_len);
}

test "parser recovers and a valid tags after a broken construct survives (M0.8 E3 lockstep)" {
    const gpa = std.testing.allocator;
    // The lockstep stop-set now lists `kw_tags`: a broken leading construct
    // resyncs at the `tags` that follows, which lands in the AST.
    var result = try parse(gpa,
        \\@@@bad
        \\tags { character { status { alive } } }
    );
    defer result.deinit(gpa);
    try std.testing.expect(result.diagnostics.len > 0);
    try std.testing.expectEqual(@as(usize, 1), result.ast.tags_decls.items.len);
}

test "parser builds tag-filter when conditions (M0.8 E3)" {
    const gpa = std.testing.allocator;
    var result = try parse(gpa,
        \\tags { character { status { alive, stunned } } }
        \\rule a(entity: Entity) when entity has_tag .character.status.stunned { }
        \\rule b(entity: Entity) when entity has_any_tag [.character.status.alive, .character.status.stunned] { }
    );
    defer result.deinit(gpa);
    if (result.diagnostics.len > 0) {
        std.debug.print("unexpected parse diagnostic: {s}\n", .{result.diagnostics[0].primary_message});
        try std.testing.expect(false);
    }
    // Two tag filters: a single-operand `has_tag`, a two-operand `has_any_tag`.
    try std.testing.expectEqual(@as(usize, 2), result.ast.tag_filters.items.len);
    const f0 = result.ast.tag_filters.items[0];
    try std.testing.expectEqual(ast_mod.TagOp.has_tag, f0.op);
    try std.testing.expectEqual(@as(u32, 1), f0.operand_len);
    const f1 = result.ast.tag_filters.items[1];
    try std.testing.expectEqual(ast_mod.TagOp.has_any_tag, f1.op);
    try std.testing.expectEqual(@as(u32, 2), f1.operand_len);
    // The first operand of `has_tag` is a 3-segment tag path.
    const path_node = result.ast.tag_operands.items[f0.operand_start];
    const tp = result.ast.tag_paths.items[result.ast.exprData(path_node)];
    try std.testing.expectEqual(@as(u32, 3), tp.segs_len);
    try std.testing.expectEqualStrings("character", result.ast.strings.slice(result.ast.tag_path_segs.items[tp.segs_start]));
    try std.testing.expectEqualStrings("stunned", result.ast.strings.slice(result.ast.tag_path_segs.items[tp.segs_start + 2]));
}

test "parser builds tag mutation statements (M0.8 E3)" {
    const gpa = std.testing.allocator;
    var result = try parse(gpa,
        \\tags { character { status { alive, stunned } } }
        \\rule a(entity: Entity) {
        \\  entity.add_tag(.character.status.stunned)
        \\  entity.remove_tag(.character.status.alive)
        \\}
    );
    defer result.deinit(gpa);
    if (result.diagnostics.len > 0) {
        std.debug.print("unexpected parse diagnostic: {s}\n", .{result.diagnostics[0].primary_message});
        try std.testing.expect(false);
    }
    // Two mutations: an `add_tag` then a `remove_tag`.
    try std.testing.expectEqual(@as(usize, 2), result.ast.tag_mutation_stmts.items.len);
    const m0 = result.ast.tag_mutation_stmts.items[0];
    try std.testing.expectEqual(ast_mod.TagMutationKind.add, m0.kind);
    const m1 = result.ast.tag_mutation_stmts.items[1];
    try std.testing.expectEqual(ast_mod.TagMutationKind.remove, m1.kind);
    // The mutation operand is a 3-segment tag path.
    const tp = result.ast.tag_paths.items[result.ast.exprData(m0.path)];
    try std.testing.expectEqual(@as(u32, 3), tp.segs_len);
    try std.testing.expectEqualStrings("stunned", result.ast.strings.slice(result.ast.tag_path_segs.items[tp.segs_start + 2]));
    // Both mutations are `.stmt`-category nodes living in the rule body run.
    const rule = result.ast.rule_decls.items[0];
    const first_stmt: ast_mod.NodeId = @bitCast(result.ast.extra.items[rule.body_start]);
    try std.testing.expectEqual(ast_mod.NodeCategory.stmt, first_stmt.category);
    try std.testing.expectEqual(ast_mod.StmtKind.tag_mutation_stmt, result.ast.stmtKind(first_stmt));
}

test "parser: async rule parses with await wait + global_event targets (M0.8 E3 sub-slice B)" {
    const gpa = std.testing.allocator;
    var result = try parse(gpa,
        \\event Done { }
        \\async rule seq() {
        \\  await wait(3)
        \\  await global_event(Done)
        \\}
    );
    defer result.deinit(gpa);
    if (result.diagnostics.len > 0) {
        std.debug.print("unexpected parse diagnostic: {s}\n", .{result.diagnostics[0].primary_message});
        try std.testing.expect(false);
    }
    try std.testing.expectEqual(@as(usize, 1), result.ast.rule_decls.items.len);
    const rule = result.ast.rule_decls.items[0];
    try std.testing.expect(rule.is_async);
    try std.testing.expectEqual(@as(u32, 2), rule.body_len);

    // stmt 0: a bare expr-stmt wrapping `await wait(3)` (a `.wait` target).
    const s0: ast_mod.NodeId = @bitCast(result.ast.extra.items[rule.body_start]);
    try std.testing.expectEqual(ast_mod.StmtKind.expr_stmt, result.ast.stmtKind(s0));
    const e0: ast_mod.NodeId = @bitCast(result.ast.stmtData(s0));
    try std.testing.expectEqual(ast_mod.ExprKind.await_expr, result.ast.exprKind(e0));
    try std.testing.expectEqual(ast_mod.AwaitTargetKind.wait, result.ast.awaitExpr(e0).target_kind);

    // stmt 1: `await global_event(Done)` (a `.global_event` target naming `Done`).
    const s1: ast_mod.NodeId = @bitCast(result.ast.extra.items[rule.body_start + 1]);
    const e1: ast_mod.NodeId = @bitCast(result.ast.stmtData(s1));
    try std.testing.expectEqual(ast_mod.ExprKind.await_expr, result.ast.exprKind(e1));
    const aw1 = result.ast.awaitExpr(e1);
    try std.testing.expectEqual(ast_mod.AwaitTargetKind.global_event, aw1.target_kind);
    try std.testing.expectEqualStrings("Done", result.ast.strings.slice(aw1.event_type));
}

test "parser: await entity_event(entity, T) parses; payload-filter body rejected (M0.8 E3 sub-slice B)" {
    const gpa = std.testing.allocator;
    var result = try parse(gpa,
        \\event Hit { }
        \\async rule watch(target: Entity) {
        \\  await entity_event(target, Hit)
        \\}
    );
    defer result.deinit(gpa);
    if (result.diagnostics.len > 0) {
        std.debug.print("unexpected parse diagnostic: {s}\n", .{result.diagnostics[0].primary_message});
        try std.testing.expect(false);
    }
    const rule = result.ast.rule_decls.items[0];
    try std.testing.expect(rule.is_async);
    const s0: ast_mod.NodeId = @bitCast(result.ast.extra.items[rule.body_start]);
    const e0: ast_mod.NodeId = @bitCast(result.ast.stmtData(s0));
    const aw = result.ast.awaitExpr(e0);
    try std.testing.expectEqual(ast_mod.AwaitTargetKind.entity_event, aw.target_kind);
    try std.testing.expectEqualStrings("Hit", result.ast.strings.slice(aw.event_type));
    try std.testing.expect(!aw.entity_expr.isNone());

    // The optional `entity_event(e, T { ... })` payload-filter body is rejected.
    var bad = try parse(gpa,
        \\event Hit { }
        \\async rule watch(target: Entity) {
        \\  await entity_event(target, Hit { x: 1 })
        \\}
    );
    defer bad.deinit(gpa);
    try std.testing.expect(bad.diagnostics.len > 0);
}

test "parser builds a data table declaration with entries + spread (M0.8 E4)" {
    const gpa = std.testing.allocator;
    var result = try parse(gpa,
        \\data ItemDatabase: Item {
        \\  iron_sword: {
        \\    display_name: "Iron Sword",
        \\    value: 50,
        \\  },
        \\  iron_sword_enchanted: {
        \\    ..ItemDatabase.iron_sword,
        \\    value: 120,
        \\  },
        \\}
    );
    defer result.deinit(gpa);
    if (result.diagnostics.len > 0) {
        std.debug.print("unexpected parse diagnostic: {s}\n", .{result.diagnostics[0].primary_message});
        try std.testing.expect(false);
    }
    try std.testing.expectEqual(@as(usize, 1), result.ast.data_decls.items.len);
    const decl = result.ast.data_decls.items[0];
    try std.testing.expectEqualStrings("ItemDatabase", result.ast.strings.slice(decl.name));
    try std.testing.expectEqualStrings("Item", result.ast.strings.slice(decl.entry_type));
    try std.testing.expectEqual(@as(u32, 2), decl.entries_len);

    const first = result.ast.data_entries.items[decl.entries_start];
    try std.testing.expectEqualStrings("iron_sword", result.ast.strings.slice(first.id));
    try std.testing.expect(!first.id_pascal);
    try std.testing.expectEqual(@as(u32, 2), first.fields_len);
    const f0 = result.ast.struct_lit_fields.items[first.fields_start];
    try std.testing.expectEqualStrings("display_name", result.ast.strings.slice(f0.name));

    // Second entry: a spread (`name == 0`) followed by one override field.
    const second = result.ast.data_entries.items[decl.entries_start + 1];
    try std.testing.expectEqualStrings("iron_sword_enchanted", result.ast.strings.slice(second.id));
    try std.testing.expectEqual(@as(u32, 2), second.fields_len);
    const spread = result.ast.struct_lit_fields.items[second.fields_start];
    try std.testing.expectEqual(@as(ast_mod.StringId, 0), spread.name);
    try std.testing.expect(!spread.value.isNone());
    const override_field = result.ast.struct_lit_fields.items[second.fields_start + 1];
    try std.testing.expectEqualStrings("value", result.ast.strings.slice(override_field.name));
}

test "parser keeps data entry field runs contiguous around nested struct literals (M0.8 E4)" {
    const gpa = std.testing.allocator;
    // The `pos` value is a struct literal whose own fields land in
    // `struct_lit_fields` DURING the entry parse; the entry's run must stay
    // contiguous (buffered commit), i.e. exactly [pos, hp].
    var result = try parse(gpa,
        \\data SpawnTable: Spawn {
        \\  guard: { pos: Vec2 { x: 1.0, y: 2.0 }, hp: 5 },
        \\}
    );
    defer result.deinit(gpa);
    if (result.diagnostics.len > 0) {
        std.debug.print("unexpected parse diagnostic: {s}\n", .{result.diagnostics[0].primary_message});
        try std.testing.expect(false);
    }
    const decl = result.ast.data_decls.items[0];
    const entry = result.ast.data_entries.items[decl.entries_start];
    try std.testing.expectEqual(@as(u32, 2), entry.fields_len);
    const f0 = result.ast.struct_lit_fields.items[entry.fields_start];
    const f1 = result.ast.struct_lit_fields.items[entry.fields_start + 1];
    try std.testing.expectEqualStrings("pos", result.ast.strings.slice(f0.name));
    try std.testing.expectEqualStrings("hp", result.ast.strings.slice(f1.name));
}

test "parser accepts a PascalCase data entry id, recorded for E1768 (M0.8 E4)" {
    const gpa = std.testing.allocator;
    var result = try parse(gpa,
        \\data Foo: Bar {
        \\  BadId: { x: 1 },
        \\}
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    const decl = result.ast.data_decls.items[0];
    const entry = result.ast.data_entries.items[decl.entries_start];
    try std.testing.expect(entry.id_pascal);
}

test "parser rejects a data table without its entry type (M0.8 E4)" {
    const gpa = std.testing.allocator;
    var result = try parse(gpa,
        \\data ItemDatabase {
        \\  iron_sword: { value: 50 },
        \\}
    );
    defer result.deinit(gpa);
    try std.testing.expect(result.diagnostics.len > 0);
    try std.testing.expectEqual(@as(usize, 0), result.ast.data_decls.items.len);
}

test "parser recovers and a valid data after a broken construct survives (M0.8 E4 lockstep)" {
    const gpa = std.testing.allocator;
    // The lockstep stop-set now lists `kw_data`: a broken leading construct
    // resyncs at the `data` that follows, which lands in the AST.
    var result = try parse(gpa,
        \\@@@bad
        \\data ItemDatabase: Item { iron_sword: { value: 50 } }
    );
    defer result.deinit(gpa);
    try std.testing.expect(result.diagnostics.len > 0);
    try std.testing.expectEqual(@as(usize, 1), result.ast.data_decls.items.len);
}

test "parser builds a routine with segments + interrupts (M0.8 E4)" {
    const gpa = std.testing.allocator;
    var result = try parse(gpa,
        \\routine BlacksmithDaily {
        \\  segment Working {
        \\    trigger: at 06:00 or after Sleeping
        \\    actions: use_smart_object("forge_anvil")
        \\    until: at 12:00 or on_event MealCallReceived
        \\  }
        \\  segment Sleeping {
        \\    trigger: at 22:00
        \\    actions: go_to("bed") then idle("sleeping")
        \\    until: at 06:00
        \\  }
        \\  on_threat_detected -> CombatBehavior
        \\  on_dialogue_request -> pause_segment
        \\}
    );
    defer result.deinit(gpa);
    if (result.diagnostics.len > 0) {
        std.debug.print("unexpected parse diagnostic: {s}\n", .{result.diagnostics[0].primary_message});
        try std.testing.expect(false);
    }
    try std.testing.expectEqual(@as(usize, 1), result.ast.routine_decls.items.len);
    const decl = result.ast.routine_decls.items[0];
    try std.testing.expectEqualStrings("BlacksmithDaily", result.ast.strings.slice(decl.name));
    try std.testing.expectEqual(@as(u32, 2), decl.segments_len);
    try std.testing.expectEqual(@as(u32, 2), decl.interrupts_len);

    const working = result.ast.routine_segments.items[decl.segments_start];
    try std.testing.expectEqualStrings("Working", result.ast.strings.slice(working.name));
    try std.testing.expectEqual(@as(u32, 2), working.triggers_len);
    try std.testing.expectEqual(@as(u32, 1), working.actions_len);
    try std.testing.expectEqual(@as(u32, 2), working.untils_len);
    const t0 = result.ast.routine_triggers.items[working.triggers_start];
    try std.testing.expectEqual(ast_mod.RoutineTriggerKind.at_time, t0.kind);
    try std.testing.expectEqualStrings("06:00", result.ast.strings.slice(t0.value));
    const t1 = result.ast.routine_triggers.items[working.triggers_start + 1];
    try std.testing.expectEqual(ast_mod.RoutineTriggerKind.after_segment, t1.kind);
    try std.testing.expectEqualStrings("Sleeping", result.ast.strings.slice(t1.value));
    const until_alt = result.ast.routine_triggers.items[working.untils_start + 1];
    try std.testing.expectEqual(ast_mod.RoutineTriggerKind.on_event, until_alt.kind);
    try std.testing.expectEqualStrings("MealCallReceived", result.ast.strings.slice(until_alt.value));

    // Second segment: two `then`-chained actions, each a fn_call.
    const sleeping = result.ast.routine_segments.items[decl.segments_start + 1];
    try std.testing.expectEqual(@as(u32, 2), sleeping.actions_len);
    const a0: ast_mod.NodeId = @bitCast(result.ast.extra.items[sleeping.actions_start]);
    try std.testing.expectEqual(ast_mod.ExprKind.fn_call, result.ast.exprKind(a0));

    // Interrupts: behavior target then pause_segment.
    const int0 = result.ast.routine_interrupts.items[decl.interrupts_start];
    try std.testing.expectEqualStrings("on_threat_detected", result.ast.strings.slice(int0.event_name));
    try std.testing.expect(!int0.is_pause);
    const int1 = result.ast.routine_interrupts.items[decl.interrupts_start + 1];
    try std.testing.expect(int1.is_pause);
}

test "parser rejects routine clause-order and shape violations (M0.8 E4)" {
    const gpa = std.testing.allocator;
    // `actions` before `trigger` — the §8.2 clause order is fixed.
    var bad_order = try parse(gpa,
        \\routine R {
        \\  segment A {
        \\    actions: go_to("x")
        \\    trigger: at 06:00
        \\    until: at 07:00
        \\  }
        \\}
    );
    defer bad_order.deinit(gpa);
    try std.testing.expect(bad_order.diagnostics.len > 0);

    // A non-call action is rejected at parse (routine_action = IDENT(args)).
    var bad_action = try parse(gpa,
        \\routine R {
        \\  segment A {
        \\    trigger: at 06:00
        \\    actions: just_an_ident
        \\    until: at 07:00
        \\  }
        \\}
    );
    defer bad_action.deinit(gpa);
    try std.testing.expect(bad_action.diagnostics.len > 0);

    // `at` requires a DD:DD time literal.
    var bad_time = try parse(gpa,
        \\routine R {
        \\  segment A {
        \\    trigger: at 6
        \\    actions: go_to("x")
        \\    until: at 07:00
        \\  }
        \\}
    );
    defer bad_time.deinit(gpa);
    try std.testing.expect(bad_time.diagnostics.len > 0);
}

test "parser rejects the out-of-scope timer statement after kw_after graduation (M0.8 E4)" {
    const gpa = std.testing.allocator;
    var result = try parse(gpa,
        \\rule r(entity: Entity) when entity has Health {
        \\  after 2.0 { }
        \\}
    );
    defer result.deinit(gpa);
    try std.testing.expect(result.diagnostics.len > 0);
}

test "parser recovers and a valid routine after a broken construct survives (M0.8 E4 lockstep)" {
    const gpa = std.testing.allocator;
    // The lockstep stop-set now lists `kw_routine`: a broken leading
    // construct resyncs at the `routine` that follows, which lands in the AST.
    var result = try parse(gpa,
        \\@@@bad
        \\routine Daily {
        \\  segment A {
        \\    trigger: at 06:00
        \\    actions: go_to("forge")
        \\    until: at 12:00
        \\  }
        \\}
    );
    defer result.deinit(gpa);
    try std.testing.expect(result.diagnostics.len > 0);
    try std.testing.expectEqual(@as(usize, 1), result.ast.routine_decls.items.len);
}

test "parser builds the §6 when-surface extension forms (M0.8 E4 item 4)" {
    const gpa = std.testing.allocator;
    var result = try parse(gpa,
        \\component Counter { value: int = 0 }
        \\resource Config { enabled: bool = true }
        \\rule r1(entity: Entity)
        \\  when entity has Counter { value * 2 < 10 }
        \\{
        \\  entity.get_mut(Counter).value += 1
        \\}
        \\rule r2(entity: Entity)
        \\  when entity has Counter and entity.get(Counter).value > 4
        \\{
        \\  entity.get_mut(Counter).value += 1
        \\}
        \\rule r3(entity: Entity)
        \\  when resource Config { enabled } and entity has Counter
        \\{
        \\  entity.get_mut(Counter).value += 1
        \\}
    );
    defer result.deinit(gpa);
    if (result.diagnostics.len > 0) {
        std.debug.print("unexpected parse diagnostic: {s}\n", .{result.diagnostics[0].primary_message});
        try std.testing.expect(false);
    }
    // r1: a single has_expr_filter leaf (the general filter, NOT the body).
    const r1 = result.ast.rule_decls.items[0];
    const n1 = result.ast.when_nodes.items[r1.when_root];
    try std.testing.expectEqual(ast_mod.WhenNodeKind.has_expr_filter, n1.kind);
    try std.testing.expect(!n1.filter_value.isNone());
    try std.testing.expectEqual(@as(u32, 1), r1.body_len);
    // r2: and(has, expr_cond) — the bare arm capped below and/or.
    const r2 = result.ast.rule_decls.items[1];
    const n2 = result.ast.when_nodes.items[r2.when_root];
    try std.testing.expectEqual(ast_mod.WhenNodeKind.logical_and, n2.kind);
    try std.testing.expectEqual(ast_mod.WhenNodeKind.has, result.ast.when_nodes.items[n2.lhs].kind);
    try std.testing.expectEqual(ast_mod.WhenNodeKind.expr_cond, result.ast.when_nodes.items[n2.rhs].kind);
    // r3: and(resource_filter, has).
    const r3 = result.ast.rule_decls.items[2];
    const n3 = result.ast.when_nodes.items[r3.when_root];
    try std.testing.expectEqual(ast_mod.WhenNodeKind.logical_and, n3.kind);
    try std.testing.expectEqual(ast_mod.WhenNodeKind.resource_filter, result.ast.when_nodes.items[n3.lhs].kind);
}

test "parser keeps the body brace out of the §6 general filter (M0.8 E4)" {
    const gpa = std.testing.allocator;
    // `has Counter` directly followed by the rule body: the matching-brace
    // scan sees the body's `}` followed by EOF → NOT a filter.
    var result = try parse(gpa,
        \\component Counter { value: int = 0 }
        \\rule r(entity: Entity)
        \\  when entity has Counter
        \\{
        \\  let x = 1
        \\  entity.get_mut(Counter).value += x
        \\}
    );
    defer result.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    const rule = result.ast.rule_decls.items[0];
    try std.testing.expectEqual(ast_mod.WhenNodeKind.has, result.ast.when_nodes.items[rule.when_root].kind);
    try std.testing.expectEqual(@as(u32, 2), rule.body_len);
}
