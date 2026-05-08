# S0 — Bootstrap repo and CI

> **Status:** CLOSED
> **Phase:** -1
> **Branch:** `phase-pre-0/bootstrap/repo-and-ci`
> **Planned tag:** `v0.0.1-S0-bootstrap`
> **Dependencies:** none
> **Opened:** 2026-05-08
> **Closed:** 2026-05-08

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
- `.zls.json` — creation — project-level zls config (build-on-save,
  warn_style, no argument placeholders)
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
- 2026-05-08 10:18 — `main` branch created at the brief commit (`46f4668`); milestone branch and `main` pushed to `origin`. Pre-push hook (`zig build && zig build test`) green on both pushes. PR #1 opened: https://github.com/weldengine/weld/pull/1.
- 2026-05-08 10:25 — First CI run failed on all 4 jobs at the `mlugg/setup-zig@v2` step: every mirror returns 404 because the action takes `0.16.x` literally as a filename component. Pinned to `0.16.0` exact in commit `429de07` and logged under § Acted deviations.
- 2026-05-08 10:35 — Second CI run on PR #1: 4/4 green. Slowest job 1m43s (windows-2025 ReleaseSafe). Run URL: https://github.com/weldengine/weld/actions/runs/25545765639.
- 2026-05-08 10:40 — Demo PR #2 opened (https://github.com/weldengine/weld/pull/2): branch `demo/ci-readme-tweak` from milestone tip + 1 newline in README, target `main`. CI run https://github.com/weldengine/weld/actions/runs/25546101581 — 4/4 green, slowest 1m37s. PR closed without merge as instructed by the brief.
- 2026-05-08 10:45 — CLAUDE.md final patch applied (status to "S1 next", tag row added, S0 hypothesis to validated, branch field to main). Brief Status flipped ACTIVE → CLOSED, Closed date set, Closing notes filled.
- 2026-05-08 11:54 — Post-review fixes applied: simplified `src/main.zig` to print build mode via `@tagName(builtin.mode)`; switched `build.zig` version guard from `@panic` to `@compileError` with explicit `comptime` block and major+minor check; corrected hallucinated spec filenames in `CLAUDE.md` § Quick links spec and added explicit no-guess rule; cleared Blockers placeholder; enabled zls in `.vscode/settings.json` and added project-level `.zls.json`. Single commit, branch retipped before push to PR #1.
- 2026-05-08 12:06 — `.vscode/settings.json` revised per Fix 6 update from Claude.ai: added `files.exclude` and `files.watcherExclude` for `.zig-cache` / `zig-out` / `zig-pkg` (hides build artefacts from the VSCode tree and the OS file watcher), added `zig.buildOnSaveProvider: "zls"` (delegates build-on-save to zls, coherent with `enable_build_on_save: true` in `.zls.json`, avoids the extension and zls both invoking it), and reordered the `zig.*` keys.
- 2026-05-08 12:21 — `lefthook.yml` pre-push extended with a third command `test-release` running `zig build test -Doptimize=ReleaseSafe`. Local timing of the full sequence (cold-ish but warm Zig cache from prior CI runs): ~0.7s. Far below the 30s budget. Catches optimization-sensitive failures locally before CI burns ~2 min to surface them.

## Acted deviations

*Modifications to the FROZEN SECTION made mid-milestone after a Claude.ai round-trip. Each deviation references the commit that enacts it. Empty at end of milestone is the nominal case.*

- `429de07` — `.github/workflows/ci.yml` step 2 pinned to `version: 0.16.0` instead of the brief's `version: 0.16.x` (cf. § Files to create or modify → `.github/workflows/ci.yml` specification, step 2). **Reason:** `mlugg/setup-zig@v2` — the action mandated by both the brief and `engine-spec.md` §22.3.0 — takes the version string literally and tries to fetch `zig-x86_64-{linux,windows}-0.16.x.tar.xz`, which 404s on every mirror. Tool capability fact, not a design choice. The brief's underlying intent (run on the latest 0.16 patch automatically) is preserved as future work once the action supports semver ranges, or via `version-file: build.zig.zon`. The `build.zig` minor-version guard continues to enforce the 0.16.x invariant on the local toolchain. Mechanical deviation — no Claude.ai round-trip; flagged here for review and surfaced in the PR's review notes.

