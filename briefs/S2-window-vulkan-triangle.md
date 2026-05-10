# S2 — Native Window + Vulkan Triangle

> **Status:** ACTIVE
> **Phase:** −1
> **Branche:** `phase-pre-0/platform/window-vulkan-triangle`
> **Tag prévu:** `v0.0.3-S2-window-vulkan-triangle`
> **Dépendances:** `v0.0.2-S1-mini-ecs`
> **Date d'ouverture:** 2026-05-10
> **Date de fermeture:** —

---

# SECTION FIGÉE

*Produced by Claude.ai. Not modifiable by Claude Code outside a Claude.ai round-trip (cf. § Acted deviations).*

## Context

Third spike of Phase −1. Validates the hypothesis that a Win32 window, a Wayland window, a Vulkan instance/device/swapchain and a textured triangle can be built end-to-end in pure Zig 0.16.x — no SDL, no GLFW, no `wayland-scanner`, no `@cImport`. Code produced is **not throwaway**: the public surface of `Window` and the generated Vulkan/Wayland bindings becomes Tier 0 from S2 onward (extended in Phase 0.3 with X11 + input, refactored in S3 to use the unified bindgen system without changing call sites). Only the Vulkan setup/render code in `src/main.zig` and its private helpers are explicitly throwaway, scheduled for Phase 0.4 refactor when the GPU Abstraction Layer is designed.

## Scope

- Native Win32 windowing in `src/core/platform/window/win32.zig`. `extern fn` declarations written by hand against `user32.dll` / `gdi32.dll` / `kernel32.dll`. Static linkage via Zig import libs. No `dlopen`, no translate-c, no XML.
- Native Wayland windowing in `src/core/platform/window/wayland.zig`. Wayland client library (`libwayland-client.so.0`) loaded at runtime via `dlopen` + `dlsym`. Wayland event callbacks declared with Zig `callconv(.c)`. Protocol bindings emitted by `tools/wayland_gen/` from the vendored XML files (`wayland.xml`, `xdg-shell.xml`, `xdg-decoration-unstable-v1.xml`).
- Public `Window` interface in `src/core/platform/window.zig` exposing exactly: `create`, `destroy`, `close`, `resize` event delivery, `dpi_changed` event delivery. Comptime dispatch to the Win32 or Wayland backend based on `@import("builtin").os.tag`. No input handling, no focus, no minimize/restore, no multi-monitor — those land in Phase 0.3.
- Vulkan loader and bindings in `src/core/platform/vk.zig`, emitted by `tools/vk_gen/` from the vendored `vk.xml`. Vulkan loader (`libvulkan.so.1` / `vulkan-1.dll`) loaded at runtime via `dlopen` / `LoadLibraryW`. Per-instance and per-device dispatch tables, standard Vulkan loader pattern.
- Vulkan binding API surface conforms to `engine-c-bindings.md` §4.2 idiomatic mapping rules: functions in `camelCase` attached to their owning type, slices instead of `[*]T + size_t` length pairs, error unions on `VkResult`, `packed struct` representation for bitmasks (`VkBufferUsageFlags`, etc.), opaque handle types, tagged enums. This conformance guarantees a zero-or-trivial diff when S3 regenerates the binding via the unified system, with **zero call site changes** in the spike binary.
- Standalone monolithic binding generators `tools/vk_gen/` and `tools/wayland_gen/`. XML → Zig direct, no intermediate canonical format. Both are explicitly throwaway: replaced in S3 by the unified bindgen system (cf. `engine-c-bindings.md` §10.1). Generated files are committed; regeneration is triggered explicitly via `zig build bindgen-vk` / `zig build bindgen-wayland`, never as part of the default `zig build`.
- Vulkan triangle rendering in `src/main.zig` plus 2-3 private helper files under `src/spike/` (e.g. `vk_setup.zig`, `vk_frame.zig`). Static colored triangle, barycentric RGB interpolation. Vertex buffer in device-local memory, populated via staging buffer.
- Swapchain in FIFO present mode (vsync on), 2 frames in flight. Recreated on resize events from both backends. Image acquisition / submission / presentation use semaphores and fences correctly so that the host never blocks on present completion.
- HiDPI handling at the integer scale level only: read `GetDpiForWindow` on Win32 and `wl_output.scale` on Wayland, create the swapchain at the physical pixel resolution. Fractional scaling (Wayland `wp_fractional_scale_v1`) is out of scope.
- Multi-GPU selection. Default scoring picks discrete > integrated > other GPU. CLI flag `--gpu-prefer=<discrete|integrated|index:N>` overrides the default. Allows running both Mesa ANV (Intel UHD 630) and NVIDIA proprietary (GTX 1660 Ti) on the same Fedora machine without rebuild.
- Vulkan validation layers active in Debug builds. The binary attempts to enable `VK_LAYER_KHRONOS_validation` and the `VK_EXT_debug_utils` instance extension. If the validation layer is not installed on the host, log a warning and continue without it. ReleaseSafe builds never enable validation layers regardless of host environment.
- Pre-compiled SPIR-V shaders committed under `assets/shaders/`. Sources `triangle.vert.glsl` and `triangle.frag.glsl` committed alongside their `triangle.vert.spv` and `triangle.frag.spv` outputs. POSIX shell script `scripts/compile-shaders.sh` invokes `glslc`; the script is **not** wired into `zig build`. The runtime binary embeds the SPV files via `@embedFile`; the Vulkan SDK is required only to regenerate them.
- `--smoke-test` mode: opens the window, runs the render loop until 10 frames have been successfully presented, captures the contents of the last presented swapchain image as PPM (P6 binary format) into `zig-out/smoke/<os>-<gpu_name>.ppm`, exits with code 0. Hard timeout of 5 seconds wall-clock — if the 10th frame is not reached, exit with code 1 and an explanatory log line. SIGINT during smoke-test triggers a clean teardown and exit code 130.
- `--measure-frame-time=<N>` mode (default 300): runs the render loop for N frames, prints median, p95 and max frame durations to stdout, exits with code 0. Used to populate the `validation/s2-go-nogo.md` report. Compatible with `--smoke-test`.
- `--verbose` flag: enables event logging in interactive mode (off by default to keep stdout clean for normal runs). Smoke-test mode always logs events.
- Validation report `validation/s2-go-nogo.md` committed in the merge PR. Contains three rows of validation: Windows 11 + RTX 4080 Super, Fedora 44 + UHD 630 (Mesa ANV), Fedora 44 + GTX 1660 Ti (NVIDIA proprietary 595.71.05 with `--gpu-prefer=discrete`). Each row records OS / GPU / driver / build mode / date, an OK-or-KO checklist for every acceptance criterion, and the median / p95 / max frame time over 300 frames. Raw PPM captures committed under `validation/`; PNG conversions committed alongside (PPM is not previewable on GitHub).
- CI matrix unchanged from S0/S1: `{ubuntu-24.04, windows-2025} × {Debug, ReleaseSafe}` running `zig fmt --check`, `zig build`, `zig build test`. The smoke-test is **not** run in CI (no Wayland on Ubuntu runners; software Vulkan on Windows runners would not exercise the real path).

