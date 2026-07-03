# Chore — CI cache refresh + ReleaseSafe budget (windows-2025 unblock)

> **Status:** CLOSED
> **Phase:** 1
> **Branch:** `phase-1/chore/ci-cache-refresh`
> **Tag:** none — maintenance chore, merged to `main` without a tag (cf. `engine-development-workflow.md`: maintenance chores are not tagged). Sits **before the M1.0.12 merge** (PR #40 is blocked by the broken cell).
> **Dependencies:** current `main` (`v0.10.11-async-core`). Blocks the M1.0.12 merge sequence.
> **Opened:** 2026-07-03
> **Closed:** 2026-07-03 — PR #41, squash-merged to `main` without a tag (maintenance chore)

---

# FROZEN SECTION

*Produced by Claude.ai. Not modifiable by Claude Code outside a Claude.ai round-trip (cf. § Recorded deviations).*

## Context

Since M1.0.11, the required check `build-and-test (windows-2025, ReleaseSafe)` is canceled by its job timeout (~31 min into `zig build test`, `timeout-minutes: 40`). Root cause, established from the M0.9 timing artifacts (`cache_hit=true`, `build_seconds=487`, `test_seconds=NA` on run 28641181940): the Zig build cache is a FOSSIL by construction. The cache key (`os-mode-zigver-zonhash`) has no per-commit component, and the monolithic `actions/cache@v5` never re-saves on an exact-key hit — so the cache froze at the first run under the current `build.zig.zon` hash. Every milestone since drifts the sources further from the fossil; after M1.0.11 + M1.0.12 (~3,400 lines across `interp.zig`/`types.zig`/`parser.zig` plus their test binaries), the ReleaseSafe recompile on the slowest runner exceeds the 40-min budget. The timeout also skips the post-job save, so nothing can ever refresh the cache. Debug windows and ubuntu ReleaseSafe carry the same fossil but still absorb it — ubuntu ReleaseSafe is on the same trajectory. Fix the mechanism, not the symptom.

## Scope

Single gate (E1), one file: `.github/workflows/ci.yml`.

**E1 — Cache split + budget**

- In the `build-and-test` job, replace the monolithic `actions/cache@v5` step with the restore/save split:
  - `actions/cache/restore@v5` (id: `zig-cache`), `key: zig-${{ matrix.os }}-${{ matrix.mode }}-${{ env.ZIG_VERSION }}-${{ hashFiles('build.zig.zon') }}-${{ github.sha }}`, `restore-keys` falling back to the same key minus `-${{ github.sha }}`, then minus the zon hash (three-level prefix fallback: exact sha → newest cache under this zon → newest cache under this os/mode/zig). The per-sha primary key never exact-hits on a fresh commit, so every green run refreshes the cache from the most recent prior state; GitHub's LRU eviction retires old entries.
  - `actions/cache/save@v5` immediately AFTER the `zig build` step, key `...-${{ github.sha }}-build`: a run killed during `zig build test` still leaves a fresh build cache (timeout immunity — this breaks the current death loop and prevents its recurrence). Add `...-build` (sha-less form) as the FIRST restore-keys fallback so it seeds the next attempt. Keep it minimal: `-${{ github.sha }}-build` exact in save; `-build` is not needed in restore-keys if the prefix fallback already matches it — verify prefix-matching order (restore-keys match by prefix, newest first) and rely on the plain prefix fallback; do NOT over-engineer the key ladder beyond the three levels above plus the post-build save.
  - `actions/cache/save@v5` at the END of the job steps (after the timing artifact upload), `if: always()`, key `...-${{ github.sha }}`: the full post-test cache when the job got that far.
- The timing-report step reads `steps.zig-cache.outputs.cache-hit` — with restore/save split, `cache-hit` is `true` only on an exact primary-key hit (per-sha: effectively never). Change the report line to record `cache_matched_key=${{ steps.zig-cache.outputs.cache-matched-key || 'none' }}` alongside `cache_hit` so the artifact stays diagnostic (which fallback level actually seeded the run).
- `timeout-minutes` for ReleaseSafe: 40 → 55 (Debug stays 20). Update the budget-history comment above it in the established style (M0.1 → M0.8 → this chore, with the fossil-cache rationale one-liner).
- Update the in-file cache doc comment (the "M0.9 / E1" block) to describe the split and the per-sha refresh; note the §7.3 whitelist extension: `actions/cache/restore@v5` and `actions/cache/save@v5` are sub-actions of the already-whitelisted `actions/cache@v5` (same repo, same major).
- Do NOT touch the other two `actions/cache@v5` sites (`bench.yml`-shared key at the bench job, docs-build job): they complete normally and refresh on zon changes; converting them is not needed to unblock and stays out.

## Out of scope

- The other cache sites (bench, docs) — see above.
- Any change to `build.zig`, test layout, or compile-time reduction work (a legitimate future concern for the giant-file ReleaseSafe Sema cost, but not this chore).
- Branch-protection / ruleset settings (repository settings, Guy's side — not a repo file).
- `nightly-fuzz.yml`, `bench.yml`.

## Specs to read first

1. `engine-development-workflow.md` — §4.3 (commits), §4.6 (merge), §7.3 (action whitelist), maintenance-chore tagging rule

## Files to create or modify

- `.github/workflows/ci.yml` — modify — cache split, per-sha keys, post-build save, budget 55, doc comments

## Acceptance criteria

### Tests

- None (no Zig code). CI itself is the test bench.

### Observable behavior

- The chore PR's own run: all four `build-and-test` cells green — including `windows-2025, ReleaseSafe` completing within the new budget (near-cold: the fossil helps little; expect a long but green run).
- The `windows-2025, ReleaseSafe` timing artifact of that run shows `test_seconds` populated (not NA) and reports the matched restore key.

### CI

- Full required-check set green on the PR.
- `commit-msg` hook green (≤72-char subject).

## Conventions

- **Branch:** `phase-1/chore/ci-cache-refresh`
- **PR title:** `Phase 1 / Chore / CI cache refresh + ReleaseSafe budget`
- **Commit convention:** Conventional Commits — `ci(...)` type
- **Merge strategy:** squash-and-merge, no tag

## Notes

- **Why per-sha keys:** `actions/cache` never overwrites an existing key. A stable key under a stable `build.zig.zon` is write-once — the fossil mechanism. A per-sha primary key with prefix fallbacks is the canonical pattern for an evolving build cache under stable dependencies.
- **Why the post-build save:** the post-job save of the monolithic action is skipped on timeout cancellation. Any future budget breach would otherwise re-enter a no-refresh loop. The mid-job save bounds the damage of ANY test-step death (timeout, crash, runner loss) to one build's worth of recompilation.
- **Cache volume:** per-sha keys multiply entries; GitHub's 10 GB per-repo LRU handles retirement. Do not add manual cleanup machinery.
- **Merge sequence context (for the PR description):** this chore unblocks PR #40 (M1.0.12). After this merges, the push run on `main` writes the fresh main-scoped cache; PR #40's checks are then re-run (warm from main), and M1.0.12 merges + tags.

---

# LIVING SECTION

*Maintained by Claude Code during the chore.*

## Specs read

- [x] `engine-development-workflow.md` — read in full: §4.3 (commit convention, type whitelist), §4.6 (squash-and-merge), §6.1 (maintenance-chore tagging exception), §7.3 (action whitelist) — 2026-07-03 12:07 CEST

## Execution log

- 2026-07-03 12:07 CEST — branch `phase-1/chore/ci-cache-refresh` created from `main` (`4daaf6c`, v0.10.11-async-core) and pushed; brief committed verbatim; spec read confirmed; brief ACTIVE.
- 2026-07-03 12:20 CEST — E1 implemented in `.github/workflows/ci.yml` (`build-and-test` job only): monolithic `actions/cache@v5` replaced by `actions/cache/restore@v5` (id `zig-cache`, per-sha primary key, two prefix restore-keys = three-level fallback) + `actions/cache/save@v5` post-`zig build` (key `...-${{ github.sha }}-build`, timeout immunity) + `actions/cache/save@v5` final `if: always()` (key `...-${{ github.sha }}`). No explicit `-build` entry in restore-keys: verified that restore-keys prefix-match (newest first), so the zon-level fallback `...-<zonhash>-` matches both save entries — the key ladder stays at three levels per the brief's minimality instruction. Timing report records `cache_matched_key` (and `cache_key` updated to the per-sha primary so the artifact stays truthful). ReleaseSafe `timeout-minutes` 40 -> 55, Debug untouched. Budget-history comment extended in the established style; cache doc comment rewritten (split + per-sha refresh + §7.3 sub-action note); the `zig build` timer comment's stale "cold=miss / warm=hit" diagnostic recipe realigned on `cache_matched_key`. YAML syntax validated; §3.6.1 language grep on the diff: clean.
- 2026-07-03 12:20 CEST — cache-site inventory verified before editing (anti-hallucination discipline): besides `build-and-test`, THREE other `actions/cache@v5` sites exist — `runtime-smoke-test` (ci.yml), `vertical-slice-smoke` (ci.yml), `bench-ecs-smoke` (bench.yml). The brief's Out-of-scope names "two sites (bench job, docs-build job)"; no `docs-build` job exists. The intent is unambiguous (convert ONLY `build-and-test`), so all three stay untouched. Note: the two ci.yml smoke jobs keep their sha-less exact key, which still exact-hits the existing fossil entry until LRU eviction; they complete normally either way, and on fossil eviction their prefix fallback picks up the fresh per-sha caches — no unblock dependency.
- 2026-07-03 13:00 CEST — PR #41 opened; CI run 28654090794 fully green: all four `build-and-test` cells + `runtime-smoke-test` + `vertical-slice-smoke` + `ci-gate`. The `windows-2025, ReleaseSafe` cell COMPLETED in 35 min 27 s (10:16:54Z -> 10:52:21Z), under the new 55-min budget; its timing artifact shows `test_seconds=1652` POPULATED (first non-NA value since M1.0.11) and `build_seconds=419`. All four cells report `cache_hit=false` (per-sha primary, as designed) and `cache_matched_key=zig-<os>-<mode>-0.16.0-<zonhash>` — the fossil entry, served by the level-3 os/mode/zig prefix fallback (the sha-less fossil key cannot match the level-2 `...-<zonhash>-` prefix; near-cold seeding as the brief predicted). The windows Debug job log confirms both new saves live: `...-<sha>-build` written right after `zig build` (~3.5 min in) and the full `...-<sha>` entry at job end — the refresh mechanism and the timeout immunity are both proven on a real run. Mechanism note observed in passing: on `pull_request` events `github.sha` is the merge-commit sha (`f266cc0`), not the branch head — still per-commit unique, mechanism intact.

- 2026-07-03 13:45 CEST — second CI run (28656342357, brief-journal push; the `changes` job diffs the whole PR against main, so the full matrix re-runs on every push of this PR) proves the WARM paths: `ubuntu-24.04, ReleaseSafe` seeded from the first run's per-sha entry via the level-2 zon prefix fallback and completed in 1 min 13 s (vs 29 min near-cold). `windows-2025, ReleaseSafe` attempt 1 failed on the KNOWN windows-ReleaseSafe hang flake (`error: test runner failed to respond for 1m7.07ms`, 902/933 tests passed, 31 skipped, zero failed assertions — unrelated to this chore); per the established protocol the job was re-run. Attempt 2: green in 1 min 47 s with `cache_hit=true` (exact per-sha primary-key hit — same merge sha as attempt 1, whose `if: always()` final save wrote the entry DESPITE the red test leg, exactly the salvage path this chore builds), `build_seconds=2`, `test_seconds=20`. All three ladder levels are now observed live: exact per-sha hit (attempt 2), zon-prefix warm fallback (ubuntu warm run), os/mode/zig fossil fallback (first run). All PR checks green.

## Recorded deviations

- **Commit type `ci(...)` -> `chore(ci): ...`.** The prompt and the brief's Conventions section specify Conventional Commits "type `ci(...)`", but `engine-development-workflow.md` §4.3 defines a strict 8-type whitelist (`feat|fix|perf|refactor|test|docs|chore|breaking`) enforced by the `commit-msg` hook (verified in `tools/weld_lint/rules/conventional_commit.zig` — `ci` is rejected), and the spec's own canonical example for CI work is `chore(ci): ...`. The spec and the hook prevail: all CI commits of this chore use type `chore` with scope `ci`.

## Blockers encountered

-

## Closing notes

- **What worked:** The restore/save split behaved exactly as designed on its first live run: the per-sha primary key never exact-hit on a fresh commit, the fossil seeded the near-cold run through the level-3 os/mode/zig fallback, and both new saves wrote fresh entries — the fossil death loop is broken by construction AND by observation. The timeout-immunity path was demonstrated under real conditions without having to simulate a timeout: the known windows-ReleaseSafe hang flake made one test leg red, the `if: always()` final save salvaged its cache anyway, and the rerun exact-hit that entry (`cache_hit=true`, `build_seconds=2`, `test_seconds=20`). All three ladder levels were observed live across three consecutive runs.
- **What deviated from the original spec:** (1) Commit type — the prompt/brief conventions say `ci(...)`, but the §4.3 whitelist (8 types, hook-enforced, verified in `tools/weld_lint/rules/conventional_commit.zig`) rejects `ci`; all commits use `chore(ci): ...`, the spec's own canonical example (see Recorded deviations). (2) The Out-of-scope inventory names "two other cache sites (bench job, docs-build job)"; the verified inventory is THREE sites (`runtime-smoke-test` + `vertical-slice-smoke` in ci.yml, `bench-ecs-smoke` in bench.yml) and no `docs-build` job exists — the intent (convert ONLY `build-and-test`) was unambiguous and honored.
- **What to flag explicitly in review:** (1) The two ci.yml smoke jobs keep their sha-less exact key and will keep exact-hitting the FOSSIL entry until LRU eviction; they complete normally either way and self-correct after eviction (their prefix fallback then serves the newest per-sha entry) — but their in-file comment ("the matching key warms this ReleaseSafe build even on the first push") is now slightly stale; left untouched for scope discipline. (2) On `pull_request` events `github.sha` is the merge-commit sha (branch-head sha on `main` push runs) — per-commit unique in both cases, mechanism intact. (3) Observed variance on the final head run: the ubuntu ReleaseSafe cell restored the correct newest lineage (`cache_matched_key` = the previous run's per-sha entry) yet re-paid `build_seconds=291` / `test_seconds=1344`, where the previous run on the same lineage completed in 1 min 13 s total — runner/Zig-side variance, does not gate the mechanism; worth watching in future timing artifacts.
- **Final measurements:** `windows-2025, ReleaseSafe` near-cold (fossil, level-3 fallback): job 35 min 27 s, `build_seconds=419`, `test_seconds=1652` — first non-NA since M1.0.11 — `cache_matched_key=zig-windows-2025-ReleaseSafe-0.16.0-<zonhash>`. Same cell, exact per-sha hit (flake rerun): job 1 min 47 s, `cache_hit=true`, `build_seconds=2`, `test_seconds=20`. Same cell, warm zon-level fallback (head run): job 3 min 44 s. `ubuntu-24.04, ReleaseSafe` warm zon-level fallback: job 1 min 13 s (vs 28 min 47 s near-cold). Budgets: ReleaseSafe 55 min, Debug 20 min.
- **Residual risks / tech debt left intentionally:** (1) The three untouched cache sites keep the write-once monolithic pattern — they complete normally and self-correct on fossil eviction; conversion deliberately out of scope. (2) The giant-file ReleaseSafe Sema compile cost keeps growing; the per-sha refresh masks it on warm runs, but a genuinely cold cell (zon bump, eviction) pays the full price — the compile-time reduction work remains a future concern per the brief's Out-of-scope. (3) Per-sha keys multiply cache entries; retirement is delegated to GitHub's 10 GB per-repo LRU per the brief (no manual cleanup machinery).
