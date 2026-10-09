# Etch reference file and hot reload

- Commit: 027b9b59437546ba99c0e82f02ab290aac530540
- Machine: apple_m4, aarch64-macos
- Zig 0.16.0, ReleaseFast
- Protocol: dev run — not opposable

Reference file: `tests/etch/reference_500_lines.etch`, 1132 lines.

| Row | Samples | Median | p99 | Max | Gate | Verdict (max) |
|---|---|---|---|---|---|---|
| parse, reference file | 200 | 0.185 ms | 0.299 ms | 0.325 ms | < 50 ms | GO |
| reload, rule-body edit | 200 | 0.005 ms | 0.009 ms | 0.009 ms | < 500 ms | GO |
| reload, reference file | 50 | 0.260 ms | 0.281 ms | 0.281 ms | < 500 ms | GO |
