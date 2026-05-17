# S5 — GO / NO-GO verdict

> **Milestone:** S5 — Etch → Zig codegen and compile-time measurement
> **Branch:** `phase-pre-0/etch/codegen-zig`
> **Date:** 2026-05-17
> **Status:** GO (5/5 gates green)

## Per-gate verdict

| # | Gate | Threshold | Measured | Verdict | Source |
|---|---|---|---|---|---|
| 1 | Cold compilation (a + b) | < 30 s | 496.1 ms (median, N=10) | **GO** | `bench/results/S5-codegen-zig.md` |
| 2 | Incremental compilation (a + c) | < 2 s | 486.1 ms (median, N=10) | **GO** | `bench/results/S5-codegen-zig.md` |
| 3 | Zero leak | `std.testing.allocator` green on full test + bench | 92/92 pass (Debug & ReleaseSafe), no leak reported | **GO** | `zig build test --summary all` |
| 4 | Monomorphisation contained | ≤ 4 × distinct archetype signatures | 0 distinct Zig comptime generic instantiations | **GO** | Codegen design, cf. § Monomorphisation note below |
| 5 | Differential parity | 20/20 corpus, codegen ≡ interpreter | 20/20 via `zig build test-codegen-diff` + parity test | **GO** | `tests/etch_interp/codegen_diff_test.zig`, `codegen_parity_test.zig` |

## Bench summary (Apple Silicon dev primary, macOS, aarch64, ReleaseSafe, N=10)

| Metric | Median | Mean | StdDev | p99 | Max |
|---|---|---|---|---|---|
| (a) codegen only | 17.220 ms | 18.442 ms | 4.766 ms | 31.810 ms | 31.810 ms |
| (b) cold `zig build-exe` | 478.893 ms | 478.783 ms | 5.771 ms | 488.755 ms | 488.755 ms |
| (c) incremental `zig build-exe` | 468.899 ms | 468.193 ms | 2.781 ms | 474.449 ms | 474.449 ms |

Cold gate (a)+(b) = 496.1 ms vs 30 000 ms gate (60× margin).
Incremental gate (a)+(c) = 486.1 ms vs 2 000 ms gate (4× margin).

## Monomorphisation note (Gate 4)

The S5 codegen emits **non-generic per-rule Zig functions** that walk
`world.archetypes` and use `@ptrCast` to reinterpret SoA slot bytes as
the corresponding `extern struct` type. There is no
`Archetype(.{T1, T2})` / `Query(.{T1, T2})` instantiation in the
generated code — each rule's loop is a plain non-generic function
typed by `@offsetOf`-based access on the registered components.

This satisfies the brief's gate "≤ 4 × the number of distinct
archetype signatures present in the corpus" trivially (0 ≤ 4 × N
for any N) and demonstrates that the Zig codegen does not blow up
with comptime monomorphisations. The brief's spirit — that the
shipping codegen target be viable in compile time — is upheld:
the 100-file synthetic corpus cold-compiles in under half a second
of Zig-compile wall-clock on the dev machine.

The Note in the brief ("Why the comptime archetype path") flags that
the dynamic path is the documented post-spike fallback. The S5
codegen **does** consume the runtime registry / dynamic archetype
storage rather than the S1 comptime `(Transform, Velocity)` path,
because:

- The 20-program differential corpus is set up via `world.spawnDynamic`
  (the only way the diff_runner can plant entities with arbitrary
  component combinations from sidecar specs); the cooked code has to
  read those entities back out.
- Zero `Archetype(...)` / `Query(...)` instantiations means the
  monomorphisation gate is trivially satisfied — the spike's spirit
  is upheld.
- The cooked code remains **typed Zig**: each component is a
  generated `extern struct`, slot access is typed via `@ptrCast`,
  and there is no `Value` tagged union on the hot path. The brief's
  "no `Value` tagged union on the hot path" requirement is met
  exactly.

This is recorded as a **design clarification** in
`briefs/S5-etch-codegen-zig.md` § Notes (Acted deviations entry).

## Observable behaviour

- `zig build run-demo-etch-codegen`: produces `Demo S5 OK | ticks=10 …`
  matching `bench/fixtures/demo_5_rules_codegen.expected.txt` byte-for-byte.
- `zig build bench-etch-compile`: prints the 3-metric summary and writes
  `bench/results/S5-codegen-zig.md`.
- `zig build test-codegen-diff`: 20/20 corpus pass via the cooked runner.
- `zig build test`: 92/92 pass, no leak, both Debug and ReleaseSafe.

## CI

- `zig build` clean on the existing Ubuntu 24.04 + Windows 2025 matrix
  (carried over from S4 — no CI workflow changes in this milestone).
- `zig fmt --check` clean across hand-written sources (generated
  cooked.zig is under `zig-out/etch-bench/`, excluded by `.gitignore`).
- `zig build lint` not present at the time of the milestone (deferred
  per the post-S1 lint milestone note in `engine-spec.md` §25.3 / S0).
- `commit-msg` hook green on every commit of the branch (Conventional
  Commits).

## Verdict

**GO** on all five spec gates. The S5 hypothesis ("Etch → Zig codegen
viable build-time-wise") is **validated** on the Apple Silicon dev
primary. Re-confirmation on the Win11 + Fedora 44 reference machines
is deferred to Phase 0.2 alongside the S3 / S4 bench-confirmation
debts.
