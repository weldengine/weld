# S3 — Etch parser on subset

> **Status :** ACTIVE
> **Phase :** −1
> **Branche :** `phase--1/etch/parser-subset`
> **Tag prévu :** `v0.0.4-S3-etch-parser-subset`
> **Dépendances :** S0 (bootstrap), S1 (mini-ECS), S2 (window + Vulkan triangle)
> **Date d'ouverture :** 2026-05-15
> **Date de fermeture :** —

---

# SECTION FIGÉE

*Produite par Claude.ai. Non modifiable par Claude Code hors aller-retour Claude.ai (cf. § Déviations actées).*

## Context

S3 is the fourth de-risking spike of Phase −1. It validates the hypothesis that the Etch grammar (EBNF v0.6, `etch-grammar.md`) is implementable without ambiguity and that parsing is fast enough for the target use cases. This milestone delivers the first concrete piece of the Etch compiler frontend — lexer, recursive-descent + Pratt parser, tabular SoA AST (`AstArena`), and a minimal type-checker covering five constructs (`component`, `resource`, `rule`, `when` clauses, basic arithmetic expressions). The public surface in `src/etch/root.zig` is designed to survive Phase 0.2 with additive changes only; no refactor of API shape is expected at the next milestone boundary.

## Scope

Five constructs only. Every position below tracks a decision taken in the conversation that produced this brief.

- **Lexer** producing tokens for the S3 subset: `IDENT`, `TYPE_IDENT`, `INT_LITERAL`, `FLOAT_LITERAL`, `BOOL_LITERAL`, `STRING_LITERAL` (simple-quote only, no interpolation), keywords (subset below), operators (subset below), punctuation, `EOF`. Comments (`//`, `/* */`, `///`) are skipped at the lexer level. Comment spans are collected in a parallel `comment_spans: ArrayList(SourceSpan)` for future Phase 0.2 trivia attachment. UTF-8 byte-stream validation; identifiers and keywords are ASCII-only per `etch-grammar.md` §1.2; string literals accept arbitrary UTF-8 verbatim. Invalid UTF-8 emits `E0001`.

- **Keywords recognized**: `let`, `mut`, `component`, `resource`, `rule`, `when`, `and`, `or`, `not`, `has`, `changed`, `get`, `get_mut`, `true`, `false`, plus primitive type keywords `int`, `float`, `bool`, `i32`, `u32`, `f32`, `f64`. Engine-type names usable in field/param types: `Entity`, `Vec3`, `Color`, `Duration` (treated as `TYPE_IDENT` at the lexer level, resolved against a hard-coded builtin set at the type-checker). Any other Etch keyword listed in `etch-grammar.md` §1.3 is lexed as an unknown keyword token and produces a parse error at use site (`E0001 UnsupportedConstructInS3`).

- **Operators / punctuation recognized**: `+`, `-`, `*`, `/`, `%`, `=`, `+=`, `-=`, `*=`, `/=`, `%=`, `==`, `!=`, `<`, `>`, `<=`, `>=`, `(`, `)`, `{`, `}`, `:`, `,`, `.`, `@`. Statement separation by newline (Etch uses newline-terminated statements by convention; no required semicolon). No bitwise, no shift, no range, no `as`, no `??`, no `?.`, no `!` postfix.

- **Parser** — recursive descent for top-level declarations, `when` clauses, rule bodies, statements. Pratt parsing for binary expressions using the precedence table from `etch-grammar.md` §3.1 restricted to the S3 operator set, all left-associative. Produces `AstArena` directly (no intermediate CST). Stop-on-first parse error: at most one parse diagnostic per file, AST contains a best-effort partial result so subsequent type-checking can run on declarations parsed before the error.