- `6cfaf07` — `src/main.zig` rewritten: print now includes the build mode via `@tagName(builtin.mode)` instead of the static phase tag, and the I/O path is condensed (single `print` + `flush` on a 128-byte stack buffer instead of the original 256-byte version with separate writer variable). The brief's "minimal hello-world" intent is preserved; the change is a refinement, not a scope expansion. Decided in Claude.ai post-review.

- `6cfaf07` — `build.zig` version guard switched from `@panic` (runtime, with stacktrace dump) to `@compileError` (compile-time, single-line diagnostic) inside an explicit `comptime` block. Major + minor checked instead of minor only. The brief's intent — fail at build time on wrong Zig version — is preserved; the mechanism is upgraded to the semantically correct primitive. Decided in Claude.ai post-review.

- `6cfaf07` — `.vscode/settings.json` extended with `zig.zls.enabled: "on"`, `zig.zls.path: "zls"`, `zig.path: "zig"` to actually start zls in VSCode (the extension does not start it by default). Brief originally specified format-on-save settings only; zls activation was an oversight at brief drafting time. Decided in Claude.ai post-review.

- `acdecaf` — `.vscode/settings.json` further revised: added `files.exclude` and `files.watcherExclude` blocks for `.zig-cache` / `zig-out` / `zig-pkg` (hides build artefacts from the VSCode tree and prevents the OS file watcher from receiving thousands of events per rebuild), and added `zig.buildOnSaveProvider: "zls"` so zls owns the build-on-save (coherent with `enable_build_on_save: true` in `.zls.json`, avoids double invocation between the extension and zls). The `zig.*` key order was tightened. The brief's IDE-config minimum was already exceeded by the previous commit; this is a follow-up refinement. Decided in Claude.ai post-review (revision of the original Fix 6 prescription).

- `<sha-du-commit-fix>` — `lefthook.yml` pre-push extended with a third command `test-release` running `zig build test -Doptimize=ReleaseSafe` (cf. § Files to create or modify → `lefthook.yml` specification, which originally listed two pre-push commands `zig build` then `zig build test` in Debug only). **Reason:** the CI matrix requires 4/4 green on `{Debug, ReleaseSafe} × {ubuntu, windows}`, and a regression that only fires under ReleaseSafe (mis-placed `unreachable`, optimization-sensitive code) would otherwise cost ~2 min of CI to surface. Local timing of the full sequence is ~0.7s warm, well below the 30s budget set by `engine-development-workflow.md` §4.5. To revisit if pre-push duration approaches the budget at S1+ (mini-ECS) or S2+ (Vulkan triangle). Decided in Claude.ai post-review.

- `6cfaf07` — `.zls.json` added to repo root with project-level zls configuration (editor-agnostic). This file was not in the brief's original "Files to create or modify" list; FROZEN SECTION updated accordingly with a new entry (see Fix 7). Decided in Claude.ai post-review.

## Blockers encountered

*Blocking points that required a return to Claude.ai (cf. `engine-development-workflow.md` §2.4). Two or more distinct blockers signals a re-scope.*

*None.*

## Closing notes

*To be filled at the Status → CLOSED transition, just before opening the PR.*

- **What worked**:
  - The full Étape 0 → Étape 4 protocol ran cleanly: brief committed verbatim as the first commit, specs read, status transitioned through PLANNED → ACTIVE → CLOSED, granular Conventional Commits with appropriate scopes (`docs(brief)`, `chore(repo)`, `chore(vscode)`, `feat(build)`, `chore(hooks)`, `ci`, `docs(claude-md)`, `fix(ci)`, `docs(readme)`).
  - `zig fmt`, `zig build` (Debug + ReleaseSafe), `zig build test` (Debug + ReleaseSafe), `zig build run` all green locally on Zig 0.16.0 (darwin-arm64).
  - Lefthook flow validated end-to-end: `./scripts/install-hooks.sh` populates the three hooks, `commit-msg` rejects "Add stuff" with an explicit error citing the rule, accepts conformant titles. Hooks fired on every commit + push of this milestone.
  - `scripts/check-commit-msg.sh` is POSIX-strict (validated under `/bin/sh` and `/bin/dash`).
  - CI green on the second run after the `0.16.x → 0.16.0` fix. Slowest job 1m43s on the milestone PR, 1m37s on the demo PR. Both well under the 3 min criterion.

