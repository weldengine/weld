# S5 — Etch → Zig codegen and compile-time measurement

> **Status:** PLANNED
> **Phase:** -1
> **Branche:** `phase-pre-0/etch/codegen-zig`
> **Tag prévu:** `v0.0.6-S5-etch-codegen-zig`
> **Dépendances:** S4 (merged, tag `v0.0.5-S4-etch-tree-walking-interpreter`, 2026-05-16), S3, S1
> **Date d'ouverture:** 2026-05-17
> **Date de fermeture:** —

---

# SECTION FIGÉE

*Produced by Claude.ai. Not modifiable by Claude Code outside a Claude.ai round-trip (cf. § Déviations actées).*

## Contexte

S5 is the sixth and penultimate spike of Phase -1. It validates the structural shipping hypothesis of the Etch execution layer: **Etch → Zig source → compilation by Zig** is viable in terms of build time (cf. `engine-spec.md` §25.3 / S5). This is *the* major structural risk of Phase -1 — if compile times explode (e.g. > 1 minute for a single-line incremental edit), the shipping strategy is revisited before Phase 0.2 and alternatives (VM bytecode as primary backend, minimal Zig subset codegen, hybrid Zig release / bytecode dev) are arbitrated. S5 must therefore measure honestly, not work around the comptime path that is precisely what the spike is meant to exercise. The diff harness built in S4 (generic `Runner` interface + `runner_interp` over 20 differential programs) is reused as-is by plugging a new `runner_codegen` — this is the "design on day one, implement progressively" angle that S4 paid for.

## Scope

- Etch → Zig codegen on the S3 subset (`component`, `resource`, `rule`, `when` clause, basic arithmetic expressions, `get`/`get_mut`/`has` accessors over components and resources), strict semantic parity with the S4 tree-walking interpreter
- One generated Zig file per input `.etch` file, written under `zig-out/etch-gen/<input_path>.zig`, idiomatic and human-readable Zig (proper indentation, names mirroring Etch source, file header `// Auto-generated from <source>.etch — DO NOT EDIT`)
- Codegen invoked as an automatic step of `zig build`: input `.etch` files declared in `build.zig`, regenerated before Zig compile when source mtime/content hash has changed
- Codegen cache keyed by xxHash of source `.etch` content, per-file granularity, stored at `zig-out/etch-gen/.cache/`
- Generated programs consume the comptime archetype path of S1 (`world.query(.{T1, T2, ...})`, comptime monomorphisations), not the dynamic path of S4 — the spike must exercise the production target
- Component / resource Etch declarations mapped 1:1 to `extern struct` Zig declarations under matching names (no prefix), declared in the generated file; resources spawned as singleton entities at program init (cohérent `engine-spec.md` §2.9)
- Type mapping fixed for S5 and Phase 0.2: `int` → `i64`, `float` → `f64`, `bool` → `bool`. Values in generated code are native Zig types, flow-typed from the S3 typechecker output — no `Value` tagged union on the hot path
- Differential test harness reuse: a new `Runner` implementation `runner_codegen` plugged into the existing generic driver `tests/etch_interp/diff_runner.zig` (built in S4), consuming the same 20 sidecar pairs `tests/etch_interp/<NN>-*.{etch,input.json,expected.json}` without modification of the sidecar format
- Differential test binary consolidating the 20 programs (one Zig module per cooked program, dispatched by program name), compiled statically — no JIT, no runtime `.so` loading
- Codegen surface published as `weld_etch.codegen_zig` with a stable entry point (function that takes parsed AST + type map + allocator + output directory and emits the generated `.zig` files, plus minimal error type `CodegenError` covering `UnsupportedConstruct`, `NonPodComponent`, `InternalCodegenBug`)
- Synthetic 100-file project generator under `tools/etch_synth/` (throwaway Zig CLI) producing reproducible Etch corpora seeded for determinism: 5-10 components per file, 3-5 rules per file, arithmetic variation across the S3 subset; corpus written to `bench/fixtures/synth_100/`, its own `build.zig` to cook + compile the corpus
- Compile-time benchmark `bench/etch_compile.zig` measuring **three distinct wall-clock metrics** on the synthetic 100-file corpus, N=10 iterations, median + standard deviation reported:
  - (a) Codegen only (Etch → Zig source emission), Zig compile excluded
  - (b) Cold `zig build` on cooked corpus, Zig cache wiped (`rm -rf .zig-cache` before each iteration)
  - (c) Incremental `zig build` after a one-line edit in one cooked `.etch` source file (Zig cache intact, regenerate one file, recompile)
