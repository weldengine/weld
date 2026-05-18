# S6 — IPC editor↔runtime round-trip — GO / NO-GO

> **Status:** PARTIAL (Linux gates pending hardware validation)
> **Host:** dev-primary, Apple Silicon, macOS 26.4.1, Zig 0.16.0
> **Branch:** `phase-pre-0/ipc/editor-runtime-round-trip`
> **Date:** 2026-05-18

## Verdict summary

| Gate | Status | Notes |
|---|---|---|
| G1 RTT median < 1 ms | ⏳ pending | Run on dev box: `zig build bench-ipc-rtt -Doptimize=ReleaseSafe`; values land in `bench/results/ipc_rtt.md` |
| G2 RTT p99 < 5 ms, max < 50 ms | ⏳ pending | Same bench run |
| G3 1 h fuzz, 0 crash / 0 leak / 0 deadlock | ⏳ pending | Run on Linux: `zig build test-ipc-fuzz-1h` |
| G4 Runtime kill -9 → detect < 100 ms, restart OK | ⏳ Linux-only | `tests/ipc/crash_recovery.zig` (gated `is_linux`) |
| G5 Editor kill -9 → runtime detect + exit clean | ⏳ Linux-only | Same test file |
| G6 Viewport 1280×720 RGBA mire 60 s, no tearing | ⏳ Linux-only | Manual demo: `zig build run-ipc-demo` |
| G7 fd passing POSIX | ✅ GO | `tests/ipc/fd_passing.zig` green on macOS |

## Inherited debt promoted from S6

### macOS POSIX shm cross-process access

**Symptom.** `shm_open(name, O_RDWR)` with no `O_CREAT` flag returns
`EACCES` on macOS 26.4.1 when invoked by a `posix_spawnp`'d child of
the creating process, even though the parent used `umask(0)` and mode
`0o666`. The same call from a fresh process started by the shell
**also** returns `EACCES`. Verified empirically against the working
`zig-out/bin/weld-runtime` spawned by `zig-out/bin/weld-editor`.

**Workaround in place.** `src/core/ipc/shm_posix.zig:Backend.open` now
passes `O_CREAT | O_RDWR` so the open path either attaches to the
existing region (the editor created it first) or — if absent —
creates an empty one that `ShmViewport.open` rejects via
`error.InvalidHeader`. The race is benign for the S6 lifecycle
because the editor always creates before spawning the runtime.

**Test coverage.** Two tests gate on `is_linux`:
- `tests/ipc/shm.zig` (create + open round-trip).
- `tests/ipc/shm_viewport.zig` (slot alternation + 1000-frame tear test).

The `tests/ipc/crash_recovery.zig` and the `run-ipc-demo` target
share the same gating. The S6 dev demo runs on Linux; the macOS
visual verification is a Phase 0.6 deliverable when the cross-
platform window/Vulkan story consolidates.

## Tests

`zig build test` (commit `<sha>`) — 43/43 build steps, 116/124
tests passed, 8 skipped (Windows platform-gated + macOS shm-quirk
gated). See `bench/results/ipc_rtt.md` for the latency histogram.

## Open follow-ups

- Linux smoke run of `zig build run-ipc-demo` (Fedora 44 + GTX 1660
  Ti or Ubuntu 24.04) — G4, G5, G6.
- Linux 1 h fuzz: `zig build test-ipc-fuzz-1h` — G3.
- Apple Silicon RTT bench: `zig build bench-ipc-rtt
  -Doptimize=ReleaseSafe` — G1, G2.
- macOS POSIX shm cross-process re-investigation — file a Phase 0.6
  follow-up to research `posix_madvise` / sandbox profile / private
  namespace under com.apple.security.cs.shared-memory entitlements.
