//! Token types for the Etch lexer. Keywords / operators / punctuation
//! mirror the brief's "Keywords recognized" and "Operators / punctuation
//! recognized" surface the lexer implements. Any other
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
/// enum is exhaustive for API stability; a kind may exist that the lexer
/// never produces.
pub const TokenKind = enum {
    // ── Literals ──
    ident, // any identifier starting with [a-z_]
    type_ident, // identifier starting with [A-Z]
    int_literal,
    float_literal,
    bool_literal, // true / false
    string_literal, // simple-quote only (no interpolation)
    time_literal, // DD:DD in-game time (routine triggers, §1.4)
    duration_literal, // FLOAT "s" duration (gate fix, §1.4 — greedy-contiguous)
    color_literal, // "#" + 6 or 8 hex (§1.4 l.211 — the DURATION_LIT-precedent literal lift)
    multiline_string_literal, // triple-quote `"""…"""` (§1.4 — newline-spanning, DURATION/COLOR greedy-lift precedent; common indent stripped at parse)

    // ── Keywords ──
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
    kw_as, // cast operator
    kw_type, // top-level type alias
    kw_assert, // assert statement
    kw_match, // match expression
    kw_for, // for-in loop
    kw_in, // for-in loop
    kw_loop, // loop expression
    kw_break, // break [label] [value]
    kw_continue, // continue [label]
    kw_if, // if/else expression + statement
    kw_else,
    kw_while, // while loop statement
    kw_throw, // throw expression
    kw_try, // try { } catch
    kw_catch, // try { } catch IDENT { }
    kw_fn, // top-level fn declaration
    kw_return, // return [expr]
    kw_throws, // fn throws marker
    kw_async, // async fn (parsed and interpreted; codegen rejects it loudly)
    kw_await, // await <target>
    kw_struct, // struct declaration
    kw_impl, // impl block
    kw_enum, // enum declaration
    kw_trait, // trait declaration
    kw_event, // event declaration
    kw_emit, // emit statement
    kw_tags, // tags hierarchical declaration
    kw_has_tag, // tag query operator
    kw_has_no_tag, // tag query operator
    kw_has_any_tag, // tag query operator
    kw_has_all_tags, // tag query operator
    kw_has_no_tags, // tag query operator
    kw_add_tag, // tag mutation
    kw_remove_tag, // tag mutation
    kw_data, // data table declaration
    kw_routine, // routine declaration
    kw_behavior, // behavior tree declaration
    kw_quest, // quest declaration
    kw_dialogue, // dialogue declaration
    kw_ability, // ability declaration
    kw_branch, // quest/dialogue branch
    kw_sequence, // behavior composite type + the top-level `sequence` cinematic construct (matched by token kind in parseTopLevel — the input_combo precedent)
    kw_after, // routine trigger `after Segment` (the §4.3 timer statement is a distinct parse error)
    kw_theme, // theme declaration
    kw_motion, // motion declaration
    kw_input_mapping, // input_mapping declaration
    kw_widget, // widget declaration
    kw_locale, // locale declaration
    kw_effect, // effect declaration (emitters + event handlers, VFX-only since v0.6)
    kw_audio_graph, // audio_graph declaration
    kw_audio_score, // audio_score declaration
    kw_anim_graph, // anim_graph declaration
    kw_shader, // shader declaration
    kw_scene, // scene declaration
    kw_prefab, // prefab declaration
    kw_import, // import directive
    kw_const, // top-level `const` declaration (top-level only per part1 §4.5)
    kw_private, // `private` visibility modifier prefix on a declaration_body (grammar §5.1)
    kw_test, // top-level `test "name" { ... }` block
    kw_spawn, // structural spawn expr `spawn(C{…})` (§3.2 structural_spawn) + the async task statement `[let IDENT =] spawn { }` (§4.2 spawn_stmt) — disambiguated by the next token
    kw_race, // race statement `race { race_branch* }` (§4.2 race_stmt)
    kw_sync, // sync statement `sync { sync_branch* }` (§4.2 sync_stmt)
    kw_every, // repeating timer statement `[let IDENT =] every(d) { }` (§4.3 timer_stmt)
    kw_after_unscaled, // unscaled one-shot timer statement `[let IDENT =] after_unscaled(d) { }` (§4.3 timer_stmt)
    kw_measure, // `measure { block }` expression (§17 erratum; wall-clock Duration, test-body only via E0910). Stays inside the [kw_let, kw_f64] keyword range for isKeywordToken.
    /// `service NAME { fn … }` — the `.d.etch`-only construct of
    /// `etch-grammar.md` §20.4.
    ///
    /// This is a keyword **ADDITION**, not a graduation: `service` has never
    /// been a member of `non_s3_keywords` (that list is `{ override, quantize }`),
    /// so before this milestone it lexed as an ordinary identifier. An `.etch`
    /// file using `service` as an identifier therefore stops compiling. The cost
    /// was **measured** and not assumed: zero occurrences of the bare word across
    /// the 307 `.etch` files in the repository at `4869ef1`.
    ///
    /// Like `kw_measure`, it stays inside the [kw_let, kw_f64] range that
    /// `isKeywordToken` pins with a comptime assert.
    kw_service,

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
    fat_arrow, // => (match arm)
    arrow, // -> (fn return type)
    dotdot, // .. exclusive range
    dotdot_eq, // ..= inclusive range
    lparen,
    rparen,
    lbrace,
    rbrace,
    lbracket, // [ — array / map literals, indexing
    rbracket, // ]
    semicolon, // ; — array fill literal `[v; n]`
    pipe, // | — closure delimiter `|a| e`
    colon,
    comma,
    dot,
    at,
    question, // ? — optional type suffix `T?`
    question_dot, // ?. — optional chain (part1 §6.6)
    question_question, // ?? — null coalesce (part1 §6.6)
    bang, // ! postfix — force unwrap (part1 §6.6)

    // ── End / error ──
    eof,
    /// Unknown / unsupported byte. Carries the byte span; the parser
    /// turns these into `E0001 ParseError` at use site.
    error_byte,
    /// Invalid UTF-8 continuation byte. The parser emits `E0001` with
    /// the precise byte offset.
    error_utf8,
    /// Lexed an identifier that matches an Etch keyword still outside the
    /// supported subset (e.g. `behavior`, `event`, `quest`). The parser turns
    /// these into `E0001 UnsupportedConstructInS3` at use site.
    error_unknown_keyword,
};

