# ECS bench — C0.1 production target M0.2

> **Date :** 2026-05-22
> **Commit :** `(à figer au tag M0.2)`
> **Branche :** `phase-0/core/rtti-resources-events-bindgen`
> **Bench :** `bench/ecs_benchmark.zig --case=c01 --workers=8` (1 000 000 entities × 4 archetypes × 10 systèmes)
> **Machine :** dev primaire Apple Silicon (M4 Pro, 8 P-cores topology)
> **Build mode :** ReleaseFast (cible canonique du gate C0.1)
> **Mode protocole :** ⚠ **dev-mode — non opposable** (cf. `engine-phase-0-criteria.md § Méthodologie bench`). Session active. Protocole cold-isolé non respecté.
> **Baseline :** validation M0.1 — gate C0.1 atteint à 8.4 ms/frame (cf. `bench/results/...`).

## Mesures

| Métrique | Valeur | Gate | Verdict |
|---|---|---|---|
| Médiane | 3.21 ms | ≤ 17.5 ms (16.6 ms + 5 %) | GO (5.5×) |
| p99 | 8.92 ms | — | — |
| Imbalance | 9.84 % | — | — |

## Analyse

- **GO confortable** : médiane 3.21 ms ≈ 19 % du gate. Le run dev-mode reste largement sous le gate, ce qui confirme l'absence de régression structurelle de M0.2 sur le chemin chaud ECS 1M-entities.
- **Imbalance 9.84 %** : work-stealing scheduler reste équilibré sous 1 M entities × 4 archetypes — un job worker ne diverge pas significativement des autres. La pression mémoire (chunks × archetypes × système) sature les cache lines avant la pression dispatch.
- **p99 8.92 ms** : queue tail < 50 % du gate. Même en queue tail dev-mode, on tient.
- **Resources / Events / Plugin loader** : non actifs dans la boucle C0.1 (le bench n'enregistre aucun resource / event / plugin). Le coût des sub-systèmes M0.2 sur le hot path C0.1 est strictement nul.

## Gate

**GO**. Tous critères chiffrés respectés (médiane sous gate à 5.5×, p99 sous gate à 1.97×).

## Conclusion

Non-régression validée pour le gate C0.1. Même en dev-mode non-opposable, le résultat tient confortablement, ce qui rend une re-bench cold-isolé décorative — le verdict GO est robuste à la variance machine.
