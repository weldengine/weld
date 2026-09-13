## Pose buffer layout -- AoS against SoA

Mode: ReleaseFast. 9 interleaved rounds of 20000 iterations, median per round.
Per-bone footprint: AoS 48 B, AoS-vec 48 B, SoA-3 48 B, SoA-channel 40 B.

Decides a design; no target to clear.

### Blend (no dependency between bones)

| bones | AoS (ns) | AoS-vec (ns) | SoA-3 (ns) | SoA-channel (ns) | AoS-vec / AoS | SoA-3 / AoS | SoA-ch / AoS |
|---|---|---|---|---|---|---|---|
| 32 | 99.2 | 82.1 | 85.3 | 160.4 | 0.828x | 0.860x | 1.618x |
| 64 | 156.2 | 141.2 | 146.9 | 282.4 | 0.904x | 0.940x | 1.808x |
| 128 | 319.7 | 287.6 | 303.6 | 578.9 | 0.900x | 0.949x | 1.811x |

### Forward kinematics (serialised parent -> child)

| bones | AoS (ns) | AoS-vec (ns) | SoA-3 (ns) | SoA-channel (ns) | AoS-vec / AoS | SoA-3 / AoS | SoA-ch / AoS |
|---|---|---|---|---|---|---|---|
| 32 | 122.1 | 115.2 | 114.6 | 134.1 | 0.943x | 0.938x | 1.098x |
| 64 | 252.3 | 236.4 | 232.9 | 275.0 | 0.937x | 0.923x | 1.090x |
| 128 | 504.8 | 474.7 | 474.0 | 553.0 | 0.940x | 0.939x | 1.096x |

Layout agreement: all four compute the same pose (blend 492.102287930, fk 94.101189148 at 32 bones)
