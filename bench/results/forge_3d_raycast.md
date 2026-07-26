# forge_3d raycast throughput bench

- Build mode: ReleaseFast
- Scene: 10000 STATIC bodies (spheres / boxes / capsules on a 3 m grid)
- Rays: 10000 per rep, 10 reps, best rep reported
- Anti-DCE checksum: 10635397.257

| mode | ns/ray | rays/s | rays per 16.67 ms frame | hit rate |
|---|---|---|---|---|
| closest | 784.9 | 1274048 | 21234 | 0.88 |
| any | 535.9 | 1866020 | 31100 | 0.88 |
| all (buffer 32) | 1530.0 | 653595 | 10893 | 0.88 |
| closest (5 m bound) | 374.9 | 2667378 | 44456 | 0.19 |
| closest (swept order) | 171.7 | 5824112 | 97069 | 1.00 |
| closest (swept, permuted) | 240.1 | 4164931 | 69416 | 1.00 |

**Reported, not gated.** No envelope is pre-registered: this is the first
measurement of this path, and registering a bound before measuring its
baseline is the failure mode recorded at M1.1.8. The structural guarantee is
the logarithmic visited-node test in the acceptance suite. The C1.1 target of
10 000 rays/frame at 60 Hz is verified at its own declared point,
`bench/physics_forge_3d_integration.zig` on the demo scene; the frame column
here is an order-of-magnitude indication on a synthetic grid.