- **AST — tabular SoA `AstArena`** per `etch-ast-ir.md` §3.2:
  - `MultiArrayList(Item)`, `MultiArrayList(Stmt)`, `MultiArrayList(Expr)`, `MultiArrayList(TypeNode)`. No `MultiArrayList(Pattern)` (no `match` in S3).
  - `NodeId = packed struct(u32) { category: u4, index: u28 }`.
  - `StringPool` (interning of identifier names and string literal contents).
  - `extra: ArrayList(u32)` for variable-length child lists.
  - `spans: ArrayList(SourceSpan)` indexed by `NodeId`; `SourceSpan = { byte_start: u32, byte_end: u32 }`. Conversion to `(line, column)` is on-demand via a `LineIndex` precomputed once per source from the byte stream.
  - `AnnotationMap: AutoHashMapUnmanaged(NodeId, AnnotationSpan)` + `annot_pool: ArrayList(Annotation)` — syntactic storage only.
  - `comment_spans: ArrayList(SourceSpan)` parallel slab (not attached to NodeIds in S3, kept for Phase 0.2 trivia attachment).
  - `ItemKind`, `StmtKind`, `ExprKind`, `TypeNodeKind` enums declare **all** EBNF v0.6 variants (forward-compatibility / API stability), but only those covered by S3 are produced by the parser. Call sites switching on these enums in S3 must use `else => @panic("unsupported in S3")` for unreached variants rather than partial coverage that compiles cleanly.
  - **No `StableId`** in S3. `StableId` is injected by the editor via `@id("uuid")` per `etch-ast-ir.md` §3.3. S3 has no editor; the parser leaves `stable_id = 0` (documented as absent).
  - **No `TriviaMap`** in S3 (deferred to Phase 0.2 with the pretty-printer).
  - **No `doc_comments` map** in S3: `///` is lexed as a regular comment and skipped. Reactivated Phase 0.2.

- **Top-level item parsing**: only `component_decl`, `resource_decl`, `rule_decl`. Any other top-level construct token (`fn`, `struct`, `enum`, `trait`, `impl`, `event`, `tags`, `behavior`, `import`, …) emits `E0001 UnsupportedConstructInS3` at the keyword site.

- **`when` clause parsing**: `entity has T`, `entity has T { field == value }`, `resource T`, `resource T changed`, composition via `and`, `or`, `not` with the precedence specified in `etch-grammar.md` §6. No `has_tag` and no other tag operators.

- **Rule body**: flat scope, no nested blocks in S3. Allowed statements:
  - `let x = expr`
  - `let x: T = expr`
  - `let mut x = expr`
  - `let mut x: T = expr`
  - `x = expr` and compound assignments `+= -= *= /= %=`
  - Expression statement (call expression for side effects only; an assignment target written `entity.get_mut(T).field = expr` is reached via assignment + field access)
  - No `if`, `match`, `for`, `while`, `loop`, `break`, `continue`, `return`, closures, nested blocks.

- **Expressions**:
  - Literals: `INT_LITERAL`, `FLOAT_LITERAL`, `BOOL_LITERAL`, `STRING_LITERAL` simple-quote without interpolation.
  - Identifiers and field access: `ident`, `expr.field`.
  - Restricted method call: `entity.get(T)` and `entity.get_mut(T)`. Recognized syntactically as a postfix call with a single `TYPE_IDENT` argument; the type-checker dispatches these specially (no general trait/method lookup in S3).
  - Binary: `+`, `-`, `*`, `/`, `%`, `==`, `!=`, `<`, `>`, `<=`, `>=`, `and`, `or`.
  - Unary: `-` (negation), `not`.
  - Parenthesized: `(expr)`.

- **Annotation parsing**: `@name`, `@name(arg1, arg2, ...)`, `@name(name: value)`. Stored in `AnnotationMap` keyed by the annotated node. `Annotation.kind` is resolved against the builtin `AnnotationKind` enum (declaring at minimum `@phase`, `@priority`, `@run_on`, `@pause_group`, `@config`, `@state`, `@transient`, `@save`, `@unit`, `@range`, `@hidden`, `@readonly`, `@requires`, `@storage`, `@replicated`, `@networked`, `@id`, `@loc` — full list per `etch-resolver-types.md` §13.2 and `etch-reference-part3.md` Part III); unknown names fall into `.custom` without erroring in S3 (applicability deferred Phase 0.2).

- **Default values for component/resource fields**: parsed as expressions. Restricted in the type-checker to S3-const-evaluable expressions (literals + arithmetic on literals + parenthesized). No `ConstValue` injection into the AST in S3 (deferred Phase 1).

