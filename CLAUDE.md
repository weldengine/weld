# Weld Engine — Claude Code working memory

A 100% Zig game engine. This file is read by Claude Code at the start of every
session and captures the operational state of the project plus the rules that
must never be violated. The full specification lives in the claude.ai
knowledge base — see § Quick links spec.

> **Status:** Phase −1 — S4 closed (code + bench verdict GO), PR pending
>
> S4 closed: tree-walking interpreter over the S3 AST plus the additive
> Tier 0 ECS surface required to host it (runtime component registry,
> dynamic SoA archetype, resource store, runtime query, world dynamic
> spawn / tickBoundary). Public surface `Interpreter`, `Value`,
> `RuntimeReport`, `runProgram`, `evalConst` exported through
> `src/etch/root.zig`. 20-program differential corpus under
> `tests/etch_interp/` parameterised by a `Runner` interface
> (interpreter runner today, codegen runner in S5). Bench verdict on dev
> machine (Apple Silicon, macOS, ReleaseSafe, 1 000 ticks @ 1 000
> entities + 100 ticks @ 10 000 entities, 50 warmup ticks): median
> 0.603 ms / tick at 1 000 × 5 (gate 10 ms), median 6.593 ms / tick at
> 10 000 × 5 (gate 100 ms). Validation: `zig build`, `zig build test`
> (debug + ReleaseSafe), `zig fmt --check` all green. PR
> `Phase -1 / Etch / Tree-walking interpreter` opens next; tag
> `v0.0.5-S4-etch-tree-walking-interpreter` posted by Guy after
> squash-merge.

## Current state

| Field | Value |
|---|---|
| Phase | −1 (Spikes) |
| Current milestone | S4 — Etch tree-walking interpreter (CLOSED, PR pending) |
| Last released tag | `v0.0.3-S2-window-vulkan-triangle` |
| Active branch | `phase-pre-0/etch/tree-walking-interpreter` |
| Next planned milestone | S5 — Etch → Zig codegen + compile-time measurement |

## Tags

| Tag | Date | Milestone | Notes |
|---|---|---|---|
| `v0.0.1-S0-bootstrap` | 2026-05-08 | S0 — Bootstrap repo and CI | First milestone. Build infra, CI on `{ubuntu-24.04, windows-2025} × {Debug, ReleaseSafe}`, lefthook, `CLAUDE.md`. Tag posted by Guy after merge of PR #1. |
| `v0.0.2-S1-mini-ecs` | 2026-05-09 (planned) | S1 — Mini-ECS Zig | Comptime SoA archetype + Chase-Lev work-stealing scheduler. Validates the comptime + work-stealing hypothesis (100k entities iterated in 54.5 µs median ReleaseSafe on M4 Pro reference, gate 1 ms). Tag posted by Guy after squash-merge of PR `Phase -1 / Core / Mini-ECS Zig`. |
| `v0.0.3-S2-window-vulkan-triangle` | (planned) | S2 — Window + Vulkan triangle | Native Win32 + Wayland windowing, Vulkan triangle, no SDL/GLFW. Validated GO on Win11 + RTX 4080, Fedora 44 + UHD 630, Fedora 44 + GTX 1660 Ti. |
| `v0.0.4-S3-etch-parser-subset` | (planned) | S3 — Etch parser on subset | Lexer + parser + tabular SoA AST + minimal type-checker on 5 constructs. Bench verdict GO (worst median 0.019 ms vs 5 ms target on dev machine; re-confirmation on reference machine pending). |
| `v0.0.5-S4-etch-tree-walking-interpreter` | (planned) | S4 — Etch tree-walking interpreter | Interpreter over S3 AST + additive Tier 0 ECS (runtime registry, dynamic archetype, resource store, runtime query). 20-program differential corpus. Bench verdict GO (median 0.603 ms / tick at 1 000 entities × 5 rules, gate 10 ms; median 6.593 ms / tick at 10 000 × 5, gate 100 ms) on dev Apple Silicon ReleaseSafe. |

## Hypotheses validated by spikes

