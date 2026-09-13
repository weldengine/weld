## Pose buffer layout -- AoS against SoA

Mode: ReleaseFast. 9 interleaved rounds of 20000 iterations, median per round.
Per-bone footprint: AoS 48 B, AoS-vec 48 B, SoA-3 48 B, SoA-channel 40 B.

Decides a design; no target to clear.

### Blend (no dependency between bones)

| bones | AoS (ns) | AoS-vec (ns) | SoA-3 (ns) | SoA-channel (ns) | AoS-vec / AoS | SoA-3 / AoS | SoA-ch / AoS |
|---|---|---|---|---|---|---|---|
| 32 | 75.9 | 69.2 | 72.4 | 136.5 | 0.911x | 0.954x | 1.798x |
| 64 | 152.6 | 137.8 | 142.9 | 268.2 | 0.903x | 0.936x | 1.758x |
| 128 | 305.8 | 273.7 | 286.5 | 546.1 | 0.895x | 0.937x | 1.786x |

### Forward kinematics (serialised parent -> child)

| bones | AoS (ns) | AoS-vec (ns) | SoA-3 (ns) | SoA-channel (ns) | AoS-vec / AoS | SoA-3 / AoS | SoA-ch / AoS |
|---|---|---|---|---|---|---|---|
| 32 | 119.1 | 112.2 | 112.8 | 130.1 | 0.942x | 0.947x | 1.092x |
| 64 | 242.8 | 229.0 | 228.3 | 265.6 | 0.943x | 0.940x | 1.094x |
| 128 | 489.3 | 455.5 | 457.3 | 533.9 | 0.931x | 0.934x | 1.091x |

Anti-DCE checksums: blend 1968.409152, fk 376.404757