- **Type-checker — pass 1 (collect)**:
  - Walk all top-level items in the file.
  - Register every `ComponentDecl`, `ResourceDecl`, `RuleDecl` in a file-local `SymbolTable`. Duplicates emit `E0101 DuplicateSymbol`.
  - Builtin types table covers exactly: `int`, `float`, `bool`, `i32`, `u32`, `f32`, `f64`, `Entity`, `Vec3`, `Color`, `Duration`. Any other primitive or engine type from EBNF v0.6 is treated as unknown for S3.
  - Field types resolve to a builtin or to a `TYPE_IDENT` registered in pass 1 from the same file. Unresolved name emits `E0102 UndefinedSymbol`.
  - Field name uniqueness within parent: emits `E0101`-class diagnostic at the duplicated field.
  - POD enforcement S3: every component / resource field type must be in the S3 builtin set. `string` is rejected on components (consistent with `etch-grammar.md` §5.4 POD restriction).

- **Type-checker — pass 2 (resolve / check)**:
  - For every `RuleDecl`, validate the `when` clause per `etch-resolver-types.md` §12.2:
    - `has T` → `T` registered as component → else `E1210 UnknownComponentInWhen`.
    - `has T { field == value }` → `field` exists in `T` and `value` type matches the field type → else `E1211 InvalidFieldFilter`.
    - `resource T` / `resource T changed` → `T` registered as resource → else `E1213 ResourceExpectedInWhen`.
  - Rule param types resolve to known types.
  - Rule body local scope:
    - `let x [: T] = expr` introduces `x` with the explicit type (if present) or inferred from `expr`.
    - `let mut x [: T] = expr` same plus marks `x` mutable.
    - `x = expr` requires either `x` declared `mut` in scope, or the assignment target is a field reached through `entity.get_mut(T)`.
    - `entity.get(T)` and `entity.get_mut(T)` require `T` to appear in the rule's `when` clause (S3 simplification — full ECS access tracking deferred Phase 1).
  - Expression typing (synthesis only, no bidirectional checking in S3):
    - Arithmetic: `int op int → int`, `float op float → float`. No implicit numeric coercion. Mismatch emits `E0200 TypeMismatch`.
    - Comparison: `T op T → bool` for compatible primitive `T`.
    - Logical: `bool and/or bool → bool`, `not bool → bool`.
    - Unary `-`: `int → int`, `float → float`.
    - Field access type lookup against the field's declared type in its parent component / resource.
  - Component / resource field default values are checked as S3-const-evaluable and the default's type is checked against the field type. Non-const default emits `E1101 NotConstEvaluable`; wrong type emits `E0200 TypeMismatch`.
  - Annotation applicability validation: **deferred Phase 0.2** (parsed but not validated).

- **Diagnostics — typed API**:
  - `Diagnostic` carries `code: DiagnosticCode` (enum with stable names), `severity` (`error_`, `warning`), `primary_span: SourceSpan` plus computed `(line, column)` on demand from a `LineIndex`, `primary_message: []const u8`.
  - Codes emitted in S3, all with names stable cross-version: `E0001 ParseError` (parse range, sub-distinguished by `primary_message`), `E0101 DuplicateSymbol`, `E0102 UndefinedSymbol`, `E0200 TypeMismatch`, `E1101 NotConstEvaluable`, `E1210 UnknownComponentInWhen`, `E1211 InvalidFieldFilter`, `E1213 ResourceExpectedInWhen`.
  - No fix-its in S3 (deferred Phase 2+).

- **Public surface — `src/etch/root.zig`** (must survive Phase 0.2 with additive changes only):
  - Types exported: `Lexer`, `Token`, `Parser`, `Ast`, `NodeId`, `TypeChecker`, `Diagnostic`, `DiagnosticCode`, `SourceSpan`, `ParseResult`.
  - High-level helpers: `parse(gpa, source) !ParseResult` (returns `ast` and `?Diagnostic` for at most one parse diagnostic), `typeCheck(gpa, ast, diags_out: *std.ArrayListUnmanaged(Diagnostic)) !void`.
  - No public type exposes parser internal state, allocator-stored fields, or pointers into the arena.

- **Test corpus** in `tests/etch/corpus/`:
  - `valid/components/*.etch`: approximately 15 files.
  - `valid/resources/*.etch`: approximately 10 files.
  - `valid/rules/*.etch`: approximately 20 files.
  - `valid/whens/*.etch`: approximately 15 files.
  - `valid/exprs/*.etch`: approximately 10 files.
  - `invalid/<CODE>_<slug>.etch`: approximately 30 files, one per emitted diagnostic code with `<CODE>` in the filename (e.g. `E0101_duplicate_component.etch`, `E1210_unknown_component_in_when.etch`).
  - Each file is 50–150 LOC.
  - Driver `tests/etch/corpus_test.zig` enumerates the corpus and asserts: valid files produce zero diagnostics; invalid files produce **at least** the expected diagnostic code (additional diagnostics tolerated to avoid coupling tests to internal accumulation order).