## Out-of-scope

- X11 backend (Phase 0.3).
- Input handling: keyboard, mouse, gamepad, touch, pen (Phase 0.3).
- Window state management beyond create/destroy/close: minimize, maximize, restore, suspend/resume, focus tracking, multi-monitor enumeration (Phase 0.3).
- Wayland fractional scale (`wp_fractional_scale_v1`), Wayland presentation-time, any Wayland protocol other than `wl_core` + `xdg-shell` + `xdg-decoration-unstable-v1`.
- macOS, iOS, Android, Web platform support (Phase 2+).
- GPU Abstraction Layer (Phase 0.4): Vulkan is used directly in S2.
- Render graph (Phase 0.4).
- Multiple swapchain present modes (Mailbox, Immediate, FIFO Relaxed). FIFO is the only mode in S2.
- Triple buffering, more than 2 frames in flight.
- Animation, uniforms, push constants, descriptor sets, multiple draw calls.
- Vertex/index dynamic streaming, asset loading from disk at runtime. Vertex data is hardcoded in source; SPIR-V shaders are `@embedFile`d.
- Image format conversion or color space management. The swapchain uses `VK_FORMAT_B8G8R8A8_UNORM` or the closest available SRGB format detected at runtime. PPM output is sRGB by convention; no profile is written.
- Network-attached debugging (RenderDoc remote, Vulkan layers over network).
- Canonical `.api.zig` format and unified emitter (S3).
- Refactor of `tools/vk_gen/` and `tools/wayland_gen/` toward a shared XML adapter base — they are deliberately monolithic in S2.
- Any creation of `src/modules/render/` — this directory is introduced in Phase 0.4 with the GAL.
- Any sub-directory named `spike/` other than `src/spike/` for the throwaway helper files of `src/main.zig`. Final-location code (interfaces, backends, generated bindings) lives in its final paths from day one.
- `wayland-scanner` (we do not invoke the upstream C tool).
- `addTranslateC` for Vulkan or Wayland (XML is the canonical source).
- Custom logging framework. `std.log` with scope `s2` is used.
- Benchmark file under `bench/`. Frame time measurement is in-binary and reported in the validation file, not as a sweep.

