# S1 — Mini-ECS Zig

> **Status:** PLANNED
> **Phase:** -1
> **Branch:** `phase-pre-0/core/mini-ecs`
> **Planned tag:** `v0.0.2-S1-mini-ecs`
> **Dependencies:** S0 (`v0.0.1-S0-bootstrap`)
> **Open date:** 2026-05-08
> **Close date:** —

---

# FROZEN SECTION

*Produced by Claude.ai. Not editable by Claude Code outside a Claude.ai round-trip (see § Acted deviations).*

## Context

Second spike of Phase −1. Validates the core architectural hypothesis of Weld's ECS: that Zig `comptime` query generation combined with a Chase-Lev work-stealing scheduler can iterate 100 000 entities of a single archetype in under 1 ms in `ReleaseSafe`. The code produced here is not throwaway — its architecture is reused in Phase 0.1 (the bench file evolves into `bench/ecs_benchmark.zig`, referenced by Phase 0 criterion C0.1 and by the Phase 0/1 non-regression gates). Out of scope: anything beyond the minimum needed to validate the hypothesis.

## Scope

- Generic comptime archetype storage in `src/core/ecs/`, with a 16 KiB Chunk laid out SoA per component (one contiguous array per component type, 16-byte aligned for SIMD), one entity-id array, and a header limited to `entity_count`, `capacity`, `archetype_id`, `next_chunk` pointer, and `component_offsets[C]`. Single archetype `(Transform, Velocity)` instantiated at runtime; the Archetype type itself is comptime-generic over the component tuple.
- Single comptime-generated query `(*const Transform, *Velocity)` over that archetype, body limited to `pos += vel * dt` (plus a constant-gravity tweak so Velocity is touched). No filters, no exclusions, no multi-archetype.
- Job system in `src/core/jobs/` consisting of a Chase-Lev work-stealing deque per worker, a fixed pool of 4 worker threads, and a single scheduler entry point that splits a query over chunks and waits for completion. No DAG, no phases, no priorities.
- Counting allocator wrapper in `src/core/testing/` that records alloc and free counts during a measured window; used by the no-allocation test and by the bench harness.
- Bench harness at `bench/ecs_iteration.zig` driving 100 000 entities × 1000 measured iterations after 100 warm-up iterations. Output is a single Markdown report at `zig-out/bench/ecs_iteration.md` containing: machine config (CPU model, core count, RAM, OS, Zig version), build mode, per-mode timing distribution (min, median, mean, p95, max), per-worker statistics (chunks processed, steal attempts, steal successes, worker total duration), load imbalance percentage, and a GO/NO-GO verdict against the 1.0 ms median ReleaseSafe gate.
- Extension of `src/main.zig` so that `zig build run` prints `Weld bootstrap OK + ECS spike OK ({mode}, {N} workers)` after spawning a small world and running one iteration of the query.
- New `zig build bench-ecs` step in `build.zig` that compiles and runs the bench harness, plus a `--smoke` flag that runs a single short iteration (used only to gate compilation in CI).
- New CI job `bench-ecs-smoke` running `zig build bench-ecs -- --smoke` in ReleaseSafe on the existing `{ubuntu-24.04, windows-2025}` matrix. Compile-only sanity. No perf gate in CI.

## Out-of-scope

- Multi-archetype queries.
- Query filters (`With`, `Without`, `Changed`, predicate-based).
- Component exclusions.
- Sparse-set storage.
- Tick-based change detection (no `added_ticks`, no `changed_ticks`, no `dirty_bitset` in the chunk).
- Archetype transitions cache (no `add` / `remove` of components after spawn).
- Observers (`on_add`, `on_remove`, `on_spawn`, `on_despawn`).
- Command buffers (deferred mutations).
- Resources / singleton entities.
- Cells / streaming.
- Etch bridge (covered by S4).
- Variable worker count (4 is fixed in S1; parameterisation is Phase 0.1).
- DAG scheduler / system graph (one job at a time in S1).
- Priorities, phases, `wait_all` over heterogeneous job sets.
- Tracy or any third-party profiler integration.
- macOS in the CI matrix.
- Generational indices, FreeList, EntityIndex sophistication beyond what is strictly needed to spawn 100 000 entities and iterate them once per frame.
- RTTI / component registry beyond a comptime ID per component type.

