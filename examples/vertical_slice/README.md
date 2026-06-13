# Vertical slice — M0.9 (Phase 0 closure)

End-to-end demo that exercises the existing Phase 0 engine bricks together. As of
**E4** the slice **renders**: ECS + Etch gameplay (E3) is drawn through the GAL
Vulkan forward path, fed by an M0.6-cooked texture and driven by M0.3 input. The
IPC editor-stub loop arrives in E5.

## What it does

- **Gameplay** (`gameplay.etch`): five POD `component` types + five `rule`
  systems, cooked to Zig via the Etch → Zig codegen (`tools/etch_cook`).
- **Simulation** (`sim.zig`): boots an ECS `World`, registers the cooked
  components/rules, spawns **exactly 100 entities** laid out on a 10×10 grid
  with gentle per-entity velocities, and ticks the five rules at a **fixed
  60 Hz** (`dt = 1/60`).
- **Render** (`render.zig`): a GAL Vulkan forward pass draws one shared cube
  mesh **instanced** once per entity at the entity's live `Position` (read from
  the world each frame), shaded by the cooked albedo **texture** under a
  perspective **camera** with **depth** testing. The texture is uploaded to the
  GPU via `copyBufferToTexture` — the GAL primitive E4 implements (it was a
  Phase-0 no-op).
- **Asset** (`assets/slice_albedo.png` → `cook_assets.zig`): the source PNG is
  cooked through the **real M0.6 pipeline** (import → intermediate → `.texture.bin`)
  and **loaded at runtime** via the M0.6 async `Loader`.
- **Input** (M0.3): the host pumps window events into the `InputRawState`
  resource each frame; **SPACE toggles pause**, gating the simulation — an
  observable input effect.
- **Authored content** (`world.scene.etch`, `mob.prefab.etch`,
  `elite.prefab.etch`): a multi-file scene/prefab graph exercising the M0.9
  cross-file validation (E2-B) + triple-quote strings (E2-A). Authored +
  validated, **not instantiated** (see boundaries).

## Build & run

```sh
zig build run-vertical-slice                 # windowed render (Linux/Windows); headless on macOS
zig build run-vertical-slice -- --smoke-test # offscreen render → PPM capture (out/vertical_slice.ppm)
zig build run-vertical-slice -- --headless   # pure 60 Hz sim loop, no GPU
zig build run-vertical-slice -- --ticks 600  # custom tick budget
zig build cook-vertical-slice-assets         # cook the source PNG → .texture.bin (M0.6)
zig build test-vertical-slice                # integration test (also in `zig build test`)
```

## Render validation — CI-asserted vs hardware-validated

Real GPU rendering is **not** assertable on the macOS dev box (no Vulkan window
backend — Phase 2+) nor headlessly on the Null backend (it leaves `mapBuffer`
`Unsupported`, and the slice fills vertex/instance/uniform buffers). So render
coverage is layered, and the integration test does **not** assert pixels:

- **`zig build test` (every platform)** — the sim, the M0.6 asset cook+load, and
  the M0.3 input→pause effect are asserted. The render code is **compile-checked**
  (including the `copyBufferToTexture` upload call).
- **CI `vertical-slice-smoke` (Linux lavapipe, Debug)** — the `--smoke-test`
  offscreen render runs on software Vulkan with **validation layers active**; the
  job asserts a frame composed (PPM written) and is validation-clean (no VUID).
- **Hardware** — visual correctness (the textured, depth-sorted cube grid moving,
  SPACE pausing it) is validated on a real GPU.

## Design boundaries (deliberate, not gaps)

- **Entity spawning is host-driven** — the canonical Phase 0 Etch↔ECS bridge
  pattern (`src/demo_etch_codegen.zig`): the host spawns entities of the
  Etch-declared POD component types, and Etch rules drive them (E3 Option A,
  brief Blockers #1).
- **macOS = headless** — no Tier-0 Vulkan window backend in Phase 0; the slice
  runs the pure sim loop there.
- **`*.scene.etch` / `*.prefab.etch` are authored + cross-file validated**
  (E2-B), but **NOT instantiated**: runtime scene/prefab instantiation is the
  Phase 1 *Scene Serialization* deliverable, and cross-file component type-import
  resolution (the prefabs' `Health` → `E1793`) is the Phase 1 resolver. The
  integration test asserts the E2-B code *behaviour*, not a zero-diagnostic count
  (brief Blockers #1 and #2).
- **Logical-key input** reacts to the event's normalized `KeyCode`; the
  `InputRawState` keyboard array is raw-scancode-indexed in Phase 0 (Tier-1
  action mapping is Phase 1).
