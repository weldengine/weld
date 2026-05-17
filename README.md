# Weld Engine

A game engine written in Zig 0.16.x.

> **Status:** Phase −1 — Etch Zig codegen + compile-time measurement (S5)
>
> Weld is in its earliest exploratory phase: the spike list of Phase −1 is
> validating the core architectural hypotheses (comptime ECS, work-stealing
> scheduler, Etch language, native Vulkan/Wayland, IPC editor↔runtime). No
> public release yet. The repo is internal until end of Phase 1.
>
> **S1** (closed, tag `v0.0.2-S1-mini-ecs`) validated the comptime ECS +
> Chase-Lev work-stealing hypothesis on a single `(Transform, Velocity)`
> archetype with a 4-worker pool — 54.5 µs median per 100 k entities
> iterated on the M4 Pro reference (gate: ≤ 1 ms). Run the bench locally
> with `zig build bench-ecs -Doptimize=ReleaseSafe`.
>
> **S2** (closed, tag `v0.0.3-S2-window-vulkan-triangle`) validated the
> "100 % Zig windowing + Vulkan triangle" hypothesis on three
> target machines: Win11 + RTX 4080 Super, Fedora 44 + Intel UHD 630 (Mesa
> ANV), Fedora 44 + GTX 1660 Ti (NVIDIA proprietary). Native Win32 +
> Wayland windowing (no SDL/GLFW, no `@cImport`), custom XML → Zig binding
> generators emitting ~34 000 lines of idiomatic Zig from the vendored
> upstream registries, Vulkan 1.3 triangle render path. Full report:
> [`validation/s2-go-nogo.md`](validation/s2-go-nogo.md).
>
> **S3** (closed, tag `v0.0.4-S3-etch-parser-subset`) validated the Etch
> grammar (EBNF v0.6, S3 subset: `component`,
> `resource`, `rule`, `when`, basic arithmetic expressions) — lexer +
> recursive-descent + Pratt parser + tabular SoA `AstArena` + minimal
> two-pass type-checker. Worst median 0.019 ms / file across 30 corpus
> files on dev Apple Silicon ReleaseSafe (gate: < 5 ms). Run the bench
> locally with `zig build bench-etch -Doptimize=ReleaseSafe`.
>
> **S4** (closed, tag `v0.0.5-S4-etch-tree-walking-interpreter`) validated
> the tree-walking interpreter hypothesis — the AST emitted by S3 is
> correctly executable, and a runtime bridge exists between the
> interpreter and the dynamic ECS surface (runtime component registry,
> dynamic SoA archetype, resource store, runtime query). On the dev
> primary (Apple Silicon, ReleaseSafe) the bench reports a median per
> tick of **0.603 ms** at 1 000 entities × 5 rules and **6.593 ms** at
> 10 000 entities × 5 rules — well under the 10 ms / 100 ms gates
> respectively. Run the bench locally with
> `zig build bench-etch-interp -Doptimize=ReleaseSafe` and the demo with
> `zig build run-demo-etch-interp -Doptimize=ReleaseSafe`.
>
> **S5** (closed, tag `v0.0.6-S5-etch-codegen-zig` pending merge) validated
> the shipping codegen hypothesis — `Etch → Zig source → Zig compile` is
> viable build-time-wise. The codegen lives in `src/etch/zig_codegen/`
> and lowers the S3 subset to idiomatic Zig: components become `extern
> struct`s, rules open `comptime_query.query(world, .{T1, T2})`
> iterations (via `src/core/ecs/comptime_query.zig`), and the registry
> aliases each component by both Etch name and `@typeName(T)` so the
> spawn-by-name and query-by-type paths share one `ComponentId`. The
> 20-program differential corpus passes through both the interpreter
> and the cooked code with byte-exact parity (`zig build
> test-codegen-diff`). On the dev primary the compile-time bench
> reports cold (a)+(b) at **1104 ms** and incremental (a)+(c) at
> **1066 ms** — 27× and 1.9× under the 30 s / 2 s gates respectively;
> Gate 4 measures **382 distinct comptime query instantiations** on the
> 100-file synth corpus (ceiling 4× = 1528). Run the bench locally with
> `zig build bench-etch-compile -Doptimize=ReleaseSafe` and the demo
> with `zig build run-demo-etch-codegen`. Full report:
> [`validation/s5-go-nogo.md`](validation/s5-go-nogo.md).

## Prerequisites

- **Zig 0.16.x** (any patch — 0.16.0, 0.16.1, …). Other minor versions are
  rejected at build time.
- **[lefthook](https://lefthook.dev/)** for local git hooks (formatting,
  commit message validation, pre-push tests). Install via Homebrew, winget,
  or your distro package manager.

## Basic commands

