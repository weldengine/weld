# CI-HF — cache saturation: the key carries the sha, so nothing is ever overwritten

Dedicated CI hotfix, on its own branch, BEFORE M1.2.1. It touches
`.github/workflows/ci.yml` and nothing else, it is validated by its own runs and
by nothing else, and mixing CI infrastructure into an animation codec's review is
what "one milestone, one session" refuses.

# FROZEN SECTION — the arbitration

Guy's verdict at the close of M1.2.0, after the two f64 windows cells were
cancelled on `5d79846`. Four gestures, in this order, and the third is the one
that closes the cause.

1. **Delete the `-build` save.** ~3.7 GB on windows, immediate, no correctness
   risk. The final save is `if: always()`, so the intermediate one covers only a
   job killed before the end — the timeout, which saturation causes. It exists to
   survive an ill it feeds.
2. **Recalibrate both budgets on the measured cold case.** 55 -> 75 for
   `ReleaseSafe`, 20 -> 35 for `Debug`. Not comfort: **a budget must separate
   SLOW from HUNG**, and at 55 against a cold 52-57 it separated nothing — it
   turned a known slowness into a random failure and made `M1.D.19` and
   `M1.D.27` indistinguishable.
3. **Save only from `main`.** PR branches restore, they do not write. Growth
   stops being a function of commits pushed, volume becomes a function of the
   cell count alone, and restoration becomes DETERMINISTIC instead of an LRU
   lottery. The cost is real and named: a twelve-commit PR no longer benefits
   from its own saves. **Measure it before adopting: one run with, one run
   without, on the same branch.**
4. **Do NOT split the cell by test domain, not now.** It is the tidiest-looking
   lever and the only one that AGGRAVATES the root cause — splitting multiplies
   cache entries, hence accelerates saturation. It becomes arguable once the
   volume is stable under the ceiling, and not before.

Form: points 1 and 2 in a first push. Point 3 in a second, with its before/after
measurement on the same branch, because it is the only one whose cost is not
known in advance.

# LIVING SECTION

## The diagnosis, and both first hypotheses were wrong

`ci.yml`'s three cache keys carry `${{ github.sha }}`. **No save is ever
overwritten**: each commit creates two fresh entries per cell, and restoration is
necessarily a prefix match on the previous lineage. Growth is therefore monotone
and proportional to the number of commits pushed — two entries x fifteen cells
per run, eight of them windows at 1-2 GB — against GitHub's repository-wide
10 GB ceiling. The ceiling is not brushed by accident; it is reached BY
CONSTRUCTION in a handful of commits, after which LRU eviction takes over.

Measured at the close of M1.2.0, run 34777902366 on `5d79846`:

| | attempt 1 | attempt 2 (same sha) |
|---|---|---|
| `windows-2025, ReleaseSafe, f64` | **57 min, cancelled** (budget 55) | **9.6 min, success** |
| `windows-2025, Debug, f64` | **21 min, cancelled** (budget 20) | **5.6 min, success** |
| `windows-2025, ReleaseSafe, f32` | 52 min, success | **52.1 min**, success |

Every step of both cancelled cells SUCCEEDED, `Complete job` included — so
neither is `M1.D.19` (which loses tests and prints `test runner failed to
respond`) nor `M1.D.29` (an assertion genuinely falling). It is the wall.

The restore keys attribute it exactly: attempt 1 restored `e60dda8...`, attempt 2
restored `4ad6487...` — its own attempt-1 save. And the `f32` cell, which passed
on attempt 1, restored the STALE lineage on attempt 2 because its own save had
been evicted meanwhile by the other cells of the same run. **The cells evict each
other inside one run.**

Repository cache read live during the investigation: 11.55 GB / 13 entries, then
9.44 GB / 11 entries a few minutes later — eviction in progress. The four windows
cells held **8.44 GB of 9.44**, 89 % of the budget for 4 of 15 cells, two entries
each.

**Two hypotheses refuted, one per party.** That the milestone had outgrown the
budget: the PREVIOUS run carried all three hotfix commits and both new tests and
did the same cell in **10.6 min** — two tests do not cost 46 minutes. And that
M1.2.0/G1 had widened the blast radius by making `type_info.zig` import
`foundation`: measured, `command_buffer.zig` and `scheduler.zig` already did
before the milestone, and `core_module.addImport("foundation")` dates from
M1.1.14. **Breaking `type_info.zig`'s dependency would change nothing** — one
importer of three, and the module edge outlives it.

## Where the time goes

| | cold | warm |
|---|---|---|
| `zig build` | 9.6-11.4 min | — |
| `zig build test` | **40.1-40.8 min** | — |
| whole cell | 52-57 min | **5.6-9.6 min** |

The cost is cold COMPILATION, not test execution — consistent with `M1.D.8`'s
129-of-132 measurement. No scheduling change touches the eviction.

## `M1.D.27` was mis-diagnosed and its remedy does not protect

The entry attributes the cold cache to editing a depended-upon Tier 0 file and
prescribes pushing such gates on a warm cache. Both halves are refuted above:
`36e5063 -> 5d79846` touches no Tier 0 file and the cell went cold anyway, and
the real mechanism — eviction by saturation — fires independently of what the
commit touched. A cache can be evicted between the run that writes it and the
run that reads it, including by the other cells of the same run. Guy rewrites the
entry under the SAME number: same debt, false cause.

## What this changes about the nature of the problem

It is not a slow CI, it is a **non-deterministic** one. The same sha passes or
fails depending on what eviction did meanwhile, and the re-run cleared it by
luck — the two failing cells happened to have just written. A CI whose red means
nothing costs more than a slow CI, because it makes every gate review
inconclusive, and M1.2.1 is a gate review every two hours.

## Execution log

- **Point 1 — done.** `Save Zig cache (post-build)` and its `Measure the Zig
  cache before saving` step deleted; the latter had exactly one consumer. The
  all-or-nothing doctrine was MOVED rather than deleted: it lived in the removed
  block and the surviving block referenced it. `ci.yml` already carried an
  independent corroboration — `Save Zig cache (post-build)` measured going
  39s -> 5m23s -> 7m39s on `windows-2025 / Debug` while the useful work stayed
  flat, killing that leg at its ceiling twice.
- **Point 2 — done.** 55 -> 75 and 20 -> 35, with the superseded "a cold Debug
  leg is ~11 min of work, ~45 % inside the 20-min budget" REMOVED rather than
  left beside its correction.
- **Point 3 — NOT done**, and deliberately: its cost is unknown and the brief
  requires a before/after measurement on the same branch. Second push.
- **Point 4 — refused**, with its reason recorded above.

## Acceptance

The YAML parses, the matrix job keeps exactly three cache steps (restore,
measure-final, save-final), and the CI is green on this branch. The effect of
point 1 is read on the repository's cache usage after a full run, and the effect
of point 2 is that no cell is cancelled with every step green.
