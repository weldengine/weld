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
    time_literal, // DD:DD in-game time (M0.8 E4 routine triggers, §1.4)
    duration_literal, // FLOAT "s" duration (M0.8 E4 gate fix, §1.4 — greedy-contiguous)
    color_literal, // "#" + 6 or 8 hex (M0.8 E5, §1.4 l.211 — the DURATION_LIT-precedent literal lift)
    multiline_string_literal, // triple-quote `"""…"""` (M0.9 E2-A, §1.4 — newline-spanning, DURATION/COLOR greedy-lift precedent; common indent stripped at parse)

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
    kw_await, // await <target> (M0.8 E3 sub-slice B; interp-only, codegen Phase 2)
    kw_struct, // struct declaration (M0.8 E2 block 3 declaration layer)
    kw_impl, // impl block (M0.8 E2 block 3 declaration layer)
    kw_enum, // enum declaration (M0.8 E2 block 3 tranche B)
    kw_trait, // trait declaration (M0.8 E2 block 3 tranche C)
    kw_event, // event declaration (M0.8 E3 ECS layer)
    kw_emit, // emit statement (M0.8 E3 ECS layer)
    kw_tags, // tags hierarchical declaration (M0.8 E3 ECS layer)
    kw_has_tag, // tag query operator (M0.8 E3 ECS layer)
    kw_has_no_tag, // tag query operator (M0.8 E3 ECS layer)
    kw_has_any_tag, // tag query operator (M0.8 E3 ECS layer)
    kw_has_all_tags, // tag query operator (M0.8 E3 ECS layer)
    kw_has_no_tags, // tag query operator (M0.8 E3 ECS layer)
    kw_add_tag, // tag mutation (M0.8 E3 ECS layer — deferred structural change)
    kw_remove_tag, // tag mutation (M0.8 E3 ECS layer — deferred structural change)
    kw_data, // data table declaration (M0.8 E4 Level B gameplay)
    kw_routine, // routine declaration (M0.8 E4 Level B gameplay)
    kw_behavior, // behavior tree declaration (M0.8 E4 Level B gameplay)
    kw_quest, // quest declaration (M0.8 E4 Level B gameplay)
    kw_dialogue, // dialogue declaration (M0.8 E4 Level B gameplay)
    kw_ability, // ability declaration (M0.8 E4 Level B gameplay)
    kw_branch, // quest/dialogue branch (M0.8 E4; the async T2/T3 `branch` statement stays out of M0.8 — explicit parse error)
    kw_sequence, // behavior composite type (M0.8 E4) + the E6 top-level `sequence` cinematic construct (matched by token kind in parseTopLevel — the input_combo precedent)
    kw_after, // routine trigger `after Segment` (M0.8 E4; the §4.3 timer statement stays out of M0.8 — explicit parse error)
    kw_theme, // theme declaration (M0.8 E5 Level B presentation)
    kw_motion, // motion declaration (M0.8 E5 Level B presentation — state-based UI animation)
    kw_input_mapping, // input_mapping declaration (M0.8 E5 Level B presentation — STRICT, no execution)
    kw_widget, // widget declaration (M0.8 E5 Level B presentation — recursive UI tree)
    kw_locale, // locale declaration (M0.8 E5 Level B presentation — translation table)
    kw_effect, // effect declaration (M0.8 E6 Level B VFX — emitters + event handlers, VFX-only since v0.6)
    kw_audio_graph, // audio_graph declaration (M0.8 E6 Level B audio — DSP node graph, mandatory output sink)
    kw_audio_score, // audio_score declaration (M0.8 E6 Level B audio — adaptive music, STRING-named, sections + stems)
    kw_anim_graph, // anim_graph declaration (M0.8 E6 Level B animation — skeletal state machine, states + layers)
    kw_shader, // shader declaration (M0.8 E6 Level B render — vertex/fragment stages, shader-mode body validation)
    kw_scene, // scene declaration (M0.8 E7 Level C — STRING-named scene graph, entity/instance decls)
    kw_prefab, // prefab declaration (M0.8 E7 Level C — STRING-named, of/extends relation, requires + on_attach/on_detach hooks)
    kw_import, // import directive (M1.0.7 cross-file import — module path + optional alias / selective items; graduated from non_s3_keywords)
    kw_const, // top-level `const` declaration (M1.0.8 — graduated from non_s3_keywords; top-level only per part1 §4.5)
    kw_private, // `private` visibility modifier prefix on a declaration_body (M1.0.8 — graduated from non_s3_keywords; grammar §5.1)
    kw_test, // top-level `test "name" { ... }` block (M1.0.8 — graduated from non_s3_keywords; parse + validate only, no execution)
    kw_spawn, // structural spawn expr `spawn(C{…})` (M1.0.10, §3.2 structural_spawn) + the async task statement `[let IDENT =] spawn { }` (M1.0.12, §4.2 spawn_stmt) — disambiguated by the next token
    kw_race, // race statement `race { race_branch* }` (M1.0.12 — graduated from non_s3_keywords; §4.2 race_stmt)
    kw_sync, // sync statement `sync { sync_branch* }` (M1.0.12 — graduated from non_s3_keywords; §4.2 sync_stmt)

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
    question, // ? — optional type suffix `T?` (M0.8 E2 block 5)
    question_dot, // ?. — optional chain (M0.8 E3-C tranche 4, part1 §6.6)
    question_question, // ?? — null coalesce (M0.8 E3-C tranche 4, part1 §6.6)
    bang, // ! postfix — force unwrap (M0.8 E3-C tranche 4, part1 §6.6)

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
/// CONTEXTUALLY (M0.8 E4): graduating a construct keyword (`quest`,
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
    //    call mechanism; `struct` / `impl` / `enum` / `trait` with E2 block 3;
    //    `event` + `tags` with E3 ECS layer; `data` with E4 Level B gameplay;
    //    `scene` + `prefab` graduated with E7 Level C — the last two construct
    //    keywords of the v0.6 grammar; `import` graduated with M1.0.7 cross-file
    //    import; `const` / `private` / `test` graduated with M1.0.8 — they now
    //    lex as `kw_const` / `kw_private` / `kw_test` via `s3_keywords`.
    //    `override` is the last reserved member: it waits for a Tier-1
    //    overridable module (cf. `engine-phase-1-plan.md`) ──
    "override",

    // ── Async machinery: fully graduated. `async` with M0.8 E2, `await` with
    //    M0.8 E3 sub-slice B, `spawn` with M1.0.10 (structural expr) then
    //    M1.0.12 (async task statement — disambiguated by the next token),
    //    `branch` with the M0.8 E4 quest slice (async statement form M1.0.12),
    //    `race` / `sync` with M1.0.12 (concurrency algebra, §4.2) ──

    // ── Timers / lifecycle (out of S3; `emit` graduated with E3 ECS layer;
    //    `after` graduated with E4 routine triggers — the §4.3 timer
    //    statement keeps an explicit fail-loud parse error) ──
    "every",
    "after_unscaled",
    "quantize",

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

