# `forge_3d` integration bench — the C1.1 frame column

Instrument: `bench/physics_forge_3d_integration.zig`, delivered at **M1.1.15.1 / gate E**.
Run: `zig build bench-physics-integration -Doptimize=ReleaseFast` (and `ReleaseSafe`).

`engine-phase-1-criteria.md` C1.1 names this file as where the frame column is measured, and
until this milestone **it did not exist**. Two files of the repository cited it in the present
tense. `bench/forge_3d_raycast.zig` and `bench/forge_3d_shapecast.zig` do reach 10 000 bodies,
but they interrogate a **static** scene — they never tick. So C1.1's figures were neither met
nor refuted: they were not measured, which is not the same thing.

Two targets are **GATED**, so this step fails rather than reports — frame time on the **p99**
(see below for why not the median) and zero allocation in steady state. One shape is **REPORTED**.

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

**The gated statistic is the p99, not the median.** The brief says "frame time <= 16.6 ms" with
no statistic, and the first version of this instrument settled that silently on the median — the
permissive reading. A 60 Hz frame budget is a real-time constraint: one frame in a hundred at
20 ms is a visible hitch, and a median never sees it. Nearest rank, stated rather than left to a
library convention: `ceil(0.99 x 240) - 1 = 237` zero-based, the **third-worst frame** of the
window.

Steady state opened at frame 31 in every run. P = 8 809 retained pairs, 1 000 constraints,
1 000 awake dynamic bodies of 11 000 total, **zero allocation attempts in steady state**.

| Mode | median | **p99 (gated)** | max | budget | margin on p99 |
|---|---|---|---|---|---|
| ReleaseFast | 2.028–2.144 ms | **2.113–3.576 ms** | 2.235–4.589 ms | 16.6 ms | **4.6x** worst observed |
| ReleaseSafe | 2.152–2.436 ms | **2.253–5.467 ms** | 2.275–7.873 ms | 16.6 ms | **3.0x** worst observed |

Ranges over five runs per mode, and they are reported as ranges because **the tail is machine
noise, not engine variance** — a fact that argues both ways and is therefore worth stating
plainly. Across those runs the median moved by 6 %, the p99 by up to 2.4x, and the max by up to
3.5x, on identical code and an identical scene; the anti-DCE checksum is bit-identical
throughout, ReleaseFast and ReleaseSafe alike, so the simulation is the same one every time.
Gating on the p99 therefore buys sensitivity to hitches and **costs stability**, and the margin
claim above is deliberately stated on the WORST p99 observed rather than on a best or a mean.
The median is the most stable statistic and the least informative; the max is the most
informative and the least stable.

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

## Non-vacuity — every guard was made to fail

An instrument that has never failed is not known to be able to.

| Counter-factual | Result |
|---|---|
| **three 20 ms hitches injected, budget UNCHANGED at 16.6 ms** | `GATE FAILED: p99 frame 20000000 ns exceeds … 16600000 ns (median 2050000, max 20000000)`, exit 1. **This is the discriminating one**: the median of that same run is 2.050 ms and clears the budget by 8x, so a median gate would have passed a run containing three visible hitches. No threshold was tuned to obtain it |
| budget lowered below the measured p99 | `GATE FAILED: … exceeds …`, exit 1 |
| one 8-byte allocation injected per measured frame | `GATE FAILED: 240 allocation attempts in steady state`, exit 1 — **exactly 240 for 240 frames**, so the counter is exact and not approximate |
| gated scene allowed to sleep | `GATE FAILED: only 0 of 1000 dynamic bodies awake` **and** `5280 allocation attempts` — two independent gates, exit 1 |
| warm-up bound cut to 5 frames | `error: SceneNeverConverged`, exit 1 — a scene that does not converge is refused, never measured |

Machine: Apple M4 Pro, macOS, Zig 0.16.0, `f32`. Frame times are machine-dependent; the margin,
the retention ratio and the allocation counts are the reportable quantities.
