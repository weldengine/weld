# forge_3d narrowphase fast-path bench

- Build mode: ReleaseFast
- Poses per pair: 2000 (contact + separated mix), reps: 100
- Anti-DCE checksum: 1356124.4934110916

| pair | dispatched (ns/pair) | generic (ns/pair) | ratio (disp/gen) |
|---|---|---|---|
| sphere/sphere | 38.97 | 67.17 | 0.580 |
| sphere/box | 56.31 | 204.78 | 0.275 |
| box/box | 177.10 | 746.42 | 0.237 |
| capsule/capsule | 13.90 | 128.67 | 0.108 |

**Verdict:** GO — the dispatched fast path must be strictly faster than
the generic GJK/EPA oracle on every pair (ratio < 1). Absolute ns are only
meaningful in ReleaseFast.
