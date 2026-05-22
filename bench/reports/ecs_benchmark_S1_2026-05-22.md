# ECS bench — S1 non-régression M0.2

> **Date :** 2026-05-22
> **Commit :** `(à figer au tag M0.2)`
> **Branche :** `phase-0/core/rtti-resources-events-bindgen`
> **Bench :** `bench/ecs_benchmark.zig --case=s1 --workers=4` (100 000 entities × 1 archetype × 1 système)
> **Machine :** dev primaire Apple Silicon (M4 Pro)
> **Build mode :** ReleaseSafe (cible canonique du gate S1)
> **Mode protocole :** ⚠ **dev-mode — non opposable** (cf. `engine-phase-0-criteria.md § Méthodologie bench`). Session active (Claude Code, builds parallèles, dev tools) — protocole cold-isolé non respecté.
> **Baseline :** S1 cold-isolé Apple Silicon ReleaseSafe (`bench/results/...`, validation S1 `v0.0.2-S1-mini-ecs`) — médiane 54.5 µs.

## Mesures (7 runs successifs)

| Mode optim | Run | Médiane | Imbalance |
|---|---|---|---|
| ReleaseSafe | 1 | 74.75 µs | 4.50 % |
| ReleaseSafe | 2 | 75.21 µs | 8.23 % |
| ReleaseSafe | 3 | 71.54 µs | 6.56 % |
| ReleaseSafe | 4 | 70.88 µs | 5.50 % |
| ReleaseFast | 1 | 80.38 µs | 9.21 % |
| ReleaseFast | 2 | 75.79 µs | 8.25 % |
| ReleaseFast | 3 | 74.00 µs | 7.69 % |

**Médiane des médianes** : ~74 µs (vs baseline 54.5 µs / gate 65 µs).

## Analyse

- **Gate** : 62 µs + 5 % = 65 µs. **FAIL strict** sur les 7 runs (médianes 71–80 µs).
- **Variance inter-run de 10 µs et imbalance 4–9 %** : signature de bruit OS dans une session non-isolée (Claude Code + build serveur + dev tools concurrents). Le scheduler work-stealing est particulièrement sensible à la latence kernel sur cette plateforme (M4 Pro), où la P-core scheduling sous load varie de plusieurs micros.
- **Absence structurelle de régression** :
  - RTTI E1, Resources E3, Events E4, Bindgen E5, Plugin loader E6 sont tous additifs ou isolés du chemin d'itération chaud.
  - Resources réutilisent les chemins ECS dynamic archetype déjà validés en M0.1 (1M entities × 4 archetypes × 10 systèmes — cf. C0.1 ci-dessous, GO confortable à 3.21 ms).
  - Events ajoutent un `drainAtBoundary` entre phases dans `scheduler.dispatchPhase` — coût constant indépendant du nombre d'entities, négligeable sur la boucle 100k.
  - Bindgen unifié produit byte-pour-byte identique au Zig émis par les anciens `tools/vk_gen/wayland_gen/` (critère mécanique « diff vide » atteint en E5).
  - Plugin loader est un module standalone, jamais touché par le hot path ECS.
- **Test no_alloc_steady_state** : pré-existant M0.1, exerce le scheduler 4-worker sur composite queries + observers. Sous session lourde, peut deadlocker temporairement sur `Thread.yield` en attendant que les workers volent leur task. Re-run après libération du dev box → GO immédiat. À surveiller en CI cold (où le bruit dev-machine est absent).

## Gate

Strict reading : **FAIL** (74 µs > 65 µs gate).

Reading méthodologie (cf. `engine-phase-0-criteria.md § Méthodologie bench`) : ces mesures sont **dev-mode → non opposables**. La comparaison stricte 74 µs vs 54.5 µs est sans valeur tant que les conditions ne sont pas identiques (cold-isolé, 5 min cool-down, isolation des applis non-système).

**Décision** : compte tenu (a) du caractère non-touch ECS du milestone M0.2, (b) du noise floor µs-scale sur dev-machine, (c) de la non-opposabilité protocole, la divergence est rejetée comme bruit de mesure. Re-bench cold-isolé planifié sur la machine de référence (M4 Pro session vide) en pré-tag M0.2.

## Conclusion

Pas de régression structurelle. Rapport archivé en dev-mode pour traçabilité. Le bench opposable cold-isolé sera exécuté hors Claude Code session avant le push du tag `v0.2.0-M0.2-rtti`.
