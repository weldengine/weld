# Weld Engine — Claude Code working memory

A 100% Zig game engine. This file is read by Claude Code at the start of every
session and captures the operational state of the project plus the rules that
must never be violated. The full specification lives in the claude.ai
knowledge base — see § Quick links spec.

> **Status:** Phase −1 closed (7/7 spikes validated) — Phase 0 (Fondations) opens
>
> Phase −1 wraps with tag `v0.0.7-S6-ipc-round-trip` (2026-05-18,
> S6 — IPC editor↔runtime round-trip). All seven engineering
> hypotheses (S0–S6) cleared their gates: S1 18× (54.5 µs / 1 ms),
> S3 263× (0.019 ms / 5 ms), S4 27× (0.603 ms / 10 ms tick budget),
> S5 cold 27× / incremental 1.9× (1104 ms / 30 s, 1066 ms / 2 s),
> S6 RTT 166× (6 µs p50 / 1 ms). Three Phase 0.6 debts carried
> forward: SCM_RIGHTS fd-passing as primary POSIX shm attach
> (macOS BSD shm cross-process quirk diagnosed in
> `validation/s6-go-nogo.md`), editor Windows path wire-up
> (`src/editor/main.zig` returns `error.Unimplemented`), and
> `transport_windows.zig:sendWithHandles` (Phase 3, with the GPU
> shared framebuffer). Phase 0 entry point: `engine-spec.md` §25.3
> and `engine-phase-0-plan.md`.

## Current state

| Field | Value |
|---|---|
| Phase | 0 (Fondations) |
| Current milestone | (none — between milestones) |
| Last released tag | `v0.0.7-S6-ipc-round-trip` |
| Active branch | `main` |
| Next planned milestone | M0.0 — custom Zig linter + housekeeping |

## Tags

| Tag | Date | Milestone | Notes |
|---|---|---|---|
| `v0.0.1-S0-bootstrap` | 2026-05-08 | S0 — Bootstrap repo and CI | First milestone. Build infra, CI on `{ubuntu-24.04, windows-2025} × {Debug, ReleaseSafe}`, lefthook, `CLAUDE.md`. Tag posted by Guy after merge of PR #1. |
| `v0.0.2-S1-mini-ecs` | 2026-05-09 | S1 — Mini-ECS Zig | Comptime SoA archetype + Chase-Lev work-stealing scheduler. Validates the comptime + work-stealing hypothesis (100k entities iterated in 54.5 µs median ReleaseSafe on M4 Pro reference, gate 1 ms). |
| `v0.0.3-S2-window-vulkan-triangle` | 2026-05-11 | S2 — Window + Vulkan triangle | Native Win32 + Wayland windowing, Vulkan triangle, no SDL/GLFW. Validated GO on Win11 + RTX 4080, Fedora 44 + UHD 630, Fedora 44 + GTX 1660 Ti. |
| `v0.0.4-S3-etch-parser-subset` | 2026-05-15 | S3 — Etch parser on subset | Lexer + parser + tabular SoA AST + minimal type-checker on 5 constructs. Bench verdict GO (worst median 0.019 ms vs 5 ms target on dev machine; re-confirmation on reference machine pending). |
| `v0.0.5-S4-etch-tree-walking-interpreter` | 2026-05-16 | S4 — Etch tree-walking interpreter | Interpreter over S3 AST + additive Tier 0 ECS (runtime registry, dynamic archetype, resource store, runtime query). 20-program differential corpus. Bench verdict GO (median 0.603 ms / tick at 1 000 entities × 5 rules, gate 10 ms; median 6.593 ms / tick at 10 000 × 5, gate 100 ms) on dev Apple Silicon ReleaseSafe. |
| `v0.0.6-S5-etch-codegen-zig` | 2026-05-17 | S5 — Etch → Zig codegen and compile-time measurement | Etch → Zig codegen on the S3 subset. `extern struct` types + comptime `world.query(.{T1, T2})` iteration (via `src/core/ecs/comptime_query.zig`), with `Registry.registerAlias` letting components be keyed by both Etch name and `@typeName(T)`. `tools/etch_cook` consolidates N inputs into one `.zig`. 100-file synthetic corpus + 3-metric bench. Verdict GO on all 5 gates: (a)+(b) cold 1104 ms vs 30 s, (a)+(c) incremental 1066 ms vs 2 s, zero leak, **382 distinct comptime query instantiations on 400 rules (ceiling 4×=1528)**, 20/20 differential parity. |
| `v0.0.7-S6-ipc-round-trip` | 2026-05-18 | S6 — IPC editor↔runtime round-trip | Tier 0 `src/core/ipc/` (transport, framing, shm, viewport, server, client, connection). Two binaries `weld-editor` + `weld-runtime` at canonical `src/editor/` and `src/runtime/`. Fullscreen-triangle Vulkan blit pipeline + SPIR-V committed. RTT bench Apple Silicon ReleaseSafe: p50 6 µs / p99 16 µs / max 61 µs / stddev 3 µs (G1 < 1 ms cleared by 166×, G2 cleared). G6 visual GO on Fedora 44 + GTX 1660 Ti dev box (60 s, no tearing, no stale > 100 ms). G7 fd-passing POSIX GO. Linux CI + Windows CI = GO; macOS dev primary = partial — BSD shm cross-process quirk documented in `validation/s6-go-nogo.md` § Diagnostics, migration to SCM_RIGHTS fd-passing tracked Phase 0.6. |

