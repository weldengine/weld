# S0 — Bootstrap repo and CI

> **Status:** ACTIVE
> **Phase:** -1
> **Branch:** `phase-pre-0/bootstrap/repo-and-ci`
> **Planned tag:** `v0.0.1-S0-bootstrap`
> **Dependencies:** none
> **Opened:** 2026-05-08
> **Closed:** —

---

# FROZEN SECTION

*Produced by Claude.ai. Not editable by Claude Code outside a Claude.ai round-trip (cf. § Acted deviations).*

## Context

S0 is the first milestone of Phase −1 and the first milestone of the entire Weld project. It bootstraps the engine repository with the strict minimum required to start working: a buildable Zig 0.16.x skeleton, a green CI on Linux + Windows, local git hooks enforcing format and Conventional Commits, and the infrastructure files (license, gitignore, gitattributes, editorconfig, `CLAUDE.md`) needed for a sustainable workflow. No engine code is produced — S0 validates no engineering hypothesis, it only sets up the rails on which every subsequent milestone runs.

## Scope

- Repository skeleton matching the directory layout listed under § Files to create or modify, with no extra placeholder directories
- `build.zig` + `build.zig.zon` targeting Zig 0.16.x, with a hard build-time panic if the running compiler is not on the 0.16 minor (patches 0.16.x accepted transparently, cf. `engine-zig-conventions.md` §17)
- `build.zig` exposes three steps: default (build the `weld` executable), `test` (run all tests), `run` (execute the built binary)
- GitHub Actions workflow at `.github/workflows/ci.yml` running a 4-job matrix `{ubuntu-24.04, windows-2025} × {Debug, ReleaseSafe}`. Each job runs `zig fmt --check`, `zig build -Doptimize=$MODE`, then `zig build test -Doptimize=$MODE` sequentially
- `lefthook.yml` with three hooks: `pre-commit` (`zig fmt --check` on staged `*.zig`), `commit-msg` (`bash scripts/check-commit-msg.sh {1}`), `pre-push` (`zig build && zig build test`)
- `scripts/check-commit-msg.sh`: POSIX-strict shell script validating Conventional Commits on the commit title line
- `scripts/install-hooks.sh`: idempotent setup script that runs `lefthook install`
- `src/main.zig`: trivial executable entry point with a single inline test
- `tests/smoke_test.zig`: a single trivial passing test, wired into the `test` build step
- Root files: `LICENSE` (MIT), `README.md` (English; project name, status, prerequisites, basic commands), `.gitignore`, `.gitattributes`, `.editorconfig`
- `.vscode/extensions.json` + `.vscode/settings.json`: project-level minimum (Zig extension recommendation, format-on-save for `*.zig`, EOL/whitespace settings consistent with `.editorconfig`)
- `CLAUDE.md` at repository root, English, populated as specified under § Files to create or modify
- `briefs/S0-bootstrap.md`: this brief, committed verbatim as the first commit of the branch

## Out-of-scope

- Custom Zig linter (`weld-lint`, `zig build lint`, `zig build lint-commit`) — deferred to a dedicated Phase 0 milestone post-S1 (no production code to lint at S0)
- `zig build hooks` step — deferred (depends on the Zig linter)
- macOS in the CI matrix — deferred, re-evaluated after Phase 0 (CI quota constraints)
- Engine source structure (`src/core/`, `src/modules/`, `libs/`) — deferred to Phase 0.0
- `spec/` directory in the repo — explicitly out of scope per `engine-development-workflow.md` §3.5; spec lives in claude.ai knowledge base
- GitHub PR / issue templates — deferred to Phase 0 if needed
- Tracy, profiler, benchmark infrastructure — deferred (S1+)
- Codeberg mirror or migration — deferred to end of Phase 1 (criterion C1.10)
- Any C binding or external Zig dependency
- Any non-trivial engine code (ECS, renderer, etc.) — wholly deferred to Phase 0

## Spec documents to read first

1. `engine-spec.md` — §22.3.0 (Phase −1 spike list, S0 entry) and §3.5 (in-tree default, no `spec/` in repo)
2. `engine-development-workflow.md` — §2 (milestone model), §3 (brief format), §3.4 (`CLAUDE.md` lifecycle), §4 (git conventions: branches, tags, Conventional Commits, PRs, lefthook, squash-and-merge)
3. `engine-zig-conventions.md` — §17 (Zig version policy: 0.16.x strict, patches accepted, minor refused)
4. `engine-phase-0-criteria.md` — context on what comes next (informs `CLAUDE.md` content; no implementation impact at S0)

