# forge_3d raycast throughput bench

- Build mode: ReleaseFast
- Scene: 10000 STATIC bodies (spheres / boxes / capsules on a 3 m grid)
- Rays: 10000 per rep, 10 reps, best rep reported
- Anti-DCE checksum: 10070182.340

| mode | ns/ray | rays/s | rays per 16.67 ms frame | hit rate |
|---|---|---|---|---|
| closest | 780.8 | 1280738 | 21346 | 0.88 |
| any | 574.0 | 1742160 | 29036 | 0.88 |
| all (buffer 32) | 1518.3 | 658631 | 10977 | 0.88 |
| closest (5 m bound) | 371.0 | 2695418 | 44924 | 0.19 |
| closest (shuffled order) | 752.5 | 1328904 | 22148 | 0.88 |

**Reported, not gated.** No envelope is pre-registered: this is the first
measurement of this path, and registering a bound before measuring its
baseline is the failure mode recorded at M1.1.8. The structural guarantee is
the logarithmic visited-node test in the acceptance suite. The C1.1 target of
10 000 rays/frame at 60 Hz is verified at its own declared point,
`bench/physics_forge_3d_integration.zig` on the demo scene; the frame column
here is an order-of-magnitude indication on a synthetic grid.
