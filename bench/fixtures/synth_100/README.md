# Synthetic 100-file Etch corpus

Deterministic synthetic corpus used by the S5 compile-time bench
(`zig build bench-etch-compile`). Generated procedurally by
`tools/etch_synth` from a fixed seed so re-running the generator yields
byte-identical files.

## Layout

| Path | Purpose |
|---|---|
| `scripts/000.etch … 099.etch` | 100 generated programs, committed for bench reproducibility. Each has 5–10 `component`s, 1 `resource`, and 3–5 `rule`s exercising arithmetic, `when` clauses with single- and multi-component filters, and the resource gate. |
| `build.zig`, `build.zig.zon` | Standalone sub-project: path dependency on the parent engine, cooks the corpus through the parent's `etch_cook` artifact, compiles it against `weld_core` (M0.8 E3-D, D-S5-synth100-proper). Verified by the repo-root `zig build verify-synth-100` step. The S5 bench keeps its own direct `zig build-exe` measurement path. |
| `README.md` | This file. |

## Regenerating the corpus

```
zig build synth-100 -- --output bench/fixtures/synth_100/scripts --count 100
```

The seed is hard-coded in `tools/etch_synth/main.zig`. Same seed → same
files, byte-for-byte, on every platform.

## Running the bench

```
zig build bench-etch-compile        # full N=10 sweep (median + stddev)
zig build bench-etch-compile -- --smoke  # one-shot sanity (CI)
```

The bench reports three wall-clock metrics — (a) codegen only,
(b) cold `zig build` after `rm -rf .zig-cache`, (c) incremental
`zig build` after a deterministic one-line edit. Output is written to
`bench/results/S5-codegen-zig.md`.
