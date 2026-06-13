# Vertical slice — M0.9 (Phase 0 closure)

End-to-end demo that exercises the existing Phase 0 engine bricks together. As of
**E3** the slice is **headless** (no rendering — that arrives in E4; the IPC
editor-stub loop arrives in E5).

## What it does (E3)

- **Gameplay** (`gameplay.etch`): five POD `component` types + five `rule`
  systems, cooked to Zig via the Etch → Zig codegen (`tools/etch_cook`).
- **Host** (`main.zig`): boots an ECS `World`, registers the cooked
  components/rules, spawns **exactly 100 entities**, and ticks the five rules at
  a **fixed 60 Hz** timestep (`dt = 1/60`). No window, no GPU.
- **Authored content** (`world.scene.etch`, `mob.prefab.etch`,
  `elite.prefab.etch`): a multi-file scene/prefab graph that exercises the M0.9
  cross-file validation (E2-B) and triple-quote multiline strings (E2-A). See
  the boundary note below.

## Build & run

```sh
zig build run-vertical-slice            # cook gameplay + run headless (120 ticks)
zig build run-vertical-slice -- --ticks 600   # custom tick budget
zig build test-vertical-slice           # headless integration test (also in `zig build test`)
```

## Design boundaries (deliberate, not gaps)

Entity spawning is host-driven — the canonical Phase 0 Etch↔ECS bridge pattern
(`src/demo_etch_codegen.zig`, `tests/etch_interp/diff_runner.zig`): the host
spawns entities of the Etch-declared POD component types, and Etch rules drive
them. This is the engine's intended Phase 0 model.

The `*.scene.etch` / `*.prefab.etch` are **authored and cross-file validated**
(E2-B: scene→prefab `E1786`, prefab `of` base `E1791`, cross-scene UUID `E1782`),
but are **NOT instantiated**:

- **Runtime scene/prefab instantiation** is the Phase 1 *Scene Serialization*
  deliverable (`engine-scene-serialization.md`); M0.8 set scene/prefab at
  Level C (descriptors). The slice does not load them.
- **Cross-file type-import resolution** (resolver pass-1) is a Phase 1 deliverable,
  so the prefabs' component references validate as `E1793 PrefabComponentTypeUnknown`
  under `validateProject` — this is **expected, documented Phase-0 behaviour**, not
  a defect (cf. `briefs/M0.9-vertical-slice-closure.md` Blockers #1 and #2). The
  integration test asserts the E2-B code *behaviour* (the cross-file references
  resolve), not a zero-diagnostic count.
