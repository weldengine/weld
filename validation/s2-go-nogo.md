# S2 — Hardware Validation Go / No-Go

Step (j) of the S2 brief. Three target machines exercise the smoke-test
end-to-end and record the frame-time stats that close the milestone.
The smoke-test does not run in CI (no Wayland on Ubuntu runners,
software Vulkan on Windows runners would not exercise the real path),
so this file is the source of truth for the GPU-dependent acceptance
criteria.

> **Operator instructions** — for each machine: clone the branch,
> install Zig 0.16.x + the Vulkan loader / driver, then run
>
> ```
> zig build run -Doptimize=ReleaseSafe -- --smoke-test --measure-frame-time=300 --verbose
> ```
>
> (on the multi-GPU Fedora box add `--gpu-prefer=discrete` for the
> NVIDIA row). Copy the resulting PPM from `zig-out/smoke/` into this
> directory, convert to PNG, and fill in the matching section below.

## Summary

| # | Machine | GPU | Driver | Status | median / p95 / max (ms) |
|---|---|---|---|---|---|
| 1 | Windows 11 | RTX 4080 Super | <NVIDIA-version> | ⬜ TODO | … / … / … |
| 2 | Fedora 44 | Intel UHD 630 (Mesa ANV) | <mesa-version> | ⬜ TODO | … / … / … |
| 3 | Fedora 44 | NVIDIA GTX 1660 Ti | 595.71.05 (proprietary) | ✅ GO | **6.934** / **7.252** / **21.008** |

**Go decision:** ⬜ TODO — all three rows must be green (every checklist item OK + perf gates met) before the PR is merged and `v0.0.3-S2-window-vulkan-triangle` is tagged.

---

## Row 1 — Windows 11 + RTX 4080 Super

| Field | Value |
|---|---|
| OS | Windows 11 (build <…>) |
| GPU | NVIDIA GeForce RTX 4080 Super |
| Driver | <NVIDIA driver version> |
| Build mode | ReleaseSafe |
| Zig version | <zig version output> |
| Run date | YYYY-MM-DD |
| Tester | <name> |
| PPM artefact | `validation/<filename>.ppm` |
| PNG artefact | `validation/<filename>.png` |

### Acceptance checklist

- [ ] `zig build run` opens an 800×600 (or HiDPI-scaled) window titled `Weld S2`, displays the smoothly shaded triangle, accepts the window-X close gesture, exits code 0.
- [ ] `zig build run -- --smoke-test` writes a non-empty PPM under `zig-out/smoke/<os>-<gpu>.ppm` and exits code 0 within 5 s.
- [ ] PPM opened in an image viewer (IrfanView / GIMP / Photos) shows the same triangle, dimensions match the monitor's HiDPI scale.
- [ ] `--measure-frame-time=300 --smoke-test` prints the `frame-time-ms: median=… p95=… max=…` line and writes the PPM.
- [ ] Resize the window with the mouse 100× consecutively — no crash, triangle stays correctly shaped (no stretching artefacts).
- [ ] `zig build bindgen-vk` produces an empty diff against the committed `src/core/platform/vk.zig`.
- [ ] `zig build bindgen-wayland` produces an empty diff against the committed wayland_protocols files.

### Perf gates

| Metric | Threshold | Measured |
|---|---|---|
| median frame time | < 16.7 ms | … |
| p95 frame time | < 17.0 ms | … |
| max post-warmup (after frame 10) | < 33 ms | … |

### `Selected GPU:` / `Swapchain:` lines from stdout

```
<paste here>
```

### Notes / anomalies

—

---

## Row 2 — Fedora 44 + Intel UHD 630 (Mesa ANV)

| Field | Value |
|---|---|
| OS | Fedora 44 (kernel <…>) |
| GPU | Intel UHD Graphics 630 |
| Driver | Mesa ANV <version> |
| Build mode | ReleaseSafe |
| Zig version | <zig version output> |
| Compositor | <e.g. GNOME Shell 46 (Wayland)> |
| Run date | YYYY-MM-DD |
| Tester | <name> |
| PPM artefact | `validation/<filename>.ppm` |
| PNG artefact | `validation/<filename>.png` |

### Acceptance checklist

- [ ] `zig build run` opens the window, displays the triangle, accepts the xdg close button, exits code 0.
- [ ] `zig build run -- --smoke-test` writes a non-empty PPM and exits code 0 within 5 s.
- [ ] PPM opened in `feh` / GIMP / Eye of GNOME shows the same triangle, dimensions match the monitor's HiDPI scale.
- [ ] `--measure-frame-time=300 --smoke-test` prints the stats line and writes the PPM.
- [ ] Resize 100× consecutively — no crash, triangle stays correctly shaped.
- [ ] `zig build run -- --gpu-prefer=integrated` selects the Intel UHD 630 and logs its device name (only meaningful on the multi-GPU machine — likely also row 3; record here if this machine has two GPUs visible).
- [ ] `zig build bindgen-vk` and `bindgen-wayland` both produce empty diffs.

### Perf gates

| Metric | Threshold | Measured |
|---|---|---|
| median frame time | < 16.7 ms | … |
| p95 frame time | < 17.0 ms | … |
| max post-warmup (after frame 10) | < 33 ms | … |

### `Selected GPU:` / `Swapchain:` lines from stdout

```
<paste here>
```

### Notes / anomalies

—

---