## Files to create or modify

All entries are creations — the repo is empty before this milestone.

- `briefs/S0-bootstrap.md` — creation — verbatim copy of this brief, first commit of the branch
- `LICENSE` — creation — MIT license, copyright 2026 Guy + Weld Engine contributors
- `README.md` — creation — English; project name, Phase −1 status, prerequisites (Zig 0.16.x, lefthook), basic commands (`zig build`, `zig build test`, `./scripts/install-hooks.sh`), ~50 lines max
- `CLAUDE.md` — creation — English; see content specification below
- `.gitignore` — creation — see content specification below
- `.gitattributes` — creation — LF enforced for `*.zig`, `*.md`, `*.sh`, `*.yml`, `*.yaml`, `*.zon`, `*.toml`, `*.json`; CRLF allowed for `*.bat`
- `.editorconfig` — creation — `root = true`; `[*]` charset=utf-8, end_of_line=lf, insert_final_newline=true, trim_trailing_whitespace=true; `[*.zig]` indent_style=space, indent_size=4; `[*.{yml,yaml,json,md}]` indent_style=space, indent_size=2
- `build.zig` — creation — exposes `default`, `test`, `run` steps; panics with the message `Weld requires Zig 0.16.x, got 0.X.Y` (X and Y substituted with actual values) if `builtin.zig_version.minor != 16`
- `build.zig.zon` — creation — `name = "weld"`, `version = "0.0.1"`, `minimum_zig_version = "0.16.0"`, no dependencies, `paths` enumerated (`src`, `tests`, `build.zig`, `build.zig.zon`, `LICENSE`, `README.md`)
- `src/main.zig` — creation — minimal hello-world `main` entry + a single inline `test "main module compiles"` asserting a trivial truth
- `tests/smoke_test.zig` — creation — single `test "smoke"` asserting `1 + 1 == 2`, registered into the `test` build step
- `.github/workflows/ci.yml` — creation — see specification below
- `lefthook.yml` — creation — see specification below
- `scripts/check-commit-msg.sh` — creation — POSIX shell, executable bit set, validates Conventional Commits
- `scripts/install-hooks.sh` — creation — POSIX shell, executable bit set, runs `lefthook install` idempotently
- `.vscode/extensions.json` — creation — recommends `ziglang.vscode-zig` and `tamasfe.even-better-toml`
- `.vscode/settings.json` — creation — see content below

### `.github/workflows/ci.yml` specification

- Triggers: `push` on `main`, `pull_request` targeting `main`
- Concurrency: group `ci-${{ github.ref }}`, `cancel-in-progress: true` for PRs only (not for `main`)
- Permissions: `contents: read` only
- Single job named `build-and-test` with strategy matrix: `os: [ubuntu-24.04, windows-2025]`, `mode: [Debug, ReleaseSafe]`, `fail-fast: false`
- Job-level `timeout-minutes: 10`
- Steps in order:
  1. `actions/checkout@v6`
  2. `mlugg/setup-zig@v2` with version constraint `0.16.x` (resolves to latest 0.16 patch — patch fluidity is intentional, the `build.zig` version guard enforces the minor invariant)
  3. `zig fmt --check src tests build.zig`
  4. `zig build -Doptimize=${{ matrix.mode }}`
  5. `zig build test -Doptimize=${{ matrix.mode }}`

### `lefthook.yml` specification

- Three hooks defined: `pre-commit`, `commit-msg`, `pre-push`
- `pre-commit`: runs `zig fmt --check {staged_files}` filtered on the `*.zig` glob, parallel, fails on diff
- `commit-msg`: runs `bash scripts/check-commit-msg.sh {1}` (where `{1}` is the path to the commit message file provided by git)
- `pre-push`: runs `zig build` then `zig build test` sequentially in Debug mode
- No skip directives at this stage

### `scripts/check-commit-msg.sh` specification

- Shebang `#!/usr/bin/env sh`, POSIX strict (no bashisms — must run under dash on Debian/Ubuntu and under Git Bash on Windows)
- Reads commit message file path from `$1`
- Bypasses validation for: merge commits (line begins with `Merge `), revert commits (`Revert `), and autogenerated fixup/squash markers (`fixup!`, `squash!`)
- Validates the title line (first non-empty line) against the Conventional Commits pattern: `<type>(<scope>)?!?: <description>` where:
  - `type` ∈ {`feat`, `fix`, `perf`, `refactor`, `test`, `docs`, `chore`, `breaking`}
  - optional `scope` matches `[a-z0-9-]+`
  - optional `!` marks a breaking change
  - `description` is 1 to 72 characters, must start with a lowercase letter, must not end with a period
