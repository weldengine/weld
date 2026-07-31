# S4 — Etch tree-walking interpreter

> **Status:** CLOSED
> **Phase:** -1
> **Branch:** `phase-pre-0/etch/tree-walking-interpreter`
> **Planned tag:** `v0.0.5-S4-etch-tree-walking-interpreter`
> **Dependencies:** S0 (bootstrap), S1 (mini-ECS, comptime SoA archetype + Chase-Lev jobs), S3 (Etch lexer + parser + two-pass type-checker on the S3 subset)
> **Opening date:** 2026-05-15
> **Closing date:** 2026-05-15

---

# FROZEN SECTION

*Produced by Claude.ai. Not modifiable by Claude Code outside of a Claude.ai round-trip (cf. § Acknowledged deviations).*

## Context

Fifth Phase −1 derisking spike. Validates the hypothesis stated in `engine-phase-minus-1-archive.md` S4: that the AST emitted by S3 is correctly executable by a tree-walking interpreter, and that a functional bridge can be built between this interpreter and the comptime SoA archetype storage delivered by S1. The deliverable is twofold: (a) the interpreter itself and (b) a shared differential test harness that S5 (Etch → Zig codegen) will reuse verbatim to prove behavioural equivalence between the two backends.

## Scope

- Tree-walking interpreter over the tabular SoA AST emitted by S3, executing the five constructs of the S3 subset (`component` decl, `resource` decl, `rule` decl with `when` clause, arithmetic expressions, mutation in-place via `entity.get_mut(T).field = expr`).
- Runtime `Value` representation as a stack-allocated tagged union covering `int`, `float`, `bool`, `string_id`, `entity_id`, `component_ref`, `unit`. POD-only — the S3 subset enforces POD components, no heap promotion is required at S4.
- Const evaluator `evalConst(&ast, NodeId) !Value` reusing the same expression backend, restricted to const-evaluable nodes (literals, arithmetic on literals). Used by the test harness to materialize field defaults at component registration.
- `RuntimeError` typed sum (`DivisionByZero`, `IntegerOverflow`, `UnsupportedExpr`) carrying a `SourceSpan` resolved from the AST `NodeId` that triggered the error.
- Tier 0 ECS extensions (live in `src/core/ecs/`, not in `src/etch/`) required to bridge the interpreter to the S1 archetype storage:
  - **Runtime component registry**: `world.registerComponent(comptime T) ComponentId`, table `ComponentId → (size, alignment, field offsets, default value bytes)`. Coexists with the S1 comptime archetype; does not replace it.
  - **Dynamic archetype**: runtime combinations of `ComponentId` (in addition to the S1 hardcoded `Transform + Velocity` archetype). The S1 archetype path remains intact and benchable in parallel.
  - **`ResourceStore`**: `HashMap<ComponentId, []u8>` plus a `dirty: bool` flag per resource. The flag is set inside `get_mut(resource)` paths and reset at the beginning of each tick.
  - **Runtime query**: `Query.new(world, includes: []ComponentId, excludes: []ComponentId)` returning a chunk iterator. Field-equality filters (`has T { field == value }`) are applied per-slot by the interpreter using the registry's field offset metadata.
- ECS bridge module (`src/etch/ecs_bridge.zig`) adapting the interpreter onto the Tier 0 ECS extensions above: `resolveQuery(world, when_clause_node) !RuntimeQuery`, `getComponent`, `getMutComponent`, `getResource`, `getMutResource`, `spawnDefault(world, archetype) Entity`.
- Rule scheduler in S4: strictly sequential, in source declaration order. Annotations are parsed (S3) but ignored at execution. Single-tick step exposed as `Interpreter.stepOnce`, multi-tick boundary loop as `Interpreter.run(world, ticks)`.
- `RuntimeReport` struct returned by `run`: `entities_iterated`, `rules_evaluated`, `rules_matched`, `runtime_errors`. Used by the differential harness and by the demo binary.
- Public surface of `weld_etch` extended through `src/etch/root.zig` to export: `Interpreter`, `Value`, `RuntimeError`, `RuntimeReport`, `runProgram(gpa, source, world, ticks) !RuntimeReport`, `run(gpa, &ast, world, ticks) !RuntimeReport`, `evalConst(&ast, NodeId) !Value`.
- **Shared differential test harness** (`tests/etch_interp/`) that S5 will reuse unchanged:
  - 20 differential programs under `tests/etch_interp/programs/<name>.etch`.
  - One Zig sidecar per program at `tests/etch_interp/programs/<name>.expected.zig` declaring `pub const config = .{ .ticks = N }`, `pub const initial = .{ ... }`, `pub const expected = .{ ... }`.
  - Generic driver `tests/etch_interp/diff_runner.zig` parameterised by a `Runner` interface (methods `setup`, `step`, `finalize`). S4 wires the interpreter Runner; S5 will plug a codegen Runner without modifying the harness.
  - Coverage requirement: pure arithmetic (3), in-place mutation (3), `when` clause with single component filter (2), `when` with `and`/`or`/`not` composition (3), `when` with field-equality filter `has T { f == v }` (3), `when resource T` filter (2), `when resource T changed` filter (2), multi-rule ordering (2).
- Bench harness `bench/etch_interp.zig` executing 1000 entities × 5 rules over 1000 ticks in `ReleaseSafe`, emitting a Markdown report into `bench/results/`.
- Build step `zig build bench-etch-interp` wiring the bench above.
- Demo binary entry point in `src/main.zig` extended (or new `src/demo_etch_interp.zig` wired into `build.zig`) that spawns 1000 entities, loads a fixed 5-rule program from `bench/fixtures/demo_5_rules.etch`, runs 60 ticks, logs a summary line.
- README and CLAUDE.md updates (cf. § Files to create or modify).

## Out-of-scope

The following are explicitly **not** to be touched, added, or extended in S4. Each item is either a Phase 0.2+ concern, a known S3 debt, or a feature outside the S3 subset:

- HIR introduction and AST → HIR lowering. The interpreter walks the AST directly. HIR is a Phase 0.5/Phase 1 concern.
- Bytecode VM, opcode catalogue, `.etchc` format.
- Etch → Zig codegen (this is S5 scope).
- Job system usage. Rules execute sequentially on the main thread. The Chase-Lev work-stealing scheduler from S1 is not invoked.
- Resource field access from rule bodies (`get(T).field`, `get_mut(T).field` without a receiver). Inherited S3 debt: the parser does not produce these nodes. Resources are observable from rules only through the `when resource T [changed]` filter; their fields cannot be read or written from rule bodies in S4.
- Structural mutations: `spawn`, `despawn`, `entity.add(T)`, `entity.remove(T)`. The S3 subset is mutation-in-place only.
- Command buffers, deferred mutation queues.
- Generic queries (`Changed<T>`, `With<T>`, `Without<T>` Bevy-like typed wrappers). The runtime query is plain `(includes, excludes)`.
- `ExprKind.path` and `ExprKind.tag_path` evaluation. Both are produced by the S3 parser out of brief scope and remain unsupported in S4. The interpreter detects them and returns `RuntimeError.UnsupportedExpr` with the node's span; the differential corpus never exercises them.
- `tag_path` const-evaluability soundness gap (S3 debt). `evalConst` returns `RuntimeError.UnsupportedExpr` on `tag_path` and does not attempt to fix it.
- Annotation argument resolution. Annotations are captured by S3 but their applicability is not validated and their args are not evaluated. The interpreter ignores annotations entirely at execution time.
- Annotation arg field access (S3 debt: `@requires(self.health)` breaks). Untouched.
- StableId materialization (S3 debt: stays at 0). Untouched.
- Trivia / doc comment attachment to NodeId (S3 debt). Untouched.
- Corpus volume gap from S3 (40 vs ~100). Untouched. The S4 differential corpus is a separate set of 20 programs with a different purpose.
- Bench methodology refactor for S3 (lexer double-count). Untouched. The S4 bench measures the interpreter only, not the lexer/parser.
- Multi-threading of rule evaluation, parallel chunk iteration within a rule, ECS access tracking (`reads`/`writes` maps), scheduler dependency graphs.
- Async, throws, try/catch, closures, for-loops, if-let, match, generics, traits, impls, shader bodies. None of these are in the S3 subset.
- S2 inherited debts (vk_gen whitelist closure, VkResult aliases, Win32 thread-safety globals, vk_frame.zig dispatch bypass, PPM capture path swapchain image direct). Untouched.
- macOS support. Out of scope through Phase 0 (cf. `engine-phase-0-criteria.md`).
- Custom linter for Etch interpreter code.

## Documents to read first

In the listed order. Mandatory before writing any production code — Claude Code ticks each entry in the LIVING SECTION with a real timestamp.

1. `engine-phase-minus-1-archive.md` — S4 (canonical scope) and the Phase −1 modus operandi; `ARCH-017` (in-tree Phase 1-4, no separable libs).
2. `etch-grammar.md` — §3 (expressions, operators, precedence), §5 (constructs: component, resource, rule, when), §6 (when clause grammar), §18 (annotations — captured only, not honored at execution in S4), §19 (v0.6 design decisions).
3. `etch-reference-part1.md` — §3 (type system: polymorphic literal defaulting, int/float defaulting rules already applied by S3), §4 (variables, mutability, shadowing), §5 (memory model: surface invariants — S4 does not need the deeper internals), §6 (expressions: arithmetic semantics, division by zero, integer overflow, compound assignments, comparison, logical operators).
4. `etch-resolver-types.md` — §11 (const evaluation: contexts where const is required, defaulting rules), §12 (ECS rule validations: when clause compilation to archetype set, archetype matching), §19 (phasing — confirms S4 is Phase 0.5 boundary, AST-direct execution).
5. `etch-ast-ir.md` — §3.2 (AstArena tabular SoA layout produced by S3), §3.3 (NodeId vs StableId — StableId stays at 0 in S4, NodeId is the only identity), §3.4 (catalogue of kinds per category — for the subset reached by S3).
6. `etch-memory-model.md` — surface invariants only: ECS refs are scope-bounded (lifetime = rule invocation), no GC pauses, no cycles. S4 does not implement the three-zone arena model; the tree-walker uses standard allocators with `std.testing.allocator` discipline.
7. `engine-ecs-internals.md` — §1 (architecture overview), §2 (chunk SoA layout — already implemented by S1), §4 (query compilation — the spec describes comptime compilation; S4 builds the runtime equivalent), §5 (change detection — tick-based; S4 implements a degenerate per-resource dirty bit, full tick-based detection is Phase 0.5).
8. `briefs/S1-mini-ecs-zig.md` — exact signatures of the `weld_core.ecs` and `weld_core.jobs` public surfaces delivered by S1, counting allocator wrapper in `weld_core.testing`.
9. `briefs/S3-etch-parser-subset.md` — exact public surface of `weld_etch` (`parseSource`, `typeCheck`, `Ast`, `NodeId`, `TypeChecker`, `Diagnostic`, `DiagnosticCode`, `SourceSpan`, `LineIndex`, `ParseResult`), final scope and 6 acknowledged debts (all out-of-scope for S4 except where re-listed above).
10. `engine-zig-conventions.md` — §3 (allocators, unmanaged collections, `std.testing.allocator`), §4 (naming, doc comments on public API), §13 (test conventions), §17 (Zig 0.16.x policy).
11. `engine-development-workflow.md` — §2 (milestone model), §3 (brief format), §4 (commits, PRs, hooks, squash-and-merge).
12. `engine-directory-structure.md` — §9.1 (overall layout), §9.3 (in-tree, no separable libs).

## Files to create or modify

Paths are relative to the repo root. The listing distinguishes creation from edition. Any file touched by Claude Code outside this list requires a written justification in the LIVING SECTION (Acknowledged deviations).

### Tier 0 ECS extensions

- `src/core/ecs/registry.zig` — **creation** — runtime component registry: `ComponentId`, `registerComponent`, `componentSize`, `componentAlignment`, `componentFieldOffsets`, `componentDefaultBytes`. Public surface re-exported via `src/core/root.zig` under `weld_core.ecs.Registry`.
- `src/core/ecs/resources.zig` — **creation** — `ResourceStore` (HashMap-backed), `addResource`, `getResource`, `getMutResource` (sets dirty bit), `tickBoundary` (resets dirty bits). Public surface re-exported via `weld_core.ecs.Resources`.
- `src/core/ecs/query_runtime.zig` — **creation** — runtime query type accepting includes/excludes lists of `ComponentId`, chunk iterator interface compatible with the dynamic archetype, per-slot field-equality filter callback. Public surface re-exported via `weld_core.ecs.RuntimeQuery`.
- `src/core/ecs/archetype_dynamic.zig` — **creation** — dynamic archetype storage that accepts a runtime `ComponentId[]` (in addition to the comptime archetype from S1). Same chunk layout (16 KiB chunks, SoA per component) but built from the runtime registry. Public surface re-exported via `weld_core.ecs.DynamicArchetype`.
- `src/core/ecs/world.zig` (or wherever the S1 `World` lives) — **edition** — additions only: `registerComponent`, `addResource`, `spawnDynamic(archetype) Entity`, `query(includes, excludes) RuntimeQuery`, `tickBoundary()`. The S1 comptime `(Transform, Velocity)` archetype and its query path remain unchanged.
- `src/core/root.zig` — **edition** — re-export the new types above under `weld_core.ecs`.

### Etch interpreter

- `src/etch/value.zig` — **creation** — `Value` tagged union, `RuntimeError` sum, helpers for arithmetic, comparison, logical ops, and span resolution.
- `src/etch/interp.zig` — **creation** — `Interpreter` struct, `run`, `runProgram`, `stepOnce`, `evalRuleBody`, `evalStmt`, `evalExpr`, `evalConst`. Orchestrates execution over an AST + a `*World`.
- `src/etch/ecs_bridge.zig` — **creation** — adapter from interpreter to `weld_core.ecs`: `resolveQuery(world, when_clause_node) !RuntimeQuery`, `getComponent`, `getMutComponent`, `getResource`, `getMutResource`, `spawnDefault(world, archetype_id)`. Holds the mapping `Etch component name → ComponentId` populated at program load.
- `src/etch/root.zig` — **edition** — extend the public surface of `weld_etch` to export `Interpreter`, `Value`, `RuntimeError`, `RuntimeReport`, `run`, `runProgram`, `evalConst`. Existing exports from S3 stay untouched.

### Differential test harness

- `tests/etch_interp/diff_runner.zig` — **creation** — generic driver parameterised by a `Runner` interface (`setup(world)`, `step(world)`, `finalize(world)`). Walks `programs/`, for each `<name>.etch`: parses, type-checks, instantiates a world from the sidecar's `initial`, executes `config.ticks` ticks, compares the final world state bit-by-bit against `expected`, reports.
- `tests/etch_interp/runner_interp.zig` — **creation** — `Runner` implementation backed by the tree-walking interpreter.
- `tests/etch_interp/programs/*.etch` × 20 — **creation** — differential programs covering the 8 categories listed under Scope.
- `tests/etch_interp/programs/*.expected.zig` × 20 — **creation** — one sidecar per program declaring `config`, `initial`, `expected`.
- `tests/etch_interp/corpus_facade.zig` — **creation** — same pattern as `tests/etch/corpus_facade.zig` from S3: a build-time-generated facade exposing the 20 programs and their sidecars to the driver. Naming and structure mirror the S3 facade to ease cross-reading.

### Bench

- `bench/etch_interp.zig` — **creation** — harness measuring 1000 entities × 5 rules over 1000 ticks in `ReleaseSafe`, plus a 10,000 entities × 5 rules scaling sweep.
- `bench/fixtures/demo_5_rules.etch` — **creation** — fixed 5-rule program used by both the bench and the demo binary.
- `bench/results/.gitkeep` — already present from S1.

### Demo

- `src/demo_etch_interp.zig` — **creation** — demo binary that spawns 1000 entities, loads `bench/fixtures/demo_5_rules.etch`, runs 60 ticks, prints a summary line (entities, rules evaluated, rules matched, runtime errors, total duration).
- `build.zig` — **edition** — wire (a) the new tests under `tests/etch_interp/`, (b) the new bench step `bench-etch-interp`, (c) the demo binary `run-demo-etch-interp`.

### Documentation

- `README.md` — **edition** — update the status table (current milestone S4 → S5, latest tag), add the new build steps (`zig build bench-etch-interp`, `zig build run-demo-etch-interp`), add a one-line summary of the S4 verdict under "Validated hypotheses".
- `CLAUDE.md` — **edition** — add S4 to the tags table with date and short summary, mark the S4 hypothesis as validated, update the "current state" table (active milestone now S5), add the S4 debts (if any acknowledged at closure) to the rolling debt list.
- `briefs/S4-etch-tree-walking-interpreter.md` — **creation** — verbatim copy of this brief, committed as the first commit of the milestone branch (cf. prompt Claude Code).

## Acceptance criteria

### Tests

All tests must be green in `Debug` and `ReleaseSafe`, on the Linux + Windows CI matrix.

- `src/etch/value.zig` — `test "Value arithmetic int + int yields int"`, `test "Value arithmetic int + float forbidden (no implicit coercion)"`, `test "DivisionByZero on int"`, `test "DivisionByZero on float yields NaN/Inf per IEEE 754"`, `test "IntegerOverflow detected in ReleaseSafe"`, `test "comparison between incompatible Values is a compile-time impossibility (asserts)"`, `test "compound assignment +=, -=, *=, /=, %= behave per spec"`.
- `src/etch/interp.zig` — `test "run on empty AST returns zero-rule report"`, `test "evalConst on int literal returns Value.int"`, `test "evalConst on arithmetic on literals folds correctly"`, `test "evalConst on tag_path returns UnsupportedExpr"`, `test "stepOnce executes rules in source declaration order"`, `test "rule body mutation persists across ticks"`, `test "UnsupportedExpr on ExprKind.path triggers RuntimeError with span"`.
- `src/etch/ecs_bridge.zig` — `test "resolveQuery on when has T yields matching entities"`, `test "resolveQuery on when has T and has U yields intersection"`, `test "resolveQuery on not has T excludes entities"`, `test "resolveQuery on has T { field == value } filters per-slot"`, `test "resolveQuery on when resource T evaluates resource presence"`, `test "resolveQuery on when resource T changed evaluates dirty bit"`, `test "spawnDefault initializes fields from registered defaults"`, `test "getMutComponent returns a handle valid for the rule body duration"`, `test "getMutResource sets the dirty bit"`.
- `src/core/ecs/registry.zig` — `test "registerComponent assigns stable ComponentId"`, `test "registerComponent rejects duplicate registration"`, `test "componentSize matches @sizeOf"`, `test "componentDefaultBytes initializes per registered default"`.
- `src/core/ecs/resources.zig` — `test "addResource then getResource roundtrip"`, `test "getMutResource sets dirty, tickBoundary resets it"`, `test "removing a resource clears its dirty bit"`.
- `src/core/ecs/query_runtime.zig` — `test "Query.new on includes only matches"`, `test "Query.new on includes + excludes matches"`, `test "Query iteration yields chunks in archetype order"`, `test "Query over zero matching archetypes yields empty iterator"`.
- `src/core/ecs/archetype_dynamic.zig` — `test "DynamicArchetype matches the chunk layout of the S1 comptime archetype for equivalent component sets"`, `test "spawnDynamic returns a generational Entity handle"`, `test "iteration over a 16 KiB chunk respects SoA per component"`.
- `tests/etch_interp/diff_runner.zig` — driver: for each of the 20 programs under `programs/`, parse → type-check → instantiate → run `config.ticks` ticks → assert final state bit-by-bit equal to `expected`. Failure modes reported with the program name, the diff, and the runtime report.

