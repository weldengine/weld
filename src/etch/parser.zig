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
        if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') {
            return try self.arena.strings.intern(self.gpa, raw);
        }
        return try self.arena.strings.intern(self.gpa, raw[1 .. raw.len - 1]);
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
    /// S3 (`component` / `resource` / `rule`) + `type` (M0.8 alias). Later
    /// milestones extend both sites together (`fn`/`struct`/… in E2,
    /// `event`/`tags` in E3).
    fn recoverToTopLevel(self: *Parser) ParseError!void {
        if (self.peek() != .eof) _ = try self.advance();
        while (true) {
            switch (self.peek()) {
                .eof, .kw_component, .kw_resource, .kw_rule, .kw_type => return,
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
            .kw_rule => try self.parseRuleDecl(annotations),
            .kw_type => try self.parseTypeAliasDecl(annotations),
            .eof => {},
            else => return self.parseErrFmt(self.peekSpan(), "expected top-level declaration (component | resource | rule | type), got '{s}'", .{self.sliceOf(self.peekSpan())}),
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
        switch (self.peek()) {
            // PascalCase type identifiers (Entity, Vec3, Color, Duration,
            // user-declared components/resources) and the primitive type
            // keywords baked into the S3 lexer.
            .type_ident,
            .kw_int,
            .kw_float,
            .kw_bool,
            .kw_i32,
            .kw_u32,
            .kw_f32,
            .kw_f64,
            // Lowercase identifiers that resemble types — including names
            // outside the S3 builtin set (`string`, `char`, etc.). The
            // type-checker emits `E0102 UndefinedSymbol` (or a POD-specific
            // message when applicable).
            .ident,
            => {
                const tok = try self.advance();
                const name_id = try self.internSlice(tok.span);
                return try self.arena.addNamedType(self.gpa, name_id, tok.span);
            },
            else => return self.parseErrFmt(self.peekSpan(), "expected type, got '{s}'", .{self.sliceOf(self.peekSpan())}),
        }
    }

    // ─── Rule ────────────────────────────────────────────────────────────

    fn parseRuleDecl(self: *Parser, annotations: AnnotationRange) ParseError!void {
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
        });
        _ = try self.arena.addItem(self.gpa, .rule_decl, data_idx, .{
            .byte_start = kw_span.byte_start,
            .byte_end = closing.span.byte_end,
        });
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
            var end_byte = type_tok.span.byte_end;
            if (self.peek() == .kw_changed) {
                const changed_tok = try self.advance();
                kind = .resource_changed;
                end_byte = changed_tok.span.byte_end;
            }
            const node = ast_mod.WhenNode{
                .kind = kind,
                .entity_name = 0,
                .type_name = type_name,
                .field_name = 0,
                .filter_value = NodeId.none,
                .lhs = ast_mod.WhenNode.no_child,
                .rhs = ast_mod.WhenNode.no_child,
                .span = .{ .byte_start = start_span.byte_start, .byte_end = end_byte },
            };
            const idx: u32 = @intCast(self.arena.when_nodes.items.len);
            try self.arena.when_nodes.append(self.gpa, node);
            return idx;
        }
        // `entity has T [{ field == value }]`
        const entity_tok = try self.expect(.ident, "expected entity binding in when clause");
        const entity_name = try self.internSlice(entity_tok.span);
        _ = try self.expect(.kw_has, "expected 'has' in when clause");
        const type_tok = try self.expect(.type_ident, "expected component type after 'has'");
        const type_name = try self.internSlice(type_tok.span);

        var kind = ast_mod.WhenNodeKind.has;
        var field_name: StringId = 0;
        var filter_value: NodeId = NodeId.none;
        var end_byte = type_tok.span.byte_end;
        // Disambiguation `{` filter vs `{` rule body: the filter form
        // requires `{ IDENT == ... }`. Anything else (including `{ }` or
        // `{ let ... }`) belongs to the surrounding rule body and must
        // be left for `parseRuleDecl` to consume.
        if (self.peek() == .lbrace and self.peekNext() == .ident and self.peekNext2() == .eq_eq) {
            _ = try self.advance(); // '{'
            const field_tok = try self.advance(); // IDENT
            field_name = try self.internSlice(field_tok.span);
            _ = try self.advance(); // '=='
            filter_value = try self.parseExpr(0);
            const closing = try self.expect(.rbrace, "expected '}' to close has-with-filter");
            end_byte = closing.span.byte_end;
            kind = .has_with_filter;
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
        const iterable = try self.parseExpr(0);
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

    fn parseStmt(self: *Parser) ParseError!NodeId {
        if (self.peek() == .kw_let) {
            return try self.parseLetStmt();
        }
        if (self.peek() == .kw_assert) {
            return try self.parseAssertStmt();
        }
        if (self.peek() == .kw_for) {
            return try self.parseForStmt();
        }
        // Either an assignment (lvalue followed by =/+=/etc.) or an expr stmt.
        const expr_start = self.current.span;
        const expr = try self.parseExpr(0);
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
        while (self.peek() == .dot) {
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
                .ident => {
                    const field_tok = try self.advance();
                    const field_id = try self.internSlice(field_tok.span);
                    const recv_span = self.arena.exprSpan(expr);
                    expr = try self.arena.addFieldAccess(self.gpa, expr, field_id, .{
                        .byte_start = recv_span.byte_start,
                        .byte_end = field_tok.span.byte_end,
                    });
                },
                else => return self.parseErrFmt(self.peekSpan(), "expected field name or 'get'/'get_mut' after '.', got '{s}'", .{self.sliceOf(self.peekSpan())}),
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
            else => return self.parseErrFmt(self.peekSpan(), "unsupported match pattern (E1 supports '_', literals, and bindings), got '{s}'", .{self.sliceOf(self.peekSpan())}),
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
        const scrutinee = try self.parseExpr(0);
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

    fn parsePrimary(self: *Parser) ParseError!NodeId {
        try self.surfaceTokenErrors();
        switch (self.peek()) {
            .kw_match => return try self.parseMatch(),
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
                const id = try self.internStringLiteral(tok.span);
                return try self.arena.addExpr(self.gpa, .string_lit, id, tok.span);
            },
            .ident => {
                const tok = try self.advance();
                const id = try self.internSlice(tok.span);
                return try self.arena.addExpr(self.gpa, .ident, id, tok.span);
            },
            .type_ident => {
                // TYPE_IDENT in expression position is a path-like value.
                // S3 only accepts it as annotation argument shape — the
                // type-checker does not resolve annotation args (Phase 0.2).
                const tok = try self.advance();
                const id = try self.internSlice(tok.span);
                return try self.arena.addExpr(self.gpa, .path, id, tok.span);
            },
            .lparen => {
                _ = try self.advance();
                const inner = try self.parseExpr(0);
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
    var result = try parse(gpa,
        \\fn foo() {}
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
