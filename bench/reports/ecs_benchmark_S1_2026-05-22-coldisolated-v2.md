# S1 ECS bench — M0.2 / E6 cold-isolated re-bench (v2, strict protocol)

> **Date :** 2026-05-22
> **Commit :** `4de00f6` (HEAD `phase-0/core/rtti-resources-events-bindgen` pré-tag M0.2)
> **Branche :** `phase-0/core/rtti-resources-events-bindgen`
> **Bench :** `zig-out/bin/ecs-benchmark --case=s1 --workers=4`
> **Source :** `bench/ecs_benchmark.zig` (S1 non-regression : 100 000 entités × 1 archetype × 1 système, `--workers=4`)
> **Machine :** dev primaire Apple M4 Pro (même hardware que la baseline 62 µs post-recalibration M0.1/E6)
> **Build mode :** ReleaseSafe (cible canonique du target `bench-ecs`, Debug rejeté par le bench)
> **Mode protocole :** **cold-isolé strict spec-conforme** (5 min cool-down initial + 2 min pause inter-run, machine pré-confirmée par Guy en état isolé — DND/Focus actif, toutes apps non-système fermées, pas de Time Machine / Spotlight / sync iCloud)
> **Baseline :** S1 cold-isolé Apple M4 Pro ReleaseSafe (gate canonique post-recalibration M0.1/E6) — médiane 62 µs / gate strict 65 µs (gate +5 %)
> **Predecessor :** v1 `bench/reports/ecs_benchmark_S1_2026-05-22-coldisolated.md` (cool-down 60 s + inter-run 30 s — protocole non spec-conforme, conservé pour traçabilité méthodologique)

## Protocole respecté (preuve timestamps)

| Phase | Début | Fin | Durée | Seuil spec |
|---|---|---|---|---|
| Cool-down initial | 22:44:48 | 22:52:52 | 8 min 04 s | ≥ 5 min ✓ |
| Pause 1→2 | 22:52:52 | 22:54:52 | 2 min 00 s | ≥ 2 min ✓ |
| Pause 2→3 | 22:54:52 | 22:56:52 | 2 min 00 s | ≥ 2 min ✓ |
| Pause 3→4 | 22:56:52 | 22:58:52 | 2 min 00 s | ≥ 2 min ✓ |
| Pause 4→5 | 22:58:52 | 23:00:52 | 2 min 00 s | ≥ 2 min ✓ |
| Pause 5→6 | 23:00:53 | 23:02:53 | 2 min 00 s | ≥ 2 min ✓ |
| Pause 6→7 | 23:02:53 | 23:04:53 | 2 min 00 s | ≥ 2 min ✓ |

Cool-down initial mesuré à 484 s (8 min 04) vs seuil 300 s — la surcharge ~184 s vient du delta entre le `sleep 300` du script et la latence harness/scheduling, donc dans le sens conservatif (machine au repos plus longtemps que strict). Aucun raccourci ; aucune interruption ; aucun retry.

Log brut des timestamps disponible dans `/tmp/s1_strict_runs/log.txt` (généré au tour, non commité car éphémère).

## Mesures (7 runs successifs, ns)

| Run | Timestamp | Min | Médiane | Mean | p95 | p99 | Max | Imbalance | Statut local |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 22:52:52 | 51 459 | **75 166** | 77 876 | 107 333 | 122 750 | 128 375 | 8.40 % | NO-GO |
| 2 | 22:54:52 | 50 708 | **72 125** | 74 213 | 107 125 | 125 625 | 146 125 | 6.76 % | NO-GO |
| 3 | 22:56:52 | 50 958 | **74 583** | 78 282 | 119 083 | 143 917 | 174 958 | 7.17 % | NO-GO |
| 4 | 22:58:52 | 51 291 | **77 000** | 79 380 | 110 125 | 123 417 | 142 792 | 8.10 % | NO-GO |
| 5 | 23:00:52 | 51 667 | **79 958** | 81 904 | 110 333 | 135 875 | 188 625 | 7.76 % | NO-GO |
| 6 | 23:02:53 | 51 291 | **76 708** | 78 747 | 108 917 | 132 167 | 151 667 | 7.28 % | NO-GO |
| 7 | 23:04:53 | 51 125 | **60 000** | 61 882 | 78 208 | 86 583 | 91 083 | 1.60 % | GO |

**Médianes triées ascendantes (ns) :** 60 000 ; 72 125 ; 74 583 ; **75 166** ; 76 708 ; 77 000 ; 79 958.

**Médiane des médianes (position 4 sur 7) :** **75 166 ns ≈ 75.2 µs.**

## Analyse

