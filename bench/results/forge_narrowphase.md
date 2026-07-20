# forge_3d narrowphase fast-path bench

- Build mode: ReleaseFast
- Poses per pair: 2000 (contact + separated mix), reps: 100
- Anti-DCE checksum: 1356124.4934110916

| pair | dispatched (ns/pair) | generic (ns/pair) | ratio (disp/gen) |
|---|---|---|---|
| sphere/sphere | 38.96 | 68.53 | 0.569 |
| sphere/box | 56.88 | 204.37 | 0.278 |
| box/box | 199.50 | 736.46 | 0.271 |
| capsule/capsule | 15.19 | 128.74 | 0.118 |

**Verdict:** GO — the dispatched fast path must be strictly faster than
the generic GJK/EPA oracle on every pair (ratio < 1). Absolute ns are only
meaningful in ReleaseFast.