/// `span` is a byte range *into the original source buffer*, not an
/// owned slice. Callers must keep the source alive for as long as
/// any `Token` referencing it stays in use.
pub const Token = struct {
    kind: TokenKind,
    span: SourceSpan,
};

/// True when `k` is a keyword token (the contiguous `kw_let`…`kw_f64`
/// block). Tag-path segments and tag-namespace names accept keywords
/// CONTEXTUALLY: graduating a construct keyword (`quest`,
/// `data`, …) must never break a tag hierarchy that uses the same word
/// (`.quest.merchant_intro_done`).
pub fn isKeywordToken(k: TokenKind) bool {
    comptime {
        // The range check rides the enum order — pin it.
        std.debug.assert(@intFromEnum(TokenKind.kw_let) < @intFromEnum(TokenKind.kw_f64));
    }
    const v = @intFromEnum(k);
    return v >= @intFromEnum(TokenKind.kw_let) and v <= @intFromEnum(TokenKind.kw_f64);
}

/// Map `[]const u8` → `TokenKind` for keywords. The lookup is a linear
/// scan over a small static table — adequate for the corpus (<200 LOC
/// per file, every identifier hit is amortised by the parser's main work).
pub const KeywordEntry = struct { lexeme: []const u8, kind: TokenKind };