## Documents de spec à lire en premier

1. `engine-spec.md` — §22.3 Phase −1 / S2 (full canonical definition including post-conversation refinements), §1 (overview), §3.5 (in-tree vs separable libs criterion), §1.6 (8 keepers list — none added in S2).
2. `engine-c-bindings.md` — §1.1 to §1.4 (rationale registry-driven and S2 carve-out), §4.2 (idiomatic mapping rules — these are the conformance target for the S2 generators), §10.1 (S2→S3 sequencing).
3. `engine-platform.md` — §1 (architecture, what belongs to the platform layer), §2 windowing and HiDPI subsections.
4. `engine-mach-reference.md` — §5 (native windowing inspiration: Win32 ~800 lines direct, Wayland ~2100 lines + a tiny C callbacks file). Read as design inspiration, **not** as a code template — Weld's S2 attempts pure Zig callbacks via `callconv(.c)`.
5. `engine-render.md` — §3 (GAL — read to understand what S2 deliberately does **not** build).
6. `engine-zig-conventions.md` — §1 (file naming: `window.zig` is a namespace file in `snake_case`; the `Window` struct it exposes is `PascalCase`), §14 (binding isolation rules), §17 (Zig 0.16.x policy).
7. `engine-development-workflow.md` — §3 (brief format), §4.3 (Conventional Commits scopes), §4.5 (lefthook), §4.6 (squash-and-merge), §5 (review cycle).
8. `engine-directory-structure.md` — confirm paths for `bindings/upstream/`, `tools/`, `assets/`, `src/core/platform/`.

## Fichiers à créer ou modifier

### Tooling (binding generators)

- `tools/vk_gen/main.zig` — création — entry point of the Vulkan binding generator. Reads `bindings/upstream/vulkan/vk.xml`, emits `src/core/platform/vk.zig`. Whitelist of versions/extensions enabled in S2: Vulkan 1.3 core, `VK_KHR_surface`, `VK_KHR_swapchain`, `VK_KHR_wayland_surface` on Linux, `VK_KHR_win32_surface` on Windows, `VK_EXT_debug_utils` (Debug build only). The whitelist is data, declared inside the generator, not magic.
- `tools/vk_gen/parser.zig` — création — XML parser specialized for `vk.xml`. Custom, ad-hoc, throwaway. No external XML dependency.
- `tools/vk_gen/emit.zig` — création — emits idiomatic Zig from the parsed structures, conforming to `engine-c-bindings.md` §4.2.
- `tools/wayland_gen/main.zig` — création — entry point of the Wayland binding generator. Reads `bindings/upstream/wayland/protocols/*.xml`, emits `src/core/platform/window/wayland_protocols/{core,xdg_shell,xdg_decoration}.zig`.
- `tools/wayland_gen/parser.zig` — création — XML parser for Wayland protocol files. Format is simpler than `vk.xml`; the parser does not need to reuse code from `tools/vk_gen/`.
- `tools/wayland_gen/emit.zig` — création — emits idiomatic Zig protocol bindings. Each interface produces methods for requests and a listener struct for events.

### Vendored upstream sources

- `bindings/upstream/vulkan/vk.xml` — création — Khronos Vulkan registry, current Vulkan release. Apache-2.0.
- `bindings/upstream/vulkan/LICENSE` — création — Apache-2.0 notice.
- `bindings/upstream/wayland/wayland.xml` — création — Wayland core protocol from `freedesktop.org/wayland/wayland`.
- `bindings/upstream/wayland/protocols/xdg-shell.xml` — création — from `freedesktop.org/wayland-protocols`.
- `bindings/upstream/wayland/protocols/xdg-decoration-unstable-v1.xml` — création — same source.
- `bindings/upstream/wayland/LICENSE` — création — MIT notice (Wayland and the listed protocol files).

### Generated bindings (committed)

