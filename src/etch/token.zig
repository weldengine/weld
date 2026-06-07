//! Token types for the S3 Etch lexer. Keywords / operators / punctuation
//! mirror the brief's "Keywords recognized" and "Operators / punctuation
//! recognized" subsections of `briefs/S3-etch-parser-subset.md`. Any other
//! keyword from EBNF v0.6 is lexed as an `error_unknown_keyword` token so
//! the parser can emit `E0001 ParseError` with a precise span at the use
//! site (Scope: "Any other Etch keyword listed in `etch-grammar.md` §1.3
//! is lexed as an unknown keyword token").

const std = @import("std");

/// Byte span in the original source. End is exclusive.
pub const SourceSpan = struct {
    byte_start: u32,
    byte_end: u32,

    pub fn merge(a: SourceSpan, b: SourceSpan) SourceSpan {
        return .{
            .byte_start = @min(a.byte_start, b.byte_start),
            .byte_end = @max(a.byte_end, b.byte_end),
        };
    }
};

/// Closed enum of Etch token kinds produced by the lexer. The
/// S3 subset is implemented; future kinds are added as the grammar
/// expands.
pub const TokenKind = enum {
    // ── Literals ──
    ident, // any identifier starting with [a-z_]
    type_ident, // identifier starting with [A-Z]
    int_literal,
    float_literal,
    bool_literal, // true / false
    string_literal, // simple-quote only in S3 (no interpolation)

    // ── Keywords (S3 subset) ──
    kw_let,
    kw_mut,
    kw_component,
    kw_resource,
    kw_rule,
    kw_when,
    kw_and,
    kw_or,
    kw_not,
    kw_has,
    kw_changed,
    kw_get,
    kw_get_mut,
    kw_as, // cast operator (M0.8 v0.6 foundations)
    kw_type, // top-level type alias (M0.8 v0.6 foundations)
    kw_assert, // assert statement (M0.8 v0.6 foundations)
    kw_match, // match expression (M0.8 v0.6 foundations)
    kw_for, // for-in loop (M0.8 v0.6 foundations)
    kw_in, // for-in loop (M0.8 v0.6 foundations)
    kw_loop, // loop expression (M0.8 loop/break)
    kw_break, // break [label] [value] (M0.8 loop/break)
    kw_continue, // continue [label] (M0.8 loop/break)
    kw_if, // if/else expression + statement (M0.8 control-flow completion)
    kw_else,
    kw_while, // while loop statement (M0.8 control-flow completion)
    kw_throw, // throw expression (M0.8 error handling)
    kw_try, // try { } catch (M0.8 error handling)
    kw_catch, // try { } catch IDENT { } (M0.8 error handling)
    kw_fn, // top-level fn declaration (M0.8 E2 call mechanism)
    kw_return, // return [expr] (M0.8 E2 call mechanism)
    kw_throws, // fn throws marker (M0.8 E2 call mechanism)
    kw_async, // async fn (parsed E2; interp E3, codegen Phase 2)

    // ── Primitive type keywords (lexed as kw_type_*) ──
    kw_int,
    kw_float,
    kw_bool,
    kw_i32,
    kw_u32,
    kw_f32,
    kw_f64,

    // ── Operators / punctuation ──
    plus,
    minus,
    star,
    slash,
    percent,
    eq,
    plus_eq,
    minus_eq,
    star_eq,
    slash_eq,
    percent_eq,
    eq_eq,
    bang_eq,
    lt,
    gt,
    lt_eq,
    gt_eq,
    fat_arrow, // => (match arm, M0.8 v0.6 foundations)
    arrow, // -> (fn return type, M0.8 E2 call mechanism)
    dotdot, // .. exclusive range (M0.8 v0.6 foundations)
    dotdot_eq, // ..= inclusive range (M0.8 v0.6 foundations)
    lparen,
    rparen,
    lbrace,
    rbrace,
    lbracket, // [ — array / map literals, indexing (M0.8 collections)
    rbracket, // ]
    semicolon, // ; — array fill literal `[v; n]` (M0.8 collections)
    pipe, // | — closure delimiter `|a| e` (M0.8 closures; bitwise-or is out of E1)
    colon,
    comma,
    dot,
    at,

    // ── End / error ──
    eof,
    /// Unknown / unsupported byte. Carries the byte span; the parser
    /// turns these into `E0001 ParseError` at use site.
    error_byte,
    /// Invalid UTF-8 continuation byte. The parser emits `E0001` with
    /// the precise byte offset.
    error_utf8,
    /// Lexed an identifier that matches an Etch keyword outside the S3
    /// subset (e.g. `fn`, `enum`, `behavior`). The parser turns these
    /// into `E0001 UnsupportedConstructInS3` at use site.
    error_unknown_keyword,
};

/// `span` is a byte range *into the original source buffer*, not an
/// owned slice. Callers must keep the source alive for as long as
/// any `Token` referencing it stays in use.
pub const Token = struct {
    kind: TokenKind,
    span: SourceSpan,
};

/// Map `[]const u8` → `TokenKind` for keywords. The lookup is a linear
/// scan over a small static table — adequate for the S3 corpus (<200 LOC
/// per file, every identifier hit is amortised by the parser's main work).
pub const KeywordEntry = struct { lexeme: []const u8, kind: TokenKind };