/// The keyword table — the lexer scans identifiers against this slice
/// to promote them to `KeywordEntry.kind`. Each entry is `(lexeme,
/// kind)`; entries are matched in order, so the table doubles as the
/// canonical keyword set.
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
    .{ .lexeme = "await", .kind = .kw_await },
    .{ .lexeme = "struct", .kind = .kw_struct },
    .{ .lexeme = "impl", .kind = .kw_impl },
    .{ .lexeme = "enum", .kind = .kw_enum },
    .{ .lexeme = "trait", .kind = .kw_trait },
    .{ .lexeme = "event", .kind = .kw_event },
    .{ .lexeme = "emit", .kind = .kw_emit },
    .{ .lexeme = "tags", .kind = .kw_tags },
    .{ .lexeme = "has_tag", .kind = .kw_has_tag },
    .{ .lexeme = "has_no_tag", .kind = .kw_has_no_tag },
    .{ .lexeme = "has_any_tag", .kind = .kw_has_any_tag },
    .{ .lexeme = "has_all_tags", .kind = .kw_has_all_tags },
    .{ .lexeme = "has_no_tags", .kind = .kw_has_no_tags },
    .{ .lexeme = "add_tag", .kind = .kw_add_tag },
    .{ .lexeme = "remove_tag", .kind = .kw_remove_tag },
    .{ .lexeme = "data", .kind = .kw_data },
    .{ .lexeme = "routine", .kind = .kw_routine },
    .{ .lexeme = "behavior", .kind = .kw_behavior },
    .{ .lexeme = "quest", .kind = .kw_quest },
    .{ .lexeme = "dialogue", .kind = .kw_dialogue },
    .{ .lexeme = "ability", .kind = .kw_ability },
    .{ .lexeme = "branch", .kind = .kw_branch },
    .{ .lexeme = "sequence", .kind = .kw_sequence },
    .{ .lexeme = "after", .kind = .kw_after },
    .{ .lexeme = "theme", .kind = .kw_theme },
    .{ .lexeme = "motion", .kind = .kw_motion },
    .{ .lexeme = "input_mapping", .kind = .kw_input_mapping },
    .{ .lexeme = "widget", .kind = .kw_widget },
    .{ .lexeme = "locale", .kind = .kw_locale },
    .{ .lexeme = "effect", .kind = .kw_effect },
    .{ .lexeme = "audio_graph", .kind = .kw_audio_graph },
    .{ .lexeme = "audio_score", .kind = .kw_audio_score },
    .{ .lexeme = "anim_graph", .kind = .kw_anim_graph },
    .{ .lexeme = "shader", .kind = .kw_shader },
    .{ .lexeme = "scene", .kind = .kw_scene },
    .{ .lexeme = "prefab", .kind = .kw_prefab },
    .{ .lexeme = "import", .kind = .kw_import },
    .{ .lexeme = "const", .kind = .kw_const },
    .{ .lexeme = "private", .kind = .kw_private },
    .{ .lexeme = "test", .kind = .kw_test },
    .{ .lexeme = "spawn", .kind = .kw_spawn },
    .{ .lexeme = "race", .kind = .kw_race },
    .{ .lexeme = "sync", .kind = .kw_sync },
    .{ .lexeme = "every", .kind = .kw_every },
    .{ .lexeme = "after_unscaled", .kind = .kw_after_unscaled },
    .{ .lexeme = "measure", .kind = .kw_measure },
    .{ .lexeme = "service", .kind = .kw_service },
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

/// Etch keywords that introduce **constructs the parser does not accept**.
/// Any identifier that
/// matches one of these is lexed as `error_unknown_keyword` so the parser
/// emits `E0001 UnsupportedConstructInS3` at use site.
///
/// Type names (`string`, `Entity`, `Vec3`, ...) are deliberately omitted
/// — they reach the type-checker as plain identifiers or `TYPE_IDENT`s
/// and surface as `E0102 UndefinedSymbol` (or POD-specific messages on
/// component fields). Sub-construct keywords (`segment`, `state`, `layer`,
/// `bind`, ...) are also omitted: they are unreachable in legal input
/// since their parent construct is already rejected, and including them
/// would collide with legitimate identifier names like `state`, `event`,
/// `priority`.
pub const non_s3_keywords = [_][]const u8{
    // `override` waits for a Tier-1 overridable module
    // (cf. `engine-phase-1-plan.md`).
    "override",

    // `quantize` waits for its musical beat/bar clock (Sequencer / Pulse),
    // which the runtime does not carry.
    "quantize",

    // `where`, `self`, `none`, `some` are intentionally NOT listed — they appear
    // in legitimate identifier-shaped positions in annotation args (e.g.
    // `@pause_group(.none)`). The parser accepts them as plain identifiers; their
    // grammar-level uses (generic bound, impl self param, Optional construction)
    // only show up in constructs rejected at the top level.
};

test "non_s3_keywords does not collide with s3_keywords" {
    inline for (s3_keywords) |s3_kw| {
        for (non_s3_keywords) |non| {
            // Each Etch keyword may appear in exactly one of the two tables.
            try std.testing.expect(!std.mem.eql(u8, s3_kw.lexeme, non));
        }
    }
}

test "const/private/test graduate to s3 keywords" {
    // `const` / `private` / `test` are IN `s3_keywords`, each mapped to its own
    // `kw_*` kind. `override` is the last member left reserved, so it still
    // lexes as `error_unknown_keyword`.
    const T = struct {
        fn s3Kind(lexeme: []const u8) ?TokenKind {
            for (s3_keywords) |kw| {
                if (std.mem.eql(u8, kw.lexeme, lexeme)) return kw.kind;
            }
            return null;
        }
        fn reserved(lexeme: []const u8) bool {
            for (non_s3_keywords) |kw| {
                if (std.mem.eql(u8, kw, lexeme)) return true;
            }
            return false;
        }
    };
    try std.testing.expectEqual(TokenKind.kw_const, T.s3Kind("const").?);
    try std.testing.expectEqual(TokenKind.kw_private, T.s3Kind("private").?);
    try std.testing.expectEqual(TokenKind.kw_test, T.s3Kind("test").?);
    // The three are no longer in the reserve list.
    try std.testing.expect(!T.reserved("const"));
    try std.testing.expect(!T.reserved("private"));
    try std.testing.expect(!T.reserved("test"));
    // `override` stays reserved (still lexes to error_unknown_keyword).
    try std.testing.expect(T.s3Kind("override") == null);
    try std.testing.expect(T.reserved("override"));
    // Graduated keywords sit inside the contiguous keyword range so
    // `isKeywordToken` covers them (tag-path contextual acceptance).
    try std.testing.expect(isKeywordToken(.kw_const));
    try std.testing.expect(isKeywordToken(.kw_private));
    try std.testing.expect(isKeywordToken(.kw_test));
}

