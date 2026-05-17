# S5 — bench-etch-compile

- Corpus: 100 `.etch` files at `bench/fixtures/synth_100/scripts`
- Iterations per metric: 10 (smoke: false)
- Build mode: ReleaseSafe
- Host: aarch64-macos

## Metric (a) — codegen only (`etch_cook` 100 inputs → 1 cooked.zig)

median 17.220 ms · mean 18.442 ms · stddev 4.766 ms · p99 31.810 ms · max 31.810 ms (N=10)

## Metric (b) — cold `zig build-exe` after `rm -rf zig-out/etch-bench/.zig-cache-bench`

median 478.893 ms · mean 478.783 ms · stddev 5.771 ms · p99 488.755 ms · max 488.755 ms (N=10)

## Metric (c) — incremental `zig build-exe` after one-line edit (cache intact)

median 468.899 ms · mean 468.193 ms · stddev 2.781 ms · p99 474.449 ms · max 474.449 ms (N=10)

## Gates

- Gate 1 (cold compilation, (a)+(b) < 30 s): 496.1 ms — GO
- Gate 2 (incremental compilation, (a)+(c) < 2 s): 486.1 ms — GO
- Gate 3 (zero leak): exercised by `zig build test` under `std.testing.allocator`. See test step.
- Gate 4 (monomorphisation contained, ≤ 4 × distinct archetype signatures): 0 distinct Zig comptime generic instantiations.
    The S5 codegen emits non-generic per-rule Zig functions; archetype matching uses runtime `arch.hasComponent` checks rather than comptime monomorphisation, so the cooked corpus produces zero `Archetype(...)` / `Query(...)` instantiations beyond the type definitions themselves. Trivially satisfies the 4× ceiling.
- Gate 5 (differential parity, 20/20 corpus): green via `zig build test-codegen-diff` and the parity test in the same binary set.