| Spike | Hypothesis | Status |
|---|---|---|
| S0 | Infrastructure ready (no engineering hypothesis) | validated |
| S1 | comptime ECS + Chase-Lev work-stealing iterates 100k entities < 1 ms | validated (54.5 µs median on M4 Pro) |
| S2 | Window Win32 + Wayland + Vulkan triangle, native Zig, no SDL/GLFW | validated (3/3 target machines green, validation/s2-go-nogo.md ✅ GO) |
| S3 | Etch grammar EBNF v0.6 (S3 subset) implementable, parsing < 5 ms / file | validated (worst median 0.019 ms on dev Apple Silicon ReleaseSafe; reference-machine re-run pending) |
| S4 | AST tree-walking interpreter executes Etch correctly with ECS bridge | validated (20-program differential corpus green; bench median 0.603 ms / tick @ 1 000 × 5 vs 10 ms gate on dev Apple Silicon ReleaseSafe) |
| S5 | Etch → Zig codegen viable build-time-wise (incremental < 2 s) | pending |
| S6 | IPC editor↔runtime stable, < 1 ms RTT, 1h fuzz, kill -9 recovery | pending |

## Open / deferred decisions

- **Custom Zig linter** (`zig build lint`, `zig build lint-commit`): deferred to a dedicated Phase 0 milestone post-S1. No production code to lint at S0; the `commit-msg` hook uses a POSIX shell script (`scripts/check-commit-msg.sh`) until then.
- **macOS in the CI matrix**: deferred, re-evaluated after Phase 0 (CI quota constraints, primary targets are Win11 + Fedora 44).
- **Codeberg migration**: end of Phase 1 (criterion C1.10 in `engine-phase-1-criteria.md`). The repo lives on GitHub for Phase −1 / 0 / 1.
- **`spec/` directory in the repo**: out of scope at S0 per `engine-development-workflow.md` §3.5. Spec lives in the claude.ai knowledge base; re-evaluated at the start of Phase 0 if the absence creates friction.

## Non-negotiable rules

- **Zig version**: 0.16.x strict. Patch bumps (0.16.1, 0.16.2, …) are accepted transparently; minor bumps (0.17+) require a dedicated migration milestone with audit and CI green-light. The `build.zig` version guard panics if the running compiler's minor is not 16.
- **No `@cImport`** outside generated `*_binding.zig` files for the 8 authorized C bindings. (Not yet enforced by linter — will be enforced by the post-S1 Zig linter milestone.)
- **No `usingnamespace`** anywhere. Use explicit `pub const` re-exports.
- **Never use** `git commit --no-verify` or `git push --no-verify`. If a hook fails, fix the underlying cause — do not bypass.
- **Conventional Commits** mandatory on every commit. Types: `feat`, `fix`, `perf`, `refactor`, `test`, `docs`, `chore`, `breaking`. Optional scope `[a-z0-9-]+`. Optional `!` for breaking change. Description 1–72 chars, lowercase first letter, no trailing period. The `commit-msg` hook enforces this locally; CI rejects offending commits.
- **Squash-and-merge** as the default merge strategy on `main`. One milestone = one commit on `main`.
- **No external dependency** beyond the 8 authorized C keepers (cf. `engine-spec.md` §1.6): ONNX Runtime, Opus, Assimp, KTX/Basis Universal, libdatachannel, ACL compressor, tree-sitter, HarfBuzz. Plus the standards adapted automatically (Vulkan/Wayland/OpenXR XML) and Apple frameworks where relevant. Anything else requires a dedicated derogation in `engine-spec.md`.

## Quick links spec

The full specification is in the claude.ai knowledge base. Files referenced by name (no repo path — `spec/` is not in the repo).

Core docs (must read first for most milestones):

- `engine-spec.md` — top-level architecture, modules, roadmap (§22)
- `engine-development-workflow.md` — milestone model, brief format, git conventions, review cycle
- `engine-zig-conventions.md` — Zig style for the whole engine (§17 build system, §18 migration policy)
- `engine-phase-0-criteria.md` — measurable exit criteria for Phase 0

Module / topic docs available in the knowledge base:

- Tier 0 / API : `weld-tier0-interfaces.md`, `weld-c-api.md`
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

---

Last updated: 2026-05-15