## Hypotheses validated by spikes

| Spike | Hypothesis | Status |
|---|---|---|
| S0 | Infrastructure ready (no engineering hypothesis) | validated |
| S1 | comptime ECS + Chase-Lev work-stealing iterates 100k entities < 1 ms | validated (54.5 µs median on M4 Pro) |
| S2 | Window Win32 + Wayland + Vulkan triangle, native Zig, no SDL/GLFW | validated (3/3 target machines green, validation/s2-go-nogo.md ✅ GO) |
| S3 | Etch grammar EBNF v0.6 (S3 subset) implementable, parsing < 5 ms / file | validated (worst median 0.019 ms on dev Apple Silicon ReleaseSafe; reference-machine re-run pending) |
| S4 | AST tree-walking interpreter executes Etch correctly with ECS bridge | validated (20-program differential corpus green; bench median 0.603 ms / tick @ 1 000 × 5 vs 10 ms gate on dev Apple Silicon ReleaseSafe) |
| S5 | Etch → Zig codegen viable build-time-wise (incremental < 2 s) | validated (5/5 gates GO; cold (a)+(b) 1104 ms vs 30 s gate, incremental (a)+(c) 1066 ms vs 2 s gate, 382 distinct comptime query instantiations on dev Apple Silicon ReleaseSafe; 100-file synth corpus + 20-program differential parity) |
| S6 | IPC editor↔runtime stable, < 1 ms RTT, 1h fuzz, kill -9 recovery | validated (RTT p50 6 µs vs 1 ms gate — 166× margin — on dev Apple Silicon ReleaseSafe; Linux + Windows CI GO; G6 visual GO on Fedora 44 + GTX 1660 Ti dev box; macOS dev primary partial — BSD shm cross-process quirk tracked to Phase 0.6 SCM_RIGHTS fd-passing migration) |

## Open / deferred decisions

- **macOS in the CI matrix**: deferred, re-evaluated after Phase 0 (CI quota constraints, primary targets are Win11 + Fedora 44).
- **Codeberg migration**: end of Phase 1 (criterion C1.10 in `engine-phase-1-criteria.md`). The repo lives on GitHub for Phase −1 / 0 / 1.
- **`spec/` directory in the repo**: out of scope for Phase −1. Spec lives in the claude.ai knowledge base; re-evaluated during Phase 0 if the absence creates friction.
- **SCM_RIGHTS fd-passing as primary POSIX shm attach (Phase 0.6)**: the S6 BSD shm cross-process diagnostic showed `shm_open(O_RDWR)` is structurally refused for non-creator siblings on macOS even with same UID. The Phase 0.6 migration ships the create fd via the existing AF_UNIX socket (`IpcSocket.sendWithHandles`, G7 GO) and has the runtime `mmap` directly on the received fd. Sidesteps the macOS quirk completely; cleaner protocol on every platform. `engine-ipc.md` §4.7 to be patched at the same time.
- **Editor stub Windows path (Phase 0.6)**: `src/editor/main.zig` returns `error.Unimplemented` on Windows. `CreateProcessW` + named pipe + the S2 Win32 window backend already exist — wiring it up is Phase 0.6 work.
- **`sendWithHandles` Windows (Phase 3)**: `transport_windows.zig:sendWithHandles` returns `error.Unimplemented`. The `DuplicateHandle`-based equivalent lands with the GPU shared framebuffer when an exportable Vulkan semaphore appears upstream (cf. `engine-ipc.md` §4.7).