```sh
zig build                                                # build the weld executable
zig build run                                            # build and run (S2 spike — open window + render triangle)
zig build test                                           # run all tests (S0/S1/S2/S3: spike + ABI + ECS + jobs + Etch corpus)
zig build bench-ecs -Doptimize=ReleaseSafe               # S1 ECS iteration bench
zig build bench-etch -Doptimize=ReleaseSafe              # S3 Etch parser bench (report under bench/results/)
zig build bench-etch-interp -Doptimize=ReleaseSafe       # S4 Etch interpreter bench (report under bench/results/)
zig build run-demo-etch-interp -Doptimize=ReleaseSafe    # S4 demo (1000 entities × 5 rules × 60 ticks)
zig build bench-etch-compile -Doptimize=ReleaseSafe      # S5 codegen compile-time bench (3 metrics, report under bench/results/)
zig build run-demo-etch-codegen                          # S5 codegen demo (cooks demo_5_rules_codegen.etch, 10 ticks)
zig build test-codegen-diff                              # S5 differential corpus via the cooked runner
zig build synth-100 -- --output bench/fixtures/synth_100/scripts --count 100   # regenerate the synthetic bench corpus
zig build bench-ecs -- --smoke                           # short bench run (used by CI)
zig build bench-etch -- --smoke                          # short Etch bench run (sanity)
zig build bench-etch-interp -- --smoke                   # short S4 bench run (sanity)
zig build bench-etch-compile -- --smoke                  # short S5 compile-time bench (sanity)
./scripts/install-hooks.sh                               # install local git hooks (run once after clone)
```

### S2 spike (Native Window + Vulkan triangle)

```sh
zig build run -Doptimize=ReleaseSafe -- --verbose        # interactive: window + triangle + event logging
zig build run -- --smoke-test                            # render 10 frames, capture PPM to zig-out/smoke/, exit
zig build run -- --measure-frame-time=300 --smoke-test   # capture + report median/p95/max over 300 post-warmup frames
zig build run -- --gpu-prefer=discrete                   # force discrete GPU on multi-GPU hosts
zig build run -- --gpu-prefer=integrated                 # force integrated GPU on multi-GPU hosts
zig build run -- --gpu-prefer=index:N                    # pin to physical device #N
zig build bindgen-vk                                     # regenerate src/core/platform/vk.zig from vk.xml
zig build bindgen-wayland                                # regenerate wayland_protocols/*.zig from XMLs
./scripts/compile-shaders.sh                             # recompile assets/shaders/*.glsl to *.spv (needs glslc)
```

Smoke-test exit codes: `0` success, `1` timeout (5 s wall-clock) or capture
error, `130` SIGINT / `CTRL_C_EVENT`.

## Project layout

```
briefs/                            milestone briefs (committed as first commit of each branch)
bindings/upstream/                 vendored XML registries (vk.xml, wayland.xml, xdg-shell.xml, …) + LICENSEs
src/
  main.zig                         S2 spike entry point (throwaway with src/spike/)
  core/
    ecs/                           Tier 0 ECS — components, chunks, archetypes, queries, world
    jobs/                          Tier 0 work-stealing scheduler (Chase-Lev deques + 4 workers)
    testing/                       testing helpers (counting allocator wrapper)
    platform/                      generated Vulkan binding + native Win32 / Wayland windowing
      vk.zig                       ~31 000 lines — generated from vk.xml by tools/vk_gen
      window.zig                   public Window interface (create/destroy/pollEvent/nativeHandles)
      window/{win32,wayland,stub}.zig  per-OS backends (no SDL/GLFW, no @cImport)
      window/wayland_protocols/    ~3 000 lines — generated from wayland XMLs by tools/wayland_gen
  etch/                            S3 Etch parser, S4 interpreter, S5 Zig codegen
    zig_codegen/                   S5 codegen — lower, emit, type_map, cache, errors, tests
    parser.zig, types.zig, ast.zig (S3) / interp.zig, value.zig, ecs_bridge.zig (S4)
  spike/                           throwaway S2 spike code (CLI parser, scoring, vk_setup, vk_frame, ppm)
tests/etch/                        S3 parser corpus driver + ~30 valid + ~10 invalid `.etch` fixtures
tests/etch_interp/                 S4 + S5 differential corpus — 20 `.etch` programs + sidecars + interp/codegen runners
tools/
  vk_gen/                          XML → Zig generator for Vulkan bindings
  wayland_gen/                     XML → Zig generator for Wayland protocol bindings
  etch_cook/                       S5 codegen CLI (Etch → consolidated Zig)
  etch_synth/                      S5 synthetic Etch corpus generator (deterministic)
assets/shaders/                    GLSL sources + pre-compiled SPIR-V (triangle.vert, triangle.frag)
bench/                             performance benchmarks (see "Basic commands" above)
tests/                             out-of-tree tests wired into `zig build test`
validation/                        hardware validation reports + PPM/PNG artefacts (step (j) per milestone)
scripts/                           POSIX shell helpers (commit-msg validation, hook setup, shader compile)
.github/                           CI workflows
.vscode/                           project-level VSCode minimum (extensions + settings)
```

## License

MIT — see [LICENSE](LICENSE).
