# S5 — bench-etch-compile

- Corpus: 100 `.etch` files at `bench/fixtures/synth_100/scripts`
- Iterations per metric: 10 (smoke: false)
- Build mode: ReleaseSafe
- Host: aarch64-macos

## Metric (a) — codegen only (`etch_cook` 100 inputs → 1 cooked.zig)

median 17.264 ms · mean 29.524 ms · stddev 37.518 ms · p99 141.959 ms · max 141.959 ms (N=10)

## Metric (b) — cold `zig build-exe` after `rm -rf zig-out/etch-bench/.zig-cache-bench`

median 1087.206 ms · mean 1086.010 ms · stddev 62.803 ms · p99 1198.120 ms · max 1198.120 ms (N=10)

## Metric (c) — incremental `zig build-exe` after one-line edit (cache intact)

median 1048.951 ms · mean 1058.578 ms · stddev 29.631 ms · p99 1132.060 ms · max 1132.060 ms (N=10)

## Gates

- Gate 1 (cold compilation, (a)+(b) < 30 s): 1104.5 ms — GO
- Gate 2 (incremental compilation, (a)+(c) < 2 s): 1066.2 ms — GO
- Gate 3 (zero leak): exercised by `zig build test` under `std.testing.allocator`. See test step.
- Gate 4 (monomorphisation contained, ≤ 4 × distinct archetype signatures): 382 distinct Zig comptime query instantiations over 400 rules / 382 signatures (ceiling 4× = 1528) — GO
    The S5 codegen emits one `comptime_query.query(world, .{T1, T2, ...})` invocation per rule with an AND-only when clause. Zig comptime monomorphises one iterator type per distinct tuple, so the instantiation count equals the number of distinct rule signatures in the cooked corpus. The 4× ceiling holds by construction (one instantiation per signature ≤ 4 × signatures).
- Gate 5 (differential parity, 20/20 corpus): green via `zig build test-codegen-diff` and the parity test in the same binary set.

