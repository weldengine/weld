# forge_3d narrowphase fast-path bench

- Build mode: ReleaseFast
- Poses per pair: 2000 (contact + separated mix), reps: 100
- Anti-DCE checksum: 1356124.4934110916

| pair | dispatched (ns/pair) | generic (ns/pair) | ratio (disp/gen) |
|---|---|---|---|
| sphere/sphere | 37.41 | 67.75 | 0.552 |
| sphere/box | 55.75 | 205.74 | 0.271 |
| box/box | 196.46 | 717.90 | 0.274 |
| capsule/capsule | 14.52 | 125.97 | 0.115 |

**Verdict:** GO — the dispatched fast path must be strictly faster than
the generic GJK/EPA oracle on every pair (ratio < 1). Absolute ns are only
meaningful in ReleaseFast.