- `src/core/platform/vk.zig` — création — emitted by `tools/vk_gen/`. Header comment marks the file as `// AUTO-GENERATED — do not edit. Regenerate via 'zig build bindgen-vk'.`
- `src/core/platform/window/wayland_protocols/core.zig` — création — emitted by `tools/wayland_gen/`. Same header.
- `src/core/platform/window/wayland_protocols/xdg_shell.zig` — création — same.
- `src/core/platform/window/wayland_protocols/xdg_decoration.zig` — création — same.

### Platform layer (Tier 0, stable from S2)

- `src/core/platform/window.zig` — création — public `Window` interface and event types. Comptime dispatch to the appropriate backend. The exposed surface is exactly: `create`, `destroy`, `close`, `resize` event, `dpi_changed` event. Nothing else.
- `src/core/platform/window/win32.zig` — création — Win32 backend. Hand-written `extern fn` declarations for the Win32 functions needed by the public interface. Static linkage via Zig import libs.
- `src/core/platform/window/wayland.zig` — création — Wayland backend. Loads `libwayland-client.so.0` via `dlopen`. Uses the generated `wayland_protocols` modules. Event callbacks declared `callconv(.c)`. If the `callconv(.c)` hypothesis fails, see § Notes for the documented fallback.

### Spike binary (Tier ⊘, throwaway, refactored in Phase 0.4)

- `src/main.zig` — création — entry point. Parses CLI flags (`--smoke-test`, `--measure-frame-time=N`, `--gpu-prefer=...`, `--verbose`). Drives the render loop. Owns the Vulkan instance/device/swapchain.
- `src/spike/vk_setup.zig` — création — creates VkInstance, picks the physical device per the `--gpu-prefer` policy, creates VkDevice, creates the surface using the platform-specific extension, creates the swapchain, allocates the vertex buffer + staging upload, builds the render pass, pipeline, framebuffers, command buffers, semaphores and fences.
- `src/spike/vk_frame.zig` — création — per-frame logic: acquire image, record commands, submit, present, handle out-of-date or suboptimal swapchain by recreating it.
- `src/spike/scoring.zig` — création — pure function `scoreDevice` that scores a `VkPhysicalDevice` by type (discrete > integrated > other > CPU). Tested in isolation.
- `src/spike/cli.zig` — création — pure CLI parser. Tested in isolation.

### Build and assets

- `build.zig` — édition — adds the spike binary target, the `bindgen-vk` and `bindgen-wayland` build steps, the test runner additions, and OS-specific link options (system libs `user32`/`gdi32`/`kernel32` on Windows; nothing system-linked on Linux since Wayland and Vulkan are dlopen-ed). Conditionally compiles the Wayland C fallback file when an opt-in build flag is set (see § Notes).
- `build.zig.zon` — édition — no new dependencies; this milestone introduces zero Zig packages and zero C bindings.
- `assets/shaders/triangle.vert.glsl` — création — vertex shader, GLSL 4.50, emits `gl_Position` and `vColor`.
- `assets/shaders/triangle.frag.glsl` — création — fragment shader, outputs the interpolated `vColor`.
- `assets/shaders/triangle.vert.spv` — création — pre-compiled SPIR-V committed.
- `assets/shaders/triangle.frag.spv` — création — same.
- `scripts/compile-shaders.sh` — création — POSIX shell script invoking `glslc`. Not invoked by `zig build`.

### CI

- `.github/workflows/ci.yml` — édition — no matrix change. Possibly an extra cache key for the vendored `bindings/upstream/` sources.

### Documentation

- `briefs/S2-window-vulkan-triangle.md` — création — verbatim copy of this brief, committed as the first commit of the branch.
- `validation/s2-go-nogo.md` — création — manual validation report (filled in late in the milestone, by Guy, after running on the three target hardware configurations).
- `validation/s2-windows-rtx4080.ppm` — création — smoke-test capture, Windows + RTX 4080 Super.
- `validation/s2-windows-rtx4080.png` — création — PNG conversion for GitHub preview.
- `validation/s2-fedora-uhd630.ppm` + `.png` — création — Fedora + Intel UHD 630 (Mesa ANV).
- `validation/s2-fedora-gtx1660ti.ppm` + `.png` — création — Fedora + GTX 1660 Ti (NVIDIA proprietary).
- `CLAUDE.md` — édition — update at end of milestone per `engine-development-workflow.md` §3.4: tag table, current state, hypotheses table (S2 marked validated), open decisions if any.