- **Distribution dominante dans la zone NO-GO** : 6 runs sur 7 mesurent dans la fourchette 72-80 µs. Le 7e run (run 7) sort à 60 µs avec une imbalance de 1.60 % (vs 6.76-8.40 % sur les 6 autres). L'écart entre les deux régimes est sec : il n'y a pas de transition continue, c'est un saut net entre runs 1-6 et run 7.
- **Imbalance corrélée à la médiane** : les runs 1-6 ont une imbalance moyenne ~7.4 %, le run 7 a une imbalance de 1.60 %. La répartition des tâches sur les 4 workers est sensiblement meilleure pour le run rapide. Le coefficient de corrélation visible est élevé : faible imbalance → faible médiane.
- **Aucun motif temporel** : la pause de 2 min entre chaque run est respectée. Le run 7 n'est ni le premier (post-cool-down long) ni un cas particulier de cache cold — il intervient après 6 runs précédents, dans le même régime de pause. Le retour à un régime « rapide » au run 7 n'est pas explicable par la chronologie seule.
- **p99 et max suivent le même clivage** : runs 1-6 ont p99 ∈ [122-144] µs et max ∈ [128-189] µs (queues dégradées). Run 7 a p99 = 86.6 µs et max = 91.1 µs (queue propre, dans les bornes baseline historique).
- **Imbalance dans le gate sur tous les runs** (max 8.40 %, gate 15 %). La répartition workload-vs-worker n'est pas catastrophique sur les runs lents — c'est une dérive de ~5-7 points vs le run 7 qui mesure dans les conditions « historiques ».

Le diagnostic n'est PAS livré comme justification — c'est une observation factuelle pour le retour Claude.ai. Aucune hypothèse sur la cause (RTTI registry init, singleton_resources lookup, event_bus drain, scheduler dispatch overhead, etc.) n'est avancée ici. C'est ton travail.

## Gate

**Lecture stricte des seuils :**

- Gate strict : médiane des médianes ≤ 65 µs (gate +5 % vs baseline S1 cold-isolé Apple M4 Pro ReleaseSafe post-recalibration M0.1/E6 = 62 µs).
- Mesurée : médiane des médianes = **75.2 µs**.
- Excès vs gate : **+10.2 µs (+15.7 %)** au-dessus de la limite.
- Excès vs baseline canonique 62 µs : **+13.2 µs (+21 %)**.
- Excès vs baseline historique S1 v0.0.2 (54.5 µs) : **+20.7 µs (+38 %)**.

**Verdict : NO-GO (FAIL strict en protocole spec-conforme).**

## Conclusion

Le bench S1 ne passe pas le gate strict 65 µs au commit `4de00f6` de la branche `phase-0/core/rtti-resources-events-bindgen`, avec protocole cold-isolé strict spec-conforme (5 min cool-down + 2 min inter-run respectés et tracés timestamps).

Le verdict v1 (NO-GO au protocole non spec-conforme) est confirmé en protocole strict. Le pattern observé est différent (v1 : bimodal sec runs 1-2 vs runs 3-7 ; v2 : 6 runs lents + 1 run rapide outlier) mais la conclusion arithmétique est identique : médiane des médianes > 65 µs.

Conformément à la procédure de bench opposable, aucune mitigation unilatérale n'est proposée — pas de re-run cherry-pick, pas de re-tune de paramètres, pas d'ajustement du gate. Aucune hypothèse de cause de régression n'est avancée. Le verdict FAIL est archivé tel quel pour analyse Claude.ai.

**Blocage Cas 2 — régression structurelle suspectée. Retour Claude.ai requis avant tag M0.2.**

## Référence baseline pour l'audit retour

- Baseline S1 v0.0.2 (Apple Silicon M4 Pro ReleaseSafe, mini-ECS minimal) : médiane 54.5 µs.
- Baseline canonique post-recalibration M0.1/E6 (même machine, ECS Tier 0 complet) : médiane 62 µs.
- Gate strict M0.2 (engine-phase-0-criteria.md C0.1 sub-gate S1) : 65 µs (baseline 62 µs + 5 %).
- Mesure v1 cold-isolé non spec-conforme : médiane-of-médianes 74.7 µs.
- Mesure v2 cold-isolé STRICT spec-conforme : **médiane-of-médianes 75.2 µs (NO-GO confirmé)**.

Surface modifiée entre `v0.1.0-M0.1-ecs-full` (gate 62 µs) et HEAD `4de00f6` :
- E1 RTTI (`src/core/rtti/`) — sub-system additif, pas de wiring ECS hot-path déclaré
- E2 IPC `messages.zig` swap Wyhash → xxHash64 (comptime, pas runtime ECS)
- E3 Resources (`src/core/resources/`) — `singleton_resources: ResourceRegistry` ajouté à `World`, flag `is_singleton: bool` sur `Archetype`, check `if (arch.is_singleton) continue` dans `Query.maybeRescan` + `ComptimeQuery.next`
- E4 Events (`src/core/events/`) — `event_bus: EventBus` ajouté à `World`, appels `drainAtBoundary` aux 3 boundaries du scheduler (`.phase` × 6 + `.tick` + `.frame`)
- E5 Bindgen — refactor tooling pure, aucune touche à `src/core/`
- E6 Plugin loader — `src/core/plugin_loader/`, additif, pas de wiring ECS

Les candidats prima facie pour explorer la régression sont E3 et E4 — les seuls qui touchent la boucle scheduler et la rescan-path des queries. C'est une liste de candidats, pas un diagnostic.