- Exits 0 if the title line is valid
- Exits 1 with an explicit error message printing the offending line and a valid example if invalid
- Exercised on both Linux (sh/dash) and Windows (Git Bash) — both are environments developers will commit from

### `CLAUDE.md` content specification

`CLAUDE.md` is read by Claude Code at every session start (cf. `engine-development-workflow.md` §3.4). At S0 it must contain the following sections, in order:

- **Header**: project name, current status (`Phase -1 — S0 in progress` initially, updated to `Phase -1 — S1 next` in the closing PR), date last updated
- **Current state** table: phase, current milestone, last released tag (empty initially, `v0.0.1-S0-bootstrap` after closing PR), active branch, next planned milestone
- **Tags** table: header `Tag | Date | Milestone | Notes`, empty initially. One row added in the closing PR for `v0.0.1-S0-bootstrap`
- **Hypotheses validated by spikes** table: lists S0 through S6 with columns `Spike | Hypothesis | Status`. S0 hypothesis listed as "infrastructure ready (no engineering hypothesis)". All `pending` initially; S0 set to `validated` in the closing PR
- **Open / deferred decisions**:
  - Custom Zig linter → dedicated Phase 0 milestone post-S1
  - macOS in CI matrix → re-evaluated after Phase 0
  - Codeberg migration → end of Phase 1 (criterion C1.10)
  - `spec/` directory in repo → re-evaluated at start of Phase 0
- **Non-negotiable rules**:
  - Zig 0.16.x strict; patches accepted; minor bumps require a dedicated migration milestone
  - No `@cImport` outside `*_c` modules
  - No `usingnamespace`
  - Never use `git commit --no-verify` or `git push --no-verify`
  - Conventional Commits mandatory on every commit
  - Squash-and-merge as default merge strategy
  - No external dependency beyond the 8 authorized C bindings (ONNX Runtime, Opus, Assimp, KTX/Basis Universal, libdatachannel, ACL compressor, tree-sitter, HarfBuzz)
- **Quick links spec** pointing to claude.ai knowledge base file names (no repo-relative paths since `spec/` is not in the repo). Minimum entries: `engine-spec.md`, `engine-development-workflow.md`, `engine-zig-conventions.md`, `engine-phase-0-criteria.md`. Mention that the full set of `engine-*.md` and `etch-*.md` files lives in the claude.ai project
- **Workflow reminder**: brief recap of the 4-step Claude Code protocol (read brief, request specs, read specs, implement) with a pointer to `briefs/` for milestone briefs
- **Footer**: `Last updated: <YYYY-MM-DD>`

Target size: 120–200 lines. Above 250 lines means content is being duplicated from spec.

### `.gitignore` content

Grouped by section, with section comments. The whitelist patterns for `.vscode/` and `.claude/` use the wildcard form (`dir/*`) so that subsequent `!dir/file` re-inclusions are honored by git.

```
# Zig build outputs
zig-out/
.zig-cache/
zig-pkg/

# Editor / IDE — VSCode (project-level files whitelisted)
.vscode/*
!.vscode/settings.json
!.vscode/extensions.json

# Editor / IDE — alternatives
.idea/
.helix/
.zed/
*.swp
*.swo

# OS
.DS_Store
Thumbs.db
desktop.ini

# Logs
*.log

# Claude Code (project-level settings whitelisted)
.claude/*
!.claude/settings.json
```

### `.vscode/settings.json` content

Project-level minimum only:

- `"[zig]": { "editor.formatOnSave": true, "editor.defaultFormatter": "ziglang.vscode-zig" }`
- `"files.associations": { "*.zon": "zig" }`
- `"files.eol": "\n"`
- `"files.insertFinalNewline": true`
- `"files.trimTrailingWhitespace": true`

No theme, no font, no keybindings. Personal preferences live outside the repo.

## Acceptance criteria

### Tests

- `tests/smoke_test.zig` — `test "smoke"` — asserts `1 + 1 == 2`; runs and passes via `zig build test` in both Debug and ReleaseSafe
- `src/main.zig` — `test "main module compiles"` — trivial inline test asserting a tautology; runs and passes via `zig build test`

### Benchmarks

None. Benchmark infrastructure is deferred to S1+.

### Observable behavior

