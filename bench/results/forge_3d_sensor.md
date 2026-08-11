# forge_3d sensor pass bench

- Build mode: ReleaseFast
- 1000 static bodies per scene, 200 `update` calls per mode per rep, 8 INTERLEAVED reps
- Anti-DCE checksum: 1818000

| mode | ns/tick | pairs held | % of a 16.67 ms frame |
|---|---|---|---|
| no trigger (floor) | 5.0 | 0 | 0.000% |
| resting, 1 trigger | 1005.0 | 8 | 0.006% |
| many, 64 triggers | 122745.0 | 1002 | 0.736% |

**Reported, not gated.** No envelope is pre-registered: this is the first measurement of
this path, and registering a bound before measuring its baseline is the failure mode
recorded at M1.1.8.

The `resting` row is the one the model owes a number for. `engine-physics-solver.md`
§1.13.9 states the price explicitly — sleep does not economise this pass — so a fully
resting scene pays it every tick. Every body in every scene here is static and nothing
moves, which is that regime; and because the pass reads no sleep state at all, the figure
is the same whether the population sleeps or not.

The `no trigger` row is the floor: nothing to enumerate, so it isolates the per-layer walk
from the candidate descent, and the other two rows are read against it.

The `pairs held` column is NON-VACUITY, not decoration: a row that timed an empty pass
under a busy row's name would be the same defect class as a test that exercises a path
without testing it.

Runs are INTERLEAVED — every rep runs all three modes in sequence and the best rep per mode
is kept — so a thermal ramp or a scheduling burst lands on all three rather than on
whichever happened to be measured while it passed.