## Critères d'acceptation

### Tests

- `tests/spike/scoring_test.zig` — `test "scoreDevice ranks discrete above integrated above CPU"` — direct unit test of the pure scoring function with synthetic `VkPhysicalDeviceProperties` inputs (no Vulkan loader required).
- `tests/spike/scoring_test.zig` — `test "scoreDevice respects --gpu-prefer=integrated"` — explicit override changes the ranking.
- `tests/spike/scoring_test.zig` — `test "scoreDevice respects --gpu-prefer=index:N"` — explicit index pin returns that device or an error if N is out of range.
- `tests/spike/cli_test.zig` — `test "CLI parses --smoke-test as flag"` — boolean flag, no value.
- `tests/spike/cli_test.zig` — `test "CLI parses --measure-frame-time=N with default 300"` — integer with default.
- `tests/spike/cli_test.zig` — `test "CLI parses --gpu-prefer=index:5"` — tagged union with sub-form.
- `tests/spike/cli_test.zig` — `test "CLI rejects unknown flags with helpful error"` — error path.
- `tests/bindings/vk_abi_test.zig` — `test "selected Vulkan struct sizes and offsets match translate-c reference"` — for a representative subset (`VkApplicationInfo`, `VkInstanceCreateInfo`, `VkDeviceCreateInfo`, `VkSwapchainCreateInfoKHR`, `VkSubmitInfo`, `VkPresentInfoKHR`, `VkPhysicalDeviceProperties`, `VkPhysicalDeviceFeatures`), the generated Zig struct's `@sizeOf` and field `@offsetOf` match a `translate-c` reference compiled at test time. The reference is used **only inside the test file**, never imported by production code.
- `tests/bindings/wayland_abi_test.zig` — `test "Wayland message dispatch table layouts are stable"` — for `wl_surface`, `xdg_surface`, `xdg_toplevel`, `zxdg_toplevel_decoration_v1`: opcodes and listener function pointer slot ordering match the protocol XML order. Synthetic test, no live Wayland connection.

All tests run on the existing CI matrix (`{ubuntu-24.04, windows-2025} × {Debug, ReleaseSafe}`). No GPU is required for any of them.

### Benchmarks

None. S2 has no formal benchmark file. Frame time is measured in-binary by `--measure-frame-time=N` and recorded in `validation/s2-go-nogo.md`. The performance criterion is verified manually on the three hardware configurations:

- Median frame time strictly below 16.7 ms (60 Hz vsync floor) on each configuration.
- p95 frame time below 17.0 ms on each configuration.
- No frame time above 33 ms after the first 10 frames (post-warmup).

### Comportement observable

- `zig build run` opens an 800×600 (or scaled HiDPI equivalent) window titled `Weld S2`, displays a smoothly shaded triangle (red top, green bottom-left, blue bottom-right or any consistent variant), accepts a close gesture (window X / Cmd-W / xdg close button) and exits cleanly with code 0.
- `zig build run -- --smoke-test` produces a non-empty `zig-out/smoke/<os>-<gpu_name>.ppm` file and exits with code 0 within 5 seconds.
- The PPM file, when opened in any image viewer (Linux: `feh`, GIMP, Eye of GNOME; Windows: IrfanView, GIMP) shows the same triangle. The PPM has the correct dimensions for the host monitor's HiDPI scale.
- `zig build run -- --measure-frame-time=300 --smoke-test` prints three numeric lines with `median=`, `p95=`, `max=` in milliseconds, then writes the PPM and exits.
- Resizing the window with the mouse 100 times consecutively does not crash the process; the swapchain is recreated each time, the triangle stays correctly shaped (no stretching artifacts).
- `zig build run -- --gpu-prefer=integrated` on Fedora + the multi-GPU machine selects the Intel UHD 630, logs the device name, and the smoke-test PPM is produced by Mesa ANV.
- `zig build run -- --gpu-prefer=discrete` on the same machine selects the NVIDIA GTX 1660 Ti.
- `zig build bindgen-vk` regenerates `src/core/platform/vk.zig` from `bindings/upstream/vulkan/vk.xml`. The diff against the committed file is empty modulo header timestamp.
- `zig build bindgen-wayland` does the same for the four committed Wayland binding files.

### CI

