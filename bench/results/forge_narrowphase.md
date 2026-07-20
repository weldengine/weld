# forge_3d narrowphase fast-path bench

- Build mode: ReleaseFast
- Poses per pair: 2000 (contact + separated mix), reps: 100
- Anti-DCE checksum: 1356124.4934110916

| pair | dispatched (ns/pair) | generic (ns/pair) | ratio (disp/gen) |
|---|---|---|---|
| sphere/sphere | 37.59 | 66.78 | 0.563 |
| sphere/box | 55.87 | 206.54 | 0.270 |
| box/box | 197.41 | 732.42 | 0.270 |
| capsule/capsule | 15.05 | 125.98 | 0.119 |

**Verdict:** GO — the dispatched fast path must be strictly faster than
the generic GJK/EPA oracle on every pair (ratio < 1). Absolute ns are only
meaningful in ReleaseFast.
