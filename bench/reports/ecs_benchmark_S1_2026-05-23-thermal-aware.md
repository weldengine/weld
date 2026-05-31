# ECS bench S1 — M0.2.1 / E6 (thermal-aware)

**Date** : 2026-05-23
**Commit** : `3f6528a` (`3f6528ae6b8ec3078fc06edc171b0f921afa3441`)
**Machine** : Apple M4 Pro
**Build mode** : ReleaseSafe
**Workers** : --workers=4 (forced — S1 baseline calibration)
**Protocol** : thermal-aware MBP M-series, cold-isolated, compliant.
**Gate** : 62 µs (62000 ns)
**Initial idle** : 1800 s (30 min)
**Inter-run idle** : 900 s (15 min)

## Runs

| Run | Median (ns) | Powermetrics samples | Non-Nominal Pressure |
|---|---|---|---|
| 1 | 59500 | 12 | 0 |
| 2 | 61875 | 12 | 0 |
| 3 | 61042 | 12 | 0 |

## Median of medians

**61042 ns**

Verdict : **GO** (≤ gate 62000 ns).

## Thermal-aware compliance

Pressure = Nominal on **100 %** of samples (12 12 12 cumulative samples). **Protocol compliant.**

## False-sharing inspection (M0.2.1 / E6 note 2)

The comptime layout guard in `src/core/jobs/scheduler.zig` (post-E5)
validates at compile time that `gen_and_n` and `pending_count` are each
aligned on their own cache line (offsets multiples of 64, delta ≥ 64).
Build passes ⇒ assertion validated. **No false sharing between dispatcher
and workers on these atomics.**

## Archived logs

Under `/tmp/m0_2_1_bench_e6_s1_2026-05-23_78889/`:
- `bench_report_run1.md` — bench Markdown output.
- `bench_stdout_run1.log` — stdout/stderr of the invocation.
- `powermetrics_run1.log` — thermal trace (11 samples per run).
- `bench_report_run2.md` — bench Markdown output.
- `bench_stdout_run2.log` — stdout/stderr of the invocation.
- `powermetrics_run2.log` — thermal trace (11 samples per run).
- `bench_report_run3.md` — bench Markdown output.
- `bench_stdout_run3.log` — stdout/stderr of the invocation.
- `powermetrics_run3.log` — thermal trace (11 samples per run).

## Protocol followed

- ≥ 1800 s (30 min) idle after pre-build before run #1 — enforced by sleep.
- ≥ 900 s (15 min) idle between runs — enforced by sleep.
- 3 runs per session — limits the cumulative thermal chain.
- `powermetrics --samplers thermal,cpu_power -i 100` captured in parallel with each run.
- Programmatic verification `Current pressure level: Nominal` on 100 % of samples.
