# Chore — CI cache refresh + ReleaseSafe budget (windows-2025 unblock)

> **Status:** PLANNED
> **Phase:** 1
> **Branch:** `phase-1/chore/ci-cache-refresh`
> **Tag:** none — maintenance chore, merged to `main` without a tag (cf. `engine-development-workflow.md`: maintenance chores are not tagged). Sits **before the M1.0.12 merge** (PR #40 is blocked by the broken cell).
> **Dependencies:** current `main` (`v0.10.11-async-core`). Blocks the M1.0.12 merge sequence.
> **Opened:** 2026-07-03
> **Closed:** —

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

- [ ]

## Execution log

-

## Recorded deviations

-

## Blockers encountered

-

## Closing notes

- **What worked:**
- **What deviated from the original spec:**
- **What to flag explicitly in review:**
- **Final measurements:**
- **Residual risks / tech debt left intentionally:**