- `zig build` clean (zero warnings) on the matrix.
- `zig build test` green in Debug and ReleaseSafe on the matrix.
- `zig fmt --check` green.
- `zig build lint` green when the linter exists (it is post-S1 work; if not yet present at S2 merge time, this criterion is waived per the linter sequencing decision in `engine-development-workflow.md`).
- `commit-msg` hook green on every commit of the branch.
- The smoke-test is **not** run in CI.

## Conventions

- **Branche**: `phase-pre-0/platform/window-vulkan-triangle`
- **Tag final**: `v0.0.3-S2-window-vulkan-triangle`
- **Titre de PR**: `Phase -1 / Platform / Native Window + Vulkan Triangle`
- **Convention de commits**: Conventional Commits (cf. `engine-development-workflow.md` §4.3). Suggested scopes: `bindgen`, `platform`, `spike`, `build`, `ci`, `docs`.
- **Stratégie de merge**: squash-and-merge (cf. `engine-development-workflow.md` §4.6).

## Notes

### Acceptance criterion conditional on the `callconv(.c)` Wayland hypothesis

The S2 attempt is to declare every Wayland event callback as a Zig function with `callconv(.c)` and pass it directly to the Wayland listener registration. This is a design hypothesis that the spike must validate. If this hypothesis fails (callbacks crash, return wrong values, corrupt the Wayland event queue, or trigger ABI errors detected by sanitizers), the documented fallback is to introduce **one and only one** C source file `src/core/platform/window/wayland_callbacks.c`, containing the C trampolines that call into Zig functions. `build.zig` then conditionally compiles this file when an opt-in flag is set. The fallback must be activated through an explicit deviation logged in the brief's acted-deviations section, with the failure symptom captured.

### Wayland boot sequence

The Wayland compositor requires a specific handshake before the first frame is presented: create the `xdg_surface`, wait for the first `xdg_surface.configure` event, send `ack_configure`, *then* create the swapchain at the configured size, attach the first buffer, and send `wl_surface.commit`. Inverting this order results in a window that never becomes visible. Claude Code is expected to discover this through the documented Wayland protocol; this note exists so the failure mode is recognized when it occurs.

### Why Win32 is not `dlopen`-ed

`user32.dll`, `gdi32.dll` and `kernel32.dll` are guaranteed to be present on every Windows installation since Windows 95. There is no scenario where a process starts but those DLLs are missing — the PE loader fails earlier. `dlopen`-ing them adds a third loading branch parallel to Vulkan and Wayland for zero benefit. Static linkage via Zig's MinGW import libs is the standard pattern and matches Mach-Core's approach.

### Why no canonical `.api.zig` format in S2

`engine-c-bindings.md` §1.2 introduces the canonical `ApiDescription` format that an emitter consumes to produce idiomatic Zig from XML adapters and hand-written descriptions for keepers. That system is the long-term plan; it lands in S3 (cf. §10.1). In S2, with only Vulkan and Wayland to emit and no keepers introduced, there is nothing to mutualize: the `ApiDescription` factoring would be premature surface area, not a refactor avoidance. The S2 generators emit Zig directly from XML. The guarantee that S3 regeneration will produce a zero-diff against the committed bindings comes not from the format but from the emitted code's conformance to `engine-c-bindings.md` §4.2 mapping rules.

### PPM rationale

PPM (P6 binary) was chosen explicitly: writing a PPM in Zig is a textual header (`P6 W H 255`) followed by a raw RGB byte blit, around 15 lines, no encoder dependency. PNG would require either `libpng` (which is not in the 8-keepers list and therefore forbidden) or a hand-written PNG encoder (out of scope for a windowing/rendering spike). `stb_image_write` is similarly out of scope. PPM is unambiguous and verifiable byte-by-byte in the validation report.

### Validation Layers

Vulkan validation layers and `VK_EXT_debug_utils` are activated only in Debug builds. The activation is best-effort: if the layer is not present on the host (developer machine without Vulkan SDK installed), the binary logs a one-line warning and continues without validation. ReleaseSafe builds never activate the layer. The smoke-test runs in ReleaseSafe by default for cleaner perf numbers; pass `--debug` (if added) or build manually in Debug to exercise the validation path.

### Phase 0 reusability map

