# S1 ECS bench — M0.2 / E6 cold-isolated re-bench

> **Date:** 2026-05-22
> **Commit:** `f2f823d` (HEAD `phase-0/core/rtti-resources-events-bindgen` pre-M0.2-tag)
> **Branch:** `phase-0/core/rtti-resources-events-bindgen`
> **Bench:** `zig-out/bin/ecs-benchmark --case=s1 --workers=4`
> **Source:** `bench/ecs_benchmark.zig` (S1 non-regression: 100 000 entities × 1 archetype × 1 system, `--workers=4`)
> **Machine:** primary dev Apple Silicon (cf. S6 § Results — M4 Pro reference)
> **Build mode:** ReleaseSafe (canonical target of `bench-ecs` — Debug is rejected by the bench)
> **Protocol mode:** **cold-isolated, opposable** (cf. `engine-phase-0-criteria.md § bench methodology`). Closed dev session (no IDE, no browser, no Slack/Discord, no build server) confirmed by Guy before execution. 60 s cool-down post-build before run 1. 30 s pause between successive runs to let the L1/L2 cache drift.
> **Baseline:** S1 cold-isolated Apple Silicon ReleaseSafe (cf. `validation/s1-go-nogo.md` / tag `v0.0.2-S1-mini-ecs`) — median 54.5 µs / strict gate 65 µs (gate +5 % above the 62 µs baseline planned in `engine-phase-0-criteria.md`).

## Procedure executed

1. ReleaseSafe build: `zig build bench-ecs -Doptimize=ReleaseSafe` → artifact `zig-out/bin/ecs-benchmark`.
2. 60 s cool-down.
3. 7 successive runs, 30 s pause between each, canonical parameters `--case=s1 --workers=4`. Capture stdout + markdown report per run (`/tmp/s1_cold_runs/{stdout,report}_<n>.{txt,md}`).
4. No retry, no a-posteriori selection — the report reflects all 7 measurements in execution order.

## Measurements (7 successive runs, ns)

| Run | Min | Median | Mean | p95 | p99 | Max | Imbalance |
|---|---|---|---|---|---|---|---|
| 1 | 51 333 | **60 042** | 62 034 | 78 708 | 86 791 | 92 417 | 0.39 % |
| 2 | 51 250 | **60 667** | 63 274 | 81 417 | 92 458 | 118 292 | 1.01 % |
| 3 | 51 292 | **72 750** | 74 184 | 98 458 | 107 458 | 119 916 | 8.72 % |
| 4 | 51 250 | **78 166** | 80 281 | 119 167 | 145 875 | 185 666 | 8.54 % |
| 5 | 51 708 | **75 667** | 77 614 | 117 042 | 149 792 | 167 042 | 7.63 % |
| 6 | 50 958 | **76 041** | 77 119 | 110 084 | 125 000 | 136 125 | 6.43 % |
| 7 | 51 417 | **74 709** | 77 159 | 108 125 | 141 209 | 183 708 | 6.17 % |

**Sorted ascending medians (ns):** 60 042 ; 60 667 ; 72 750 ; **74 709** ; 75 667 ; 76 041 ; 78 166.

**Median of medians (position 4 of 7):** **74 709 ns ≈ 74.7 µs.**

## Analysis

- **Bimodal pattern**: runs 1-2 measure ~60 µs (local GO), runs 3-7 measure 73-78 µs (local NO-GO). The transition happens between run 2 and run 3 — the moment when the 30 s pause is no longer enough to bring the machine back to the quiescent state observed at startup.
- **Imbalance within the gate** on all runs (max 8.72 %, gate 15 %). The scheduler distributes the load correctly — the observed degradation is not a work-stealing regression.
- **p99 and max** follow the same pattern: runs 1-2 stable (p99 87-92 µs, max 92-118 µs), runs 3-7 degraded (p99 107-150 µs, max 120-186 µs). The distribution tail is sensitive to machine state, which is consistent with OS noise on the non-critical zone.
- **The median is stable intra-regime**: 60.0 / 60.7 µs for the "quiescent" regime, 72-78 µs for the "warm" regime. The intra-regime variance is low (< 5 % between successive runs of the same regime), which rules out a one-off measurement noise.

The diagnosis is NOT delivered as a justification — it is a factual observation for the Claude.ai feedback.

## Gate

**Strict reading of `engine-phase-0-criteria.md § bench methodology`:**

- Strict gate: median of medians ≤ 65 µs (gate +5 % vs the S1 cold-isolated Apple Silicon ReleaseSafe baseline).
- Measured: median of medians = **74.7 µs**.
- Excess vs gate: **+9.7 µs (+15 %)** above the limit.

**Verdict: NO-GO (strict FAIL).**

## Conclusion

The cold-isolated S1 bench does not pass the strict 65 µs gate at commit `f2f823d` of branch `phase-0/core/rtti-resources-events-bindgen` (HEAD pre-M0.2-tag).

Per the opposable bench procedure, no unilateral mitigation is proposed — no cherry-pick re-run, no parameter re-tune, no gate adjustment. The FAIL verdict is archived as-is.

**Case 2 blocker — Claude.ai round-trip required before the M0.2 tag.**

## Baseline reference for the feedback audit

- S1 v0.0.2 baseline (Apple Silicon M4 Pro ReleaseSafe, minimal mini-ECS): median 54.5 µs.
- Strict M0.2 gate (engine-phase-0-criteria.md C0.1 sub-gate S1): 65 µs.
- M0.2 cold-isolated measurement: median of medians 74.7 µs (FAIL, +37 % vs baseline; +15 % vs gate).