## Non-negotiable rules

- **Zig version**: 0.16.x strict. Patch bumps (0.16.1, 0.16.2, …) are accepted transparently; minor bumps (0.17+) require a dedicated migration milestone with audit and CI green-light. The `build.zig` version guard panics if the running compiler's minor is not 16.
- **No `@cImport`** outside generated `*_binding.zig` files for the 7 authorized C bindings. (Not yet enforced by linter — will be enforced by the M0.0 Zig linter milestone.)
- **No `usingnamespace`** anywhere. Use explicit `pub const` re-exports.
- **Never use** `git commit --no-verify` or `git push --no-verify`. If a hook fails, fix the underlying cause — do not bypass.
- **Conventional Commits** mandatory on every commit. Types: `feat`, `fix`, `perf`, `refactor`, `test`, `docs`, `chore`, `breaking`. Optional scope `[a-z0-9-]+`. Optional `!` for breaking change. Description 1–72 chars, lowercase first letter, no trailing period. The `commit-msg` hook enforces this locally; CI rejects offending commits.
- **Squash-and-merge** as the default merge strategy on `main`. One milestone = one commit on `main`.
- **No external dependency** beyond the 7 authorized C keepers (cf. `engine-spec.md` §1.6): ONNX Runtime, Opus, Assimp, KTX/Basis Universal, libdatachannel, ACL compressor, HarfBuzz. Plus the standards adapted automatically (Vulkan/Wayland/OpenXR XML) and Apple frameworks where relevant. Anything else requires a dedicated derogation in `engine-spec.md`.

## Quick links spec

The full specification is in the claude.ai knowledge base. Files referenced by name (no repo path — `spec/` is not in the repo).

Core docs (must read first for most milestones):

- `engine-spec.md` — top-level architecture, modules, roadmap (§22)
- `engine-development-workflow.md` — milestone model, brief format, git conventions, review cycle
- `engine-zig-conventions.md` — Zig style for the whole engine (§17 build system, §18 migration policy)
- `engine-phase-0-criteria.md` — measurable exit criteria for Phase 0

Module / topic docs available in the knowledge base:

- Tier 0 / API : `engine-tier-interfaces.md`, `engine-c-api.md`
- Modules Tier 1 : `engine-render.md`, `engine-physics-forge.md`,
  `engine-physics-forge-2d.md`, `engine-audio-pulse.md`,
  `engine-ai-cortex.md`, `engine-vfx-ember.md`,
  `engine-animation-kinesis.md`, `engine-networking-relay.md`,
  `engine-ui.md`, `engine-tools-editor.md`, `engine-sequencer.md`,
  `engine-sprite.md`, `engine-input-system.md`, `engine-debug.md`,
  `engine-media.md`, `engine-asset-pipeline.md`
- Sous-systèmes : `engine-c-bindings.md`, `engine-ipc.md`,
  `engine-ecs-internals.md`, `engine-coordinate-system.md`,
  `engine-units.md`, `engine-color-picker.md`,
  `engine-collaboration.md`, `engine-platform.md`, `engine-vr-ar.md`,
  `engine-movement.md`, `engine-motion-design.md`,
  `engine-scene-serialization.md`, `engine-gameplay-systems.md`,
  `engine-mach-reference.md`, `engine-project-settings.md`,
  `engine-directory-structure.md`, `engine-terminologie.md`,
  `engine-phase-1-criteria.md`
- Etch : `etch-grammar.md`, `etch-visual-scripting.md`
- Templates : `brief-milestone_template.md`,
  `prompt-claude-code_template.md`
- Mockups : `prompt-editor-mockups.md`

The full set of `engine-*.md`, `etch-*.md`, `weld-*.md`, and template
files lives in the claude.ai project. **Never guess a spec filename.**
If a spec referenced in a brief or in conversation is not in the list
above and you are uncertain of its exact name, stop and ask Guy — do
not invent a plausible-looking filename. Hallucinated filenames cause
friction in subsequent sessions.

