# S1 ECS bench — M0.2 / E6 cold-isolated re-bench

> **Date :** 2026-05-22
> **Commit :** `f2f823d` (HEAD `phase-0/core/rtti-resources-events-bindgen` pré-tag M0.2)
> **Branche :** `phase-0/core/rtti-resources-events-bindgen`
> **Bench :** `zig-out/bin/ecs-benchmark --case=s1 --workers=4`
> **Source :** `bench/ecs_benchmark.zig` (S1 non-regression : 100 000 entités × 1 archetype × 1 système, `--workers=4`)
> **Machine :** dev primaire Apple Silicon (cf. S6 § Résultats — M4 Pro reference)
> **Build mode :** ReleaseSafe (cible canonique du target `bench-ecs` — Debug est rejeté par le bench)
> **Mode protocole :** **cold-isolé opposable** (cf. `engine-phase-0-criteria.md § Méthodologie bench`). Session dev fermée (no IDE, no browser, no Slack/Discord, no build server) confirmée par Guy avant exécution. Cool-down 60 s post-build avant le run 1. Pause 30 s entre runs successifs pour laisser le cache L1/L2 dériver.
> **Baseline :** S1 cold-isolé Apple Silicon ReleaseSafe (cf. `validation/s1-go-nogo.md` / tag `v0.0.2-S1-mini-ecs`) — médiane 54.5 µs / gate strict 65 µs (gate +5 % au-dessus de la baseline 62 µs prévue dans `engine-phase-0-criteria.md`).

## Procédure exécutée

1. Build ReleaseSafe : `zig build bench-ecs -Doptimize=ReleaseSafe` → artefact `zig-out/bin/ecs-benchmark`.
2. Cool-down 60 s.
3. 7 runs successifs, pause 30 s entre chaque, paramètres canoniques `--case=s1 --workers=4`. Capture stdout + report markdown par run (`/tmp/s1_cold_runs/{stdout,report}_<n>.{txt,md}`).
4. Aucun retry, aucune sélection a posteriori — le rapport reflète l'ensemble des 7 mesures dans l'ordre d'exécution.

## Mesures (7 runs successifs, ns)

| Run | Min | Médiane | Mean | p95 | p99 | Max | Imbalance |
|---|---|---|---|---|---|---|---|
| 1 | 51 333 | **60 042** | 62 034 | 78 708 | 86 791 | 92 417 | 0.39 % |
| 2 | 51 250 | **60 667** | 63 274 | 81 417 | 92 458 | 118 292 | 1.01 % |
| 3 | 51 292 | **72 750** | 74 184 | 98 458 | 107 458 | 119 916 | 8.72 % |
| 4 | 51 250 | **78 166** | 80 281 | 119 167 | 145 875 | 185 666 | 8.54 % |
| 5 | 51 708 | **75 667** | 77 614 | 117 042 | 149 792 | 167 042 | 7.63 % |
| 6 | 50 958 | **76 041** | 77 119 | 110 084 | 125 000 | 136 125 | 6.43 % |
| 7 | 51 417 | **74 709** | 77 159 | 108 125 | 141 209 | 183 708 | 6.17 % |

**Médianes triées ascendantes (ns) :** 60 042 ; 60 667 ; 72 750 ; **74 709** ; 75 667 ; 76 041 ; 78 166.

**Médiane des médianes (position 4 sur 7) :** **74 709 ns ≈ 74.7 µs.**

## Analyse

- **Pattern bimodal** : runs 1-2 mesurent ~60 µs (GO local), runs 3-7 mesurent 73-78 µs (NO-GO local). La transition se produit entre le run 2 et le run 3 — moment où la pause de 30 s ne suffit plus à ramener la machine au quiescent observé au démarrage.
- **Imbalance dans le gate** sur tous les runs (max 8.72 %, gate 15 %). Le scheduler répartit correctement la charge — la dégradation observée n'est pas une régression du work-stealing.
- **p99 et max** suivent le même pattern : runs 1-2 stables (p99 87-92 µs, max 92-118 µs), runs 3-7 dégradés (p99 107-150 µs, max 120-186 µs). La queue de distribution est sensible à l'état machine, ce qui est cohérent avec le bruit OS sur la zone non-critique.
- **Médiane est stable intra-régime** : 60.0 / 60.7 µs pour le régime « quiescent », 72-78 µs pour le régime « warm ». La variance intra-régime est faible (< 5 % entre runs successifs du même régime), ce qui exclut un bruit de mesure ponctuel.

Le diagnostic n'est PAS livré comme justification — c'est une observation factuelle pour le retour Claude.ai.

## Gate

**Lecture stricte de `engine-phase-0-criteria.md § Méthodologie bench` :**

- Gate strict : médiane des médianes ≤ 65 µs (gate +5 % vs baseline S1 cold-isolé Apple Silicon ReleaseSafe).
- Mesurée : médiane des médianes = **74.7 µs**.
- Excès vs gate : **+9.7 µs (+15 %)** au-dessus de la limite.

**Verdict : NO-GO (FAIL strict).**

## Conclusion

Le bench S1 cold-isolé ne passe pas le gate strict 65 µs au commit `f2f823d` de la branche `phase-0/core/rtti-resources-events-bindgen` (HEAD pré-tag M0.2).

Conformément à la procédure de bench opposable, aucune mitigation unilatérale n'est proposée — pas de re-run cherry-pick, pas de re-tune de paramètres, pas d'ajustement du gate. Le verdict FAIL est archivé tel quel.

**Blocage Cas 2 — retour Claude.ai requis avant tag M0.2.**

## Référence baseline pour l'audit retour

- Baseline S1 cold-isolé v0.0.2 (Apple Silicon M4 Pro ReleaseSafe) : médiane 54.5 µs.
- Gate strict M0.2 (engine-phase-0-criteria.md C0.1 sub-gate S1) : 65 µs.
- Mesure cold-isolé M0.2 : médiane des médianes 74.7 µs (FAIL, +37 % vs baseline ; +15 % vs gate).
