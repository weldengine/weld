# Shader hot reload

- Commit: b96cd3c22a783452f6f72e8be485e3aef6d721bf
- Machine: apple_m4, aarch64-macos
- Zig 0.16.0, ReleaseFast
- Protocol: dev run — not opposable

Watcher poll interval: 50 ms (default). 30 reloads, one warm-up compile.

| Median | p99 | Max | Gate | Verdict (max) |
|---|---|---|---|---|
| 119.311 ms | 186.412 ms | 186.412 ms | < 200 ms | GO |