- **Benchmark** `bench/etch_parse.zig`:
  - Iterates the valid corpus, measures lexer-only, parser-only, type-checker-only, and total time per file at N=1000 iterations, `ReleaseSafe` build mode.
  - Computes median / p99 / max per file and per LOC bucket (small `<50 LOC`, medium `50–150`, large `150–300`).
  - Emits an ASCII Markdown report under `bench/results/s3-etch-parse-<YYYYMMDD-HHMM>.md` with machine info (hostname, CPU model, OS, Zig version, build mode), per-bucket table, and an explicit verdict line on the `< 5 ms median per file` target.

- **Build integration**:
  - New `weld_etch` Zig module exposed via `src/etch/root.zig`, declared in `build.zig`.
  - New step `zig build bench-etch` invokes the bench binary (analogous to `zig build bench-ecs` from S1).
  - `zig build test` includes `tests/etch/corpus_test.zig` and same-file `test` blocks in `src/etch/*.zig`.

## Out-of-scope

- All other top-level constructs (26 of the 29 in EBNF v0.6): `fn`, `struct`, `enum`, `trait`, `impl`, `event`, `tags`, `import`, `const`, `type` alias, `private`, `behavior`, `routine`, `quest`, `dialogue`, `ability`, `effect`, `shader`, `widget`, `theme`, `motion`, `anim_graph`, `audio_graph`, `audio_score`, `sequence`, `data`, `scene`, `prefab`, `input_mapping`, `locale`, `test`, `override`.
- Control flow in rule bodies: `if`, `match`, `for`, `while`, `loop`, `break`, `continue`, `return`. Nested blocks of any kind.
- Async machinery: `async`, `await`, `race`, `sync`, `branch`, `spawn`.
- Error handling: `try`, `catch`, `throws`, `throw`, `assert`.
- Tag operators: `has_tag`, `has_no_tag`, `has_any_tag`, `has_all_tags`, `has_no_tags`, `add_tag`, `remove_tag`. Tag path literals `.foo.bar`.
- Bitwise operators (`&`, `|`, `^`, `<<`, `>>`, `~`), range operators (`..`, `..=`), null coalesce (`??`, `?.`), force-unwrap postfix `!`, cast `as`.
- Closures `|args| expr`. Generics `<T>`. Tuple types and tuple literals. Struct literals `X { ... }` and anonymous `.{ ... }`. Array literals, map literals.
- Triple-quote strings, string interpolation `{expr}`.
- Timers (`after`, `every`, `after_unscaled`, `quantize`).
- Cross-module resolution. `import` parsing.
- Trivia preservation (comment / blank-line round-trip). `TriviaMap`. Pretty-printer.
- Doc comments (`///`) — lexed as regular comments and skipped.
- `StableId` generation.
- Annotation applicability validation (parsed but unvalidated in S3).
- Bidirectional type checking. Const-value injection into the AST.
- Reverse direction AST → text.
- Generic monomorphisation. Pattern exhaustivity. Override merge.
- Resolver pass 1/2 for full Etch (S3 implements pass 1/2 only for the five constructs).
- tree-sitter integration.
- Parse error recovery (stop-on-first only).
- Fix-its in diagnostics.
- Language server, hover info, autocomplete, go-to-definition, find-references.
- Bench in CI (verdict given on the reference physical machine, consistent with S2).
- Touching any of the S2 residual debts (D1 `vk_gen` whitelist closure on enum types only, D2 `VkResult` aliases at module scope, Win32 thread safety globals, §4.2 dispatch bypass in `vk_frame.zig`, PPM capture path swapchain image direct). These remain explicitly tracked in `briefs/S2-window-vulkan-triangle.md` and will be addressed in C0.10 (Bindgen unifié) or Phase 0.4 (GAL).

## Documents de spec à lire en premier