| Surface                                            | S2 status                  | Phase 0 evolution                                                  |
|---|---|---|
| `src/core/platform/window.zig` (interface)         | Tier 0 stable              | Phase 0.3 extends with input events + X11 backend                  |
| `src/core/platform/window/{win32,wayland}.zig`     | Tier 0 stable              | Phase 0.3 extends with input handling                              |
| `src/core/platform/window/wayland_protocols/`      | Tier 0 stable              | Extended as new protocols are integrated                           |
| `src/core/platform/vk.zig` (binding)               | Tier 0 stable, public API  | Phase S3 regenerates via unified emitter — zero diff on call sites |
| `tools/vk_gen/`, `tools/wayland_gen/`              | Throwaway tooling          | Phase S3 absorbs into `tools/bindgen/` unified system              |
| `src/main.zig`, `src/spike/*.zig`                  | Throwaway spike code       | Phase 0.4 refactors into `src/modules/render/` with the GAL        |

### Reference reading order recommendation

Read `engine-spec.md` §22.3 / S2 in full first — the post-conversation precisions are the authoritative scope for this milestone. Then `engine-c-bindings.md` §4.2 to internalize the idiomatic mapping rules that the generators must produce. Then `engine-mach-reference.md` §5 for the design inspiration on the windowing layer (read for ideas, not for code patterns to copy: Mach-Core pulls in a tiny `wayland.c`; Weld attempts pure Zig `callconv(.c)` first, with the same C fallback documented here as a recovery path).

---

# SECTION VIVANTE

*Maintained by Claude Code during the milestone. The journal is not a marketing report — it serves PR review and post-mortem debugging.*

## Specs lues

*To check before any production code is written. Confirms the spec was fully ingested, not skim-grepped.*

- [x] `engine-spec.md` (§22.3 / S2, §1, §3.5, §1.6) — read 2026-05-10 01:29
- [x] `engine-c-bindings.md` (§1.1–§1.4, §4.2, §10.1) — read 2026-05-10 01:29
- [x] `engine-platform.md` (§1, §2 windowing) — read 2026-05-10 01:29
- [x] `engine-mach-reference.md` (§5) — read 2026-05-10 01:29
- [x] `engine-render.md` (§3) — read 2026-05-10 01:29
- [x] `engine-zig-conventions.md` (§1, §14, §17) — read 2026-05-10 01:29
- [x] `engine-development-workflow.md` (§3, §4.3, §4.5, §4.6, §5) — read 2026-05-10 01:29
- [x] `engine-directory-structure.md` — read 2026-05-10 01:29

## Journal d'exécution

*One entry per logical work sequence (typically: a goal reached, a green test, a blocker). Chronological order. Short — 1 to 3 lines per entry.*

