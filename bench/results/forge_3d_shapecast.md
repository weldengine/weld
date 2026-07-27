# forge_3d shape-cast and overlap throughput bench

- Build mode: ReleaseFast
- Scene: 10000 STATIC bodies (spheres / boxes / capsules on a 3 m grid) — the
  raycast bench's scene, so the two tables are comparable
- Queries: 10000 per rep, 10 reps, best rep reported
- Anti-DCE checksum: 19343205.471

| mode | ns/query | queries/s | queries per 16.67 ms frame | hit rate |
|---|---|---|---|---|
| sphere cast | 1216.0 | 822368 | 13706 | 0.98 |
| box cast | 1253.3 | 797894 | 13298 | 0.98 |
| capsule cast | 1222.1 | 818264 | 13638 | 0.98 |
| shape overlap (buffer 32) | 233.1 | 4290004 | 71500 | 0.19 |
| point cast (radius 0) | 1249.2 | 800512 | 13342 | 0.89 |
| raycast (same rays) | 771.5 | 1296176 | 21603 | 0.89 |

**Reported, not gated.** No envelope is pre-registered: this is the first
measurement of this path, and registering a bound before measuring its
baseline is the failure mode recorded at M1.1.8. The structural guarantees are
the swept traversal's pruning test and the cast kernel's closed-form oracles
in the acceptance suites.

The last two rows are a PAIR on the same query set: a radius-0 sphere cast
sweeps a point, so its traversal is `queryRay` exactly (the zero-extent
bit-identity pin), and the difference against the raycast entry is the GJK
march standing in for the analytic ray kernels — nothing else.
