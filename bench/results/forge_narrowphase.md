# forge_3d narrowphase fast-path bench

- Build mode: ReleaseFast
- Poses per pair: 2000 (contact + separated mix), reps: 100
- Anti-DCE checksum: 1356124.4934110916

| pair | dispatched (ns/pair) | generic (ns/pair) | ratio (disp/gen) |
|---|---|---|---|
| sphere/sphere | 52.77 | 62.91 | 0.839 |
| sphere/box | 55.50 | 214.69 | 0.259 |
| box/box | 197.03 | 723.16 | 0.272 |
| capsule/capsule | 15.95 | 123.67 | 0.129 |

**Verdict:** GO — the dispatched fast path must be strictly faster than
the generic GJK/EPA oracle on every pair (ratio < 1). Absolute ns are only
meaningful in ReleaseFast.