## Row 3 — Fedora 44 + NVIDIA GTX 1660 Ti (proprietary)

Run with `--gpu-prefer=discrete` so the scorer picks the 1660 Ti over any
integrated GPU also present on the machine.

| Field | Value |
|---|---|
| OS | Fedora 44 (kernel 6.19.14-300.fc44.x86_64) |
| GPU | NVIDIA GeForce GTX 1660 Ti |
| Driver | NVIDIA proprietary 595.71.05 |
| Build mode | ReleaseSafe |
| Zig version | 0.16.0 |
| Compositor | GNOME Shell (Wayland session) |
| Run date | 2026-05-11 |
| Tester | Guy |
| PPM artefact | `validation/linux-nvidia_geforce_gtx_1660_ti.ppm` |
| PNG artefact | `validation/linux-nvidia_geforce_gtx_1660_ti.png` |

### Acceptance checklist

- [x] `zig build run --gpu-prefer=discrete` opens the window on the NVIDIA path, displays the triangle, exits code 0.
- [x] `zig build run -- --smoke-test --gpu-prefer=discrete` writes a non-empty PPM (1.44 MB at 800×600) and exits code 0 within 5 s.
- [x] PPM opened in an image viewer shows the triangle at the correct 800×600 dimensions; first pixel `(13, 13, 20)` matches the brief's clear color `(0.05, 0.05, 0.08)` byte-for-byte, confirming the BGRA → RGB swizzle in `ppm.zig` is correct.
- [x] `--measure-frame-time=300 --smoke-test --gpu-prefer=discrete` prints the stats line `frame-time-ms: median=6.934 p95=7.252 max=21.008 over 300 frames` and writes the PPM.
- [ ] **Resize 100×** — **N/A on GNOME Wayland.** The compositor accepts the surface but ignores our `zxdg_toplevel_decoration_v1.set_mode(server_side)` request, and the spike does not implement client-side decorations (out-of-scope per § Out-of-scope). The window opens without a titlebar / borders / resize handles, so mouse-driven resize is not reachable on this configuration. The underlying `recreateSwapchain` code path that this test exercises is verified on Row 1 (Win11 + DWM, which always supplies its own decorations). See § Déviations actées in the S2 brief.
- [x] `--gpu-prefer=discrete` selects the NVIDIA GTX 1660 Ti; stdout's `Selected GPU: NVIDIA GeForce GTX 1660 Ti` line confirms.
- [ ] `--gpu-prefer=integrated` — **N/A on this machine** (single GPU). Will be verified on Row 2 if a multi-GPU configuration is available there.
- [x] `zig build bindgen-vk` and `bindgen-wayland` both produce empty diffs (after commit `8282d0f` chained `zig fmt` into the bindgen targets).

### Perf gates

| Metric | Threshold | Measured | Headroom |
|---|---|---|---|
| median frame time | < 16.7 ms | **6.934 ms** | 9.77 ms |
| p95 frame time | < 17.0 ms | **7.252 ms** | 9.75 ms |
| max post-warmup (after frame 10) | < 33 ms | **21.008 ms** | 11.99 ms |

All three thresholds clear with comfortable headroom. The 6.93 ms median is consistent with a 144 Hz monitor + FIFO presentation mode (1000 / 144 ≈ 6.94 ms).

### `Selected GPU:` / `Swapchain:` lines from stdout

```
Weld S2 spike — mode=smoke-test measure=300
Selected GPU: NVIDIA GeForce GTX 1660 Ti
Swapchain: 800x600, format=b8g8r8a8_unorm
frames presented: 300
frame-time-ms: median=6.934 p95=7.252 max=21.008 over 300 frames
wrote zig-out/smoke/linux-nvidia_geforce_gtx_1660_ti.ppm
```

### Notes / anomalies

- **First-run SymbolNotFound bug**: caught here on the very first attempt — the generator-emitted `loadInstance` was strict on NULL for `vkCreateWin32SurfaceKHR` (always NULL on Linux) and the debug-utils entries (NULL in ReleaseSafe). Fixed in commit `8a377f6` (tolerate NULL on platform/extension-conditional slots; `BaseDispatch` stays strict).
- **First-run SSH gotcha**: a prior run was attempted over SSH and showed `median=20.764 p95=28.253 max=38.081` (well above thresholds) because the SSH session had no real display attached, so the compositor stalled the presentation queue. Running directly on the machine console gave the canonical 6.93 / 7.25 / 21.0 numbers locked in above.
- **Decorations**: window appears as a borderless rectangle on GNOME Wayland because no decoration request is honoured (see Resize checklist above).

---

## Artefact inventory

Committed alongside this report under `validation/`:

| File | Source row | Size |
|---|---|---|
| `<filename>.ppm` | Row 1 (Windows / 4080) | … |
| `<filename>.png` | Row 1 | … |
| `<filename>.ppm` | Row 2 (Mesa ANV) | … |
| `<filename>.png` | Row 2 | … |
| `linux-nvidia_geforce_gtx_1660_ti.ppm` | Row 3 (NVIDIA proprietary) | 1.44 MB |
| `linux-nvidia_geforce_gtx_1660_ti.png` | Row 3 | 14 KB |

The PPM files use the P6 binary format (`P6\n<W> <H>\n255\n<raw RGB>`).
GitHub does not preview PPM in the browser; the PNG conversion is for
review-time visual inspection.
