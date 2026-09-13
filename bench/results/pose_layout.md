## Pose buffer layout -- AoS against SoA

Mode: ReleaseFast. 9 interleaved rounds of 20000 iterations, median per round.
Per-bone footprint: AoS 48 B, SoA-3 48 B, SoA-channel 40 B.

Decides a design; no target to clear.

### Blend (no dependency between bones)

| bones | AoS (ns) | SoA-3 (ns) | SoA-channel (ns) | SoA-3 / AoS | SoA-ch / AoS |
|---|---|---|---|---|---|
| 32 | 75.4 | 72.0 | 131.7 | 0.955x | 1.747x |
| 64 | 151.0 | 141.4 | 265.1 | 0.936x | 1.756x |
| 128 | 298.2 | 286.7 | 529.8 | 0.961x | 1.777x |

### Forward kinematics (serialised parent -> child)

| bones | AoS (ns) | SoA-3 (ns) | SoA-channel (ns) | SoA-3 / AoS | SoA-ch / AoS |
|---|---|---|---|---|---|
| 32 | 118.3 | 110.0 | 126.5 | 0.930x | 1.069x |
| 64 | 240.0 | 223.6 | 261.1 | 0.932x | 1.088x |
| 128 | 476.7 | 450.2 | 519.1 | 0.944x | 1.089x |

Anti-DCE checksums: blend 1476.306864, fk 282.303567
