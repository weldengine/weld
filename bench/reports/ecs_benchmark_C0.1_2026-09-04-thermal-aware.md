# ECS bench C0.1 — M1.B / G11 (thermal-aware)

**Date** : 2026-09-04
**Commit** : `391c5f7` (branch `phase-1/ecs/hybrid-storage`, M1.B pre-close)
**Machine** : Apple M4 Pro
**Build mode** : ReleaseFast
**Workers** : default (CPU-topology-driven)
**Case** : `--case=c01` — 1 000 000 entities × 4 archetypes × 10 systems
**Gate** : 16.6 ms (16 600 000 ns)
**Initial idle** : 1800 s (30 min), enforced by `sleep` under `caffeinate -i`
**Inter-run idle** : 900 s (15 min), same

## Runs

| Run | Started | Median (ns) | p99 (ms) | Imbalance |
|---|---|---|---|---|
| 1 | 21:37:45 | 3 582 083 | 3.77 | 4.48 % |
| 2 | 21:52:51 | 3 571 417 | 3.72 | 1.76 % |
| 3 | 22:07:58 | 3 573 958 | 3.83 | 1.57 % |

## Median of medians

**3 573 958 ns = 3.574 ms**

Verdict : **GO** — 4.65× under the 16.6 ms gate. Imbalance well under the 15 % gate on all three.

The three medians span **1.1 µs on 3.57 ms — 0.3 %**, which is itself the evidence that the idle
discipline did its work: a thermally perturbed set would not close that tightly.

## Deltas, and which of them is opposable

| Against | Value | Delta | Status |
|---|---|---|---|
| **the C0.1 gate** | 16.6 ms | **−78.5 %** (4.65× margin) | **OPPOSABLE** — `engine-phase-0-criteria.md` sets the ceiling and its regression clause reads "> 5 % vs **gate**" |
| the last compliant measurement (2026-05-23) | 3.742958 ms | **−4.5 %**, i.e. faster | informative |
| the M0.1 close | 3.84 ms | **−6.9 %**, i.e. faster | informative |

**No regression: the number improved.** And the opposable ceiling is the GATE, not the last
measurement — a budget of last-measurement + 5 % would be 3.93 ms and would have refused a milestone
holding 4.65× margin.

**The "14.2 ms M0.1 baseline" that earlier reports compare against does not exist.** The M0.1 squash
commit body reads `median 3.84 ms (gate 16.6 ms — 4.3× under)`, the annotated tag reads `C0.1 met at
3.84 ms median`, and `briefs/M0.1-ecs-full.md:316` reads `Median: **3.84 ms**`. `git log --all
--grep=14.2` returns two commits and the earlier is `df67e1c` (M0.2.1), which attributed the figure
to "the brief's baseline". See the head note on
`bench/reports/ecs_benchmark_C0.1_2026-05-23-thermal-aware.md`.

## Protocol compliance — WHAT COULD NOT BE VERIFIED

The idle discipline was executed in full (1800 s + 900 s + 900 s, `caffeinate -i` throughout, per
`CLAUDE.md` § Thermal-aware bench MBP M-series). **The per-sample pressure verification was NOT
performed, and could not be:** `powermetrics` requires the superuser, which this session does not
have — measured, it answers `powermetrics must be invoked as the superuser`. So the
`Current pressure level: Nominal` on 100 % of samples that the 2026-05-23 report carries has no
counterpart here.

What was available instead, recorded before and after the whole protocol:

```
$ pmset -g therm
Note: No thermal warning level has been recorded
Note: No performance warning level has been recorded
Note: No CPU power status has been recorded
```

That is an ABSENCE of any logged thermal or performance warning across the session, which is weaker
than a per-sample trace and is not nothing. **These runs are therefore protocol-SHAPED and their
compliance is not verified to the 2026-05-23 standard.** Stated rather than implied, and it changes
nothing about the gate verdict, which 4.65× of margin settles on its own; it is the two informative
deltas that would need the trace to be opposable.
