# S5 — GO / NO-GO verdict

> **Milestone:** S5 — Etch → Zig codegen and compile-time measurement
> **Branch:** `phase-pre-0/etch/codegen-zig`
> **Date:** 2026-05-17 (re-issued after review fixes)
> **Status:** GO (5/5 gates green)

## Per-gate verdict

| # | Gate | Threshold | Measured | Verdict | Source |
|---|---|---|---|---|---|
| 1 | Cold compilation (a + b) | < 30 s | 1104.5 ms (median, N=10) | **GO** | `bench/results/S5-codegen-zig.md` |
| 2 | Incremental compilation (a + c) | < 2 s | 1066.2 ms (median, N=10) | **GO** | `bench/results/S5-codegen-zig.md` |
| 3 | Zero leak | `std.testing.allocator` green on full test + bench | 90/92 pass (2 skipped, no leak) | **GO** | `zig build test --summary all` |
| 4 | Monomorphisation contained | ≤ 4 × distinct archetype signatures | **382 distinct `comptime_query.query` instantiations** over 400 rules / 382 signatures (ceiling 4× = 1528) | **GO** | `bench/results/S5-codegen-zig.md` |
| 5 | Differential parity | 20/20 corpus, codegen ≡ interpreter | 20/20 via `zig build test-codegen-diff` + parity test | **GO** | `tests/etch_interp/codegen_diff_test.zig`, `codegen_parity_test.zig` |

## Bench summary (Apple Silicon dev primary, macOS, aarch64, ReleaseSafe, N=10)

| Metric | Median | Mean | StdDev | p99 | Max |
|---|---|---|---|---|---|
| (a) codegen only | 17.264 ms | 29.524 ms | 37.518 ms | 141.959 ms | 141.959 ms |
| (b) cold `zig build-exe` | 1087.206 ms | 1086.010 ms | 62.803 ms | 1198.120 ms | 1198.120 ms |
| (c) incremental `zig build-exe` | 1048.951 ms | 1058.578 ms | 29.631 ms | 1132.060 ms | 1132.060 ms |

Cold gate (a)+(b) = 1104.5 ms vs 30 000 ms (27× margin).
Incremental gate (a)+(c) = 1066.2 ms vs 2 000 ms (1.9× margin).

## Monomorphisation note (Gate 4)

The S5 codegen lowers each Etch `rule` to a Zig function that opens a
`comptime_query.query(world, .{T1, T2, ...})` iteration over the dynamic
archetype storage. The tuple is the comptime list of component types
referenced in the rule's `when` clause's AND-conjunction. Zig comptime
monomorphises one `ComptimeQuery` iterator type per distinct tuple
across the cooked corpus.

On the 100-file synthetic corpus (400 total rules) the cook produces
**382 distinct query instantiations** — one per distinct rule signature
(some signatures recur across rules that happen to pick the same
component subset). The gate's hard ceiling is `4 × 382 = 1528`; the
codegen emits exactly one instantiation per signature by construction,
so the ratio is 1× — well within bound.

The 2/20 differential corpus programs containing `or` / `not` (S4
inherited debts) fall back to the manual archetype walk path, which
does not produce comptime instantiations. They are still tested for
behavioural parity but contribute zero to the monomorphisation count.

## Registry name↔Zig-type aliasing

For the `comptime_query.query(world, .{Cmp})` path to coexist with the
differential corpus's `world.spawnDynamic(gpa, &.{world.registry.idOf("Cmp").?})`
spawn path, both must resolve to the same `ComponentId`. The cooked
`register()` function calls `world.registry.registerComponentRaw` with
the explicit Etch name, then immediately
`world.registry.registerAlias(gpa, @typeName(Cmp), id)` so the same
component is reachable by both keys. Tested in
`src/core/ecs/registry.zig` and via the differential corpus tests.

## Observable behaviour

- `zig build run-demo-etch-codegen`: produces `Demo S5 OK | ticks=10 …`
  matching `bench/fixtures/demo_5_rules_codegen.expected.txt` byte-for-byte.
- `zig build bench-etch-compile`: prints the 3-metric summary and writes
  `bench/results/S5-codegen-zig.md`.
- `zig build test-codegen-diff`: 20/20 corpus pass via the cooked runner
  (interpreter parity verified by `codegen_parity_test`).
- `zig build test`: 90/92 pass (2 Windows-only skipped), no leak under
  `std.testing.allocator`, both Debug and ReleaseSafe.

## CI

- `zig build` clean on the existing Ubuntu 24.04 + Windows 2025 matrix
  (carried over from S4 — no CI workflow changes in this milestone).
- `zig fmt --check` clean across hand-written sources (generated
  cooked.zig is under `zig-out/etch-bench/`, excluded by `.gitignore`).
- `zig build lint` not present at the time of the milestone (deferred
  per the post-S1 lint milestone note in `engine-phase-minus-1-archive.md` S0).
- `commit-msg` hook green on every commit of the branch (Conventional
  Commits).

## Verdict

**GO** on all five spec gates. The S5 hypothesis ("Etch → Zig codegen
viable build-time-wise") is **validated** on the Apple Silicon dev
primary with the comptime monomorphisation path exercised
(382 distinct query instantiations measured, gate ceiling 1528). The
20-program differential corpus reaches byte-exact parity with the S4
interpreter. Re-confirmation on the Win11 + Fedora 44 reference
machines is deferred to Phase 0.2 alongside the S3 / S4 bench-
confirmation debts.
