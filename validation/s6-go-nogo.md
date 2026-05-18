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
| G3 1 h fuzz, 0 crash / 0 leak / 0 deadlock | ⏳ Linux-only | `zig build test-ipc-fuzz-1h` |
| G4 Runtime kill -9 → detect < 100 ms, restart OK | ⏳ Linux-only | `tests/ipc/crash_recovery.zig` (gated `is_linux`) |
| G5 Editor kill -9 → runtime detect + exit clean | ⏳ Linux-only | Same test file |
| G6 Viewport 1280×720 RGBA mire 60 s, no tearing | ⏳ Linux-only | Manual demo: `zig build run-ipc-demo` |
| G7 fd passing POSIX | ✅ GO | `tests/ipc/fd_passing.zig` green on macOS |

## macOS POSIX shm cross-process `O_RDWR` — Phase 2 debt

**Symptom.** `shm_open(name, O_RDWR | O_CREAT, mode)` from a runtime
process (spawned by `posix_spawnp` or invoked manually from a fresh
shell) returns `EACCES` for an `shm_open(name, O_RDWR | O_CREAT |
O_EXCL, mode)`-created region in another process, **for every mode
tested** (`0o600`, `0o644`, `0o660`, `0o666`), even when both
processes share the same UID. The creator process holds the fd open
through `mmap` and beyond.

**Diagnosis matrix run on 2026-05-18 against macOS 26.4.1 / Zig
0.16.0:**

| Opener flags | Mode (creator) | Result |
|---|---|---|
| `O_RDONLY` | any | ✅ fd ≥ 0 |
| `O_RDONLY \| O_CREAT` | any | ✅ fd ≥ 0 |
| `O_RDWR` | any | ❌ EACCES |
| `O_RDWR \| O_CREAT` | any | ❌ EACCES |

The kernel's BSD shm path locks write access on a region to the
process that successfully `O_RDWR`'d it first. The opener can mmap
read-only, but a `PROT_WRITE` mapping on a read-only fd fails at
`mmap` time.

**Three hypotheses tested first** (Claude.ai 2026-05-18 follow-up):

1. ❌ **Name identity** — `[editor] shm_name='/weld-shm-viewport-N'`
   and `[runtime] args.shm='/weld-shm-viewport-N'` bytes match
   exactly, including the leading `/` and the digit-encoded PID.

2. ❌ **Premature `close(fd)` on the creator side** — audit of
   `src/core/ipc/shm_posix.zig:Backend.create` confirms the fd is
   stored in `Backend.fd` and only released in `Backend.close()`.
   The editor's `var vp = try …create(…); defer vp.close();` keeps
   the fd live for the entire `main` scope.

3. ❌ **`posix_spawn` / Hardened Runtime artifact** — repro with
   `--no-spawn` flag on the editor (added in this commit) + manual
   runtime invocation from a fresh shell still produces `EACCES`
   on the runtime's `shm_open(O_RDWR)`. The bug reproduces without
   `posix_spawnp` in the chain.

**Workaround postponed to Phase 0.6:** `SCM_RIGHTS` fd-passing. The
editor creates the shm, keeps the fd, and ships the fd to the
runtime via the existing AF_UNIX socket using the
`IpcSocket.sendWithHandles` surface that S6 already builds (G7).
The runtime `mmap`s directly on the received fd without ever
calling `shm_open`. This sidesteps the macOS BSD restriction and
yields a cleaner protocol on every platform. The runtime side of
`ShmViewport.open` then takes a `fd` argument instead of a `name`.
Estimated cost: ~half a session, scope-fenced to
`src/core/ipc/shm.zig` + `viewport.zig` + the editor/runtime
attach point.

**Linux is unaffected.** The Linux POSIX shm implementation backs
the namespace with a tmpfs at `/dev/shm/`, ordinary file
permissions apply, and cross-process `O_RDWR` from the owner UID
just works. The Linux CI matrix (`ubuntu-24.04`) will surface G4 /
G5 / G6 verdicts on the upcoming hardware run.

## Inherited debt previously promoted from S6

### macOS POSIX shm intra-process re-open (subsumed)

The earlier diagnosis of an intra-process `shm_open(O_CREAT) →
shm_open(O_RDWR)` cap (one per process lifetime) is a downstream
manifestation of the same write-access restriction. The
`tests/ipc/shm_cases/*` and `tests/ipc/viewport_cases/*` files
gate themselves on `is_linux` for that reason.

## Tests

`zig build test` exit 0. On macOS dev-box, 8 tests skipped via
`is_linux` gates (shm_cases × 2, viewport_cases × 3,
crash_recovery × 2, fuzz_short × 1) — all Linux-CI-bound. The
remaining ~25 syscall tests pass: framing, schema_hash, transport
(reader thread + 64 KB), fd_passing (SCM_RIGHTS), handshake (full
round-trip cross-thread), process (spawn / kill / is_alive),
shm-too-long-name (negative). `bench/results/ipc_rtt.md` populated
by `zig build bench-ipc-rtt`.

## Open follow-ups

- Linux smoke run of `zig build run-ipc-demo` (Fedora 44 + GTX 1660
  Ti or Ubuntu 24.04) — G4, G5, G6.
- Linux 1 h fuzz: `zig build test-ipc-fuzz-1h` — G3.
- Apple Silicon RTT bench: `zig build bench-ipc-rtt
  -Doptimize=ReleaseSafe` — G1, G2.
- Phase 0.6: implement `SCM_RIGHTS` fd-passing for shm viewport.
  Closes the macOS POSIX shm cross-process gap for free and removes
  the `is_linux` gates on `shm_cases/`, `viewport_cases/`, and
  `crash_recovery`.
