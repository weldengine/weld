# ECS bench C0.1 — M0.2.1 / E6 (thermal-aware)

> **HEAD NOTE added 2026-09-04 at M1.B/G11 — this report's § "Question — delta vs
> M0.1 baseline 14.2 ms" INVESTIGATES A DIVERGENCE THAT DOES NOT EXIST, and its
> conclusion (b) is a mechanism invented to explain it.** The M0.1 squash commit
> body reads `C0.1, ReleaseFast, --workers=4 … median 3.84 ms (gate 16.6 ms —
> 4.3× under)`, the annotated tag reads `C0.1 met at 3.84 ms median`, and
> `briefs/M0.1-ecs-full.md:316` reads `Median: **3.84 ms**`. **No M0.1 artifact
> carries 14.2 ms**; `git log --all --grep=14.2` returns two commits and the
> earlier is `df67e1c` (M0.2.1 itself), which attributed the figure to "the
> brief's baseline". So the real delta against this report's own 3.742958 ms is
> **2.6 %**, not 3.8×, and there was never a ReleaseSafe-to-ReleaseFast gap to
> account for. Note (a) here DID check the code and found it unchanged, correctly;
> what was never checked is the NUMBER'S SOURCE.
>
> The measurements below are UNTOUCHED and remain valid — they are what this
> instrument measured under a compliant protocol on that date. Only the § Question
> is superseded, and the debt it opened,
> `D-M0.2.1-c01-baseline-investigation`, is closed by this note plus the M1.B
> brief: it was tracking a phantom. A dated report is the record of the milestone
> that wrote it and is not rewritten.

**Date** : 2026-05-23
**Commit** : `3f6528a` (`3f6528ae6b8ec3078fc06edc171b0f921afa3441`)
**Machine** : Apple M4 Pro
**Build mode** : ReleaseFast
**Workers** : default (CPU-topology-driven)
**Protocol** : thermal-aware MBP M-series, cold-isolated, compliant.
**Gate** : 16.6 ms (16600000 ns)
**Initial idle** : 1800 s (30 min)
**Inter-run idle** : 900 s (15 min)

## Runs

| Run | Median (ns) | Powermetrics samples | Non-Nominal Pressure |
|---|---|---|---|
| 1 | 3742958 | 68 | 0 |
| 2 | 3779000 | 96 | 0 |
| 3 | 3729667 | 65 | 0 |

## Median of medians

**3742958 ns**

Verdict : **GO** (≤ gate 16600000 ns).

## Thermal-aware compliance

Pressure = Nominal on **100 %** of samples (68 96 65 cumulative samples). **Protocol compliant.**

## Question — delta vs M0.1 baseline 14.2 ms (M0.2.1 / E6 review)

Measurement 3.74 ms vs the M0.1 baseline 14.2 ms documented in the M0.1
squash commit and reproduced in `engine-phase-0-criteria.md`. To investigate:

- (a) Did the C0.1 bench change parameters between M0.1 and HEAD M0.2.1?
  **No** — `git log v0.1.0-M0.1-ecs-full..HEAD -- bench/ecs_benchmark.zig`
  returns empty. The C0.1 constants (1M entities over 4 archetypes 700k/200k/60k/40k,
  10 systems, warmup 100 + measured 1000) are identical.

- (b) Compile mode discrepancy? **Probable cause.** The M0.1 squash commit
  shows a `Measures (..., ReleaseSafe, --workers=4 for S1)` header that
  encompasses the C0.1 14.2 ms line. But the `engine-phase-0-criteria.md`
  § bench methodology protocol requires **ReleaseFast for C0.1**. ReleaseSafe adds
  bounds checks + overflow checks + other runtime safety — typically
  2-4× slower. Observed ratio: 14.2 / 3.74 ≈ 3.8× — consistent with a
  ReleaseSafe → ReleaseFast gap.

- (c) Does the M0.1 14.2 ms baseline remain comparable? **Probably not** —
  non-protocol-compliant if actually measured in ReleaseSafe. The 3.74 ms
  thermal-aware ReleaseFast value is the first protocol-compliant measurement
  archived for C0.1.

- (d) New baseline? **To be recorded by a dedicated Phase 0.1+ milestone.** Not in
  M0.2.1 scope. For this milestone, the 16.6 ms gate is met (3.74 ms ≤
  16.6 ms ✓, headroom ~4.4×). M0.2.1 concludes GO on the gate, and the baseline
  question is tracked as debt `D-M0.2.1-c01-baseline-investigation`.

## False-sharing inspection (M0.2.1 / E6 note 2)

The comptime layout guard in `src/core/jobs/scheduler.zig` (post-E5)
validates at compile time that `gen_and_n` and `pending_count` are each
aligned on their own cache line (offsets multiples of 64, delta ≥ 64).
Build passes ⇒ assertion validated. **No false sharing between dispatcher
and workers on these atomics.**

## Archived logs

Under `/tmp/m0_2_1_bench_e6_c01_2026-05-23_11537/`:
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