1. `engine-spec.md` — §22.3 sub-section S3 (canonical definition), §3.5 (in-tree Phase 1-4), §22 Couche 2 (parsing layer context).
2. `etch-grammar.md` — entire file, with special attention to §1 lexique, §3 expressions and precedence, §5.4 component_decl, §5.5 resource_decl, §6 when clauses, §7 rule_decl, §19 ambiguities resolved.
3. `etch-reference-part1.md` — §2 lexique, §3 type system primitives and engine builtins, §6 expressions and operator precedence.
4. `etch-ast-ir.md` — §1 pipeline overview, §3 entire (AST tabular layout, NodeId/StableId, kinds catalog, annotations, doc comments), §10 invariants.
5. `etch-resolver-types.md` — §1 overview, §11 const evaluation, §12 ECS rule validations, §13 annotations applicability schemas, §17 diagnostics structure, §19 phasing.
6. `etch-diagnostics.md` — §1 convention de codes, §2 ranges, sections covering E01XX-E02XX, E1100-E1199, E1200-E1299.
7. `etch-reference-part3.md` — Part III §1-§6 (annotations builtin: lifecycle, networking, scheduling, Inspector, serialization, ECS). Needed to dimension the `AnnotationKind` enum even though applicability is unvalidated in S3.
8. `etch-visual-scripting.md` — "Pipeline de compilation" section only, to confirm S3 produces `AstArena` directly without CST.
9. `engine-zig-conventions.md` — §3 (allocators, unmanaged-first), §4 (collections, MultiArrayList), §13 (tests).
10. `engine-development-workflow.md` — §2 milestone granularity, §3 brief format, §4 git conventions.
11. `engine-directory-structure.md` — §9.1 repo arborescence (locate `src/etch/`, `tests/etch/`, `bench/`), §9.3 in-tree policy.

## Fichiers à créer ou modifier

(Paths concrets. Anything outside this list must not be touched without a justified entry in « Déviations actées ».)

- `src/etch/root.zig` — création — module entrypoint, public surface (`parse`, `typeCheck`, exported types)
- `src/etch/token.zig` — création — `Token`, `TokenKind` enum (S3 subset of keywords/operators), `SourceSpan`
- `src/etch/lexer.zig` — création — UTF-8 stream lexer, comment-span collection, error tokens with byte spans
- `src/etch/ast.zig` — création — `AstArena`, `NodeId`, `ItemKind`, `StmtKind`, `ExprKind`, `TypeNodeKind`, `StringPool`, `LineIndex`, `AnnotationMap`, `Annotation`, typed accessors
- `src/etch/parser.zig` — création — recursive descent + Pratt expression parser, error path returns `ParseResult { ast, diagnostic }`
- `src/etch/types.zig` — création — pass-1 collector + pass-2 checker, scope management for rule bodies, hard-coded dispatch for `get` / `get_mut`
- `src/etch/diagnostics.zig` — création — `Diagnostic`, `DiagnosticCode` (S3 subset with stable names), severity enum, `(line, column)` computation from `LineIndex`
- `tests/etch/corpus_test.zig` — création — corpus driver (comptime enumeration of files, valid → zero diagnostics, invalid → expected code present)
- `tests/etch/corpus/valid/components/*.etch` — création — approximately 15 files
- `tests/etch/corpus/valid/resources/*.etch` — création — approximately 10 files
- `tests/etch/corpus/valid/rules/*.etch` — création — approximately 20 files
- `tests/etch/corpus/valid/whens/*.etch` — création — approximately 15 files
- `tests/etch/corpus/valid/exprs/*.etch` — création — approximately 10 files
- `tests/etch/corpus/invalid/*.etch` — création — approximately 30 files, one per emitted diagnostic code (filename pattern `<CODE>_<slug>.etch`)
- `bench/etch_parse.zig` — création — corpus-driven bench, ASCII Markdown report writer
- `bench/results/s3-etch-parse-<YYYYMMDD-HHMM>.md` — création — one report file generated by the first authoritative bench run, committed for traceability
- `build.zig` — édition — register `weld_etch` module, add `bench-etch` step, wire `tests/etch/corpus_test.zig` into `zig build test`
- `CLAUDE.md` — édition — update "État courant" (Phase −1 / S3 → CLOSED at merge), add row to "Tags" table (`v0.0.4-S3-etch-parser-subset`), flip hypothesis "EBNF v0.6 implémentable sans ambiguïté" status to VALIDATED if S3 succeeds, refresh "Date de dernière mise à jour"
- `README.md` — édition — update roadmap status (S2 ✓, S3 active → ✓ at merge), update current tag pointer (`v0.0.3-S2-window-vulkan-triangle` → `v0.0.4-S3-etch-parser-subset`), append `zig build bench-etch` to the build instructions section

