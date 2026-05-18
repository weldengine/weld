# S6 IPC RTT bench — Echo 64 B round-trip

| metric | value |
|---|---|
| N | 10000 (after 100 warmup) |
| p50 | 0.006 ms |
| p99 | 0.016 ms |
| max | 0.061 ms |
| stddev | 0.003 ms |
| mean | 0.007 ms |

## Gates

- G1 p50 < 1 ms — GO
- G2 p99 < 5 ms, max < 50 ms — GO