- Validation report `validation/s5-go-nogo.md` (analogous to `validation/s2-go-nogo.md`) with explicit GO/NO-GO verdict against the five spec gates (cf. § Critères d'acceptation › Benchmarks)
- Demo target `run-demo-etch-codegen` cooking a single representative `.etch` fixture, compiling it through the full pipeline and running a few ticks against a sample initial world, printing component values to stdout

## Out-of-scope

- Any extension beyond the S3 subset: `for`, `if`/`if let`, `match`, `async`/`await`, closures, `race`/`sync`/`branch`/`spawn`, `try`/`catch`, `emit`/`event`, structural changes (`spawn`, `despawn`, `add`, `remove`), tags, traits, generics, stdlib calls — all Phase 0.2 or later
- HIR introduction — Phase 0.2 minimum, more likely Phase 1 (cf. `etch-ast-ir.md` §5). The S3 subset has no non-trivial desugaring; introducing HIR for it would be cosmetic architecture
- Bytecode codegen and VM — Phase 2 (cf. `etch-bytecode.md`)
- Hot-reload of generated code (cf. `etch-abi-zig.md` §10) — not in S5, not in Phase 0
- Watch mode for the codegen build step — overkill for a spike
- Win11 and Fedora 44 confirmation runs of the bench — deferred to Phase 0.2 (consistent with debts inherited from S3 / S4)
- Any optimisation of the comptime archetype path (computed goto, SIMD batch, inline caching, etc.) — Phase 2+
- Removal or refactor of S4's dynamic ECS path (registry, `query_dynamic`, `archetype_dynamic`, `tickBoundary`) — S5 leaves S4 code intact, S4 debts remain in S4's brief
- All inherited debts from S2 (5), S3 (10), S4 (9). Specifically not touched in S5:
  - S2: `vk_gen` whitelist closure on enum types, `VkResult` aliases at module scope, Win32 thread safety globals, §4.2 dispatch bypass in `vk_frame.zig`, PPM capture path swapchain image direct
  - S3: parser corpus volume (40 vs ~100 target), bench non-official on Apple Silicon, `StableId` left at 0, trivia / doc comments not attached to `NodeId`, annotation applicability not validated, `get(T) / get_mut(T)` without receiver for resources, `ExprKind.path` and `ExprKind.tag_path` produced out of S3 brief scope, `tag_path` accepted as const-evaluable, bench methodology double-counts the lexer, annotation arg field access
  - S4: bench verdict Apple Silicon dev primary only, `or` predicate walks every archetype, field filter limited to one `has_with_filter` per rule, `RuntimeQuery` + `world.query_dynamic` not used on hot path, `RuntimeReport.last_error` never set, `ecs_bridge.writeValueAsBytes` panics on type mismatch
- Compile-time fallback to the dynamic path "in case of explosion" — explicitly *not* documented as a mid-spike option. If the comptime path actually explodes (bench cold > 60s on the 100-file corpus, or incremental > 10s), it is a legitimate blocker per `engine-development-workflow.md` §2.4 (stop, journal, return to Claude.ai). The spec gate is the gate; fallback strategies are arbitrated *after* the spike, not during

## Documents de spec à lire en premier

1. `engine-spec.md` — §25.3 / S5 (canonical milestone definition), §25.3 / S4 (shared invariants reminder), §25.3 / S3 + S1 (delivered contracts), §3.5 (in-tree Phase 1-4)
2. `etch-grammar.md` — §5 (component, resource, struct, enum), §6 (when clauses), §7 (rules), §19 (design decisions v0.6) — only as needed for the S3 subset
3. `etch-reference-part1.md` — §3 (type system), §5 (memory model surface), §8 (functions) — only as needed for S3 subset semantics
4. `etch-reference-part2.md` — §3 (component access patterns), §4 (resources) — only the parts in scope for S5
5. `etch-ast-ir.md` — §3 (AstArena consumed), §5 (lowering AST → HIR — context only, no HIR is built in S5), §6 (HIR-Shader — out of scope, context only)
6. `etch-memory-model.md` — §1 (3 zones overview), §6 (allocation patterns by context) — confirm that generated code does not need to manipulate any of the 3 zones explicitly for the S3 subset (rule body locals stay on Zig stack, no event emission, no deferred commands)
7. `etch-resolver-types.md` — §11 (const eval), §12 (ECS rule validations), §19 (phasing — Phase 0.5/S3 line)
8. `etch-bytecode.md` — §18 (architectural reminders only: shipping = full Zig codegen, VM is dev-only)
9. `etch-abi-zig.md` — §12 (shipping codegen target — S5 is the early instantiation of this contract on the S3 subset)
10. `etch-visual-scripting.md` — §4 (shipping = Zig codegen reminder)
11. `engine-ecs-internals.md` — §1 (architecture), §3 (archetype transitions — read paths only matter), §4 (query compilation — the comptime path consumed by generated code), §5 (change detection — out of scope for S5 but useful context)
12. `engine-zig-conventions.md` — §3 (allocators), §4 (collections unmanaged), §9 (comptime — depth limits matter for the codegen output), §13 (general conventions)
13. `engine-development-workflow.md` — §2 (milestone model), §3 (brief format), §4 (git conventions)
14. `engine-directory-structure.md` — §9 (repo layout), §9.1 (`src/etch/zig_codegen/` location)
15. `briefs/S1-mini-ecs-zig.md` — delivered contract: comptime ECS API (`world.query`, archetype storage SoA)
16. `briefs/S3-etch-parser-subset.md` — delivered contract: parser subset, public surface `parseSource`, `typeCheck`, `Ast`, `NodeId`, `Diagnostic`
17. `briefs/S4-etch-tree-walking-interpreter.md` — delivered contract: interpreter, ECS dynamic bridge, generic differential driver, **20 differential programs + sidecars (REUSED IN S5)**

## Fichiers à créer ou modifier

### Codegen module (`src/etch/zig_codegen/`)

- `src/etch/zig_codegen/root.zig` — ajout — module root, public surface (`generate(...)`, `CodegenError`)
- `src/etch/zig_codegen/emit.zig` — ajout — emission primitives (`Writer` wrapper, indentation, helpers)
- `src/etch/zig_codegen/lower.zig` — ajout — AST → Zig source lowering for the S3 subset (components, resources, rules, when clauses, expressions, accessors)
- `src/etch/zig_codegen/type_map.zig` — ajout — Etch type → Zig type mapping (`int` → `i64`, `float` → `f64`, `bool` → `bool`)
- `src/etch/zig_codegen/cache.zig` — ajout — content hash cache, per-file regeneration skip
- `src/etch/zig_codegen/errors.zig` — ajout — `CodegenError` enum and diagnostic formatting

### Etch public surface (`src/etch/`)

- `src/etch/root.zig` — édition — re-export `codegen_zig` namespace, keep S4 surface intact (parser, typecheck, interpreter, ecs_bridge)

### Build integration (`build.zig`)

- `build.zig` — édition — add codegen step that runs the Etch → Zig pass for files declared in a top-level list before compiling generated modules; add targets `bench-etch-compile`, `run-demo-etch-codegen`, `test-codegen-diff`; preserve all existing targets

### Synthetic corpus tool (`tools/etch_synth/`)

- `tools/etch_synth/main.zig` — ajout — CLI generating N `.etch` files into an output directory, with seed for determinism and configurable distribution (components per file, rules per file, arithmetic variation)
- `tools/etch_synth/README.md` — ajout — usage, seed, distribution parameters

### Synthetic corpus fixtures (`bench/fixtures/synth_100/`)

- `bench/fixtures/synth_100/build.zig` — ajout — local build script cooking + compiling the 100-file corpus
- `bench/fixtures/synth_100/build.zig.zon` — ajout — minimal manifest
- `bench/fixtures/synth_100/README.md` — ajout — corpus generation command, seed, regeneration procedure
- `bench/fixtures/synth_100/scripts/00*.etch` — ajout — 100 generated files (committed for reproducibility; deterministic from seed)

### Benchmark (`bench/`)

- `bench/etch_compile.zig` — ajout — harness running the three metrics (a) (b) (c) over the synthetic 100-file corpus, N=10 iterations, median + stddev, output to `bench/results/S5-codegen-zig.md`
- `bench/results/S5-codegen-zig.md` — ajout — bench report (markdown), generated by `bench/etch_compile.zig` and committed

### Differential test driver runner (`tests/etch_interp/`)

- `tests/etch_interp/runner_codegen.zig` — ajout — new `Runner` implementation that, for each `.etch` program in the corpus: invokes the codegen, dispatches to the pre-compiled corresponding Zig module of the consolidated test binary, applies the input sidecar, runs ticks, compares output to expected sidecar
- `tests/etch_interp/codegen_corpus_build.zig` — ajout — helper build script generating one Zig module per program in the diff corpus (consolidated into the test binary)
- `tests/etch_interp/diff_runner.zig` — édition (minimal) — wire `runner_codegen` as a second runner mode alongside `runner_interp`. The driver core does not change. Both runners are exercised in `zig build test`

### Tests unitaires codegen (`src/etch/zig_codegen/tests/`)

- `src/etch/zig_codegen/tests/lower_test.zig` — ajout — unit tests on lowering for each S3 construct (component declaration, resource declaration, rule with when, arithmetic expressions, get/get_mut accessors)
- `src/etch/zig_codegen/tests/cache_test.zig` — ajout — cache hit/miss on identical/modified content
- `src/etch/zig_codegen/tests/errors_test.zig` — ajout — `CodegenError` paths

### Demo program (`src/`)

- `src/demo_etch_codegen.zig` — ajout — entry point exercised by `zig build run-demo-etch-codegen`, taking a fixture `.etch` file, running it through the full pipeline (parse → typecheck → codegen → Zig compile invoked via subprocess if needed, or pre-cooked at build time), executing a few ticks, printing component values

### Demo fixture (`bench/fixtures/`)

- `bench/fixtures/demo_5_rules_codegen.etch` — ajout — minimal Etch program for the codegen demo (variant of `demo_5_rules.etch` from S4 to avoid sidecar collisions)

### Validation report (`validation/`)

- `validation/s5-go-nogo.md` — ajout — explicit GO/NO-GO verdict against the five spec gates, references to bench results and test results, mention of any deviation taken during the milestone

### Repo-level documentation

- `README.md` — édition — roadmap status update (S5 → CLOSED at the end of the milestone), tag bump, new build targets section listing `bench-etch-compile`, `run-demo-etch-codegen`, `test-codegen-diff`, brief description of the `tools/etch_synth/` synthetic corpus generator
- `CLAUDE.md` — édition — état courant: milestone S5 closed, last tag, S5 hypothesis status in the "Hypothèses validées par les spikes" table, last updated date
- `briefs/S5-etch-codegen-zig.md` — ajout (this file, committed as first commit of the branch)

## Critères d'acceptation

### Tests

- `src/etch/zig_codegen/tests/lower_test.zig` — `test "lowers component declaration to extern struct"` — generated Zig contains `extern struct` with correct field types per type map
- `src/etch/zig_codegen/tests/lower_test.zig` — `test "lowers resource declaration to extern struct + singleton spawn"` — generated init code spawns a singleton entity with the resource as component
- `src/etch/zig_codegen/tests/lower_test.zig` — `test "lowers rule with single component when clause"` — generated rule function calls `world.query(.{T})` and iterates
- `src/etch/zig_codegen/tests/lower_test.zig` — `test "lowers rule with multi-component when clause and arithmetic body"` — generated function matches expected idiomatic Zig over the S1 query API
- `src/etch/zig_codegen/tests/lower_test.zig` — `test "lowers get and get_mut accessors"` — generated body uses correct comptime access pattern
- `src/etch/zig_codegen/tests/lower_test.zig` — `test "type mapping int=>i64 float=>f64 bool=>bool"` — verified across multiple constructs
- `src/etch/zig_codegen/tests/cache_test.zig` — `test "identical content hits cache, no regeneration"` — second call returns cache-hit, no file rewrite
- `src/etch/zig_codegen/tests/cache_test.zig` — `test "modified content invalidates cache, regenerates"` — file rewritten when source changes
- `src/etch/zig_codegen/tests/errors_test.zig` — `test "UnsupportedConstruct surfaced for out-of-subset input"` — codegen returns expected error
- `src/etch/zig_codegen/tests/errors_test.zig` — `test "NonPodComponent surfaced before codegen entry"` — caught at S3 typecheck, surfaced as codegen-side error if a malformed AST slips through
- `tests/etch_interp/codegen_diff_test.zig` — `test "<NN> codegen runner matches expected sidecar"` — 20 differential programs all green when executed by `runner_codegen` (one test per program, parameterised by program name)
- `tests/etch_interp/codegen_parity_test.zig` — `test "codegen result matches interpreter result on all 20 corpus programs"` — runs both `runner_interp` and `runner_codegen` against each program, asserts identical post-tick component state
- All tests green in both `debug` and `ReleaseSafe` modes

### Benchmarks

- `bench/etch_compile.zig` — codegen-only wall-clock (metric a) on synthetic 100-file corpus — reported in `bench/results/S5-codegen-zig.md`, median + stddev over N=10 iterations
- `bench/etch_compile.zig` — cold `zig build` wall-clock (metric b) on cooked synthetic 100-file corpus, Zig cache wiped before each iteration — reported, median + stddev over N=10 iterations
- `bench/etch_compile.zig` — incremental `zig build` wall-clock (metric c) after one-line edit in one cooked source, Zig cache intact — reported, median + stddev over N=10 iterations
- **Spec gate 1 — cold compilation:** (a) + (b) < 30 s on Apple Silicon dev primary
- **Spec gate 2 — incremental compilation:** (a) + (c) < 2 s on Apple Silicon dev primary
- **Spec gate 3 — zero leak:** `std.testing.allocator` counting wrapper green on the full test + bench run
- **Spec gate 4 — monomorphisation contained:** the number of distinct Zig comptime instantiations generated by the cooked 100-file corpus stays within reasonable bounds. Hard ceiling: ≤ 4 × the number of distinct archetype signatures present in the corpus. Measured by introspecting `zig build --summary all` output or equivalent compiler instrumentation, reported in `bench/results/S5-codegen-zig.md`
- **Spec gate 5 — differential parity:** 20/20 differential programs green via `runner_codegen` with exact post-tick state match against `runner_interp`

### Comportement observable

- `zig build run-demo-etch-codegen` — cooks `bench/fixtures/demo_5_rules_codegen.etch`, compiles the generated Zig as part of the build, runs a small fixed scenario (~10 ticks against a sample initial world), prints component values to stdout in a deterministic format. Output matches a committed reference at `bench/fixtures/demo_5_rules_codegen.expected.txt`
- `zig build bench-etch-compile` — runs the three-metric benchmark, prints summary to stdout, writes `bench/results/S5-codegen-zig.md`
- `zig build test-codegen-diff` — runs the 20-program diff corpus through `runner_codegen` and the parity check against `runner_interp`
- `validation/s5-go-nogo.md` — present, complete, with explicit GO or NO-GO verdict per gate, GO overall if all five gates green

### CI

- `zig build` clean, zero warning, on the Ubuntu 24.04 + Windows 2025 matrix (existing matrix unchanged)
- `zig build test` green in `debug` and `ReleaseSafe` — within an accepted wall-clock budget for S5: **< 120 s on the CI matrix** (acknowledged tradeoff of the spike, recorded in § Notes)
- `zig fmt --check` clean across all hand-written sources (generated Zig under `zig-out/etch-gen/` excluded from the check, as it lives in the build artifacts directory)
- `zig build lint` clean if the custom linter is present at the time the milestone is run; otherwise skipped (consistent with the post-S1 lint milestone deferral noted in `engine-spec.md` §25.3 / S0)
- `commit-msg` hook green on all commits of the branch (Conventional Commits)
- Benchmark CI artifact: `bench/results/S5-codegen-zig.md` committed and updated by the bench run

## Conventions

- **Branche:** `phase-pre-0/etch/codegen-zig`
- **Tag final:** `v0.0.6-S5-etch-codegen-zig`
- **Titre de PR:** `Phase -1 / Etch / Etch → Zig codegen and compile-time measurement`
- **Convention de commits:** Conventional Commits (cf. `engine-development-workflow.md` §4.3). Recommended scope: `etch` for codegen module, `build` for build.zig edits, `tools` for `etch_synth`, `bench` for the bench harness, `tests` for the diff runner, `docs` for README / CLAUDE.md / brief journal
- **Stratégie de merge:** squash-and-merge (cf. `engine-development-workflow.md` §4.6)

## Notes

### Methodology — three distinct bench metrics

Three distinct wall-clock measurements are reported separately, not fused into cumulative numbers. This is non-negotiable: if the cold bench fails, the spec gives different fallback paths depending on whether codegen or Zig compile is responsible for the overage. Mixing them would discard the diagnostic information the bench is supposed to produce.

For metric (b) the Zig cache is wiped via `rm -rf .zig-cache` (POSIX) or its Windows equivalent inside the bench harness before each of the N=10 iterations. For metric (c) the cache is left intact and a deterministic one-line edit (e.g. mutate a constant numeric literal in a known position of a known source file) is applied before each iteration, then reverted after. Both procedures are documented in `bench/etch_compile.zig` source comments.

### Why the comptime archetype path, not the S4 dynamic path

The spec gate "Pas d'explosion de monomorphisations comptime dégénérées" can only be measured by *generating* those monomorphisations. The dynamic path (registry, `query_dynamic`) is the documented post-spike fallback in case the comptime path explodes — it is not a way of avoiding the measurement. If the comptime path explodes, that is the spike outcome: stop, journal, return to Claude.ai for re-design. The spec text in `engine-spec.md` §25.3 / S5 ("Si échec : la stratégie shipping est revue avant Phase 0.2. Alternatives à arbitrer alors…") places the arbitration *after* the spike, not during.

### Why one Zig file per `.etch`, in `zig-out/etch-gen/`

One-to-one mapping is the simplest predictable scheme for a spike. `zig-out/etch-gen/` is the build-artifacts directory, already gitignored. No "src/generated/" or similar versioned location — generated code is build output, not source. The output path is `zig-out/etch-gen/<relative_input_path>.zig`, mirroring the input layout. Path collisions are not a concern at the S5 corpus size.

### Why one consolidated test binary for the diff harness

Compiling 20 separate test binaries (one per program) would multiply the linker work and inflate `zig build test` time well beyond the 120s budget. A single consolidated binary with one Zig module per program, dispatched by program name in the runner, amortises linkage cost. The `tests/etch_interp/codegen_corpus_build.zig` helper builds this consolidation; the diff driver itself stays generic and parameterised by `Runner`.

### Why no HIR in S5

The S3 subset has no construct that requires desugaring: no `for`, no `if let`, no `match`, no `await`, no closures, no `try`/`catch`. Lowering AST → Zig source directly is straightforward and produces idiomatic output. HIR (cf. `etch-ast-ir.md` §5) becomes valuable when desugarings need to be factored across the bytecode and Zig backends — that point arrives in Phase 0.2 (subset extension) or Phase 1 (async / closures). Introducing HIR in S5 would be cosmetic and would slow down the spike without informing the compile-time hypothesis.

### Why per-file content hash for the codegen cache

Per-declaration granularity (cache per component, per rule) is over-engineering for the spike. Per-file is sufficient to make metric (c) meet the < 2 s gate: a one-line edit invalidates one file, regenerates one Zig file, triggers Zig's per-module incremental recompilation. If the gate is missed at per-file granularity, the conclusion is that the bottleneck is downstream (Zig compile itself), not the cache strategy — finer cache would not save us.

### Type mapping rationale

`int` → `i64` is the safe default for gameplay code (IDs, scores, durations in ns can fit). The `i32`/`i64` perf-memory tradeoff is a Phase 2+ profiling decision, not a spike concern. `f64` is consistent with the S3 arithmetic subset and avoids float-precision surprises in differential testing. The mapping is stable through Phase 0.2.

### Resources as singleton entities

Resources are spawned as singleton entities at program init, exposed via accessors generated for `get(R)` / `get_mut(R)` over the singleton handle. This is consistent with `engine-spec.md` §2.9 and reuses the S1 + S4 ECS APIs without introducing a separate resource storage. The generated `init(world)` function spawns one entity per resource declared in the cooked file and attaches the resource as a component on that entity.

### Generated file layout — readable, not minified

Generated Zig is idiomatic and human-readable: 4-space indentation, names mirroring Etch source (`rule fire_damage` → `pub fn rule_fire_damage(world: *World) void { ... }`), file header noting source and timestamp. This is for debug ergonomics during S5 and Phase 0.2 when extending the subset — manually reading a generated file should be possible to diagnose codegen bugs. No minification, no obfuscation. The downside (larger generated files) is irrelevant at S5 corpus size.

### Test budget tradeoff acknowledged

`zig build test` becoming ~60-120 s (vs ~5 s in S0-S4) is the natural cost of running 20 codegen + Zig compile cycles end-to-end. This is acknowledged as a spike tradeoff. If sustained at this duration through Phase 0, a follow-up milestone would parallelise the diff runner or cache cooked artifacts across runs. Out of scope for S5.

### Bench primary on Apple Silicon — Win/Linux confirmation = Phase 0.2 debt

Consistent with S3 (bench Apple Silicon dev primary) and S4 (idem). Win11 + Fedora 44 confirmation runs of the compile-time bench are deferred to Phase 0.2, listed alongside the other S3 / S4 confirmation debts. The bench harness itself is platform-portable (uses `std.time.nanoTimestamp` for wall-clock, POSIX/Windows-aware cache-wipe).

### Synthetic corpus is generated, not hand-curated

The 100-file synthetic corpus is generated procedurally by `tools/etch_synth/` with a fixed seed (recorded in `bench/fixtures/synth_100/README.md`). The generated `.etch` files are committed to the repo for reproducibility of bench numbers (so the bench is not dependent on having a working `etch_synth` at the time of regression). Regenerating the corpus from scratch with the same seed must yield byte-identical files — `tools/etch_synth/` is deterministic.

### Inherited debts intentionally not addressed

The debts inherited from S2 (5), S3 (10), S4 (9) are listed in § Out-of-scope. S5 does not touch them. They remain in their original briefs as Phase 0.2 work. This is explicit so Claude Code does not stretch S5 to fix them "while they are nearby."

### Failure mode is a legitimate blocker

If during implementation the comptime path produces compile times that exceed the spec gates by an order of magnitude (e.g. cold > 60 s, incremental > 10 s) and the cause is clearly the codegen strategy (not, say, a bug in the bench harness or in the generated code), this is a legitimate blocker per `engine-development-workflow.md` §2.4: stop, journal under "Blocages rencontrés", return to Claude.ai. The spec arbitration of fallback strategies (`engine-spec.md` §25.3 / S5 "Alternatives à arbitrer") happens in a new conversation, with the bench numbers as input. Claude Code must not silently switch to the dynamic path to "make it pass."

---

# SECTION VIVANTE

*Maintained by Claude Code during the milestone. The journal is not a marketing report: it serves review and post-mortem debug.*

## Specs lues

*To be checked before any production code is written. Confirms the spec was fully ingested, not skimmed.*

- [ ] `engine-spec.md` §25.3 / S5 + §25.3 / S4 + §25.3 / S3 + §25.3 / S1 + §3.5 — read <YYYY-MM-DD HH:MM>
- [ ] `etch-grammar.md` §5 + §6 + §7 + §19 — read <YYYY-MM-DD HH:MM>
- [ ] `etch-reference-part1.md` §3 + §5 + §8 — read <YYYY-MM-DD HH:MM>
- [ ] `etch-reference-part2.md` §3 + §4 — read <YYYY-MM-DD HH:MM>
- [ ] `etch-ast-ir.md` §3 + §5 + §6 — read <YYYY-MM-DD HH:MM>
- [ ] `etch-memory-model.md` §1 + §6 — read <YYYY-MM-DD HH:MM>
- [ ] `etch-resolver-types.md` §11 + §12 + §19 — read <YYYY-MM-DD HH:MM>
- [ ] `etch-bytecode.md` §18 — read <YYYY-MM-DD HH:MM>
- [ ] `etch-abi-zig.md` §12 — read <YYYY-MM-DD HH:MM>
- [ ] `etch-visual-scripting.md` §4 — read <YYYY-MM-DD HH:MM>
- [ ] `engine-ecs-internals.md` §1 + §3 + §4 + §5 — read <YYYY-MM-DD HH:MM>
- [ ] `engine-zig-conventions.md` §3 + §4 + §9 + §13 — read <YYYY-MM-DD HH:MM>
- [ ] `engine-development-workflow.md` §2 + §3 + §4 — read <YYYY-MM-DD HH:MM>
- [ ] `engine-directory-structure.md` §9 + §9.1 — read <YYYY-MM-DD HH:MM>
- [ ] `briefs/S1-mini-ecs-zig.md` — read <YYYY-MM-DD HH:MM>
- [ ] `briefs/S3-etch-parser-subset.md` — read <YYYY-MM-DD HH:MM>
- [ ] `briefs/S4-etch-tree-walking-interpreter.md` — read <YYYY-MM-DD HH:MM>

## Journal d'exécution

*One entry per logical work sequence (typically: an objective reached, a test passing, a blocker). Chronological order. Short format — 1 to 3 lines per entry.*

- <YYYY-MM-DD HH:MM> — <summary>

## Déviations actées

*Modifications of the SECTION FIGÉE made during the milestone after a Claude.ai round-trip. Each deviation references the commit that records it. If empty at the end of the milestone: nominal case.*

- <commit SHA> — <deviation summary and reason>

## Blocages rencontrés

*Blocking points that required a return to Claude.ai (cf. `engine-development-workflow.md` §2.4). If 2+ distinct blockers: signal for re-scope.*

- <blocker summary> — resolved by <commit SHA> or <reference to the Claude.ai conversation>

## Notes de fin

*To be filled when Status transitions to CLOSED, just before opening the PR.*

- **What worked:**
- **What deviated from the original spec:**
- **What to flag explicitly in review:**
- **Final measurements** (compile-time figures from `bench/results/S5-codegen-zig.md`, test wall-clock, binary sizes if relevant, monomorphisation count):
- **Residual risks / technical debt left intentionally:**

## Pre-PR diff check

*Mandatory step before opening the PR. Compares `git diff main..HEAD --name-only` against the § Fichiers à créer ou modifier list.*

- [ ] Run `git diff main..HEAD --name-only` and paste the output here
- [ ] For every file in § Fichiers à créer ou modifier: confirm it appears in the diff (or justify its absence as a deviation)
- [ ] For every file in the diff: confirm it appears in § Fichiers à créer ou modifier (or justify it under § Déviations actées)
- [ ] No discrepancy → proceed to PR
- [ ] Discrepancy → either fix the diff or record the deviation, then re-check
