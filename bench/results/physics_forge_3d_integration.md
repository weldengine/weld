# `forge_3d` integration bench — the C1.1 frame column

Instrument: `bench/physics_forge_3d_integration.zig`, delivered at **M1.1.15.1 / gate E**.
Run: `zig build bench-physics-integration -Doptimize=ReleaseFast` (and `ReleaseSafe`).

`engine-phase-1-criteria.md` C1.1 names this file as where the frame column is measured, and
until this milestone **it did not exist**. Two files of the repository cited it in the present
tense. `bench/forge_3d_raycast.zig` and `bench/forge_3d_shapecast.zig` do reach 10 000 bodies,
but they interrogate a **static** scene — they never tick. So C1.1's figures were neither met
nor refuted: they were not measured, which is not the same thing.

Two targets are **GATED**, so this step fails rather than reports. One shape is **REPORTED**.

## Method, stated before the figures

**Steady state is defined on the SCENE, not on the allocator.** It begins at the first frame
after which the retained candidate pair count *and* the constraint count are unchanged for
**30 consecutive frames** (half a second at 60 Hz). Defining it as "the frames after allocation
stops" would make the zero-allocation result true by choice of window and unable to fail; both
criteria here are structural quantities the allocator knows nothing about, so "no allocation
from there on" is a **prediction this bench can falsify**. The frame at which the window opens
is reported with every run. **240 frames** are then measured; the reported time is the median,
with the max beside it.

**The gated scene is kept awake, and the denominator is reported.** C1.1 asks for 1 000 dynamic
bodies at 60 Hz; a scene that has fallen asleep is not simulating them, and its frame time and
allocation count would both be excellent and meaningless. The gated run uses `initNoSleep`, and
the count of **awake dynamic** bodies is reported per window. The qualifier is load-bearing:
`isSleeping` answers `false` for a static, which never carries the flag, so an unqualified count
reports 11 000 awake for a scene whose 1 000 dynamics have all gone to sleep — which is exactly
what the first version of this instrument printed.

**Bodies are spawned in contact, not dropped.** A falling population spends the warm-up changing
its contact set, so structural convergence would measure the fall rather than the simulation.

## Gated results — 1 000 dynamic + 10 000 static, 60 Hz, f32

| Mode | median / frame | max / frame | budget | margin | awake dyn | steady allocations |
|---|---|---|---|---|---|---|
| ReleaseFast | **2.001 ms** | 2.370 ms | 16.6 ms | **8.3×** | 1000 / 1000 | **0** |
| ReleaseSafe | **2.436 ms** | 7.873 ms | 16.6 ms | **6.8×** | 1000 / 1000 | **0** |

Steady state opened at frame 31 in both. P = 8 809 retained pairs, 1 000 constraints. The
anti-DCE checksum is `-3660009.420159` and is **identical in the two modes**, so the two rows
measure the same simulation and not two different ones.

## Retention shape of step 2 — reported, not gated

`M1.D.13` closed at gate D by giving `proxyOf` a dense index; step 2 resolves both endpoints of
every retained pair through it, every tick, so the question is whether that step is Θ(P) or
Θ(P·N). **Growing the floor cannot answer it**: N and P then move together. The discriminating
experiment holds P fixed and moves N alone, by adding statics far enough away to touch nothing —
statics never pair with statics, so they enter the broadphase and the registration list and
contribute zero pairs.

| | N | P | ReleaseFast | ReleaseSafe |
|---|---|---|---|---|
| A | 2 756 | 2 209 | 504 µs | 574 µs |
| B | 10 256 | **2 209** | 574 µs | 701 µs |
| | **×3.72** | **×1.00** | **×1.14** | **×1.22** |

P is measured, not assumed: it reads 2 209 in both rows.

A Θ(P·N) step 2 would perform 45 311 008 endpoint resolutions per frame at B against
12 176 008 at A — **33.1 million extra** — for a measured delta of **70 µs**. That implies
2.1 **picoseconds** per resolution, which is not a slow implementation but an impossible one.
The Θ(P·N) shape is refuted by roughly 470× rather than by the absence of a visible slowdown.

For contrast, the confounded reading the first version of this bench offered, which
discriminates nothing: N = 2 756 / P = 2 209 → 504 µs against N = 11 000 / P = 8 809 → 2 001 µs.

## A finding: an ASLEEP scene allocates every frame, an awake one does not

Ungated, and the inverse of the intuition. The same 11 000-body scene with sleeping enabled:

| | awake dyn | constraints | median | steady allocations |
|---|---|---|---|---|
| awake (gated) | 1000 / 1000 | 1000 | 2.001 ms | **0** |
| asleep | **0** / 1000 | 0 | 0.202 ms | **5 280** (2 400 alloc + 2 880 remap) |

5 280 over 240 frames is **22 per frame**. The mechanism is named and already owned:
`rigid/contact_constraint.zig:578` allocates its `deferred` list per tick and frees it at the
end, and when every body is asleep all 8 809 retained pairs land in it — about fourteen doubling
steps, from empty, every tick. The file's own comment says so ("*what a resting tick still costs
is one pass over every deferred pair, including that list's allocation*"), and `CLAUDE.md`
assigns it by name: "*`build`'s per-tick deferred-index buffer is the one allocation on the
build path and moves to the orchestrator's scratch*". **This bench is the first measurement of
it.** It is left where its owner put it; what is new here is the number.

## Non-vacuity — the four guards were each made to fail

An instrument that has never failed is not known to be able to.

| Counter-factual | Result |
|---|---|
| budget lowered to 1 ms | `GATE FAILED: median frame 2160000 ns exceeds … 1000000 ns`, exit 1 |
| one 8-byte allocation injected per measured frame | `GATE FAILED: 240 allocation attempts in steady state`, exit 1 — **exactly 240 for 240 frames**, so the counter is exact and not approximate |
| gated scene allowed to sleep | `GATE FAILED: only 0 of 1000 dynamic bodies awake` **and** `5280 allocation attempts` — two independent gates, exit 1 |
| warm-up bound cut to 5 frames | `error: SceneNeverConverged`, exit 1 — a scene that does not converge is refused, never measured |

Machine: Apple M4 Pro, macOS, Zig 0.16.0, `f32`. Frame times are machine-dependent; the margin,
the retention ratio and the allocation counts are the reportable quantities.