/// S3 keyword table — the lexer scans identifiers against this slice
/// to promote them to `KeywordEntry.kind`. Each entry is `(lexeme,
/// kind)`; entries are matched in order, so the table doubles as the
/// canonical S3 keyword set.
pub const s3_keywords = [_]KeywordEntry{
    .{ .lexeme = "let", .kind = .kw_let },
    .{ .lexeme = "mut", .kind = .kw_mut },
    .{ .lexeme = "component", .kind = .kw_component },
    .{ .lexeme = "resource", .kind = .kw_resource },
    .{ .lexeme = "rule", .kind = .kw_rule },
    .{ .lexeme = "when", .kind = .kw_when },
    .{ .lexeme = "and", .kind = .kw_and },
    .{ .lexeme = "or", .kind = .kw_or },
    .{ .lexeme = "not", .kind = .kw_not },
    .{ .lexeme = "has", .kind = .kw_has },
    .{ .lexeme = "changed", .kind = .kw_changed },
    .{ .lexeme = "get", .kind = .kw_get },
    .{ .lexeme = "get_mut", .kind = .kw_get_mut },
    .{ .lexeme = "as", .kind = .kw_as },
    .{ .lexeme = "type", .kind = .kw_type },
    .{ .lexeme = "assert", .kind = .kw_assert },
    .{ .lexeme = "match", .kind = .kw_match },
    .{ .lexeme = "for", .kind = .kw_for },
    .{ .lexeme = "in", .kind = .kw_in },
    .{ .lexeme = "loop", .kind = .kw_loop },
    .{ .lexeme = "break", .kind = .kw_break },
    .{ .lexeme = "continue", .kind = .kw_continue },
    .{ .lexeme = "if", .kind = .kw_if },
    .{ .lexeme = "else", .kind = .kw_else },
    .{ .lexeme = "while", .kind = .kw_while },
    .{ .lexeme = "throw", .kind = .kw_throw },
    .{ .lexeme = "try", .kind = .kw_try },
    .{ .lexeme = "catch", .kind = .kw_catch },
    .{ .lexeme = "fn", .kind = .kw_fn },
    .{ .lexeme = "return", .kind = .kw_return },
    .{ .lexeme = "throws", .kind = .kw_throws },
    .{ .lexeme = "async", .kind = .kw_async },
    .{ .lexeme = "true", .kind = .bool_literal },
    .{ .lexeme = "false", .kind = .bool_literal },
    .{ .lexeme = "int", .kind = .kw_int },
    .{ .lexeme = "float", .kind = .kw_float },
    .{ .lexeme = "bool", .kind = .kw_bool },
    .{ .lexeme = "i32", .kind = .kw_i32 },
    .{ .lexeme = "u32", .kind = .kw_u32 },
    .{ .lexeme = "f32", .kind = .kw_f32 },
    .{ .lexeme = "f64", .kind = .kw_f64 },
};

/// Etch keywords that introduce **constructs explicitly out of S3 scope**
/// (`briefs/S3-etch-parser-subset.md` Out-of-scope). Any identifier that
/// matches one of these is lexed as `error_unknown_keyword` so the parser
/// emits `E0001 UnsupportedConstructInS3` at use site.
///
/// Type names (`string`, `Entity`, `Vec3`, ...) are deliberately omitted
/// — they reach the type-checker as plain identifiers or `TYPE_IDENT`s
/// and surface as `E0102 UndefinedSymbol` (or POD-specific messages on
/// component fields). Sub-construct keywords (`segment`, `state`, `layer`,
/// `bind`, ...) are also omitted: they are unreachable in legal S3 input
/// since their parent construct is already rejected, and including them
/// would collide with legitimate identifier names like `state`, `event`,
/// `priority`.
pub const non_s3_keywords = [_][]const u8{
    // ── Top-level constructs still out of scope (`fn` graduated with M0.8 E2
    //    call mechanism) ──
    "struct",      "enum",           "trait",         "impl",
    "event",       "tags",           "import",        "const",
    "private",     "behavior",       "routine",       "quest",
    "dialogue",    "ability",        "effect",        "shader",
    "widget",      "theme",          "motion",        "anim_graph",
    "audio_graph", "audio_score",    "sequence",      "data",
    "scene",       "prefab",         "input_mapping", "locale",
    "test",        "override",

    // ── Async machinery: `async` graduated with M0.8 E2 (`async fn` parsed;
    //    interp E3, codegen Phase 2); the await machinery stays out of scope ──
          "await",         "race",
    "sync",        "branch",         "spawn",

    // ── Tag operators (out of S3) ──
            "has_tag",
    "has_no_tag",  "has_any_tag",    "has_all_tags",  "has_no_tags",
    "add_tag",     "remove_tag",

    // ── Timers / emit / lifecycle (out of S3) ──
        "emit",          "after",
    "every",       "after_unscaled", "quantize",

    // Note: `where`, `self`, `none`, `some` are intentionally NOT listed —
    // they appear in legitimate identifier-shaped positions in S3 annotation
    // args (e.g. `@pause_group(.none)`). The S3 parser accepts them as plain
    // identifiers; their grammar-level uses (generic bound, impl self param,
    // Optional construction) only show up in constructs rejected at the top
    // level. `as` graduated to a real keyword with the M0.8 cast operator.
};

test "non_s3_keywords does not collide with s3_keywords" {
    inline for (s3_keywords) |s3_kw| {
        for (non_s3_keywords) |non| {
            // Each Etch keyword may appear in exactly one of the two tables.
            try std.testing.expect(!std.mem.eql(u8, s3_kw.lexeme, non));
        }
    }
}
