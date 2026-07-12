# Weld Engine

A game engine written in Zig 0.16.x.

> **Status:** Phase 1 (Playability) — in progress.
>
> - **Phase −1** (7 validation spikes S0–S6) closed 2026-05-18.
> - **Phase 0** (Foundations, M0.0–M0.9) closed 2026-06-15, tag
>   `v0.9.0-phase-0-complete` — Tier 0 (ECS, jobs, RTTI, resources,
>   events, plugin-loader skeleton, IPC, platform), Vulkan forward
>   renderer + GAL, offline asset pipeline, Etch toolchain
>   (full-grammar parser + tree-walking interpreter + Zig codegen
>   prototype), vertical slice.
> - **Phase 1 / M1.0** (Etch ↔ ECS, core-language execution) closed
>   2026-07-12, tag `v0.10.18-extension-additive-warning` — the C1.6
>   Etch core-language closure. Next: the Tier 1 module cores (Forge,
>   Kinesis, Cortex, Pulse, Render delta), Asset Pipeline v1, and the
>   Phase 1 demo game.
>
> The repo is internal until the end of Phase 1. The living state
> (current milestone, full tag table, open decisions) is in
> [`CLAUDE.md`](CLAUDE.md); per-milestone history is under
> [`briefs/`](briefs/) and hardware validation reports under
> [`validation/`](validation/).

## Prerequisites

- **Zig 0.16.x** (any patch — 0.16.0, 0.16.1, …). Other minor versions are
  rejected at build time.
- **[lefthook](https://lefthook.dev/)** for local git hooks (formatting,
  commit message validation, pre-push tests). Install via Homebrew, winget,
  or your distro package manager.

## Basic commands

```sh
# build & run
zig build                                                # build everything (default install step)
zig build run-editor-stub                                # editor binary — opens a window, spawns the runtime
zig build run-runtime-stub                               # runtime binary alone (needs --socket=… --shm=… argv)
zig build run-ipc-demo                                   # full editor↔runtime demo (window + Vulkan blit, ~60 s)
zig build run-demo-etch-interp                           # Etch tree-walking interpreter demo (1000 entities × 5 rules)
zig build run-demo-etch-codegen                          # Etch → Zig codegen demo (cooks a scene, runs 10 ticks)

# test
zig build test                                           # run the whole test suite (pre-push gate)
zig build test-etch                                      # Etch test-runner acceptance corpus (test "…" blocks)
zig build test-ipc                                       # IPC tests only (fast subset of `zig build test`)
zig build test-codegen-diff                              # interp↔codegen differential corpus, byte-exact parity

# lint
zig build lint                                           # weld_lint (no @cImport / no usingnamespace / doc comments)
zig build lint-commit -- <file>                          # Conventional Commits validation (drives the commit-msg hook)

# bench (ReleaseSafe)
zig build bench-ecs -Doptimize=ReleaseSafe               # Tier 0 ECS iteration bench
zig build bench-etch-interp -Doptimize=ReleaseSafe       # Etch interpreter per-tick bench
zig build bench-etch-compile -Doptimize=ReleaseSafe      # Etch → Zig compile-time bench

# assets & tooling
zig build scene-cook -- --output <out.scene.bin> <in.scene.etch>   # cook a .scene.etch into a .scene.bin
zig build cook-demo                                      # cook the asset fixtures end-to-end (import → cook → cache)
zig build shaders                                        # regenerate assets/shaders/*.spv from *.glsl (needs glslc)
zig build bindgen                                        # regenerate the Vulkan + Wayland Zig bindings
./scripts/install-hooks.sh                               # install the local git hooks (run once after clone)
```

## Project layout

```
src/
  foundation/       cross-cutting substrate (consumed by every tier) — root.zig + simd/ SIMD kernels
  core/             Tier 0 engine internals (the weld_core module)
    ecs/            components, chunks, archetypes, queries, world
    jobs/           work-stealing scheduler (Chase-Lev deques + worker pool)
    memory/         persistent refcounted heap (strings / values / collections)
    rtti/           runtime type information
    resources/      global resource store
    events/         event bus + structural observers
    plugin_loader/  dynamic plugin loading
    ipc/            editor↔runtime transport, framing, shm, viewport
    scene/          .scene.bin / .prefab.bin codec (writer, accessor, loader)
    platform/       generated Vulkan binding + native Win32 / Wayland windowing + process control
    testing/        test helpers (counting allocator wrapper)
  etch/             Etch toolchain — lexer, parser, resolver, type-checker, interpreter
    zig_codegen/    Etch → Zig lowering (lower, emit, type_map, cache)
    (parser.zig, interp.zig, ast.zig, value.zig, ecs_bridge.zig, scene_cook.zig, test_runner.zig, …)
  modules/          Tier 1 modules
    render/         Vulkan forward renderer + GAL
    audio/          audio module
    asset_pipeline/ offline asset pipeline (formats, codecs, cooking cache)
  editor/           editor binary — Window + Vulkan blit pipeline + IPC server (main.zig, vk_blit.zig)
  runtime/          runtime binary — IPC client + CPU mire to shm viewport (main.zig)
  demo_etch_interp.zig, demo_etch_codegen.zig    Etch demo entry points (run-demo-etch-*)
tools/              in-tree CLIs and generators
  weld_lint/        custom linter (zig build lint)
  bindgen/          XML → Zig binding generator (Vulkan + Wayland)
  etch_cook/        Etch → consolidated Zig CLI
  etch_synth/       deterministic synthetic Etch corpus generator
  etch_test/        Etch test-runner shim (zig build test-etch)
  scene_cook/       .scene.etch → .scene.bin CLI
  asset_cook/       asset cooking CLI
  shader_compiler/  GLSL → SPIR-V helper
tests/              out-of-tree tests wired into `zig build test` (ecs, etch, ipc, scene, render, …)
bench/              performance benchmarks (see "Basic commands" above)
briefs/             per-milestone briefs (committed as the first commit of each branch)
validation/         hardware validation reports + PPM/PNG artefacts
examples/           standalone example sub-projects (triangle, vertical_slice)
bindings/           vendored upstream XML registries + generated Zig bindings
assets/             engine assets (shaders/ — GLSL sources + pre-compiled SPIR-V)
scripts/            POSIX shell helpers (commit-msg validation, hook setup, shader compile)
.github/            CI workflows
```

## License

MIT — see [LICENSE](LICENSE).
