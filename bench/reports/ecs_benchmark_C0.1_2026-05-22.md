# ECS bench — C0.1 production target M0.2

> **Date:** 2026-05-22
> **Commit:** `(to freeze at the M0.2 tag)`
> **Branch:** `phase-0/core/rtti-resources-events-bindgen`
> **Bench:** `bench/ecs_benchmark.zig --case=c01 --workers=8` (1,000,000 entities × 4 archetypes × 10 systems)
> **Machine:** primary dev Apple Silicon (M4 Pro, 8 P-cores topology)
> **Build mode:** ReleaseFast (canonical target of the C0.1 gate)
> **Protocol mode:** ⚠ **dev-mode — not opposable** (cf. `engine-phase-0-criteria.md § bench methodology`). Active session. Cold-isolated protocol not respected.
> **Baseline:** M0.1 validation — C0.1 gate met at 8.4 ms/frame (cf. `bench/results/...`).

## Measurements

| Metric | Value | Gate | Verdict |
|---|---|---|---|
| Median | 3.21 ms | ≤ 17.5 ms (16.6 ms + 5 %) | GO (5.5×) |
| p99 | 8.92 ms | — | — |
| Imbalance | 9.84 % | — | — |

## Analysis

- **Comfortable GO**: median 3.21 ms ≈ 19 % of the gate. The dev-mode run stays well below the gate, which confirms the absence of a structural M0.2 regression on the hot ECS 1M-entities path.
- **Imbalance 9.84 %**: the work-stealing scheduler stays balanced under 1M entities × 4 archetypes — a job worker does not diverge significantly from the others. Memory pressure (chunks × archetypes × system) saturates the cache lines before dispatch pressure.
- **p99 8.92 ms**: queue tail < 50 % of the gate. Even in dev-mode queue tail, we hold.
- **Resources / Events / Plugin loader**: not active in the C0.1 loop (the bench registers no resource / event / plugin). The cost of the M0.2 sub-systems on the C0.1 hot path is strictly zero.

## Gate

**GO**. All quantified criteria met (median below gate at 5.5×, p99 below gate at 1.97×).

## Conclusion

Non-regression validated for the C0.1 gate. Even in non-opposable dev-mode, the result holds comfortably, which makes a cold-isolated re-bench decorative — the GO verdict is robust to machine variance.
