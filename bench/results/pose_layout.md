## Pose buffer layout -- AoS against SoA

Mode: ReleaseFast. 9 interleaved rounds of 20000 iterations, median per round.
Per-bone footprint: AoS 48 B, AoS-vec 48 B, SoA-3 48 B, SoA-channel 40 B.

Decides a design; no target to clear. The kinematics arm composes MATRICES,
whose arithmetic dominates the cost of reading any layout: its ratios straddle
1.0 and its sign flips between bone counts, so no verdict is registered there.
The ruling rests on the blend.

### Blend (no dependency between bones)

| bones | AoS (ns) | AoS-vec (ns) | SoA-3 (ns) | SoA-channel (ns) | AoS-vec / AoS | SoA-3 / AoS | SoA-ch / AoS |
|---|---|---|---|---|---|---|---|
| 32 | 94.1 | 85.3 | 88.2 | 161.3 | 0.906x | 0.937x | 1.714x |
| 64 | 152.0 | 137.7 | 142.8 | 267.8 | 0.906x | 0.940x | 1.762x |
| 128 | 305.3 | 274.4 | 286.5 | 547.9 | 0.899x | 0.938x | 1.794x |

### Forward kinematics (serialised parent -> child)

| bones | AoS (ns) | AoS-vec (ns) | SoA-3 (ns) | SoA-channel (ns) | AoS-vec / AoS | SoA-3 / AoS | SoA-ch / AoS |
|---|---|---|---|---|---|---|---|
| 32 | 180.8 | 165.8 | 160.2 | 158.1 | 0.917x | 0.886x | 0.874x |
| 64 | 312.8 | 339.7 | 332.9 | 318.9 | 1.086x | 1.064x | 1.019x |
| 128 | 643.5 | 657.3 | 683.3 | 637.7 | 1.021x | 1.062x | 0.991x |

Layout agreement: all four compute the same pose (blend 492.102287930, fk -101.293061173 at 32 bones)