test "const/private/test graduate to s3 keywords" {
    // M1.0.8: `const` / `private` / `test` move from the reserve list into
    // `s3_keywords`, each mapped to its own `kw_*` kind. `override` is the last
    // member left reserved, so it still lexes as `error_unknown_keyword`.
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
    // M1.0.10: `spawn` moves from the reserve list into `s3_keywords`, mapped
    // to `kw_spawn`. The structural `spawn(C{…})` expr now lexes to a real
    // keyword so the parser can dispatch it. (The async `spawn { }` task form
    // shares the keyword since M1.0.12 — next-token disambiguation.)
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
    // M1.0.12: `race` / `sync` move from the reserve list into `s3_keywords`,
    // mapped to `kw_race` / `kw_sync` — the concurrency-algebra statements
    // (§4.2) become parseable. `override` remains the last reserved top-level
    // construct keyword (waits for a Tier-1 overridable module); the timer
    // family (`every` / `after_unscaled` / `quantize`) waits for M1.0.13.
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
    // `override` stays reserved; the timers stay reserved until M1.0.13.
    try std.testing.expect(T.reserved("override"));
    try std.testing.expect(T.reserved("every"));
    try std.testing.expect(T.reserved("after_unscaled"));
    try std.testing.expect(T.reserved("quantize"));
    // Graduated keywords sit inside the contiguous keyword range (tag-path
    // contextual acceptance via `isKeywordToken`).
    try std.testing.expect(isKeywordToken(.kw_race));
    try std.testing.expect(isKeywordToken(.kw_sync));
}