- 2026-05-10 01:42 — Vendored upstream XML registries under `bindings/upstream/`. Vulkan: `vk.xml` from Vulkan-Headers tag `vulkan-sdk-1.4.341.0` (commit b5c8f99). Wayland core: `wayland.xml` from wayland tag `1.25.0` (commit 3e673a4). Protocols: `xdg-shell.xml` + `xdg-decoration-unstable-v1.xml` from wayland-protocols tag `1.48` (commit 02e63e7). LICENSE notices written for each vendor (Apache-2.0 OR MIT for Vulkan, MIT for Wayland). All four XML files validate as well-formed.
- 2026-05-10 03:55 — `tools/vk_gen/` first emission. Three files: minimal generic XML parser (`parser.zig`, ~600 lines including the vk.xml model + whitelist closure pass), idiomatic Zig emitter (`emit.zig`, ~700 lines), CLI orchestrator (`main.zig`). Whitelist Vulkan 1.3 core (BASE/GRAPHICS/COMPUTE/aggregate features for 1.0→1.3) + 5 extensions filters the surface to 31 handles, 122 enums, 92 bitmasks, 297 structs, 244 commands, 7 funcpointers. Generated `src/core/platform/vk.zig` (480 KB) compiles clean (`zig test src/core/platform/vk.zig`). Wired `zig build bindgen-vk`. §4.2 manual review on a representative sample (Instance opaque + methods, ApplicationInfo struct, BufferUsageFlags packed struct, Result enum) confirms: opaque handles, camelCase methods inside opaque blocks, Error union on VkResult, packed struct bitmasks with vendor tags stripped, snake_case fields with sType/pNext defaults. Compromises documented but acceptable for S2: out-params not hoisted to return tuples, funcpointer callbacks emitted as `?*const anyopaque` (typed in S3).
- 2026-05-10 04:30 — Round 2 §4.2 review feedback applied to vk_gen. Six blocking fixes, all live in `emit.zig` — re-ran `zig build bindgen-vk`, formatted, `zig test src/core/platform/vk.zig` green:
    1. Wrapper params lose the Vulkan-C `p_` / `pp_` Hungarian prefix (`p_create_info` → `create_info`). Struct fields keep theirs since they document the underlying ABI.
    2. Out-params `T*` hoisted to return value. Dispatchable handle out-param → `Error!*T` for VkResult commands or `*T` for void; struct/non-dispatchable out-param → `Error!T` / `T`. `vkCreateBuffer`, `vkAllocateMemory`, `vkGetDeviceQueue`, `vkCreateWaylandSurfaceKHR` and ~80 others now return their result directly.
    3. Two-pass count/array hoisted to `Error![]T` taking `gpa: std.mem.Allocator`. Body does the two-call pattern, mapping gpa OOM → `error.OutOfHostMemory`. Applies to `vkEnumeratePhysicalDevices`, `vkGetPhysicalDeviceQueueFamilyProperties`, `vkEnumerateInstance{Layer,Extension}Properties`, etc.
    4. Single representation for input arrays: Zig slice everywhere (`buffers: []const Buffer` instead of `count: u32, buffers: [*]const Buffer`). Both sibling-count slices (drops the count param) and composite-len slices (`pAllocateInfo->commandBufferCount`, no count to drop, `.ptr` only in body) handled consistently.
    5. `(~NU)` API constants typed explicitly — `pub const QUEUE_FAMILY_EXTERNAL: u32 = 0xFFFFFFFE` instead of comptime-int `~1` (which would mean -2). Generalized to `(~NU)` / `(~NULL)` / `(~NU-K)` patterns.
    6. Reserved bitmask fields uniformly `_reserved_N` — both synthesized unnamed bits and named `RESERVED_N_BIT_KHR` variants normalized to the underscore-prefixed form.

  Acknowledged debt logged here for post-S2 cleanup, no impact on the spike binary:
    - **D1** — Whitelist closure not applied to enum *values*, only to enum *types*. The 5 extensions' enum extension entries land in the canonical enum groups, so `vk.zig` carries ~7000 enum variant lines beyond what's strictly required. Filter to whitelisted source extensions in S3, expected reduction to ~3500 total lines.
    - **D2** — VkResult aliases (e.g. `VK_ERROR_FRAGMENTATION_EXT` aliasing `VK_ERROR_FRAGMENTATION`) emitted at module scope as `pub const Result_error_fragmentation_ext: Result = .error_fragmentation;` instead of inside the `Result` namespace. S3 emitter places them inside the enum block.
- 2026-05-10 04:55 — `tools/wayland_gen/` first emission. Three files (parser.zig with own minimal XML parser per brief, emit.zig, main.zig) — independent from vk_gen as the brief allows. Output: `core.zig` (37 KB, 1244 lines) for the Wayland core protocol (23 interfaces), `xdg_shell.zig` (10 KB, 351 lines) for xdg-shell (5 interfaces), `xdg_decoration.zig` (2.5 KB, 83 lines) for xdg-decoration (2 interfaces). Each interface emits: opaque proxy type, enums, request+event opcode struct, listener struct with `callconv(.c)` function pointers, WlMessage arrays + WlInterface metadata. Cross-protocol references resolved via `@import` (xdg_decoration imports core + xdg_shell). The WlMessage `types` arrays are emitted as null in S2 — the spike will pass new_id interfaces explicitly to `wl_proxy_marshal_array_flags`. All three files compile clean (`zig test` on each). Wired `zig build bindgen-wayland`. Total wayland_gen source ~700 lines.

## Déviations actées

*Modifications to the FROZEN SECTION that occurred mid-milestone after a Claude.ai round-trip. Each deviation references the commit that enacts it. Empty at end of milestone is the nominal case.*

- <commit SHA> — <summary of deviation and reason>

## Blocages rencontrés

*Blocker points that required a return to Claude.ai (cf. `engine-development-workflow.md` §2.4). 2+ distinct blockers signals re-scoping.*

- <blocker summary> — resolved by <commit SHA> or <Claude.ai conversation reference>

## Notes de fin

*To fill in at Status → CLOSED transition, just before opening the PR.*

- **What worked**:
- **What deviated from the original spec**:
- **What to flag explicitly during review**:
- **Final measurements** (frame time on each of the three target configurations, PPM file sizes, binary size, build time):
- **Residual risks / technical debt left intentionally**:
