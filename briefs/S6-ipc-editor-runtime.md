# S6 — IPC editor↔runtime round-trip

> **Status:** PLANNED
> **Phase:** -1
> **Branche:** `phase-pre-0/ipc/editor-runtime-round-trip`
> **Tag prévu:** `v0.0.7-S6-ipc-round-trip`
> **Dépendances:** S2 (merged, tag `v0.0.3-S2-window-vulkan-triangle`), S0
> **Date d'ouverture:** 2026-05-17
> **Date de fermeture:** —

---

# SECTION FIGÉE

*Produced by Claude.ai. Not modifiable by Claude Code outside a Claude.ai round-trip (cf. § Déviations actées).*

## Contexte

S6 is the seventh and final spike of Phase -1. It validates the IPC editor↔runtime protocol specified in `engine-ipc.md` on a real two-process workload: an editor stub that spawns a runtime stub, exchanges typed framed messages over a Unix-domain socket / Win32 named pipe, shares a viewport framebuffer via POSIX shm / `CreateFileMapping`, and recovers from a `kill -9` of the runtime by detecting EOF, restarting, and re-handshaking. The hypothesis under test is that the wire protocol, the shared-memory layout, the handshake versioning, and the OS-handle passing primitives (`SCM_RIGHTS` on POSIX) all hold together as designed (cf. `engine-spec.md` §25.3 / S6). This is the last structural risk of Phase -1 — if IPC fails its gates, the two-process editor architecture is revised before Phase 0.

## Scope

- **`src/core/ipc/` module** — Tier 0 endpoint, in-tree per `engine-directory-structure.md` §9.1. Internal split: `mod.zig` (public exports), `protocol.zig` (constants, `IpcConnection`), `messages.zig` (`extern struct` definitions + comptime `schema_hash`), `framing.zig` (16-byte header read/write + validation), `transport.zig` (`IpcSocket` interface + `OsHandle` alias), `transport_posix.zig` (`AF_UNIX SOCK_STREAM` + `SCM_RIGHTS`), `transport_windows.zig` (named pipes byte mode, `sendWithHandles` returns `error.Unimplemented`), `shm.zig` (`ShmRegion` interface), `shm_posix.zig` (`shm_open` + `mmap`), `shm_windows.zig` (`CreateFileMapping` + `MapViewOfFile`), `viewport.zig` (`ShmViewport` double-buffer header + slot atomics), `server.zig` (`IpcServer`, editor side), `client.zig` (`IpcClient`, runtime side).
- **`IpcSocket` public API** conforming to `engine-ipc.md` §2.3: `listen(path)`, `connect(path)`, `accept()`, `send(bytes)`, `recv(buffer)`, `close()`. Plus `sendWithHandles(bytes, []const OsHandle)` and `recvWithHandles(buffer, []OsHandle)`: POSIX implementation via `sendmsg`/`recvmsg` + `cmsghdr` with `SCM_RIGHTS`; Windows returns `error.Unimplemented` with a documented `// Phase 3 — see engine-ipc.md §4.7` comment.
- **`OsHandle` type alias** in `transport.zig`: `std.posix.fd_t` on Linux and macOS, `std.os.windows.HANDLE` on Windows. Used by `sendWithHandles` / `recvWithHandles`.
- **`ShmRegion` public API**: `create(name, size)` (editor side), `open(name)` (runtime side), `close()`. Single region in S6: `viewport_framebuffer`.
- **`IpcConnection`** — combines `IpcSocket` + framing + handshake + heartbeat into a single client/server-symmetric type consumed by both stubs.
- **Framing** — 16-byte fixed header per `engine-ipc.md` §3.1: `magic: u32 = 0x57454C44 ("WELD")`, `version: u16 = WELD_IPC_PROTOCOL_VERSION (=1)`, `msg_type: u16`, `seq_id: u32`, `payload_len: u32 (max 16 MB)`. Payload = `extern struct` written/read byte-for-byte preceded by `schema_hash: u64`. Receiver-side validation: invalid magic / wrong protocol version / unknown msg_type / oversized payload / truncated payload → connection reset (fatal).
- **`schema_hash` comptime** — computed at compile time per message type via `std.hash.Wyhash` over `@typeName(T)` concatenated with each field's name and declared type. Stable across builds. Mismatch on receive → fatal (mirrors RTTI Weld behavior to come in Phase 0.2).
- **Endianness invariant** — `comptime` check at module load that `builtin.cpu.arch.endian() == .little`. All Phase -1/0/1/2 targets satisfy this; cross-endian support is explicitly out of scope.
- **Message catalogue** — exactly 11 message types in S6, defined as `extern struct` in `messages.zig`:

| Type | Direction | Pattern | Purpose |
|---|---|---|---|
| `ProtocolHello` | R→E | handshake | runtime announces protocol version, engine version, build hash, capabilities |
| `ProtocolHelloAck` | E→R | handshake | editor accepts or rejects |
| `Echo` | E→R | transactional | 64 B random payload, RTT measurement |
| `EchoReply` | R→E | ack | echoes the seq_id and the payload back |
| `SpawnEntity` | E→R | transactional | requests an entity creation (stub: increments a counter) |
| `EntityCreated` | R→E | ack | confirms with a synthetic `entity: u64` |
| `ModifyComponent` | E→R | transactional | non-trivial payload exercise |
| `ModifyAck` | R→E | ack | confirms with `seq_id` and a `success: bool` |
| `Heartbeat` | E→R | periodic | 1 s interval |
| `HeartbeatAck` | R→E | periodic | echo + reception timestamp |
| `Shutdown` | E→R | graceful close | requests termination |
| `ShutdownAck` | R→E | graceful close | confirms before exit |
| `LogMessage` | R→E | unidirectional event | validates the event direction without ack |

Total = 12 messages (the table sums 13 because `LogMessage` was added below the count). The fire-and-forget event direction is covered by `LogMessage`. `Echo` is transactional but cheap: the runtime stub replies immediately, no state change.
- **`ProtocolHello.capabilities: u32`** — bitflags, bit 0 = `GPU_SHARED_FB`. Published to 0 by the runtime stub in S6 (no GPU shared support). Reserved-for-future bits are zero. Posted now to stabilize the `schema_hash` of `ProtocolHello` against Phase 3 introduction (cf. `engine-spec.md` §25.3 / S6 and `engine-ipc.md` §4.7).
- **Two binaries** at canonical locations per `engine-directory-structure.md` §9.1:
  - `src/editor/main.zig` — editor stub. Owns the listen socket and the shm region. Spawns the runtime via `platform.process.spawn_process` passing the socket path, the shm region name, and the editor PID in argv. Opens a window (reuses S2 `Window` + Vulkan setup), runs a fullscreen-quad blit pipeline that samples the viewport texture each frame and presents it. Drains the IPC inbox on its main thread.
  - `src/runtime/main.zig` — runtime stub. Connects to the socket, attaches the shm region, sends `ProtocolHello`, awaits `ProtocolHelloAck`. Renders a CPU-side moving color mire (gradient with frame-counter modulation) at 60 Hz into the viewport shm using the double-buffer atomics. Drains the IPC inbox on a dedicated reader thread that pushes into an MPSC queue consumed by the main loop.
- **Editor lifecycle** strictly per `engine-ipc.md` §5.1:
  1. Editor creates the shm region with a name including its PID (e.g. `/weld-shm-viewport-<pid>` POSIX, `Local\weld-shm-viewport-<pid>` Windows session-local).
  2. Editor opens the socket in listen mode at a path including its PID (e.g. `/tmp/weld-<pid>.sock` POSIX, `\\.\pipe\weld-<pid>` Windows).
  3. Editor spawns the runtime via `platform.process.spawn_process` passing the socket path, the shm name, and the editor PID in argv.
  4. Runtime connects, attaches shm, sends `ProtocolHello`.
  5. Editor replies `ProtocolHelloAck { accepted: true }` (or `{ accepted: false, reason: <string> }` on version mismatch).
  6. Both processes are ready. Editor starts heartbeat (1 s period). Runtime starts writing viewport frames.
- **Orphan cleanup at editor startup** — editor scans `/tmp/weld-<pid>.sock` and `/weld-shm-*-<pid>` (POSIX) or `\\.\pipe\weld-*` and `Local\weld-*` (Windows) for orphan resources, queries `platform.process.is_alive(pid)`, removes them if the owning PID is dead. Conforms to `engine-ipc.md` §2.4.
- **Crash recovery** — partial scope per the arbitrated descope (cf. § Notes):
  - **Runtime `kill -9`**: editor detects via socket EOF in < 100 ms plus a non-blocking `platform.process.wait` poll. Logs the death, spawns a new runtime via `spawn_process`, awaits the new `ProtocolHello`, sends `ProtocolHelloAck`, then sends an `Echo` that must round-trip OK. One restart attempt only — if the second runtime also dies, editor exits with a fatal log.
  - **Editor `kill -9`**: runtime detects socket EOF in < 100 ms, performs `ShmRegion.close()` on its side, exits cleanly (exit code 0). No reconnection attempt, no inverse heartbeat (cf. `engine-ipc.md` §6.3).
- **Viewport shm — double buffering** (S6 simplification of `engine-ipc.md` §4.2):
  - Resolution: **1280×720 RGBA8 unorm** (vs 1920×1080 Phase 0.6).
  - Slots: **2** (vs 3 Phase 0.6).
  - Header (128 B, cache-line aligned): `magic`, `version`, `width`, `height`, `format`, `slot_count = 2`, atomics `writer_slot`, `reader_slot`, `last_complete`.
  - Synchronization: writer (runtime) commits frames by atomically updating `last_complete`. Reader (editor) reads `last_complete`, copies the slot's pixels into a Vulkan staging buffer, transfers to a texture, samples in the blit shader.
  - Pixel format negotiated at handshake: `RGBA8_UNORM` only in S6.
- **Vulkan blit pipeline editor side**: fullscreen triangle (vertex shader generates positions algorithmically, no VBO) + fragment shader sampling the viewport texture. SPIR-V pre-compiled and committed under `assets/shaders/viewport_blit.{vert,frag}.spv` (sources next to them). Pattern identical to S2 SPIR-V handling.
- **Heartbeat** — editor starts after `ProtocolHelloAck` sent. Period 1 s, timeout 3 s, per `engine-ipc.md` §6.1. Flag `--no-heartbeat` on the editor binary disables the timer (debug aid, not shipping).
- **RTT benchmark** — `bench/ipc_rtt.zig` runs N=10 000 `Echo` round-trips (64 B payload) after 100 warmup iterations on the dev-primary machine, ReleaseSafe. Reports p50 / p99 / max / stddev. Auto-generates `bench/results/ipc_rtt.md`.
- **1h fuzz harness** — `tests/ipc/fuzz_1h.zig`. Two-axis fuzz: (a) corrupt framing (bad magic, bad version, unknown msg_type, oversized payload_len, truncated tail) — receiver must reset the connection cleanly; (b) high traffic at ~10 000 valid msg/s sustained for 1 h (~36 M messages). Run manually for the verdict; verdict archived in `validation/s6-go-nogo.md`. Not in CI in Phase -1.
- **Short fuzz** — `tests/ipc/fuzz_short.zig` runs 60 s in `zig build test`, same harness scaled down, validates the framework end-to-end before the 1 h run.
- **Crash recovery test** — `tests/ipc/crash_recovery.zig` covers both directions (runtime killed, editor killed). Uses real `spawn_process` + `kill`/`TerminateProcess` (POSIX `SIGKILL`, Windows `TerminateProcess`).
- **fd passing test** — `tests/ipc/fd_passing.zig` (POSIX only, skipped on Windows): the editor opens a `memfd_create` (Linux) or `/dev/null` (macOS), transmits the fd via `sendWithHandles`, the runtime writes a known byte sequence into it, the editor reads it back and asserts.
- **Build steps** — new targets in `build.zig`:
  - `zig build run-editor-stub` — runs the editor stub alone (will spawn the runtime).
  - `zig build run-runtime-stub` — runs the runtime stub alone (for manual testing with a pre-existing socket; not the normal lifecycle).
  - `zig build run-ipc-demo` — entry point that runs the full demo: editor spawns runtime, handshake, exchange a few messages, viewport mire visible for 5 seconds, graceful shutdown.
  - `zig build bench-ipc-rtt` — runs the RTT benchmark, writes the Markdown report.
  - `zig build test-ipc` — runs `tests/ipc/*.zig` (excluding `fuzz_1h.zig`).
  - `zig build test-ipc-fuzz-1h` — runs the 1 h fuzz harness (manual invocation).
- **Validation verdict** — `validation/s6-go-nogo.md` per the S2/S5 pattern. One row per gate (G1..G7) with GO / NO-GO and measured value. Includes the host platform, Zig version, RTT histogram digest, 1h fuzz log digest, and the crash-recovery test traces.

## Out-of-scope

- **Best-effort replay of pending commands** after `kill -9` (cf. `engine-tools-editor.md` §2.7.3, `engine-ipc.md` §7). Depends on `CommandLog` + `SaveProject` acks, which do not exist in Phase -1. Postponed to Phase 0.6. S6 validates the harder part (detection + restart + re-handshake) — the replay of pending commands is the easier follow-up.
- **Triple buffering** for the viewport (S6 = 2 slots). Phase 0.6.
- **1920×1080 viewport** (S6 = 1280×720). Phase 0.6.
- **Other shm regions** — `debug_overlays`, `profiler_samples`, `selection_snapshot`, `log_stream` (cf. `engine-ipc.md` §4). Phase 0.6.
- **IPC Debugger panel** in the editor (`engine-ipc.md` §9.3). Phase 0.6.
- **Session record / replay `.weld-session`** (`engine-ipc.md` §9.2). Phase 0.6.
- **Auto-restart multi-attempt with backoff** — S6 retries once, then exits. Phase 0.6.
- **`MsgKind` plugin range 4096..65535** (`engine-tools-editor.md` §2.6.9). Phase 1.
- **Subscription / topic filtering** (`engine-tools-editor.md` §2.6.4). Phase 2.
- **Native crash dumps** — `MiniDumpWriteDump` (Windows), `systemd-coredump` (Linux), `.ips` (macOS). Phase 0.6.
- **macOS backend** for both the IPC and the window/Vulkan parts. Phase 2 (cf. S2 decision).
- **Job system S1 integration** — the IPC reader thread does **not** use the work-stealing scheduler. A dedicated OS thread is the right primitive; coupling to S1 would be gratuitous.
- **Windows `sendWithHandles` / `recvWithHandles` implementation** via `DuplicateHandle`. Phase 3 (cf. `engine-ipc.md` §4.7).
- **GPU shared framebuffer** per `engine-ipc.md` §4.7 — `VK_KHR_external_memory`, `ViewportConfig` / `ViewportTexturesShared`, exportable Vulkan semaphores. Phase 3.
- **GAL renderer abstraction** — S6 uses raw Vulkan exactly like S2 (cf. `engine-spec.md` §25.3 / S2 Précisions de design — pas de GAL avant Phase 0.4).
- **Inverse heartbeat** runtime→editor (cf. `engine-ipc.md` §6.3).
- **CRDT op format coupling** — the wire `IpcMessage` is deliberately decoupled from `CrdtOp` in S6 (the format freeze is Phase 1 per `engine-collaboration.md`).
- **Cross-endian support** — `comptime` panic if `builtin.cpu.arch.endian() != .little`.
- **Bidirectional fuzz** — only editor→runtime traffic is fuzzed in S6. Runtime→editor event fuzzing (LogMessage spam, malformed acks) is Phase 0.6.

## Documents de spec à lire en premier

1. `engine-spec.md` — §25.3 / S6 (canonical definition), §25.3 / S2 (Précisions de design — pattern for raw Vulkan + window reuse), §1.3 (process separation), §3.5 (in-tree Phase 1-4)
2. `engine-ipc.md` — full document (§1 architecture, §2 transport, §3 messages and serialization, §4 shared memory including §4.7 GPU shared framebuffer Phase 3, §5 handshake and versioning, §6 heartbeat, §7 command-log replay, §8 security, §9 testing, §10 phasing)
3. `engine-tools-editor.md` — §2.2 threading model, §2.5 state management overview, §2.6 IPC dispatcher (especially §2.6.8 Phase 1 topics, §2.6.9 plugin MsgKind range), §2.7 crash recovery (especially §2.7.3 CommandLog and §2.7.4 best-effort replay — out of scope but read for context)
4. `engine-platform.md` — Process (spawn / wait / read_stdout), Memory (mmap, virtual_alloc), Threading (Mutex, atomics), FileSystem
5. `engine-zig-conventions.md` — §3 modules and naming, §4 allocators and ownership, §11 threading and `std.Io.Mutex` / `Uncancelable` variants, §13 tests in-file pattern, §17 Zig version policy
6. `engine-development-workflow.md` — §2 milestone model, §3 brief format, §4 git conventions (branches, tags, commits, hooks, squash-and-merge), §5 review cycle
7. `engine-directory-structure.md` — confirm `src/core/ipc/`, `src/editor/`, `src/runtime/` layouts and tests / bench / validation paths
8. `engine-phase-0-criteria.md` — C0.4 (IPC editor↔runtime stable) for the Phase 0.6 endpoint
9. `engine-collaboration.md` — introduction and §3.5 (CRDT op format freeze Phase 1, used as command-log payload — read to confirm S6 does not preempt any decision)
10. `briefs/S1-mini-ecs-zig.md` — calibration: the job system exists but is not used by S6
11. `briefs/S2-window-vulkan-triangle.md` — pattern for window creation, Vulkan setup, fullscreen rendering, SPIR-V handling (S6 reuses all of it)
12. `briefs/S5-etch-codegen-zig.md` — most recent calibration of brief detail and journal style

## Fichiers à créer ou modifier

- `src/core/ipc/mod.zig` — création — public exports of the IPC module
- `src/core/ipc/protocol.zig` — création — constants (`MAGIC`, `WELD_IPC_PROTOCOL_VERSION = 1`), endianness `comptime` check, `IpcConnection` combining transport + framing + handshake + heartbeat
- `src/core/ipc/messages.zig` — création — `extern struct` definitions for all 12 message types, `MsgType` enum, comptime `schema_hash` helper, `ProtocolHelloCapability` bitflags including `GPU_SHARED_FB`
- `src/core/ipc/framing.zig` — création — 16-byte header read/write, validation (magic, version, msg_type known, payload_len bounds), connection-reset semantics on invalid frame
- `src/core/ipc/transport.zig` — création — `IpcSocket` interface, `OsHandle` alias, dispatcher to `transport_posix.zig` / `transport_windows.zig` via `@import(builtin)`
- `src/core/ipc/transport_posix.zig` — création — `AF_UNIX SOCK_STREAM` socket, listen/accept/connect/send/recv/close, `sendWithHandles` / `recvWithHandles` via `sendmsg`/`recvmsg` + `cmsghdr` + `SCM_RIGHTS`, EOF detection
- `src/core/ipc/transport_windows.zig` — création — named-pipe byte-mode socket, listen via `CreateNamedPipeW` + `ConnectNamedPipe`, connect via `CreateFileW`, `sendWithHandles` / `recvWithHandles` return `error.Unimplemented`, EOF detection via `ReadFile` returning 0 / `ERROR_BROKEN_PIPE`
- `src/core/ipc/shm.zig` — création — `ShmRegion` interface, dispatcher to `shm_posix.zig` / `shm_windows.zig`
- `src/core/ipc/shm_posix.zig` — création — `shm_open` + `ftruncate` + `mmap` (create), `shm_open` + `mmap` (open), `munmap` + `close` + `shm_unlink` (close on owner side), PID-based naming
- `src/core/ipc/shm_windows.zig` — création — `CreateFileMapping` with `INVALID_HANDLE_VALUE` + `MapViewOfFile` (create), `OpenFileMapping` + `MapViewOfFile` (open), `UnmapViewOfFile` + `CloseHandle` (close), session-local naming (`Local\weld-shm-*-<pid>`)
- `src/core/ipc/viewport.zig` — création — `ShmViewport` helper: 128 B header, 2 slots of 1280×720×4 = 3.5 MB each, atomic slot writer/reader/last-complete operations conforming to `engine-ipc.md` §4.2 (simplified for 2 slots)
- `src/core/ipc/server.zig` — création — `IpcServer` (editor side): owns the listen socket, accepts one client, exposes `send_message` / `recv_message` / `send_message_with_handles`, manages heartbeat timer
- `src/core/ipc/client.zig` — création — `IpcClient` (runtime side): connects, exposes `send_message` / `recv_message` / `send_message_with_handles`, replies to heartbeats automatically
- `src/editor/main.zig` — création — editor stub: parses argv (`--no-heartbeat` flag), cleanup of orphan IPC resources, creates shm region, listens, spawns runtime via `platform.process.spawn_process`, opens window (reuses S2 `Window`), creates Vulkan blit pipeline, main loop drains IPC + reads viewport shm + blits + presents, handles crash recovery (one restart)
- `src/runtime/main.zig` — création — runtime stub: parses argv (socket path, shm name, editor PID), connects to socket, attaches shm, sends `ProtocolHello`, awaits `ProtocolHelloAck`, dedicated IPC reader thread, main loop writes mire to viewport shm at ~60 Hz, handles editor EOF (exits clean)
- `src/main.zig` — édition — the existing S2 demo entry point is preserved; this file is only touched to add a `--demo s2` vs `--demo s6` dispatch if needed, or unchanged if `run-ipc-demo` invokes the dedicated binaries directly (Claude Code chooses the simpler path)
- `src/core/platform/process.zig` — édition — implements the minimum surface needed: `spawn_process(path, argv) !Process`, `wait_nonblock(proc) !?i32`, `kill(proc) !void` (POSIX `SIGKILL` / Windows `TerminateProcess`), `is_alive(pid) bool`. Existing `engine-platform.md` API kept; this fills the implementation gap on the editor side
- `assets/shaders/viewport_blit.vert` — création — fullscreen triangle generated algorithmically
- `assets/shaders/viewport_blit.frag` — création — samples the viewport texture
- `assets/shaders/viewport_blit.vert.spv` — création — pre-compiled SPIR-V committed (pattern S2)
- `assets/shaders/viewport_blit.frag.spv` — création — pre-compiled SPIR-V committed
- `bench/ipc_rtt.zig` — création — N=10 000 Echo round-trips, 100 warmup, p50/p99/max/stddev, writes `bench/results/ipc_rtt.md`
- `bench/results/ipc_rtt.md` — création — auto-generated benchmark report
- `tests/ipc/framing.zig` — création — round-trip a framed message; reject invalid magic; reject mismatched protocol version; reject unknown msg_type; reject oversized payload (> 16 MB); reject truncated payload
- `tests/ipc/handshake.zig` — création — full handshake completes; version mismatch is rejected with `ProtocolHelloAck { accepted: false }`; `capabilities` round-trips correctly with the `GPU_SHARED_FB` bit observed at 0
- `tests/ipc/schema_hash.zig` — création — comptime `schema_hash` is stable across builds for a given struct; modifying a field changes the hash
- `tests/ipc/shm_viewport.zig` — création — writer + reader on a shared region using the double-buffer atomics; over 1000 frames, no tearing (reader always reads a complete slot); no stale frame older than 100 ms
- `tests/ipc/fd_passing.zig` — création — Linux + macOS only (Windows test is `skipNow`): editor opens a `memfd_create` (Linux) or `/dev/null` (macOS), transmits via `sendWithHandles`, runtime writes a known sequence, editor reads back and asserts
- `tests/ipc/crash_recovery.zig` — création — runtime `kill -9` → editor detects in < 100 ms, restart succeeds, first post-restart Echo round-trips OK; editor `kill -9` → runtime detects in < 100 ms and exits clean; no orphan shm or socket file remains after the run
- `tests/ipc/fuzz_short.zig` — création — 60 s framing + traffic fuzz, exit 0 with zero crash / zero leak / zero deadlock
- `tests/ipc/fuzz_1h.zig` — création — 1 h harness (manual invocation only; not in `zig build test`)
- `validation/s6-go-nogo.md` — création — per-gate verdict (G1..G7), measurements, host platform, Zig version, raw 1h fuzz log digest
- `build.zig` — édition — register the new build steps (`run-editor-stub`, `run-runtime-stub`, `run-ipc-demo`, `bench-ipc-rtt`, `test-ipc`, `test-ipc-fuzz-1h`), compile both binaries (`weld_editor`, `weld_runtime`), embed the SPIR-V files
- `README.md` — édition — Phase -1 roadmap status (S6 in progress / merged), current tag, new build steps listed under "Build and run", brief link added to "Milestones"
- `CLAUDE.md` — édition — at milestone close (cf. `engine-development-workflow.md` §3.4): État courant table updated, Tags table adds the row, Hypothèses validées par les spikes updates the S6 row, Décisions ouvertes / reportées adjusted

## Critères d'acceptation

### Tests

All tests must pass in `Debug` and `ReleaseSafe`.

- `tests/ipc/framing.zig` — `test "round-trips a framed message"` — header + payload write and read back identically
- `tests/ipc/framing.zig` — `test "rejects invalid magic"` — receiver returns `error.InvalidMagic`
- `tests/ipc/framing.zig` — `test "rejects mismatched protocol version"` — receiver returns `error.ProtocolVersionMismatch`
- `tests/ipc/framing.zig` — `test "rejects unknown msg_type"` — receiver returns `error.UnknownMsgType`
- `tests/ipc/framing.zig` — `test "rejects oversized payload"` — header with `payload_len > 16 MB` → `error.PayloadTooLarge`
- `tests/ipc/framing.zig` — `test "rejects truncated payload"` — connection EOF mid-payload → `error.UnexpectedEof`
- `tests/ipc/handshake.zig` — `test "full handshake completes within 100 ms"` — measured locally
- `tests/ipc/handshake.zig` — `test "version mismatch produces explicit rejection"` — editor sends `ProtocolHelloAck { accepted: false, reason: "..." }`, runtime logs and exits
- `tests/ipc/handshake.zig` — `test "GPU_SHARED_FB capability is 0 in S6"` — runtime publishes 0, editor observes 0
- `tests/ipc/schema_hash.zig` — `test "schema_hash is comptime-stable"` — two compilations of the same struct produce the same hash (asserted against a baked-in constant)
- `tests/ipc/schema_hash.zig` — `test "modifying a field changes schema_hash"` — uses an alternate struct in the test file
- `tests/ipc/shm_viewport.zig` — `test "writer and reader on double-buffered viewport produce no tearing over 1000 frames"` — counting allocator wrapper from S1 ensures no leak; reader records a per-frame slot index and checksum, asserts no torn read
- `tests/ipc/shm_viewport.zig` — `test "reader never observes a stale frame older than 100 ms"` — clock-based, writer at 60 Hz, reader records frame ages
- `tests/ipc/fd_passing.zig` — `test "transmits an opened fd via sendWithHandles, receiver can write into it"` — POSIX only, skipped on Windows
- `tests/ipc/crash_recovery.zig` — `test "runtime kill -9 → editor detects in <100 ms"` — measured with monotonic clock
- `tests/ipc/crash_recovery.zig` — `test "runtime kill -9 → editor restarts + re-handshakes + first Echo round-trips OK"`
- `tests/ipc/crash_recovery.zig` — `test "editor kill -9 → runtime detects in <100 ms and exits clean"` — exit code 0, no shm orphan
- `tests/ipc/fuzz_short.zig` — `test "60 s fuzz of framing + traffic produces 0 crash, 0 leak, 0 deadlock"` — counting allocator, deadlock = `recv()` timeout 5 s per call

### Benchmarks

Target machine: dev-primary Apple Silicon ReleaseSafe (consistent with S1, S3, S4, S5). Re-confirmation on Windows 11 and Fedora 44 is deferred to Phase 0.2 (inherited debt from S3 / S4 / S5).

- `bench/ipc_rtt.zig` — Echo 64 B round-trip, N=10 000 after 100 warmup. Reports p50, p99, max, stddev. Auto-writes `bench/results/ipc_rtt.md`.
  - **G1 target:** p50 < 1 ms
  - **G2 target:** p99 < 5 ms, max < 50 ms (tolerated 1× per 10 000 iterations)

### Gates

| Gate | Validation method | Target |
|---|---|---|
| **G1 RTT median** | `bench/ipc_rtt.zig` median over 10 000 | < 1 ms |
| **G2 RTT queue** | same bench p99 and max | p99 < 5 ms, max < 50 ms |
| **G3 1 h fuzz** | `tests/ipc/fuzz_1h.zig` manual run, log archived in `validation/s6-go-nogo.md` | 0 crash, 0 leak (counting allocator), 0 deadlock (5 s `recv()` timeout) over 1 h |
| **G4 Runtime kill -9** | `tests/ipc/crash_recovery.zig` and manual demo | detection < 100 ms, restart + re-handshake + first Echo OK < 500 ms |
| **G5 Editor kill -9** | `tests/ipc/crash_recovery.zig` and manual demo | runtime detects EOF < 100 ms, exits clean (code 0), 0 shm / socket orphan after test |
| **G6 Viewport shm** | manual demo `zig build run-ipc-demo` running for 60 s | runtime writes 1280×720 RGBA mire at 60 Hz double-buffer, editor displays via Vulkan blit, no visible tearing, no stale frame > 100 ms |
| **G7 fd passing POSIX** | `tests/ipc/fd_passing.zig` on Linux and macOS | test green on POSIX, `skipNow` on Windows (not a failure) |

### Comportement observable

- `zig build run-ipc-demo` launches the editor stub, which spawns the runtime stub. Handshake completes. Editor sends one `SpawnEntity`, receives `EntityCreated`. Viewport window opens (1280×720) and displays the moving mire generated by the runtime for 5 seconds. Editor sends `Shutdown`, receives `ShutdownAck`, both exit cleanly.
- `zig build bench-ipc-rtt` produces `bench/results/ipc_rtt.md` with the latency histogram.
- `zig build test-ipc` runs all tests under `tests/ipc/` except the 1 h fuzz; vert in CI.
- `zig build test-ipc-fuzz-1h` (manual) runs the 1 h fuzz harness; result appended to `validation/s6-go-nogo.md`.
- A live demonstration of `kill -9` on the runtime (with the editor still running and rendering) shows the editor logging the death, restarting the runtime, and the viewport resuming within ~500 ms.

### CI

- `zig build` propre, zéro warning, sur la matrix `{ubuntu-24.04, windows-2025} × {Debug, ReleaseSafe}`
- `zig build test` vert (incluant `test-ipc` mais hors `test-ipc-fuzz-1h`)
- `zig build test-ipc` vert
- `zig fmt --check` vert
- `commit-msg` hook vert sur tous les commits de la branche
- `pre-push` hook vert localement

## Conventions

- **Branche** : `phase-pre-0/ipc/editor-runtime-round-trip`
- **Tag final** : `v0.0.7-S6-ipc-round-trip`
- **Titre de PR** : `Phase -1 / IPC / IPC editor↔runtime round-trip`
- **Convention de commits** : Conventional Commits (cf. `engine-development-workflow.md` §4.3). Scopes attendus : `ipc`, `editor`, `runtime`, `platform`, `build`, `bench`, `tests`, `docs`
- **Stratégie de merge** : squash-and-merge (cf. `engine-development-workflow.md` §4.6)

## Notes

### Replay best-effort — descope acté

The wording in `engine-spec.md` §25.3 / S6 reads "Replay best-effort fonctionnel après `kill -9` du runtime". In S6 this criterion is interpreted narrowly as **detection + restart + re-handshake + first post-restart command round-trips OK**. The replay of pending commands via a `CommandLog` and `SaveProject` ack mechanism (cf. `engine-tools-editor.md` §2.7.3 and `engine-ipc.md` §7) is **out of scope** for S6 and postponed to Phase 0.6. Rationale: the `CommandLog` depends on `SaveProject` acks which depend on a real save pipeline, none of which exist in Phase -1. Synthesizing a mini-CommandLog for S6 would be throwaway code. The hard part of the criterion — detecting the crash, killing orphan resources, spawning a new runtime, re-establishing the handshake, validating the connection is alive — is fully tested in G4 and `tests/ipc/crash_recovery.zig`. A "Précisions de design" subsection is appended to `engine-spec.md` §25.3 / S6 in the same session to record this descope (pattern S2).

### Two binaries at canonical locations

`src/editor/main.zig` and `src/runtime/main.zig` are placed at their final Phase 0+ locations per `engine-directory-structure.md` §9.1, not in `src/spike/`. S6 produces code that survives. These are "stubs" in the sense that the logic inside is minimal, but the invocation pattern (editor spawns runtime, two distinct binaries) is the shipping pattern.

### No GAL, raw Vulkan

The fullscreen blit pipeline uses raw Vulkan exactly like S2 — no GAL abstraction. The GAL is designed in Phase 0.4 when a second backend is on the horizon (cf. `engine-spec.md` §25.3 / S2 Précisions de design).

### Endianness invariant

A `comptime` check at `protocol.zig` load asserts `builtin.cpu.arch.endian() == .little`. All current Phase -1/0/1/2 targets are little-endian (x86_64, aarch64). Cross-endian support is explicitly out of scope; if a big-endian target ever enters the roadmap, byte swapping is added then.

### `schema_hash` is a proxy for the future RTTI Weld

The Phase 0.2 RTTI Weld will replace the comptime `Wyhash` with a stable RTTI-derived hash. Call sites do not change — only the helper inside `messages.zig` is swapped. The current hash is sufficient for S6 to validate the version-drift detection mechanism.

### `ProtocolHello.capabilities` bit posted at 0

The `GPU_SHARED_FB` bit must be present in the `ProtocolHello` struct at S6 even though the runtime stub publishes it at 0. This stabilizes the `schema_hash` of `ProtocolHello` against the Phase 3 introduction of GPU shared framebuffer (`engine-ipc.md` §4.7) — adding the bit later would change the hash and break older builds. The bit's semantic value (0 = unsupported, 1 = supported) is reserved for Phase 3.

### Heartbeat debug flag

The editor binary accepts `--no-heartbeat` to disable the heartbeat timer. Useful when the runtime is suspended under a debugger and the timeout would fire spuriously. Not a shipping feature; not documented in the user-facing README.

### Orphan cleanup on startup

At editor startup, scan POSIX socket paths matching `/tmp/weld-*.sock` and shm names `/weld-shm-*-<pid>`, plus on Windows pipe names matching `\\.\pipe\weld-*` and shm names `Local\weld-shm-*-<pid>`. For each, parse the PID, query `platform.process.is_alive(pid)`, remove the resource if the PID is dead. Critical: without this, developers running the demo repeatedly accumulate orphan shm regions.

### Dettes héritées (à NE PAS toucher en S6)

Mentionned explicitly so Claude Code does not attempt incidental fixes during S6:

- **S2 (5)**: `vk_gen` whitelist closure (D1), `VkResult` aliases module scope (D2), Win32 thread safety globals, §4.2 dispatch bypass in `vk_frame.zig`, PPM capture path swapchain direct.
- **S3 (10)**: see `briefs/S3-etch-parser-subset.md` § Notes de fin.
- **S4 (9)**: see `briefs/S4-etch-tree-walking-interpreter.md` § Notes de fin.
- **S5**: re-confirmation Win11 + Fedora 44 benchmarks (Phase 0.2), 2 Windows-only skipped tests, archetype-walk fallback for `or`/`not` rules (path 2 in `lower.zig`), any other debt logged in `briefs/S5-etch-codegen-zig.md` § Notes de fin.

These debts are out of scope. Do not touch them in S6.

### Alternatives examinées et écartées

- **Sockets-only S6, no shm** — rejected. The spec §25.3 / S6 explicitly lists the viewport shm + display reusing S2. Removing shm would not validate the architecture deployed in Phase 0.6, and the viewport is a primary risk: the entire reason for the two-process editor is to display runtime output in the editor without coupling GPU threads. The marginal cost for S6 is one `shm.zig`, one `viewport.zig`, and a fullscreen-quad blit pipeline (~500-700 lines Zig).
- **TCP localhost transport** — rejected. The shipping target is Unix domain sockets + Win32 named pipes; a TCP proxy would validate TCP, not the target. The wrapper API is the same shape (`IpcSocket`), so the cost of implementing the right backend now is the same as later.
- **Single binary with `--editor` / `--runtime` modes** — rejected. The `kill -9` semantics require distinct processes anyway. Two binaries are also the canonical layout per `engine-directory-structure.md` §9.1.
- **Job system for IPC reader** — rejected. The S1 work-stealing scheduler is built for parallelizable ECS queries, not for a single blocking `recv()`. A dedicated OS thread is correct here.
- **Mini-CommandLog for S6** — rejected. See § Replay best-effort — descope acté above.

---

# SECTION VIVANTE

*Maintained by Claude Code during the milestone. The journal is for review and post-mortem, not marketing.*

## Specs lues

*To be checked before any production code is written. Confirms full ingestion, not skim.*

- [x] `engine-spec.md` (§25.3 / S6, §25.3 / S2, §1.3, §3.5) — lu 2026-05-17 22:03
- [x] `engine-ipc.md` (full document) — lu 2026-05-17 22:03
- [x] `engine-tools-editor.md` (§2.2, §2.5, §2.6, §2.7) — lu 2026-05-17 22:03
- [x] `engine-platform.md` (Process, Memory, Threading, FileSystem) — lu 2026-05-17 22:03
- [x] `engine-zig-conventions.md` (§3, §4, §11, §13, §17) — lu 2026-05-17 22:03
- [x] `engine-development-workflow.md` (§2, §3, §4, §5) — lu 2026-05-17 22:03
- [x] `engine-directory-structure.md` — lu 2026-05-17 22:03
- [x] `engine-phase-0-criteria.md` (C0.4) — lu 2026-05-17 22:03
- [x] `engine-collaboration.md` (intro, §3.5) — lu 2026-05-17 22:03
- [x] `briefs/S1-mini-ecs-zig.md` — lu 2026-05-17 22:03 (fichier réel dans le repo : `briefs/S1-mini-ecs.md`)
- [x] `briefs/S2-window-vulkan-triangle.md` — lu 2026-05-17 22:03
- [x] `briefs/S5-etch-codegen-zig.md` — lu 2026-05-17 22:03

## Journal d'exécution

*One entry per logical work sequence (objective reached, test green, refactor, blocker). Chronological. 1-3 lines per entry.*

- YYYY-MM-DD HH:MM — <summary>

## Déviations actées

*Modifications of the FROZEN SECTION agreed via Claude.ai round-trip. Each deviation references the commit that records it. Empty at milestone close = nominal case.*

- <commit SHA> — <summary and reason>

## Blocages rencontrés

*Blocking points that required a Claude.ai round-trip (cf. `engine-development-workflow.md` §2.4). 2+ distinct blockers = re-scope signal.*

- <blocker summary> — resolved by <commit SHA> or <reference to the Claude.ai conversation>

## Notes de fin

*To be filled when Status transitions to CLOSED, just before opening the PR.*

- **What worked:**
- **What deviated from the original spec:**
- **What to flag explicitly in review:**
- **Final measurements** (RTT p50/p99/max from `bench/results/ipc_rtt.md`, 1 h fuzz outcome, crash-recovery timings, viewport tearing tally, fd-passing test status):
- **Residual risks / technical debt left intentionally:**

## Pre-PR diff check

*Mandatory step before opening the PR. Compares `git diff main..HEAD --name-only` against the § Fichiers à créer ou modifier list.*

- [ ] Run `git diff main..HEAD --name-only` and paste the output here
- [ ] For every file in § Fichiers à créer ou modifier: confirm it appears in the diff (or justify its absence as a deviation)
- [ ] For every file in the diff: confirm it appears in § Fichiers à créer ou modifier (or justify it under § Déviations actées)
- [ ] No discrepancy → proceed to PR
- [ ] Discrepancy → either fix the diff or record the deviation, then re-check