- `zig build` produces an executable at `zig-out/bin/weld` (Linux) or `zig-out\bin\weld.exe` (Windows)
- `zig build run` executes the binary and exits 0
- Running `zig build` under a Zig compiler whose minor version is not 16 fails at build time with the explicit panic message specified above (manually verifiable on a 0.15.x or 0.17.x toolchain if one is installed)
- `./scripts/install-hooks.sh` from a fresh clone installs lefthook hooks; subsequent `git commit` triggers `pre-commit` and `commit-msg`; `git push` triggers `pre-push`
- A commit with a non-conformant message (e.g. `Add stuff`) is rejected by the `commit-msg` hook with an explicit error pointing to the rule violated
- A commit with a conformant message (e.g. `feat(build): add zig version guard`) passes the hook
- A demonstration PR modifying only `README.md` (e.g. adding a single character) sees all four CI jobs pass in under 3 minutes wall-clock per job. The PR is **not merged** — it is closed after verification, and its CI run URL is recorded in the closing notes of this brief as the proof artifact for this criterion

### CI

- `zig build` clean, zero warnings, on the configured matrix `{ubuntu-24.04, windows-2025} × {Debug, ReleaseSafe}`
- `zig build test` green on the four matrix combinations
- `zig fmt --check` green
- `commit-msg` hook green on every commit of the branch
- The slowest CI job for a `README.md`-only PR completes in under 3 minutes wall-clock (proof URL recorded in closing notes)

## Conventions

- **Branch**: `phase-pre-0/bootstrap/repo-and-ci`
- **Final tag**: `v0.0.1-S0-bootstrap`
- **PR title**: `Phase -1 / Bootstrap / Repo and CI`
- **Commit convention**: Conventional Commits (cf. `engine-development-workflow.md` §4.3)
- **Merge strategy**: squash-and-merge (cf. `engine-development-workflow.md` §4.6)

## Notes

- This brief is committed as the first commit of the branch (`docs(brief): add S0 bootstrap milestone brief`), per the standard milestone protocol.
- `CLAUDE.md` initial version is committed during S0; the final update (status transition to "S1 next", addition of the `v0.0.1-S0-bootstrap` tag row, switch of S0 hypothesis status to `validated`) is committed in the closing PR per `engine-development-workflow.md` §3.4.
- The custom Zig linter mentioned in `engine-development-workflow.md` §4.5 (`zig build lint`, `zig build lint-commit`) does not exist at S0. The `commit-msg` hook uses `bash scripts/check-commit-msg.sh` instead. When the Zig linter ships in a later Phase 0 milestone, `lefthook.yml` and the workflow doc will be amended together.
- `mlugg/setup-zig@v2` is the established standard for Zig in GitHub Actions and supports semver ranges (`0.16.x`). Patch pinning is intentionally avoided — the `build.zig` version guard enforces the minor invariant, patches are fluid.
- Pinning `ubuntu-24.04` and `windows-2025` (not `*-latest`) is deliberate. `*-latest` aliases shift unpredictably and have caused silent CI breaks across the GitHub-hosted runners ecosystem; pinning gives the project explicit control over runner version bumps via dedicated PRs.
- `engine-spec.md` §22.3.0 originally listed `Fedora 44` as the Linux CI target. GitHub Actions does not provide a hosted Fedora runner; using `ubuntu-24.04` for CI is the pragmatic choice. Spec amendment to be applied by Guy in claude.ai knowledge base alongside this milestone.
- `engine-spec.md` §22.3.0 also listed `.vscode/` in the skeleton without specifying its content. The S0 scope refines this to a minimal project-level pair (`extensions.json` + `settings.json`), with personal IDE files explicitly gitignored.
- `CLAUDE.md` was not present in the original `engine-spec.md` §22.3.0 deliverables list. It is added at S0 because Claude Code reads it at every session start (`engine-development-workflow.md` §3.4); shipping S1 without it would mean a blind first session.
- `engine-zig-conventions.md` §17: minor version bumps require a dedicated migration milestone, never a silent change. The build-time guard enforces this.

---

# LIVING SECTION

*Maintained by Claude Code during the milestone. Not a marketing report — used for review and post-mortem debugging.*

## Specs read

*To be checked before any production code is written. Confirms specs were ingested in full, not skimmed.*