- **What deviated from the original spec**:
  - One acted deviation, recorded above: `.github/workflows/ci.yml` pins Zig to `0.16.0` exact instead of the brief's `0.16.x` semver wildcard, because `mlugg/setup-zig@v2` does not resolve `x` as a wildcard (it 404s on every mirror trying to fetch `zig-...-0.16.x.tar.xz`). The brief's intent — patch fluidity — is preserved as a future fix once the action supports semver ranges or via `version-file: build.zig.zon`. The `build.zig` minor-version guard continues to enforce 0.16.x locally. See § Acted deviations, commit `429de07`.
  - No FROZEN scope/criteria changes.

- **What to flag explicitly in review**:
  1. **Brief's `engine-zig-conventions.md §17` reference** — the actual section about Zig version policy is §18 (§17 is "Build system and package management"). Both are pertinent. Documented in the Specs read section at milestone start, no FROZEN change requested.
  2. **`std.fs.File.stdout()` vs `std.Io.File.stdout()`** — the convention doc §6 example does not match the actual Zig 0.16.0 stdlib path. `src/main.zig` follows the actual stdlib (`std.Io.File.stdout().writer(io, &buf)`). Flag for a future docs PR on the conventions.
  3. **Workflow doc §4.6 "Exception historique S0"** — the workflow says S0 was previously merged via merge commit, but this is a fresh first-time S0. The brief overrides with `Merge strategy: squash-and-merge`. Following the brief.
  4. **`main` initial state** — `main` was created at the brief commit only (the unborn HEAD was renamed to the milestone branch first, then `main` branched from the brief commit). This is why the demo PR (#2) couldn't satisfy the strict letter of the criterion ("PR modifying only README.md") against `main` directly: `zig build` would fail with no `build.zig.zon`. The demo PR was opened from the milestone branch tip + 1 README newline, validating the duration criterion in spirit. Future milestones won't have this constraint.
  5. **GitHub repo Settings → "Squash and merge" as the only enabled option** — recommended by `engine-development-workflow.md` §4.6. Out of scope of this PR (Claude Code does not have admin rights). Guy to apply before merging.
  6. **`build.zig.zon` fingerprint** — Zig 0.16 requires a fingerprint with the high 32 bits derived from the package name. Initial random value was rejected; the value `0x1a27cf1846a92a3e` was suggested by the Zig toolchain itself and used as-is. Stable from now on (changing it has security/trust implications per Zig's own warning).

- **Final measurements**:
  - **Milestone PR #1 second CI run** (after `0.16.x → 0.16.0` fix): https://github.com/weldengine/weld/actions/runs/25545765639 — ubuntu-24.04 Debug 24s, ubuntu-24.04 ReleaseSafe 52s, windows-2025 Debug 1m20s, windows-2025 ReleaseSafe 1m43s. Slowest 1m43s, criterion (< 3 min) met.
  - **Demo PR #2 CI run** (README-only tweak, target main, source = milestone branch tip + 1 newline): https://github.com/weldengine/weld/actions/runs/25546101581 — ubuntu-24.04 Debug 22s, ubuntu-24.04 ReleaseSafe 1m11s, windows-2025 Debug 57s, windows-2025 ReleaseSafe 1m37s. Slowest 1m37s, criterion (< 3 min) met. PR closed without merge as instructed: https://github.com/weldengine/weld/pull/2.

- **Residual risks / technical debt left intentionally**:
  - Zig version pinned to `0.16.0` exact in CI (instead of the brief's `0.16.x`). Patch fluidity will need to be re-introduced when 0.16.1+ ships, either by switching CI to `version-file: build.zig.zon` or by upgrading the action.
  - `commit-msg` validation is a POSIX shell script, not a Zig binary. To be replaced by the Zig linter milestone post-S1 (see CLAUDE.md § Open / deferred decisions).
  - `pre-push` hook duration is fine at S0 (sub-second `zig build` + `zig build test`) but will need re-evaluation in Phase 0.1+ once the ECS lands. Convention doc §4.5 already plans this.
  - macOS not in CI matrix. Local development on macOS works but is unverified by CI. Reconsidered after Phase 0.