## Critères d'acceptation

### Tests

Same-file `test` blocks in `src/etch/*.zig` plus corpus-driven integration in `tests/etch/`. All tests must pass in `debug` and `ReleaseSafe`. Total expected: approximately 30 unit tests + the 100-file corpus driven by `tests/etch/corpus_test.zig`.

- `tests/etch/lexer.zig` (same-file in `src/etch/lexer.zig`) — `test "lexer tokenizes minimal component declaration"` — exact sequence of expected `TokenKind` values and spans
- `src/etch/lexer.zig` — `test "lexer skips line and block comments, records spans in comment_spans"` — comments absent from token stream, present in `comment_spans` with correct byte ranges
- `src/etch/lexer.zig` — `test "lexer rejects invalid UTF-8 with E0001"` — invalid continuation byte produces error token
- `src/etch/lexer.zig` — `test "lexer disambiguates integer vs float literal"` — `42`, `42.0`, `4.2`, `0.5` each yield the expected `TokenKind`
- `src/etch/lexer.zig` — `test "lexer rejects unknown keyword from full Etch with E0001 at use site"` — e.g. `fn`, `enum`, `behavior` at any position
- `src/etch/parser.zig` — `test "parser builds ComponentDecl with two annotated fields"` — node counts; field names and type identifiers reachable through accessors
- `src/etch/parser.zig` — `test "parser builds ResourceDecl with default value expression"` — default-value `NodeId` retrievable, expression structure verified
- `src/etch/parser.zig` — `test "parser builds RuleDecl with when clause composition (and / or / not)"` — `when` tree structure matches grammar §6
- `src/etch/parser.zig` — `test "parser handles binary expression precedence per grammar §3.1 subset"` — `a + b * c` parses as `a + (b * c)`; mixed `==`/`<`/`and` cases
- `src/etch/parser.zig` — `test "parser rejects unsupported top-level construct with E0001"` — `fn`, `enum`, `behavior` at top-level all flagged
- `src/etch/parser.zig` — `test "parser stops at first parse error and returns partial AST"` — diagnostic emitted, AST non-empty for decls preceding the error
- `src/etch/parser.zig` — `test "parser accepts top-level declarations in any order"` — rule referencing component declared after it parses without error
- `src/etch/parser.zig` — `test "parser captures annotation kind and args"` — `@phase(.update)`, `@range(0, 100)`, `@unit(.health_points)` reachable in `AnnotationMap`
- `src/etch/ast.zig` — `test "NodeId encodes category and index round-trip"` — packed struct invariants
- `src/etch/ast.zig` — `test "AstArena spans align with byte offsets in source"` — span retrieval matches lexer output
- `src/etch/ast.zig` — `test "LineIndex converts byte offset to (line, column) correctly"` — boundary cases (start of line, end of file, multibyte UTF-8 inside a string literal)
- `src/etch/ast.zig` — `test "StringPool interns identical identifiers to the same StringId"` — pool deduplication invariant
- `src/etch/types.zig` — `test "type-checker emits E0101 on duplicate component declaration"`
- `src/etch/types.zig` — `test "type-checker emits E0102 on field referencing unknown type"`
- `src/etch/types.zig` — `test "type-checker emits E0200 on arithmetic between int and float without cast"`
- `src/etch/types.zig` — `test "type-checker emits E1101 on non-const default value"` — default involving an identifier
- `src/etch/types.zig` — `test "type-checker emits E1210 on rule when clause referencing unknown component"`
- `src/etch/types.zig` — `test "type-checker emits E1211 on field filter type mismatch"` — `has Health { current == "foo" }`
- `src/etch/types.zig` — `test "type-checker emits E1213 on resource clause referencing unknown resource"`
- `src/etch/types.zig` — `test "type-checker rejects get/get_mut for components absent from when clause"` — `entity.get(NotInWhen)` flagged
- `src/etch/types.zig` — `test "type-checker rule body let mut allows reassignment, immutable let does not"`
- `src/etch/types.zig` — `test "type-checker accepts compound assignment += on numeric field via get_mut"`
- `src/etch/types.zig` — `test "type-checker rejects string field on component (POD enforcement)"`
- `src/etch/types.zig` — `test "type-checker accepts top-level declarations in any order via pass 1 / pass 2"` — forward reference from rule to component declared later
- `src/etch/diagnostics.zig` — `test "Diagnostic line/column computed correctly from byte span"` — multi-line source, span on line 3 column 7
- `tests/etch/corpus_test.zig` — `test "all valid corpus files parse and type-check with zero diagnostics"`
- `tests/etch/corpus_test.zig` — `test "every invalid corpus file emits the diagnostic code in its filename"` — filename `<CODE>_<slug>.etch` → expected code present in diagnostics

Additional same-file tests welcome at Claude Code's discretion to reach broader edge-case coverage.

### Benchmarks

Reference machine: same physical machine used for S2 verdict (Win11 + RTX 4080 Super or Fedora 44 + UHD 630 / GTX 1660 Ti, per `engine-phase-0-criteria.md`). Benchmark builds in `ReleaseSafe`.

- `bench/etch_parse.zig` — median total time (lexer + parser + type-checker) per file across the valid corpus — target: **< 5 ms median**, **< 15 ms p99**, **< 25 ms max** on any single file
- `bench/etch_parse.zig` — separate lexer / parser / type-checker contributions per phase (no individual target; informational)
- `bench/etch_parse.zig` — report written to `bench/results/s3-etch-parse-<YYYYMMDD-HHMM>.md` with machine info, Zig version, build mode, per-bucket table (`small <50 LOC`, `medium 50-150`, `large 150-300`), explicit verdict line GO / NO-GO against the median target

### Comportement observable

- `zig build bench-etch` runs the bench and writes the Markdown report to `bench/results/`. The verdict line at the bottom of the report states GO or NO-GO against the `< 5 ms median per file` target.
- `zig build test` runs the same-file unit tests and the corpus driver, both in `debug` and `ReleaseSafe`. Output shows zero failures.
- For each file in `tests/etch/corpus/valid/`, the `parse` public API returns a non-empty `AstArena` with zero diagnostics. Demonstrable via a one-liner shell loop or a tiny helper binary (Claude Code chooses the form; the artifact to confirm is the public API exercised on every file in the corpus).

### CI

- `zig build` clean, zero warning, on the configured matrix `{ubuntu-24.04, windows-2025} × {Debug, ReleaseSafe}`
- `zig build test` green (debug + ReleaseSafe), both runners
- `zig fmt --check` green
- `zig build lint` green (linter currently absent — no-op until C0.x milestone)
- `commit-msg` hook green on every commit of the branch (lefthook)
- `zig build bench-etch` not run in CI (consistent with S2 `--smoke-test` policy: bench verdict on physical reference machine only)

## Conventions

- **Branche** : `phase--1/etch/parser-subset`
- **Tag final** : `v0.0.4-S3-etch-parser-subset`
- **Titre de PR** : `Phase -1 / Etch / S3 parser on subset`
- **Convention de commits** : Conventional Commits, with scopes `etch` (for `src/etch/*`), `tests` (for `tests/etch/*`), `bench` (for `bench/*`), `build` (for `build.zig`), `docs` (for `CLAUDE.md`, `README.md`, the brief itself)
- **Stratégie de merge** : squash-and-merge (cf. `engine-development-workflow.md` §4.6)

## Notes

- S3 is purely a parser milestone. It does not touch GPU bindings, the platform layer, or any module from S0/S1/S2. The five S2 residual debts (D1 `vk_gen` whitelist closure on enum types only, D2 `VkResult` aliases at module scope, Win32 thread safety globals, §4.2 dispatch bypass in `vk_frame.zig`, PPM capture path swapchain image direct) are explicitly **out of S3 scope** and will be addressed in the dedicated Phase 0 milestone (C0.10 Bindgen unifié) or in Phase 0.4 GAL — see `engine-phase-0-criteria.md` § C0.10.

- **Two-pass type-checker is a deliberate architecture choice for S3**, not over-engineering. Etch allows top-level declarations in any order (`etch-reference-part1.md` §1.4), so a single linear pass would not resolve forward references to components declared later in the file. Implementing pass 1 (collect) and pass 2 (resolve) separately in S3 keeps the architecture aligned with `etch-resolver-types.md` §1 — the same shape scales to the full resolver in Phase 1 with additive checks only.