test "spawn graduates to s3 keyword (M1.0.10)" {
    // `spawn` is IN `s3_keywords`, mapped
    // to `kw_spawn`, so the structural `spawn(C{…})` expr lexes to a real
    // keyword so the parser can dispatch it. (The async `spawn { }` task form
    // shares the keyword — next-token disambiguation.)
    const T = struct {
        fn s3Kind(lexeme: []const u8) ?TokenKind {
            for (s3_keywords) |kw| {
                if (std.mem.eql(u8, kw.lexeme, lexeme)) return kw.kind;
            }
            return null;
        }
        fn reserved(lexeme: []const u8) bool {
            for (non_s3_keywords) |kw| {
                if (std.mem.eql(u8, kw, lexeme)) return true;
            }
            return false;
        }
    };
    try std.testing.expectEqual(TokenKind.kw_spawn, T.s3Kind("spawn").?);
    try std.testing.expect(!T.reserved("spawn"));
    // `kw_spawn` sits inside the contiguous keyword range (tag-path contextual
    // acceptance via `isKeywordToken`).
    try std.testing.expect(isKeywordToken(.kw_spawn));
}

test "race/sync graduate to s3 keywords (M1.0.12 E2)" {
    // `race` / `sync` are IN `s3_keywords`,
    // mapped to `kw_race` / `kw_sync` — the concurrency-algebra statements
    // (§4.2) become parseable. `override` remains the last reserved top-level
    // construct keyword (waits for a Tier-1 overridable module).
    const T = struct {
        fn s3Kind(lexeme: []const u8) ?TokenKind {
            for (s3_keywords) |kw| {
                if (std.mem.eql(u8, kw.lexeme, lexeme)) return kw.kind;
            }
            return null;
        }
        fn reserved(lexeme: []const u8) bool {
            for (non_s3_keywords) |kw| {
                if (std.mem.eql(u8, kw, lexeme)) return true;
            }
            return false;
        }
    };
    try std.testing.expectEqual(TokenKind.kw_race, T.s3Kind("race").?);
    try std.testing.expectEqual(TokenKind.kw_sync, T.s3Kind("sync").?);
    try std.testing.expect(!T.reserved("race"));
    try std.testing.expect(!T.reserved("sync"));
    // `override` stays reserved.
    try std.testing.expect(T.reserved("override"));
    // Graduated keywords sit inside the contiguous keyword range (tag-path
    // contextual acceptance via `isKeywordToken`).
    try std.testing.expect(isKeywordToken(.kw_race));
    try std.testing.expect(isKeywordToken(.kw_sync));
}

test "every/after_unscaled graduate to s3 keywords (M1.0.13 E1)" {
    // `every` / `after_unscaled` are IN
    // `s3_keywords`, mapped to `kw_every` / `kw_after_unscaled` — the §4.3
    // timer statements become parseable (`after` has been a real keyword
    // for longer). `quantize` stays reserved: its
    // musical clock is absent from the runtime.
    const T = struct {
        fn s3Kind(lexeme: []const u8) ?TokenKind {
            for (s3_keywords) |kw| {
                if (std.mem.eql(u8, kw.lexeme, lexeme)) return kw.kind;
            }
            return null;
        }
        fn reserved(lexeme: []const u8) bool {
            for (non_s3_keywords) |kw| {
                if (std.mem.eql(u8, kw, lexeme)) return true;
            }
            return false;
        }
    };
    try std.testing.expectEqual(TokenKind.kw_every, T.s3Kind("every").?);
    try std.testing.expectEqual(TokenKind.kw_after_unscaled, T.s3Kind("after_unscaled").?);
    try std.testing.expect(!T.reserved("every"));
    try std.testing.expect(!T.reserved("after_unscaled"));
    // `quantize` stays reserved (still lexes to error_unknown_keyword);
    // `override` stays the last reserved top-level construct keyword.
    try std.testing.expect(T.s3Kind("quantize") == null);
    try std.testing.expect(T.reserved("quantize"));
    try std.testing.expect(T.reserved("override"));
    // Graduated keywords sit inside the contiguous keyword range (tag-path
    // contextual acceptance via `isKeywordToken`).
    try std.testing.expect(isKeywordToken(.kw_every));
    try std.testing.expect(isKeywordToken(.kw_after_unscaled));
}
