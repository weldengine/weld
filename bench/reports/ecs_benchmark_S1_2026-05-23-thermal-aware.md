# ECS bench S1 — M0.2.1 / E6 (thermal-aware)

**Date** : 2026-05-23
**Commit** : `3f6528a` (`3f6528ae6b8ec3078fc06edc171b0f921afa3441`)
**Machine** : Apple M4 Pro
**Build mode** : ReleaseSafe
**Workers** : --workers=4 (forced — S1 baseline calibration)
**Protocol** : thermal-aware MBP M-series, cold-isolé conforme.
**Gate** : 62 µs (62000 ns)
**Initial idle** : 1800 s (30 min)
**Inter-run idle** : 900 s (15 min)

## Runs

| Run | Median (ns) | Powermetrics samples | Non-Nominal Pressure |
|---|---|---|---|
| 1 | 59500 | 12 | 0 |
| 2 | 61875 | 12 | 0 |
| 3 | 61042 | 12 | 0 |

## Médiane des médianes

**61042 ns**

Verdict : **GO** (≤ gate 62000 ns).

## Conformité thermal-aware

Pressure = Nominal sur **100 %** des samples (12 12 12 samples cumul). **Protocole conforme.**

## Inspection false sharing (M0.2.1 / E6 note 2)

Le comptime layout guard dans `src/core/jobs/scheduler.zig` (post-E5)
valide à compile time que `gen_and_n` et `pending_count` sont chacun
aligné sur sa propre cache line (offsets multiples de 64, delta ≥ 64).
Build passe ⇒ assertion validée. **Aucun false sharing entre dispatcher
et workers sur ces atomics.**

## Logs archivés

Sous `/tmp/m0_2_1_bench_e6_s1_2026-05-23_78889/` :
- `bench_report_run1.md` — sortie Markdown du bench.
- `bench_stdout_run1.log` — stdout/stderr de l'invocation.
- `powermetrics_run1.log` — trace thermique (11 samples par run).
- `bench_report_run2.md` — sortie Markdown du bench.
- `bench_stdout_run2.log` — stdout/stderr de l'invocation.
- `powermetrics_run2.log` — trace thermique (11 samples par run).
- `bench_report_run3.md` — sortie Markdown du bench.
- `bench_stdout_run3.log` — stdout/stderr de l'invocation.
- `powermetrics_run3.log` — trace thermique (11 samples par run).

## Protocole respecté

- ≥ 1800 s (30 min) idle après pre-build avant run #1 — enforced par sleep.
- ≥ 900 s (15 min) idle entre runs — enforced par sleep.
- 3 runs par session — limite la chaîne thermal cumulée.
- `powermetrics --samplers thermal,cpu_power -i 100` capturé en parallèle de chaque run.
- Vérification programmatique `Current pressure level: Nominal` sur 100 % des samples.