## Documents to read first

1. `engine-spec.md` — §2 (ECS overview), §3.5 (in-tree extraction criterion), §22.3.0 sub-section S1 (canonical milestone definition).
2. `engine-ecs-internals.md` — §1 (architecture overview), §2 (chunk SoA layout), §4 (query compilation), §12 (comparison with other ECS).
3. `engine-zig-conventions.md` — full read; in particular naming, allocator passing, `extern struct` POD components, doc comments on public API, ban on `@cImport` outside `*_c` modules and on `usingnamespace`.
4. `engine-development-workflow.md` — §2 (milestone model), §3 (brief format), §4 (git conventions, hooks, squash-merge), §5 (Claude review cycle).
5. `engine-directory-structure.md` — for placement of new files under `src/core/`.

## Files to create or modify

- `src/core/jobs/scheduler.zig` — create — public scheduler API (entry point that splits a query over chunks, dispatches to workers, waits for completion).
- `src/core/jobs/worker.zig` — create — worker thread loop (pop local, steal remote, execute, repeat).
- `src/core/jobs/deque.zig` — create — Chase-Lev work-stealing deque.
- `src/core/ecs/world.zig` — create — root `World` struct, owns archetypes, exposes `spawn` / `query`.
- `src/core/ecs/archetype.zig` — create — comptime-generic archetype storage parameterised over a component tuple.
- `src/core/ecs/chunk.zig` — create — 16 KiB chunk with SoA per-component layout, header as specified in Scope.
- `src/core/ecs/query.zig` — create — comptime query generator that returns an iterable parallelisable by the scheduler.
- `src/core/ecs/components.zig` — create — `Transform` and `Velocity` POD `extern struct` definitions (fields locked once chosen, recorded in the journal).
- `src/core/testing/alloc_counting.zig` — create — counting allocator wrapper that records alloc/free counts; reusable in Phase 0 non-regression tests.
- `bench/ecs_iteration.zig` — create — bench harness, produces the Markdown report.
- `tests/ecs/world_test.zig` — create — spawn / despawn / leak checks.
- `tests/ecs/chunk_test.zig` — create — chunk size, alignment, capacity computation.
- `tests/ecs/query_test.zig` — create — iteration correctness, mutation persistence.
- `tests/ecs/no_alloc_in_simulation_test.zig` — create — counting-allocator-based assertion of zero allocation post-init over 1000 iterations.
- `tests/jobs/deque_test.zig` — create — deque LIFO/FIFO semantics, concurrent steal correctness.
- `tests/jobs/scheduler_test.zig` — create — full dispatch coverage, completion semantics.
- `src/main.zig` — edit — extend the smoke output as specified in Scope.
- `build.zig` — edit — add `bench-ecs` build step, expose `--smoke` flag, declare new modules.
- `build.zig.zon` — edit — only if new module declarations are required by the chosen build layout.
- `.github/workflows/ci.yml` — edit — add the `bench-ecs-smoke` job.
- `README.md` — edit — short paragraph noting the ECS spike availability and how to run the bench locally.

## Acceptance criteria

### Tests

- `tests/ecs/world_test.zig` — `test "spawn and despawn 100k entities without leak"` — uses `std.testing.allocator`, spawns 100 000 entities of `(Transform, Velocity)`, despawns them, asserts no leak.
- `tests/ecs/chunk_test.zig` — `test "chunk total size is 16 KiB"` — asserts chunk byte size equals 16 384.
- `tests/ecs/chunk_test.zig` — `test "per-component arrays are 16-byte aligned within chunk"` — asserts every component array start address modulo 16 equals 0.
- `tests/ecs/chunk_test.zig` — `test "chunk capacity matches manual computation for (Transform, Velocity)"` — asserts the capacity formula based on component sizes returns the expected value (recorded in the test as a constant once measured).
- `tests/ecs/query_test.zig` — `test "query visits every spawned entity exactly once"` — spawns N entities, runs the query with a counter side-effect, asserts counter equals N.
- `tests/ecs/query_test.zig` — `test "writes through query persist across iterations"` — writes a known value via the query, reads it back next iteration, asserts equality.
- `tests/ecs/no_alloc_in_simulation_test.zig` — `test "1000 query iterations allocate zero bytes after init"` — installs the counting allocator after spawn, runs 1000 iterations, asserts alloc count and free count both equal zero in the measurement window.
- `tests/jobs/deque_test.zig` — `test "owner push and pop are LIFO"` — single-threaded sanity.
- `tests/jobs/deque_test.zig` — `test "concurrent steal: every element is consumed exactly once"` — one owner pushes N items, three stealers race, the union of consumed items equals the pushed set, no item consumed twice.
- `tests/jobs/scheduler_test.zig` — `test "split-over-chunks dispatch covers every chunk"` — dispatches a no-op job, asserts every chunk's `arch_id` and chunk index are visited.
- `tests/jobs/scheduler_test.zig` — `test "scheduler returns only after all work is done"` — no spurious early return.
- All tests green in `Debug` and `ReleaseSafe`.
- All tests use `std.testing.allocator`.

### Benchmarks

- `bench/ecs_iteration.zig` — query iteration over 100 000 entities of archetype `(Transform, Velocity)` with body `vel.linear.y -= 9.81 * dt; pos += vel.linear * dt` (or equivalent simple integration; exact body locked in the journal once chosen and reused for every measurement).
- Primary gate: median iteration time ≤ 1.0 ms in `ReleaseSafe` on Guy's primary dev machine (MacBook Pro M4 Pro, 48 GB RAM), measured over 1000 iterations after 100 warm-up iterations.
- Secondary target (non-blocking, recorded only): median ≤ 0.5 ms.
- Load imbalance across workers ≤ 15 %, computed as `(max_worker_duration - min_worker_duration) / mean_worker_duration` over the same 1000 iterations.
- The bench writes a single Markdown report at `zig-out/bench/ecs_iteration.md` with: machine config (`os.uname` + CPU brand string + core count + RAM), Zig version, build mode, distribution table (min, median, mean, p95, max) per mode, per-worker stats table, load imbalance percentage, and a final GO/NO-GO verdict line.

### Observable behaviour

- `zig build run` outputs `Weld bootstrap OK + ECS spike OK (Debug, 4 workers)` (or `ReleaseSafe` accordingly), followed by exit code 0. No panic, no error.
- `zig build bench-ecs` produces `zig-out/bench/ecs_iteration.md`. The file is human-readable and contains every field listed under Benchmarks.
- The Markdown report's verdict line on Guy's primary dev machine reads `GO` for the ReleaseSafe gate.

### CI

- `zig build` clean, zero warnings, on `ubuntu-24.04` × `windows-2025` × `{Debug, ReleaseSafe}`.
- `zig build test` green on the full matrix.
- `zig fmt --check` green.
- `commit-msg` hook green on every commit of the branch.
- New job `bench-ecs-smoke` runs `zig build bench-ecs -- --smoke` in `ReleaseSafe` on both OS; passes if compilation succeeds and the smoke run exits 0.

## Conventions

- **Branch:** `phase-pre-0/core/mini-ecs`
- **Final tag:** `v0.0.2-S1-mini-ecs`
- **PR title:** `Phase -1 / Core / Mini-ECS Zig`
- **Commit convention:** Conventional Commits (cf. `engine-development-workflow.md` §4.3). Allowed scopes for this milestone: `ecs`, `jobs`, `bench`, `ci`, `build`, `docs`.
- **Merge strategy:** squash-and-merge (cf. `engine-development-workflow.md` §4.6). The squash message follows the example in §4.6, e.g. `feat(core): mini-ECS spike (Chase-Lev jobs + comptime SoA archetype)`.

## Notes

- The `comptime` + work-stealing hypothesis is exactly what S1 exists to test. A single-threaded fallback is therefore not implemented — falling back would invalidate the experiment. If the hypothesis fails, that is a Claude.ai outcome, not a runtime fallback.
- The chunk header is intentionally minimal. Tick arrays, dirty bitset, and the transitions cache come in Phase 0.1; their absence here is purely additive — adding them later relayouts the header offsets without breaking the public API. This is consistent with the Weld design rule on deferring decisions only when the deferral is purely additive.
- Component layout: `Transform` and `Velocity` are `extern struct` POD per `engine-zig-conventions.md`. The exact fields are not pre-decided — pick the simplest fields that fit the iteration body, lock them in the first commit that touches `components.zig`, and record the lock in the journal. Suggested baseline: `Transform { pos: [3]f32, _pad0: f32, rot: [4]f32, scale: [3]f32, _pad1: f32 }` and `Velocity { linear: [3]f32, _pad0: f32, angular: [3]f32, _pad1: f32 }` (16-byte aligned), but the chosen layout must be justified once.
- ABA mitigation in the Chase-Lev deque: tagged pointers, sequence counters, or any equivalent technique idiomatic in Zig 0.16.x. The choice is recorded in the journal and in a doc comment on `deque.zig`.
- Worker thread count is hardcoded to 4 in S1. Do not parameterise. Phase 0.1 will introduce CPU-topology-driven sizing.
- The bench is committed and becomes the ECS perf baseline; in Phase 0.1 it is renamed/extended into `bench/ecs_benchmark.zig` (the file referenced by C0.1 and by the non-regression gates of Phase 0/1).
- The bench gate runs on Guy's primary dev workstation: **MacBook Pro M4 Pro, 48 GB RAM, macOS**. CI runners do not gate perf — only the `--smoke` compile-and-run sanity is gated in CI. The bench Markdown report records the machine config (`os.uname` + CPU brand + core count + RAM) so future runs on the same machine remain comparable.
- Out-of-scope items remain out-of-scope **even when adding them looks cheap**. The whole reason this milestone is a spike is to isolate one hypothesis. Any temptation to add a SparseSet, a filter, or change detection is a Claude.ai round-trip, not a unilateral extension.

---

# LIVING SECTION

*Maintained by Claude Code during the milestone. Not a marketing summary — exists for review and post-mortem debug.*

## Specs read

*To check before any production code is written. Confirms the spec was ingested in full, not skimmed.*

- [x] `engine-spec.md` (§2, §3.5, §22.3.0 sub-section S1) — read 2026-05-09 02:34
- [x] `engine-ecs-internals.md` (§1, §2, §4, §12) — read 2026-05-09 02:34
- [x] `engine-zig-conventions.md` (full) — read 2026-05-09 02:34
- [x] `engine-development-workflow.md` (§2, §3, §4, §5) — read 2026-05-09 02:34
- [x] `engine-directory-structure.md` — read 2026-05-09 02:34

## Execution journal

*One entry per logical work sequence (objective reached, test green, blocker hit). Chronological. Short — one to three lines per entry.*

- <YYYY-MM-DD HH:MM> — <summary>

## Acted deviations

*Modifications to the FROZEN section made during the milestone after a Claude.ai round-trip. Each deviation references the commit that records it. Empty at close = nominal case.*

- <commit SHA> — <deviation summary and reason>

## Blockers encountered

*Blocking points that required a return to Claude.ai (cf. `engine-development-workflow.md` §2.4). Two or more distinct blockers = re-scope signal.*

- <blocker summary> — resolved by <commit SHA> or <reference to the Claude.ai conversation>

## Closing notes

*Filled in at Status → CLOSED, just before opening the PR.*

- **What worked:**
- **What deviated from the original spec:**
- **What to flag explicitly in review:**
- **Final measurements** (perf, binary size, compile time, anything relevant to this milestone):
- **Residual risks / technical debt left intentionally:**
