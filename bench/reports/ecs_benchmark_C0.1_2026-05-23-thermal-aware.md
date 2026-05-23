# ECS bench C0.1 — M0.2.1 / E6 (thermal-aware)

**Date** : 2026-05-23
**Commit** : `3f6528a` (`3f6528ae6b8ec3078fc06edc171b0f921afa3441`)
**Machine** : Apple M4 Pro
**Build mode** : ReleaseFast
**Workers** : default (CPU-topology-driven)
**Protocol** : thermal-aware MBP M-series, cold-isolé conforme.
**Gate** : 16.6 ms (16600000 ns)
**Initial idle** : 1800 s (30 min)
**Inter-run idle** : 900 s (15 min)

## Runs

| Run | Median (ns) | Powermetrics samples | Non-Nominal Pressure |
|---|---|---|---|
| 1 | 3742958 | 68 | 0 |
| 2 | 3779000 | 96 | 0 |
| 3 | 3729667 | 65 | 0 |

## Médiane des médianes

**3742958 ns**

Verdict : **GO** (≤ gate 16600000 ns).

## Conformité thermal-aware

Pressure = Nominal sur **100 %** des samples (68 96 65 samples cumul). **Protocole conforme.**

## Question — delta vs baseline M0.1 14.2 ms (M0.2.1 / E6 review)

Mesure 3.74 ms vs baseline M0.1 14.2 ms documentée dans le squash commit
M0.1 et reproduite dans `engine-phase-0-criteria.md`. Investiguer :

- (a) Le bench C0.1 a-t-il changé de paramètres entre M0.1 et HEAD M0.2.1 ?
  **Non** — `git log v0.1.0-M0.1-ecs-full..HEAD -- bench/ecs_benchmark.zig`
  retourne vide. Les constantes C0.1 (1M entités sur 4 archetypes 700k/200k/60k/40k,
  10 systèmes, warmup 100 + measured 1000) sont identiques.

- (b) Compile mode discrepancy ? **Probable cause.** Le squash commit M0.1
  affiche un header `Measures (..., ReleaseSafe, --workers=4 pour S1)` qui
  englobe la ligne C0.1 14.2 ms. Or le protocole `engine-phase-0-criteria.md`
  § Méthodologie bench exige **ReleaseFast pour C0.1**. ReleaseSafe ajoute
  bounds checks + overflow checks + autres safety runtime — typiquement
  2-4× plus lent. Ratio observé : 14.2 / 3.74 ≈ 3.8× — cohérent avec un
  écart ReleaseSafe → ReleaseFast.

- (c) La baseline M0.1 14.2 ms reste-t-elle opposable ? **Non, vraisemblablement
  pas** — non-protocol-compliant si effectivement mesurée en ReleaseSafe. La
  valeur 3.74 ms thermal-aware ReleaseFast est la première mesure protocol-
  compliant archivée pour C0.1.

- (d) Nouvelle baseline ? **À acter par milestone Phase 0.1+ dédié.** Pas en
  scope M0.2.1. Pour ce milestone, le gate 16.6 ms est respecté (3.74 ms ≤
  16.6 ms ✓, headroom ~4.4×). M0.2.1 conclut GO sur le gate, et la question
  baseline est tracée comme dette `D-M0.2.1-c01-baseline-investigation`.

## Inspection false sharing (M0.2.1 / E6 note 2)

Le comptime layout guard dans `src/core/jobs/scheduler.zig` (post-E5)
valide à compile time que `gen_and_n` et `pending_count` sont chacun
aligné sur sa propre cache line (offsets multiples de 64, delta ≥ 64).
Build passe ⇒ assertion validée. **Aucun false sharing entre dispatcher
et workers sur ces atomics.**

## Logs archivés

Sous `/tmp/m0_2_1_bench_e6_c01_2026-05-23_11537/` :
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