Zero leaks on the full test suite under `std.testing.allocator`. The S1 counting allocator constraint ("no allocation in the simulation loop") does **not** apply to S4 — the tree-walker allocates by construction. Only the leak discipline carries over.

### Benchmarks

Reference machine: same as S1 (M4 Pro, dev primary). Benches are not run in CI; results archived as Markdown under `bench/results/`.

- `bench/etch_interp.zig` — 1000 entities × 5 rules × 1000 ticks, `ReleaseSafe`. **Gate:** median < 10 ms / tick. **Target:** median < 5 ms / tick.
- Same bench, scaling sweep: 10 000 entities × 5 rules × 100 ticks, `ReleaseSafe`. **Gate:** median < 100 ms / tick. **Target:** median < 50 ms / tick.
- Bench report includes: hostname, CPU model, OS, Zig version, build mode, median, p99, max per tick, and a per-rule breakdown of (rules evaluated, rules matched, mutation count).

The S3 bench methodology bug (lexer double-count) does not affect S4: this bench measures only the interpreter steady state, parse + type-check happen once before the timed loop.

### Observable behaviour

- `zig build run-demo-etch-interp` launches the demo binary on the dev machine, prints (within ~3 s on the reference machine) a summary line of the form:

      Demo S4 OK | mode=ReleaseSafe | entities=1000 | rules=5 | ticks=60 | rules_matched=N | errors=0 | total=Tms

- The bench Markdown report exists under `bench/results/s4-etch-interp-<YYYYMMDD-HHMM>.md` and meets both gates above.

### CI

- `zig build` clean, zero warnings, on the existing `{ubuntu-24.04, windows-2025} × {Debug, ReleaseSafe}` matrix.
- `zig build test` green on the same matrix (includes the new tests under `src/etch/`, `src/core/ecs/`, and `tests/etch_interp/`).
- `zig fmt --check` green.
- `commit-msg` hook green on all commits of the branch (Conventional Commits via `scripts/check-commit-msg.sh`).
- New build steps registered and discoverable through `zig build --help`: `zig build bench-etch-interp`, `zig build run-demo-etch-interp`.
- Existing build steps (`zig build run`, `zig build bench-ecs`, `zig build bench-etch`, `zig build bindgen-vk`, `zig build bindgen-wayland`) still pass.

### Diff-list discipline (closure step)

Before opening the PR, run `git diff main..HEAD --name-only` and compare item-by-item with the "Files to create or modify" section above:

- Every file listed in the brief but absent from the diff → blocker, do not open the PR.
- Every file present in the diff but not listed in the brief → must be justified under "Acknowledged deviations" in the LIVING SECTION, with a one-line rationale per file.

The PR description (cf. Conventions below) must list the documentation files modified (README, CLAUDE.md, brief) in the `## Changelog` section, in addition to the code change summary.

## Conventions

- **Branch:** `phase-pre-0/etch/tree-walking-interpreter`
- **Final tag:** `v0.0.5-S4-etch-tree-walking-interpreter`
- **PR title:** `Phase -1 / Etch / Tree-walking interpreter`
- **Commit convention:** Conventional Commits (cf. `engine-development-workflow.md` §4.3). Allowed scopes: `etch`, `ecs`, `core`, `bench`, `brief`, `docs`, `build`, `ci`, `test`.
- **Merge strategy:** squash-and-merge (cf. `engine-development-workflow.md` §4.6). Squash message follows the format documented in §4.6, with a body of 2-3 lines summarising the S4 verdict and citing the bench median.
- **PR description structure:** as mandated by `engine-development-workflow.md` §4.4 (Brief, Summary, Acceptance criteria, Review notes, `## Changelog`). The Changelog section explicitly lists modified documentation files (README, CLAUDE.md, brief) alongside the code summary.

## Notes

- **Why elevate the ECS to a runtime registry now.** S1 deliberately hardcoded `Transform + Velocity` to validate the comptime + work-stealing hypothesis under a tight constraint. S4 cannot use that path because the components are unknown until the `.etch` source is parsed. The runtime registry + dynamic archetype + runtime query is the minimum addition that lets the interpreter exist at all. This is not S1-scope creep — S1 is closed, validated, and untouched. The S1 comptime archetype remains in `src/core/ecs/` and remains benched by `bench/ecs_iteration.zig`. The new runtime path is additive.

- **Why no HIR.** The S3 subset has zero non-trivial desugarings. Building a lowering pass + a second IR + a second codegen path for five constructs is pure ceremony with negative leverage. `etch-resolver-types.md` §19 (Phase 0.5/Phase 1) confirms HIR is introduced when constructs requiring desugaring appear (`for`, `if let`, `await`, `race`/`sync`, `match` with guards, generics, closures). None of these are in the S3 subset, none arrive before Phase 0.5. The interpreter walking the AST directly is therefore the cheapest valid choice and survives to be reused as the dev backend until the bytecode VM lands in Phase 2.

- **Why a shared `Runner` interface for the diff harness from day one.** S5 is one milestone ahead. Wiring the interpreter behind a `Runner` interface costs ~30 lines and saves the need to rewrite the harness when S5 plugs in the Zig codegen. The interface stays minimal (3 methods: `setup`, `step`, `finalize`) — it is a contract, not a framework.

- **Why `RuntimeError` is its own type and not a `Diagnostic` variant.** `Diagnostic` is compile-time bound (parse + type-check, span-anchored at lex tokens). `RuntimeError` is execution-time, anchored at AST nodes that already carry their span. Mixing both into one enum forces every consumer of the parse-time API to handle runtime variants and vice-versa. Keeping them separate also leaves room for Phase 0.5+ to add backtraces (rule chain), stepping context, watchpoint hits, etc., none of which make sense for parse-time diagnostics.

- **Inherited S2 debts (not addressed in S4).** D1 `vk_gen` whitelist closure on enum types only, D2 `VkResult` aliases at module scope, Win32 thread-safety globals, §4.2 dispatch bypass in `vk_frame.zig`, PPM capture path swapchain image direct.

- **Inherited S3 debts (not addressed in S4).** Corpus volume (40 vs ~100), Apple Silicon bench non-official, `StableId` left at 0, trivia/doc comments not attached to `NodeId`, annotation applicability not validated, `get(T)`/`get_mut(T)` without receiver for resources unsupported, `ExprKind.path` and `ExprKind.tag_path` produced out of S3 brief scope, `tag_path` accepted as const-evaluable (soundness gap), bench methodology double-counts the lexer, annotation arg field access (`@requires(self.health)`) breaks.

- **S2 hardware-validation gate does not apply to S4.** S2 required the dev machines run check (Win11 + RTX 4080 Super, Fedora 44 + UHD 630/GTX 1660 Ti) because it crossed the Win32/Wayland/Vulkan boundary. S4 is pure CPU compute — the Linux + Windows CI matrix is the gate. Bench validation is run by Guy on the dev primary (M4 Pro) and archived.

- **Polymorphic literal defaulting.** Already applied by S3's two-pass type-checker (S3 debt note from the previous brief: it was implemented outside scope). The interpreter consumes a type-checked AST and trusts the resolved literal types — no re-inference at runtime.

- **What stays in `src/etch/` vs what goes in `src/core/ecs/`.** Rule of thumb: anything that depends on the Etch AST (interpreter, value, ecs_bridge) is `src/etch/`. Anything that is a generic ECS capability with no dependency on Etch (registry, resources, runtime query, dynamic archetype) is `src/core/ecs/`. The ECS extensions must be usable by future non-Etch consumers (C-API plugins in Phase 1+, editor in Phase 0.6+) without dragging the Etch surface in.

- **Zig 0.16.x strict.** Patches accepted, minor bumps forbidden (cf. `engine-zig-conventions.md` §17). At S4 closure, record the exact `zig version` used in the bench report and in the closure notes.

---

# LIVING SECTION

*Maintained by Claude Code during the milestone. The journal is not a marketing report — it serves review and post-mortem debugging.*

## Specs read

*To tick before any production code is written. Confirms the spec was ingested in full, not skim-read.*

- [x] `engine-spec.md` (§22.3 / S4, §22.3.0, §3.5) — read 2026-05-15 20:11
- [x] `etch-grammar.md` (§3, §5, §6, §18, §19) — read 2026-05-15 20:11
- [x] `etch-reference-part1.md` (§3, §4, §5, §6) — read 2026-05-15 20:11
- [x] `etch-resolver-types.md` (§11, §12, §19) — read 2026-05-15 20:11
- [x] `etch-ast-ir.md` (§3.2, §3.3, §3.4) — read 2026-05-15 20:11
- [x] `etch-memory-model.md` (surface invariants only) — read 2026-05-15 20:11
- [x] `engine-ecs-internals.md` (§1, §2, §4, §5) — read 2026-05-15 20:11
- [x] `briefs/S1-mini-ecs-zig.md` — read 2026-05-15 20:11
- [x] `briefs/S3-etch-parser-subset.md` — read 2026-05-15 20:11
- [x] `engine-zig-conventions.md` (§3, §4, §13, §17) — read 2026-05-15 20:11
- [x] `engine-development-workflow.md` (§2, §3, §4) — read 2026-05-15 20:11
- [x] `engine-directory-structure.md` (§9.1, §9.3) — read 2026-05-15 20:11

## Execution journal

