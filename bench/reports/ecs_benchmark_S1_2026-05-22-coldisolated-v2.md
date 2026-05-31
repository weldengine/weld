# S1 ECS bench — M0.2 / E6 cold-isolated re-bench (v2, strict protocol)

> **Date:** 2026-05-22
> **Commit:** `4de00f6` (HEAD `phase-0/core/rtti-resources-events-bindgen` pre-M0.2-tag)
> **Branch:** `phase-0/core/rtti-resources-events-bindgen`
> **Bench:** `zig-out/bin/ecs-benchmark --case=s1 --workers=4`
> **Source:** `bench/ecs_benchmark.zig` (S1 non-regression: 100 000 entities × 1 archetype × 1 system, `--workers=4`)
> **Machine:** primary dev Apple M4 Pro (same hardware as the 62 µs post-recalibration M0.1/E6 baseline)
> **Build mode:** ReleaseSafe (canonical target of `bench-ecs`, Debug rejected by the bench)
> **Protocol mode:** **strict spec-compliant cold-isolated** (5 min initial cool-down + 2 min inter-run pause, machine pre-confirmed by Guy in an isolated state — DND/Focus active, all non-system apps closed, no Time Machine / Spotlight / iCloud sync)
> **Baseline:** S1 cold-isolated Apple M4 Pro ReleaseSafe (canonical gate post-recalibration M0.1/E6) — median 62 µs / strict gate 65 µs (gate +5 %)
> **Predecessor:** v1 `bench/reports/ecs_benchmark_S1_2026-05-22-coldisolated.md` (60 s cool-down + 30 s inter-run — non-spec-compliant protocol, kept for methodological traceability)

## Protocol followed (timestamp proof)

| Phase | Start | End | Duration | Spec threshold |
|---|---|---|---|---|
| Initial cool-down | 22:44:48 | 22:52:52 | 8 min 04 s | ≥ 5 min ✓ |
| Pause 1→2 | 22:52:52 | 22:54:52 | 2 min 00 s | ≥ 2 min ✓ |
| Pause 2→3 | 22:54:52 | 22:56:52 | 2 min 00 s | ≥ 2 min ✓ |
| Pause 3→4 | 22:56:52 | 22:58:52 | 2 min 00 s | ≥ 2 min ✓ |
| Pause 4→5 | 22:58:52 | 23:00:52 | 2 min 00 s | ≥ 2 min ✓ |
| Pause 5→6 | 23:00:53 | 23:02:53 | 2 min 00 s | ≥ 2 min ✓ |
| Pause 6→7 | 23:02:53 | 23:04:53 | 2 min 00 s | ≥ 2 min ✓ |

Initial cool-down measured at 484 s (8 min 04) vs the 300 s threshold — the ~184 s overage comes from the delta between the script's `sleep 300` and harness/scheduling latency, so in the conservative direction (machine at rest longer than strict). No shortcut; no interruption; no retry.

Raw timestamp log available in `/tmp/s1_strict_runs/log.txt` (generated on the fly, not committed because ephemeral).

## Measurements (7 successive runs, ns)

| Run | Timestamp | Min | Median | Mean | p95 | p99 | Max | Imbalance | Local status |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 22:52:52 | 51 459 | **75 166** | 77 876 | 107 333 | 122 750 | 128 375 | 8.40 % | NO-GO |
| 2 | 22:54:52 | 50 708 | **72 125** | 74 213 | 107 125 | 125 625 | 146 125 | 6.76 % | NO-GO |
| 3 | 22:56:52 | 50 958 | **74 583** | 78 282 | 119 083 | 143 917 | 174 958 | 7.17 % | NO-GO |
| 4 | 22:58:52 | 51 291 | **77 000** | 79 380 | 110 125 | 123 417 | 142 792 | 8.10 % | NO-GO |
| 5 | 23:00:52 | 51 667 | **79 958** | 81 904 | 110 333 | 135 875 | 188 625 | 7.76 % | NO-GO |
| 6 | 23:02:53 | 51 291 | **76 708** | 78 747 | 108 917 | 132 167 | 151 667 | 7.28 % | NO-GO |
| 7 | 23:04:53 | 51 125 | **60 000** | 61 882 | 78 208 | 86 583 | 91 083 | 1.60 % | GO |

**Sorted ascending medians (ns):** 60 000 ; 72 125 ; 74 583 ; **75 166** ; 76 708 ; 77 000 ; 79 958.

**Median of medians (position 4 of 7):** **75 166 ns ≈ 75.2 µs.**

## Analysis

