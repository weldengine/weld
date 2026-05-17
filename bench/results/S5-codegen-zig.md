# S5 — bench-etch-compile

- Corpus: 100 `.etch` files at `bench/fixtures/synth_100/scripts`
- Iterations per metric: 1 (smoke: true)
- Build mode: ReleaseSafe
- Host: aarch64-macos

## Metric (a) — codegen only (`etch_cook` 100 inputs → 1 cooked.zig)

median 165.135 ms · mean 165.135 ms · stddev 0.000 ms · p99 165.135 ms · max 165.135 ms (N=1)

## Metric (b) — cold `zig build-exe` after `rm -rf zig-out/etch-bench/.zig-cache-bench`

median 474.683 ms · mean 474.683 ms · stddev 0.000 ms · p99 474.683 ms · max 474.683 ms (N=1)

## Metric (c) — incremental `zig build-exe` after one-line edit (cache intact)

median 469.479 ms · mean 469.479 ms · stddev 0.000 ms · p99 469.479 ms · max 469.479 ms (N=1)

## Gates

- (a)+(b) cold: 639.8 ms · gate 30000.0 ms — GO
- (a)+(c) incremental: 634.6 ms · gate 2000.0 ms — GO

