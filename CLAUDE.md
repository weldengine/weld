# Weld Engine — Claude Code working memory

A 100% Zig game engine. This file is read by Claude Code at the start of every
session and captures the operational state of the project plus the rules that
must never be violated. The full specification lives in the claude.ai
knowledge base — see § Quick links spec.

> **Status:** Phase −1 — S1 next
>
> S0 closed: Zig 0.16.x build skeleton in place, CI green on Linux + Windows
> (Debug + ReleaseSafe), local hooks (lefthook) installed, repo metadata
> committed. Next milestone is S1 (mini-ECS Zig spike).

## Current state

| Field | Value |
|---|---|
| Phase | −1 (Spikes) |
| Current milestone | _(none active — S0 closed)_ |
| Last released tag | `v0.0.1-S0-bootstrap` |
| Active branch | `main` |
| Next planned milestone | S1 — Mini-ECS Zig (Chase-Lev jobs + comptime SoA archetype) |

## Tags

| Tag | Date | Milestone | Notes |
|---|---|---|---|
| `v0.0.1-S0-bootstrap` | 2026-05-08 | S0 — Bootstrap repo and CI | First milestone. Build infra, CI on `{ubuntu-24.04, windows-2025} × {Debug, ReleaseSafe}`, lefthook, `CLAUDE.md`. Tag posted by Guy after merge of PR #1. |

## Hypotheses validated by spikes

| Spike | Hypothesis | Status |
|---|---|---|
| S0 | Infrastructure ready (no engineering hypothesis) | validated |
| S1 | comptime ECS + Chase-Lev work-stealing iterates 100k entities < 1 ms | pending |
| S2 | Window Win32 + Wayland + Vulkan triangle, native Zig, no SDL/GLFW | pending |
| S3 | Etch grammar EBNF v0.5 implementable, parsing < 5 ms / file | pending |
| S4 | AST tree-walking interpreter executes Etch correctly with ECS bridge | pending |
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

- `engine-c-bindings.md`, `engine-ipc.md`, `engine-render.md`, `engine-vfx-ember.md`, `engine-physics-forge.md`, `engine-audio-pulse.md`, `engine-ai-cortex.md`, `engine-network-relay.md`, `engine-asset-pipeline.md`, `engine-editor-islandz.md`, `engine-tier0-interfaces.md`, `engine-c-api.md`, `engine-directory-structure.md`, `engine-phase-1-criteria.md`
- `etch-spec.md`, `etch-grammar.md`, `etch-runtime.md`, …

The full set of `engine-*.md` and `etch-*.md` files lives in the claude.ai project. Ask Guy to paste an excerpt when needed mid-session — never guess.

## Workflow reminder (Claude Code protocol)

1. **Read the brief** for the milestone (in `briefs/<id>-<slug>.md`, committed as the first commit of the milestone branch).
2. **Request the spec docs** listed under "Spec documents to read first" — Guy attaches them.
3. **Read those docs** in order, in full (no skim). Tick them off in the brief's "Specs read" section with timestamps.
4. **Implement** strictly within the brief's scope. Granular Conventional Commits. Update the brief's "Execution log" as you go.

If blocked by a point not covered by the brief or its referenced specs: stop, log it under "Blockers encountered" in the brief, push, and signal Guy. No silent workarounds.

The `briefs/` directory is the source of truth for milestone state. The brief's FROZEN SECTION is editable only via a Claude.ai round-trip (tracked under "Acted deviations").

---

Last updated: 2026-05-08
