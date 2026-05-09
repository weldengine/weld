# Weld Engine

A game engine written in Zig 0.16.x.

> **Status:** Phase −1 — Mini-ECS spike (S1)
>
> Weld is in its earliest exploratory phase: the spike list of Phase −1 is
> validating the core architectural hypotheses (comptime ECS, work-stealing
> scheduler, Etch language, native Vulkan/Wayland, IPC editor↔runtime). No
> public release yet. The repo is internal until end of Phase 1.
>
> S1 validates the comptime ECS + Chase-Lev work-stealing hypothesis on a
> single `(Transform, Velocity)` archetype with a 4-worker pool. Run the
> bench locally with `zig build bench-ecs -Doptimize=ReleaseSafe`; the
> Markdown report lands at `zig-out/bench/ecs_iteration.md` with a GO/NO-GO
> verdict against the 1.0 ms median gate.

## Prerequisites

- **Zig 0.16.x** (any patch — 0.16.0, 0.16.1, …). Other minor versions are
  rejected at build time.
- **[lefthook](https://lefthook.dev/)** for local git hooks (formatting,
  commit message validation, pre-push tests). Install via Homebrew, winget,
  or your distro package manager.

## Basic commands

```sh
zig build                                       # build the weld executable
zig build run                                   # build and run
zig build test                                  # run all tests
zig build bench-ecs -Doptimize=ReleaseSafe      # S1 ECS iteration bench
zig build bench-ecs -- --smoke                  # short bench run (used by CI)
./scripts/install-hooks.sh                      # install local git hooks (run once after clone)
```

## Project layout

```
briefs/        milestone briefs (committed as first commit of each branch)
src/           engine source
  core/ecs/      Tier 0 ECS — components, chunks, archetypes, queries, world
  core/jobs/     Tier 0 work-stealing scheduler (Chase-Lev deques + 4 workers)
  core/testing/  testing helpers (counting allocator wrapper)
bench/         performance benchmarks (`zig build bench-ecs`)
tests/         out-of-tree tests wired into `zig build test`
scripts/       POSIX shell helpers (commit-msg validation, hook setup)
.github/       CI workflows
.vscode/       project-level VSCode minimum (extensions + settings)
```

## License

MIT — see [LICENSE](LICENSE).
