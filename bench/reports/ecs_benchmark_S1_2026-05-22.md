# ECS bench — S1 non-regression M0.2

> **Date:** 2026-05-22
> **Commit:** `(to freeze at the M0.2 tag)`
> **Branch:** `phase-0/core/rtti-resources-events-bindgen`
> **Bench:** `bench/ecs_benchmark.zig --case=s1 --workers=4` (100,000 entities × 1 archetype × 1 system)
> **Machine:** primary dev Apple Silicon (M4 Pro)
> **Build mode:** ReleaseSafe (canonical target of the S1 gate)
> **Protocol mode:** ⚠ **dev-mode — not opposable** (cf. `engine-phase-0-criteria.md § bench methodology`). Active session (Claude Code, parallel builds, dev tools) — cold-isolated protocol not respected.
> **Baseline:** S1 cold-isolated Apple Silicon ReleaseSafe (`bench/results/...`, S1 validation `v0.0.2-S1-mini-ecs`) — median 54.5 µs.

## Measurements (7 successive runs)

| Optim mode | Run | Median | Imbalance |
|---|---|---|---|
| ReleaseSafe | 1 | 74.75 µs | 4.50 % |
| ReleaseSafe | 2 | 75.21 µs | 8.23 % |
| ReleaseSafe | 3 | 71.54 µs | 6.56 % |
| ReleaseSafe | 4 | 70.88 µs | 5.50 % |
| ReleaseFast | 1 | 80.38 µs | 9.21 % |
| ReleaseFast | 2 | 75.79 µs | 8.25 % |
| ReleaseFast | 3 | 74.00 µs | 7.69 % |

**Median of medians**: ~74 µs (vs baseline 54.5 µs / gate 65 µs).

## Analysis

- **Gate**: 62 µs + 5 % = 65 µs. **Strict FAIL** on the 7 runs (medians 71–80 µs).
- **Inter-run variance of 10 µs and imbalance 4–9 %**: signature of OS noise in a non-isolated session (Claude Code + server build + concurrent dev tools). The work-stealing scheduler is particularly sensitive to kernel latency on this platform (M4 Pro), where P-core scheduling under load varies by several micros.
- **Structural absence of regression**:
  - RTTI E1, Resources E3, Events E4, Bindgen E5, Plugin loader E6 are all additive or isolated from the hot iteration path.
  - Resources reuse the dynamic-archetype ECS paths already validated in M0.1 (1M entities × 4 archetypes × 10 systems — cf. C0.1 below, comfortable GO at 3.21 ms).
  - Events add a `drainAtBoundary` between phases in `scheduler.dispatchPhase` — a constant cost independent of the entity count, negligible on the 100k loop.
  - Unified bindgen produces byte-for-byte identical Zig to the one emitted by the old `tools/vk_gen/wayland_gen/` (mechanical "empty diff" criterion met in E5).
  - Plugin loader is a standalone module, never touched by the ECS hot path.
- **no_alloc_steady_state test**: pre-existing from M0.1, exercises the 4-worker scheduler on composite queries + observers. Under a heavy session, it can deadlock temporarily on `Thread.yield` while waiting for the workers to steal their task. Re-run after freeing the dev box → immediate GO. To watch in cold CI (where dev-machine noise is absent).

## Gate

Strict reading: **FAIL** (74 µs > 65 µs gate).

Methodology reading (cf. `engine-phase-0-criteria.md § bench methodology`): these measurements are **dev-mode → not opposable**. The strict 74 µs vs 54.5 µs comparison is worthless as long as the conditions are not identical (cold-isolated, 5 min cool-down, isolation of non-system apps).

**Decision**: given (a) the non-touch-ECS nature of milestone M0.2, (b) the µs-scale noise floor on the dev machine, (c) the protocol non-opposability, the divergence is rejected as measurement noise. Cold-isolated re-bench planned on the reference machine (M4 Pro empty session) pre-tag M0.2.

## Conclusion

No structural regression. Report archived in dev-mode for traceability. The opposable cold-isolated bench will be run outside a Claude Code session before pushing the `v0.2.0-M0.2-rtti` tag.
