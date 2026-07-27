# forge_3d shape-cast and overlap throughput bench

- Build mode: ReleaseFast
- Scene: 10000 STATIC bodies (spheres / boxes / capsules on a 3 m grid) — the
  raycast bench's scene, so the two tables are comparable
- Queries: 10000 per rep, 10 reps, best rep reported
- Anti-DCE checksum: 14262579.523

| mode | ns/query | queries/s | queries per 16.67 ms frame | hit rate |
|---|---|---|---|---|
| sphere cast | 1292.9 | 773455 | 12891 | 0.98 |
| box cast | 1343.7 | 744214 | 12404 | 0.98 |
| capsule cast | 1276.1 | 783638 | 13061 | 0.98 |
| shape overlap (buffer 32) | 292.3 | 3421143 | 57019 | 0.19 |
| point cast (radius 0) | 1452.3 | 688563 | 11476 | 0.89 |
| raycast (same rays) | 926.1 | 1079797 | 17997 | 0.89 |

**Reported, not gated.** No envelope is pre-registered: this is the first
measurement of this path, and registering a bound before measuring its
baseline is the failure mode recorded at M1.1.8. The structural guarantees are
the swept traversal's pruning test and the cast kernel's closed-form oracles
in the acceptance suites.

The last two rows are a PAIR on the same query set: a radius-0 sphere cast
sweeps a point, so its traversal is `queryRay` exactly (the zero-extent
bit-identity pin), and the difference against the raycast entry is the GJK
march standing in for the analytic ray kernels — nothing else.