- **No `StableId` injection in S3** is intentional. Per `etch-ast-ir.md` §3.3, `StableId` is injected by the editor at construct creation via `@id("uuid")`. S3 ships no editor; the parser leaves `stable_id = 0`, documented as "absent — disables hot-reload and collaboration for the construct". Claude Code must not invent a `StableId` generation scheme; the editor owns that responsibility starting Phase 2.

- **Pratt parsing for binary expressions**: the precedence table from `etch-grammar.md` §3.1, restricted to the S3 operator set, drives a single `parseExpr(min_bp)` function. Avoids the chain of RD functions a literal EBNF transcription would produce, and matches what rustc / swift / zig themselves do for expression precedence. All S3 binary operators are left-associative.

- **AST `kind` enums declare all EBNF v0.6 variants, even those not produced in S3**, to keep the public API stable across phases. Phase 0.2 will populate additional variants. Call sites switching on these enums in S3 must use `else => @panic("unsupported in S3")` rather than partial switches that compile cleanly while leaving silent gaps.

- **Comment spans collected but not attached** to `NodeId` in S3. The `comment_spans: ArrayList(SourceSpan)` parallel slab is the seed for Phase 0.2's `TriviaMap`. Decision motivated by `etch-ast-ir.md` §3.6 — trivia preservation is the pretty-printer's job (Phase 0.2+), but throwing comment spans away in S3 would force re-tokenization in Phase 0.2.

- **`AstArena` is unmanaged**: it receives `gpa: std.mem.Allocator` at each operation, not stored. Etch is not in the whitelist of `engine-zig-conventions.md` §3 (it is conceptually a foundation module, not Tier 1). Lifecycle is `parse(gpa, source) !ParseResult` ... `ast.deinit(gpa)`.

- **No bench in CI** mirrors the S2 stance: GitHub Actions runners are not representative for absolute timings. Bench verdict is given on the physical reference machine (same as S2). The `bench/results/*.md` report is committed for traceability.

- **PR description requirement** (carried from S2 review feedback): the PR description must explicitly enumerate the documentation files modified (`CLAUDE.md`, `README.md`, this brief itself) in the `## Changelog` section mandated by `engine-development-workflow.md` §4.4, in addition to the code changelog summary.

- **Pre-PR diff-list verification**: before opening the PR, run `git diff main..HEAD --name-only` and compare item-by-item to the "Fichiers à créer ou modifier" section above. Any file listed but absent from the diff is a blocker; any file in the diff not listed must be justified in « Déviations actées ».

- **Reference brief**: `briefs/S2-window-vulkan-triangle.md` is the calibration target for this brief's level of detail. S3 should not exceed S2 in length without justification — and given S3's narrower technical surface (no hardware validation, no multi-platform matrix, no Vulkan), this brief is similar or slightly shorter.

- **Expected volume**: ~1800 lines of Zig (production + same-file unit tests) + ~100 corpus files in Etch (~5000 LOC of fixtures, not production code). Fits the 500–2000-line target of `engine-development-workflow.md` §2.2.

---

# SECTION VIVANTE

*Tenue par Claude Code pendant le milestone. Le journal n'est pas un compte-rendu marketing : il sert à la review et au debug post-mortem.*

## Specs lues

- [x] `engine-spec.md` (§22.3 sub-section S3, §3.5, §22 Couche 2) — lu 2026-05-15 09:27
- [x] `etch-grammar.md` (entire file) — lu 2026-05-15 09:27
- [x] `etch-reference-part1.md` (§2, §3, §6) — lu 2026-05-15 09:27
- [x] `etch-ast-ir.md` (§1, §3, §10) — lu 2026-05-15 09:27
- [x] `etch-resolver-types.md` (§1, §11, §12, §13, §17, §19) — lu 2026-05-15 09:27
- [x] `etch-diagnostics.md` (§1, §2) — lu 2026-05-15 09:27
- [x] `etch-reference-part3.md` (Part III §1-§6) — lu 2026-05-15 09:27
- [x] `etch-visual-scripting.md` (Pipeline de compilation) — lu 2026-05-15 09:27
- [x] `engine-zig-conventions.md` (§3, §4, §13) — lu 2026-05-15 09:27
- [x] `engine-development-workflow.md` (§2, §3, §4) — lu 2026-05-15 09:27
- [x] `engine-directory-structure.md` (§9.1, §9.3) — lu 2026-05-15 09:27

## Journal d'exécution

## Déviations actées

## Blocages rencontrés

## Notes de fin