## Workflow reminder (Claude Code protocol)

1. **Read the brief** for the milestone (in `briefs/<id>-<slug>.md`, committed as the first commit of the milestone branch).
2. **Request the spec docs** listed under "Spec documents to read first" — Guy attaches them.
3. **Read those docs** in order, in full (no skim). Tick them off in the brief's "Specs read" section with timestamps.
4. **Implement** strictly within the brief's scope. Granular Conventional Commits. Update the brief's "Execution log" as you go.

If blocked by a point not covered by the brief or its referenced specs: stop, log it under "Blockers encountered" in the brief, push, and signal Guy. No silent workarounds.

The `briefs/` directory is the source of truth for milestone state. The brief's FROZEN SECTION is editable only via a Claude.ai round-trip (tracked under "Acted deviations").

## Workflow

### Thermal-aware bench MBP M-series

- `caffeinate -i` est obligatoire pour toute boucle de validation longue
  (E7 stress, bench multi-run) sur MBP. Sans lui, macOS endort la machine
  sur les fenêtres d'idle protocolaires et produit de faux positifs de
  hang. À acter dans `engine-phase-0-criteria.md` § Méthodologie bench.

### Milestone hotfix à cause root inconnue

- Format M0.2.1 reproductible : décomposition E1..En avec stop systématique
  entre étapes + N décisions interdites en autonomie listées en § Notes du
  brief. Les retours Claude.ai fréquents sont du protocole, pas du re-scope.
  La règle workflow §2.4 « 2+ blocages = re-scope » vise les défaillances
  de cadrage, pas les décisions structurelles prévues par le brief.
- Pattern de validation tiers cumulatifs : Tier 1 synthétique rapide
  (faux positif statistiquement faible mais qualitativement incomplet) +
  Tier 2 authentique slow (couverture qualitative). Inversion du raisonnement
  vs « plus de runs synthétiques = meilleure validation » qui rate les
  charges de travail VM/cache non-répliquables synthétiquement.

## Anti-hallucination

### Discipline E1 analyse statique

- En E1 d'un milestone de diagnostic, confirmer chaque symbole nommé dans
  le brief par lecture directe du code. Le brief M0.2.1 mentionnait
  `helpUntilDone` comme hypothèse — qui n'existait pas dans le code.
  Sans cette vérification, le diagnostic se serait déroulé autour d'un
  fantôme. À appliquer systématiquement dans les briefs de diagnostic
  futurs : les noms de symboles dans la SECTION FIGÉE sont des candidats
  à vérifier, pas des affirmations.

## Patterns

### Atomic packing pour racing snapshots

- Quand deux champs `(a: u32, b: u32)` doivent être lus comme un snapshot
  cohérent depuis un thread non-writer, packer en un seul
  `std.atomic.Value(u64) align(64)` avec helpers `pack`/`unpack` est
  préférable à un pattern double-check + retry. Coût perf nul (load 64-bit
  aligné = load 32-bit aligné sur Apple Silicon et x86_64), robustesse
  préservée face aux refactors (impossible de casser silencieusement).
  Réutilisable au-delà du job system — n'importe quel scheduler
  (frame state, generation counters, version+epoch) suit ce pattern.

### Comptime layout guards

- Pour les invariants de layout cache-line entre champs `align(64)`
  écrits par des threads différents, ajouter un `comptime {
  std.debug.assert(@offsetOf(...) ...); }` proche de la déclaration de la
  struct. Pin l'invariant à la compilation, résiste aux refactors
  silencieux qui réorganisent les champs. Voir M0.2.1 fix scheduler.zig.

## Garde-fous

### Interprétation prudente des baselines bench héritées

- Le commit squash M0.1 listait C0.1 à 14.2 ms ; M0.2.1 mesure 3.74 ms en
  thermal-aware ReleaseFast. Ratio 3.8× cohérent avec un écart
  ReleaseSafe → ReleaseFast. Avant d'opposer une baseline héritée, vérifier
  qu'elle a été mesurée selon le protocole opposable courant
  (`engine-phase-0-criteria.md` § Méthodologie bench). Pour les baselines
  Phase 0 ancien protocole, la première mesure conforme au protocole
  thermal-aware est une candidate plus robuste que la valeur héritée.

---

Last updated: 2026-05-24
