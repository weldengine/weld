# Vertical slice (C0.8) — runnable demo + 30 s capture procedure

> **Milestone:** M0.9 — Vertical slice + Phase 0 closure (E8)
> **Branch:** `phase-0/closure/vertical-slice-and-freeze`
> **What it exercises:** ECS + Etch (codegen) + render (GAL) + assets (cook+load) + input + IPC, simultaneously — the C0.8 acceptance slice.
> **Recording + hardware validation:** performed by Guy on the reference machines (Fedora 44 + GTX 1660 Ti / Windows 11 + RTX 4080). This doc delivers the runnable commands + the capture procedure; the video is archived as a tag artifact of `v0.9.0-phase-0-complete`.

## Build + run

```sh
# 1. Cook the slice assets (PNG → .texture.bin + the Etch gameplay module).
zig build cook-vertical-slice-assets

# 2a. Run the slice (auto mode: windowed if a display is available, else
#     headless). 100 entities on a 60 Hz fixed timestep, instanced cube +
#     sampled cooked texture + MVP camera + depth; SPACE pauses the sim.
zig build run-vertical-slice

# 2b. C0.8 IPC edit loop — an in-process editor-stub sends a real
#     ModifyComponent over the M0.7 AF_UNIX transport; the slice decodes +
#     applies it to the live World (Position.x teleport of entity 0) and the
#     GAL renderer reflects it the same frame.
zig build run-vertical-slice -- --ipc-edit

# Optional flags (examples/vertical_slice/main.zig):
#   --smoke-test     headless offscreen render, asserts the frame composes
#   --headless       force headless (no window) even if a display exists
#   --ticks <N>      run N fixed-timestep ticks then exit
#   --capture <path> write the rendered frame to a PPM for visual diff
```

CI runs the headless paths on lavapipe with validation + sync-validation layers
active (`vertical-slice-smoke` job): the smoke render, the `--ipc-edit` C0.8
edit, and the `run-ipc-demo` blit assertion — all VUID-clean.

## 30 s capture procedure (Guy, reference machine)

1. Build on the reference machine (Fedora 44 / Windows), `-Doptimize=ReleaseFast`.
2. `zig build cook-vertical-slice-assets` then `zig build run-vertical-slice`
   (windowed). Confirm: 100 instanced cubes animating at 60 Hz, textured,
   depth-correct; SPACE pauses/resumes.
3. Start a 30 s screen capture. Within the window: let the sim run ~10 s,
   press SPACE (pause) ~5 s, resume ~5 s.
4. In a second terminal, run `zig build run-vertical-slice -- --ipc-edit`
   (or trigger the in-slice editor-stub edit) and show entity 0 teleporting on
   the live frame — the C0.8 edit → live-world → visible loop.
5. Stop the capture. Archive the video as the `v0.9.0-phase-0-complete` tag
   artifact. Reference GPU stills already in `validation/` (the
   `*-nvidia_geforce_*` / `*-intel_*` PNG/PPM captures).

## Notes

- The visual/GPU validation is the reference machine's job (lavapipe in CI is
  the software-render gate; hardware GO is Guy's, mirroring S2/S6).
- macOS dev primary: the slice runs headless (`run-vertical-slice` falls back
  to headless on macOS — no Vulkan swapchain), sufficient for the C0.8 headless
  smoke + the IPC edit loop, not for the windowed capture.
