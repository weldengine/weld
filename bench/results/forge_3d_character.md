# forge_3d kinematic character controller bench

- Build mode: ReleaseFast
- 2000 calls per mode per rep, 8 INTERLEAVED reps, best rep reported
- Anti-DCE checksum: 31917.672

| mode | ns/call | calls/s | calls per 16.67 ms frame |
|---|---|---|---|
| moveCharacter / plane | 212.0 | 4716981 | 78616 |
| moveCharacter / stairs | 2235.5 | 447327 | 7455 |
| moveCharacter / wall | 1764.5 | 566733 | 9446 |
| moveCharacter / mesh floor | 7979.0 | 125329 | 2089 |
| resizeCharacter | 203.0 | 4926108 | 82102 |

**Reported, not gated.** No envelope is pre-registered: this is the first measurement of
this path, and registering a bound before measuring its baseline is the failure mode
recorded at M1.1.8.

Runs are INTERLEAVED — every rep runs all five modes in sequence and the best rep per mode
is kept — so a thermal ramp or a scheduling burst lands on all five rather than on
whichever happened to be measured while it passed. Best-of-N per mode cannot resolve a gap
under about 5 %, which is the size of the gaps between these rows.

The five rows are five different code paths, not five scales of one: the plane row runs the
ground sweep alone, the stairs row arms the climb's three sweeps, the wall row arms the
slide, the mesh row puts the ground sweep and the contact fallback on a `.triangle_soup`
shape, and `resizeCharacter` is the only row that allocates.