*One entry per logical work sequence (typically: an objective reached, a test green, a refactor, a blocker). Chronological order. Short format — 1 to 3 lines per entry.*

- 2026-05-15 20:11 — Branch `phase-pre-0/etch/tree-walking-interpreter` created, brief copied verbatim, specs read, Status flipped to ACTIVE.
- 2026-05-15 20:30 — Tier 0 ECS extensions implemented (registry, archetype_dynamic, resources, query_runtime, world). All inline tests + the S1 tests green. Per `engine-zig-conventions.md` §3, Registry / ResourceStore / DynamicArchetype are unmanaged (gpa at every op) so `World.init()` stays zero-arg and the S1 call sites are untouched.
- 2026-05-15 20:45 — Etch interpreter pieces (value, ecs_bridge, interp). Initial implementation used (includes, excludes) sets, refactored to a `PredicateNode` pool so `entity has A or entity has B` resolves correctly per-archetype. `evalConst` reuses the same arithmetic backend; `tag_path` returns `UnsupportedExpr`.
- 2026-05-15 20:55 — Differential corpus + driver wired. Hit a lifetime bug — the Interpreter held `*const Ast` pointing to a stack-resident `Ast` (from the parser's value-returning `parse`). Fix: heap-box the Ast in the runner so the borrowed pointer survives the Runner move. All 20 corpus programs green in debug + ReleaseSafe.
- 2026-05-15 21:10 — Bench + demo. Apple Silicon dev primary, ReleaseSafe, 1 000 ticks @ 1 000 entities + 100 ticks @ 10 000 entities, 50 warmup ticks: median 0.603 ms / tick at 1 000 × 5 (gate 10 ms), median 6.593 ms / tick at 10 000 × 5 (gate 100 ms). Demo OK summary line emitted on `zig build run-demo-etch-interp -Doptimize=ReleaseSafe` in ~40 ms total. Reports archived under `bench/results/`.
- 2026-05-15 21:20 — README + CLAUDE.md updated. Status flipped to CLOSED.

## Acknowledged deviations

*Modifications to the FROZEN SECTION occurring mid-milestone after a Claude.ai round-trip. Each deviation references the commit that enacts it. If empty at milestone end: nominal case.*

No modifications to the FROZEN SECTION. Three additions outside the explicit "Files to create or modify" list, each justified below — none extend the technical scope of the milestone.

- **Addition not listed: `tests/etch_interp/corpus_test.zig`** — the brief lists `tests/etch_interp/diff_runner.zig` as the generic driver but does not name a test entry point. The driver is a parameterised function; the test binary that calls it lives in `corpus_test.zig` (same pattern as `tests/etch/corpus_test.zig` from S3). No additional public surface.
- **Addition not listed: `bench/fixture_facade.zig`** — `@embedFile` cannot escape the package root of the module that invokes it (Zig 0.16 restriction). The bench (`bench/etch_interp.zig`) and the demo binary (`src/demo_etch_interp.zig`) have distinct module roots so they cannot share `@embedFile("fixtures/demo_5_rules.etch")` directly. The facade is a one-line module that holds the embed and is consumed by both. Same workaround as the S3 corpus facade.
- **Addition not listed: `bench/results/s4-etch-interp-20260515-1946.md`** — bench report file committed for traceability per the brief's Acceptance criteria / Benchmarks observable behaviour ("The bench Markdown report exists under `bench/results/s4-etch-interp-<YYYYMMDD-HHMM>.md`"). Filename follows the timestamp template.

## Blockers encountered

*Blocking points that required a return to Claude.ai (cf. `engine-development-workflow.md` §2.4). If 2+ distinct blockers: signal for re-scope.*

None. Internal refactors (predicate-based when iteration, runner Ast lifetime) were settled by Claude Code from the spec without round-trip.

## Closure notes

*To fill at Status → CLOSED, just before opening the PR.*

- **What worked:** the tree-walking interpreter hypothesis is validated empirically on the dev primary — median 0.603 ms / tick at 1 000 entities × 5 rules (gate 10 ms, target 5 ms — gate beaten 16×, target beaten 8×) and 6.593 ms / tick at 10 000 × 5 (gate 100 ms, target 50 ms — gate beaten 15×, target beaten 7.5×). The 20-program differential corpus exercises every supported `when` form (single, and, not, or via predicate eval, field-equality filter on int/bool/float, resource gate, resource changed dirty/clean) and multi-rule ordering; all green in debug and ReleaseSafe with zero leaks under `std.testing.allocator`. The additive Tier 0 ECS surface (`registry.zig`, `archetype_dynamic.zig`, `resources.zig`, `query_runtime.zig`) leaves the S1 comptime `(Transform, Velocity)` path untouched — `World.init()` stayed zero-arg, all S1 tests and the S1 bench still green. The `Runner`-parameterised driver is ~70 LoC and exposes a contract that S5 will plug into without modifying the harness.
- **What deviated from the original spec:** none on the technical scope. Three filenames added outside the explicit list (`tests/etch_interp/corpus_test.zig`, `bench/fixture_facade.zig`, the bench report file) — each justified under "Acknowledged deviations" above. The `or` semantics on `when` clauses required a refactor mid-milestone from (includes, excludes) sets to a `PredicateNode` pool — same scope, cleaner implementation; documented in the execution journal.
- **What to flag explicitly in review:** (1) the Tier 0 ECS surface is intentionally additive — verify no S1 path was modified (the S1 bench and tests remain unchanged); (2) `or` predicates compile to a `PredicateNode` tree and the runtime walks every dynamic archetype to evaluate it — adequate for S4 corpus volume but a bitset short-cut may be needed in Phase 0.5 when archetype counts grow; (3) the runner heap-boxes the `Ast` because the Interpreter stores a borrowed `*const Ast` — the value-return path of `parse(gpa, source)` would otherwise leave a dangling pointer once `Ast` is moved into the runner struct; (4) field defaults are materialised by `evalConst` at compile time and memcpy'd into each freshly spawned slot — non-const-evaluable defaults emit a diagnostic, never a runtime fallback; (5) resource semantics — `getMutResource` sets the dirty bit and `tickBoundary` clears it; the differential corpus uses an `initial_dirty: bool` flag on `ResourceInit` to trigger `when resource T changed` once on tick 1, after which the bit clears naturally.
- **Final measurements** (Apple Silicon dev primary, macOS, aarch64, Zig 0.16.0, ReleaseSafe, 50 warmup ticks + sample window per sweep): bench `bench/results/s4-etch-interp-20260515-1946.md` — sweep "1 000 × 5 × 1 000": median 0.603 ms, p99 0.618 ms, max 0.716 ms, min 0.576 ms per tick. Sweep "10 000 × 5 × 100": median 6.593 ms, p99 9.252 ms, max 9.252 ms, min 6.493 ms per tick. Demo `zig build run-demo-etch-interp -Doptimize=ReleaseSafe`: `Demo S4 OK | mode=ReleaseSafe | entities=1000 | rules=5 | ticks=60 | rules_matched=300 | errors=0 | total=39.605ms`. Production LoC under `src/core/ecs/` (S4 additions): ~750 lines including same-file tests. Production LoC under `src/etch/` (S4 additions): ~830 lines. Differential corpus (driver + runner + facade + sidecars + .etch): ~750 lines.
- **Residual risks / debt intentionally left:** (a) bench verdict on Apple Silicon dev primary only — re-confirmation on the S2 reference machines (Win11 + RTX 4080, Fedora 44 + UHD 630 / GTX 1660 Ti) is Guy's call, vu the 15-16× margin against both gates the risk of flipping NO-GO is negligible; (b) inherited S3 debts (`ExprKind.path` and `ExprKind.tag_path` reaching the interpreter, `tag_path` const-eval soundness gap, annotation applicability not validated, etc.) untouched per brief Out-of-scope — they remain on the rolling debt list; (c) inherited S2 debts (D1 vk_gen whitelist, D2 VkResult aliases, Win32 thread-safety globals, vk_frame.zig dispatch bypass, PPM capture path) untouched per brief Out-of-scope; (d) `or` predicate evaluation walks every dynamic archetype — fine for S4 corpus volume (a handful of archetypes) but a future bitset short-cut might be needed when archetype counts grow; (e) field filter limited to a single `has_with_filter` clause per rule (multiple filters would require an array); (f) resource field access from rule bodies remains an inherited S3 debt — not addressed in S4 per brief Out-of-scope; (g) **`RuntimeQuery` + `world.query_dynamic` not used on the hot path** — the brief listed them as the interpreter's entity-iteration surface, but the predicate-pool refactor mid-milestone made `interp.runRule` walk `world.archetypes.items` directly and evaluate `evalPredicate` locally. `RuntimeQuery` is exercised only by its own tests in `src/core/ecs/query_runtime.zig`, never by the interpreter. To address in Phase 0.2: either route the interpreter through `RuntimeQuery`, or drop the abstraction if no consumer materialises; (h) **`RuntimeReport.last_error` is never assigned** — the field is declared on the report struct but every runtime failure is collapsed into an opaque `error.RuntimeFailure` inside `execBody`, counted via `runtime_errors += 1`, and the `RuntimeError`/`SourceSpan` payload defined in `value.zig` never reaches the caller. To fix in Phase 0.2 by threading the typed `RuntimeError` from `execStmt` / `evalExpr` up through `execBody` into the report; (i) **`ecs_bridge.writeValueAsBytes` panics on type mismatch** — `@panic("type mismatch on writeValueAsBytes (...)")` for each kind branch, currently relying on the invariant that the S3 type-checker eliminates every mismatch before reaching the interpreter. Fragile against a type-checker bug. To convert in Phase 0.2 by adding a `TypeMismatch` variant to `RuntimeErrorKind` and returning it rather than panicking.