- **Distribution dominated by the NO-GO zone**: 6 of 7 runs measure in the 72-80 µs range. The 7th run (run 7) comes out at 60 µs with an imbalance of 1.60 % (vs 6.76-8.40 % on the other 6). The gap between the two regimes is sharp: there is no continuous transition, it is a clean jump between runs 1-6 and run 7.
- **Imbalance correlated with the median**: runs 1-6 have an average imbalance ~7.4 %, run 7 has an imbalance of 1.60 %. Task distribution across the 4 workers is markedly better for the fast run. The visible correlation coefficient is high: low imbalance → low median.
- **No temporal pattern**: the 2 min pause between each run is respected. Run 7 is neither the first (post-long-cool-down) nor a special cold-cache case — it occurs after 6 previous runs, in the same pause regime. The return to a "fast" regime at run 7 is not explainable by chronology alone.
- **p99 and max follow the same split**: runs 1-6 have p99 ∈ [122-144] µs and max ∈ [128-189] µs (degraded tails). Run 7 has p99 = 86.6 µs and max = 91.1 µs (clean tail, within the historical baseline bounds).
- **Imbalance within the gate on all runs** (max 8.40 %, gate 15 %). The workload-vs-worker distribution is not catastrophic on the slow runs — it is a ~5-7 point drift vs run 7, which measures under "historical" conditions.

The diagnosis is NOT delivered as a justification — it is a factual observation for the Claude.ai feedback. No hypothesis on the cause (RTTI registry init, singleton_resources lookup, event_bus drain, scheduler dispatch overhead, etc.) is advanced here. That is your job.

## Gate

**Strict reading of the thresholds:**

- Strict gate: median of medians ≤ 65 µs (gate +5 % vs the S1 cold-isolated Apple M4 Pro ReleaseSafe baseline post-recalibration M0.1/E6 = 62 µs).
- Measured: median of medians = **75.2 µs**.
- Excess vs gate: **+10.2 µs (+15.7 %)** above the limit.
- Excess vs the canonical 62 µs baseline: **+13.2 µs (+21 %)**.
- Excess vs the historical S1 v0.0.2 baseline (54.5 µs): **+20.7 µs (+38 %)**.

**Verdict: NO-GO (strict FAIL under spec-compliant protocol).**

## Conclusion

The S1 bench does not pass the strict 65 µs gate at commit `4de00f6` of branch `phase-0/core/rtti-resources-events-bindgen`, with a strict spec-compliant cold-isolated protocol (5 min cool-down + 2 min inter-run respected and timestamp-traced).

The v1 verdict (NO-GO under non-spec-compliant protocol) is confirmed under strict protocol. The observed pattern is different (v1: sharp bimodal runs 1-2 vs runs 3-7; v2: 6 slow runs + 1 fast outlier run) but the arithmetic conclusion is identical: median of medians > 65 µs.

Per the opposable bench procedure, no unilateral mitigation is proposed — no cherry-pick re-run, no parameter re-tune, no gate adjustment. No regression-cause hypothesis is advanced. The FAIL verdict is archived as-is for Claude.ai analysis.

**Case 2 blocker — structural regression suspected. Claude.ai round-trip required before the M0.2 tag.**

## Baseline reference for the feedback audit

- S1 v0.0.2 baseline (Apple Silicon M4 Pro ReleaseSafe, minimal mini-ECS): median 54.5 µs.
- Canonical baseline post-recalibration M0.1/E6 (same machine, full Tier 0 ECS): median 62 µs.
- Strict M0.2 gate (engine-phase-0-criteria.md C0.1 sub-gate S1): 65 µs (62 µs baseline + 5 %).
- v1 non-spec-compliant cold-isolated measurement: median-of-medians 74.7 µs.
- v2 STRICT spec-compliant cold-isolated measurement: **median-of-medians 75.2 µs (NO-GO confirmed)**.

Surface modified between `v0.1.0-M0.1-ecs-full` (gate 62 µs) and HEAD `4de00f6`:
- E1 RTTI (`src/core/rtti/`) — additive sub-system, no declared ECS hot-path wiring
- E2 IPC `messages.zig` swap Wyhash → xxHash64 (comptime, not runtime ECS)
- E3 Resources (`src/core/resources/`) — `singleton_resources: ResourceRegistry` added to `World`, `is_singleton: bool` flag on `Archetype`, `if (arch.is_singleton) continue` check in `Query.maybeRescan` + `ComptimeQuery.next`
- E4 Events (`src/core/events/`) — `event_bus: EventBus` added to `World`, `drainAtBoundary` calls at the scheduler's 3 boundaries (`.phase` × 6 + `.tick` + `.frame`)
- E5 Bindgen — pure tooling refactor, no touch to `src/core/`
- E6 Plugin loader — `src/core/plugin_loader/`, additive, no ECS wiring

The prima facie candidates for exploring the regression are E3 and E4 — the only ones touching the scheduler loop and the queries' rescan-path. This is a candidate list, not a diagnosis.