- [x] `engine-spec.md` (§22.3.0, §3.5) — read 2026-05-08 09:46
- [x] `engine-development-workflow.md` (§2, §3, §3.4, §4) — read 2026-05-08 09:46
- [x] `engine-zig-conventions.md` (§17 + §18) — read 2026-05-08 09:46 — brief labels this "§17 (Zig version policy)" but in the actual document §17 is "Build system and package management" and §18 is "Politique de migration de version Zig". Per Guy's clarification at milestone start, both are pertinent: §17 informs the `build.zig` version guard, §18 is the policy text referenced in the brief.
- [x] `engine-phase-0-criteria.md` — read 2026-05-08 09:46

## Execution log

- 2026-05-08 09:42 — Repo initialized (`git init` already done). Branch `phase-pre-0/bootstrap/repo-and-ci` created from unborn `main` via `git symbolic-ref HEAD`. Brief committed verbatim as first commit (`docs(brief): add S0 bootstrap milestone brief`).
- 2026-05-08 09:46 — All 4 spec documents read (engine-spec.md §22.3.0+§3.5, engine-development-workflow.md §2+§3+§3.4+§4, engine-zig-conventions.md §17+§18, engine-phase-0-criteria.md full). Brief's reference to "engine-zig-conventions.md §17" was clarified by Guy at milestone start to mean §17 (Build system) + §18 (Migration policy) — actual section number for "Zig version policy" is §18, not §17. Both are pertinent.
- 2026-05-08 09:50 — Repo metadata committed: LICENSE (MIT), README.md, .gitignore, .gitattributes, .editorconfig, .vscode/{extensions,settings}.json. Three commits.
- 2026-05-08 09:58 — Build infra committed: build.zig.zon (name `.weld`, version 0.0.1, fingerprint generated by Zig — high bits derived from package name) + build.zig (version guard panicking on minor != 16, default/run/test steps) + src/main.zig (Juicy Main with `std.process.Init`, prints banner, inline `test "main module compiles"`) + tests/smoke_test.zig (single `test "smoke"` asserting 1+1==2). One commit. `zig build`, `zig build test`, `zig build run` all green in Debug + ReleaseSafe locally.
  - Note: the engine-zig-conventions.md §6 example uses `std.fs.File.stdout()` but the actual 0.16.0 API path is `std.Io.File.stdout()` (and `writer()` takes `(file, io, buffer)`, not just `(buffer)`). Implementation follows the actual stdlib; convention doc may need a sync in a future docs PR.
- 2026-05-08 10:00 — Hooks committed: lefthook.yml (pre-commit zig fmt parallel, commit-msg via bash script, pre-push build+test piped) + scripts/check-commit-msg.sh (POSIX strict, validated under both /bin/sh and /bin/dash on macOS) + scripts/install-hooks.sh (idempotent lefthook install with helpful error if absent). One commit.
- 2026-05-08 10:05 — CI workflow committed: .github/workflows/ci.yml — 4-job matrix `{ubuntu-24.04, windows-2025} × {Debug, ReleaseSafe}`, fail-fast false, timeout 10 min, concurrency cancel-in-progress only on PRs. Steps: actions/checkout@v6 → mlugg/setup-zig@v2 (0.16.x) → fmt check → build → test.
- 2026-05-08 10:07 — CLAUDE.md committed (90 lines, slightly under the 120-200 target but covers every required section: header, current state, tags, hypotheses S0-S6, deferred decisions, non-negotiable rules, quick links, workflow reminder, footer).
- 2026-05-08 10:10 — Local validation of full hook flow: `./scripts/install-hooks.sh` populates `.git/hooks/{pre-commit,commit-msg,pre-push}`. Tested with `git commit --allow-empty`: title "Add stuff" rejected by commit-msg hook with explicit error pointing to the rule violated; title "chore(test): ..." accepted. Test commit reset. Final `zig fmt --check`, `zig build`, `zig build test` green in both Debug and ReleaseSafe.

## Acted deviations

*Modifications to the FROZEN SECTION made mid-milestone after a Claude.ai round-trip. Each deviation references the commit that enacts it. Empty at end of milestone is the nominal case.*

- <commit SHA> — <summary of deviation and reason>

## Blockers encountered

*Blocking points that required a return to Claude.ai (cf. `engine-development-workflow.md` §2.4). Two or more distinct blockers signals a re-scope.*

- <summary> — resolved by <commit SHA> or <Claude.ai conversation reference>

## Closing notes

*To be filled at the Status → CLOSED transition, just before opening the PR.*

- **What worked**:
- **What deviated from the original spec**:
- **What to flag explicitly in review**:
- **Final measurements**: CI duration on `README.md`-only PR (job-by-job), CI run URL archived as proof of the < 3 min criterion
- **Residual risks / technical debt left intentionally**:
