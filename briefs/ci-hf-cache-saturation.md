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

## Not this hotfix's subject — the scheduler park dump, recorded because nowhere else would keep it

`CLAUDE.md`'s M1.1.1-HF3 row closes on: *"the windows-2025/ReleaseSafe hang (4
consecutive pre-E9b occurrences) did not recur on the post-E9b merge run —
unexplained, instrumented, **first recurrence self-names via the dump**."*

**This is that first recurrence.** It landed on this branch's own CI, which is
the only reason it is written here: a CI hotfix is not where a Tier 0 scheduler
finding belongs, and a scratchpad does not survive the session. A repository file
is the only durable place available, and this is the open PR.

Provenance, so nothing about it has to be taken on trust:

| | |
|---|---|
| run | 34795835386, **attempt 1** |
| job | 103828662582 |
| cell | `build-and-test (windows-2025, ReleaseSafe, true)` — f64 |
| sha | `03e084b` (this branch: `ci.yml` + this brief, **zero source files**) |
| when | 2026-09-14T01:47:02Z |
| attempt 2, same sha | **did not reproduce** |

VERBATIM, as the log carries it:

```
test
+- run test 2 pass, 1 crash (3 total)
error: 'scheduler.test.workers deterministically park then wake on dispatch' exited with code 2 with stderr:
       === M1.0.1 test watchdog: 'workers deterministically park then wake on dispatch' did not finish within 5s — deadlock/livelock (covers scheduler.deinit join) ===
       === Job scheduler ===
         pending_count : 0
         generation    : 1
         chunk_count   : 13
         shutdown      : false
         worker_count  : 4
         worker[ 0] id= 0 chunks=       4 parks_entered=     0 parks=     0 steals_a=     724 steals_s=       0 work_ns=300
         worker[ 1] id= 1 chunks=       3 parks_entered=     0 parks=     0 steals_a=     720 steals_s=       0 work_ns=0
         worker[ 2] id= 2 chunks=       3 parks_entered=     0 parks=     0 steals_a=     719 steals_s=       0 work_ns=100
         worker[ 3] id= 3 chunks=       3 parks_entered=     0 parks=     0 steals_a=     719 steals_s=       0 work_ns=300
         totals: chunks=13 parks_entered=0 parks=0 steals_a=2882 steals_s=0 (invariant parks<=parks_entered: true)
```

### What it ESTABLISHES

- **The work was entirely drained.** `pending_count = 0`, and the per-worker
  `chunks` sum to the `chunk_count` of 13. So the 2882 attempted steals failing
  for 0 successes is not an anomaly — with nothing left to steal, failing is the
  correct outcome.
- **No worker entered a park.** `parks_entered = 0` on all four, while every one
  of them should have: the work was gone and there was nothing else to do.
- **The test could not possibly have exited.** `tests/ecs/scheduler.zig:214`'s
  phase (a) loops until `Σ parks_entered > Σ parks_completed`. At `0 > 0` that is
  false forever, so the 5 s watchdog was the only exit. Its own comment
  anticipates exactly this reading: *"a genuine regression — workers never
  parking — hangs here and the watchdog dumps the scheduler state, rather than a
  silent CI timeout."* The instrumentation did what it was built for.
- **It is not this branch.** The diff against `5d79846` is `.github/workflows/`
  and `briefs/` — no source file, so no compiled code changed.

### What it does NOT establish, and is deliberately not guessed at here

Why no worker parked. One occurrence, one cell, and this repository's own
discipline is against conjecturing on a scheduler's internals from a single
dump — M1.1.11.1 paid for that lesson twice.

**The question the dump makes answerable BY READING CODE rather than by
hypothesis: what does a worker do after an unsuccessful steal, and under what
condition does it enter a park?** That is a Tier 0 question and belongs to
whoever opens the entry. Recorded, not diagnosed.
