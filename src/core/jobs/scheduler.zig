//! FROZEN — see engine-phase-0-criteria.md C0.5 (M0.9)
//!
//! M0.1 / E5a work-stealing scheduler.
//!
//! Dynamic worker pool — `worker_count = std.Thread.getCpuCount() catch 4`
//! at `Scheduler.init` — and dynamic chunk-pointer buffer sized
//! `worker_count * Deque.capacity` so the dispatch never overflows a
//! single worker's local deque. Replaces the S1 fixed `[4]Worker` +
//! `[1024]chunks` layout and absorbs debts D-S1-3 (sleep/wake) and
//! D-S1-4 (`MaxChunksPerDispatch` dynamic).
//!
//! Wake-up. Workers used to busy-yield on `pending_count`; now they
//! park on a `std.Io.Condition` ("work_available") when they cannot
//! find work locally and no new generation has been published yet.
//! The main thread broadcasts on `work_available` after every
//! dispatch and waits on a second condition ("work_completed") until
//! every chunk has been processed.
//!
//! Ownership invariant from S1 preserved. Chase-Lev assumes a single
//! owner per deque; the dispatch still has each worker push its own
//! strided share `worker_idx, worker_idx + N, …` into its own deque.
//! The lock-free hot path inside the worker loop is untouched — only
//! the idle path enters the mutex.
//!
//! Trampoline. `dispatch` keeps the S1 shape (the comptime body
//! type-checks against `query.chunkAt(0)`'s return type) but the
//! `ctx_storage` lifetime extends until the dispatch returns. The
//! tuple of args can hold pointers, slices, or other non-trivially-
//! copyable references — the workers consume them via the trampoline's
//! `ctx.*` deref while the dispatcher's stack frame is alive (D-S1-5).
//!
//! Zero-allocation steady state. After `init` allocates the workers
//! slice, the chunks slice, and the workers' stack-resident deques,
//! every subsequent `dispatch` runs without touching the allocator.
//! The dedicated test `tests/ecs/no_alloc_scheduler_dispatch.zig`
//! validates this for one full dispatch cycle (D-S1-6).

const std = @import("std");
const archetype_mod = @import("../ecs/archetype.zig");
const worker_mod = @import("worker.zig");

const Job = worker_mod.Job;
const TrampolineFn = worker_mod.TrampolineFn;
const Worker = worker_mod.Worker;
const WorkerStats = worker_mod.WorkerStats;

/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.9)
/// Version of the frozen Job-system Tier-0 public surface (Scheduler
/// methods, SchedulerError, Job/TrampolineFn/Deque shapes). Bumped on
/// any breaking change — a tracked migration, not a freeze failure (the
/// `*_PROTOCOL_VERSION` rule, generalized from `WELD_IPC_PROTOCOL_VERSION`).
pub const WELD_JOBS_PROTOCOL_VERSION: u32 = 1;

/// Fallback worker count used when `std.Thread.getCpuCount` returns
/// an error (no /proc/cpuinfo, Wasm sandbox, etc.). Matches the S1
/// hardcoded count so existing benches behave consistently in
/// degraded environments.
pub const default_worker_count: usize = 4;

/// Per-worker deque capacity inherited from S1. Drives the dynamic
/// upper bound on `MaxChunksPerDispatch` — each worker can carry at
/// most this many chunks in its local deque before the dispatch
/// fails with `error.TooManyChunks`.
pub const per_worker_capacity: usize = worker_mod.DequeCapacity;

/// Errors surfaced by the fallible `Scheduler` methods: `init` /
/// `initWithWorkerCount` and `start` (thread-spawn failures),
/// `dispatch` / `dispatchBatch` (`TooManyChunks` on chunk-count
/// overflow), and `snapshotStats` (`OutOfMemory`). The set is the
/// union of `std.Thread.SpawnError` and `TooManyChunks`.
pub const SchedulerError = error{
    OutOfMemory,
    TooManyChunks,
    ThreadQuotaExceeded,
    SystemResources,
    LockedMemoryLimitExceeded,
    Unexpected,
};

/// M0.2.1 / E5 — packed snapshot of (generation, chunk_count) loaded
/// atomically by workers. Two helpers and a wrapper struct guarantee
/// that a worker observing a given generation sees the matching
/// chunk_count by construction (single 64-bit atomic load) — fixes
/// the wave-lifecycle race confirmed by E2ter dumps (R1 in § Notes).
pub const GenAndN = struct { gen: u32, n: u32 };

inline fn pack(gen: u32, n: u32) u64 {
    return (@as(u64, gen) << 32) | @as(u64, n);
}

inline fn unpack(packed_value: u64) GenAndN {
    return .{
        .gen = @intCast(packed_value >> 32),
        .n = @truncate(packed_value),
    };
}

/// M0.2.1 / E5 — cache line size assumed on the targets we run
/// (Apple Silicon ARM64, x86_64). Used for the comptime layout
/// assertions on `Scheduler` below.
const cache_line: usize = 64;

/// Top-level work-stealing scheduler. Owns its dynamic worker pool,
/// the chunk-pointer buffer, and the synchronisation primitives that
/// drive sleep / wake / barrier.
pub const Scheduler = struct {
    /// Shared `io` instance — needed by workers for `Clock.now` so
    /// they can record their per-job duration, and by the mutex /
    /// condition primitives.
    io: std.Io,
    /// Heap-allocated worker pool, sized at `init` from
    /// `std.Thread.getCpuCount() catch default_worker_count`.
    workers: []Worker,
    /// Heap-allocated job buffer for the in-flight dispatch. Sized
    /// `workers.len * per_worker_capacity` so the per-worker stride
    /// never overflows the local deque. M0.1 / E5b each job carries
    /// its own `(trampoline, ctx_ptr)` inline so a single dispatch
    /// can run heterogeneous bodies (multi-job concurrent intra-
    /// phase via `dispatchBatch`).
    jobs: []Job,

    /// M0.2.1 / E5 — single atomic snapshot of `(generation: u32,
    /// chunk_count: u32)`. Replaces the pre-M0.2.1 split `chunk_count:
    /// u32` + `generation: std.atomic.Value(u64)`. The split version
    /// allowed a wave-lifecycle race where a worker observing the
    /// older generation could read the newer chunk_count after a
    /// preemption between the two field accesses, causing a double
    /// `pushShare` and an over-decrement on `pending_count` (R1
    /// confirmed by E2ter dumps — cf. brief § Notes "E3 residual
    /// hypotheses"). Packed atomic guarantees `(gen, n)` is
    /// observed as a single snapshot by construction. `gen` is u32
    /// (wraps at 2^32 dispatches ≈ 33 years at 3600 dispatches/s,
    /// outside any product lifecycle). Workers compare `gen` against
    /// their private `last_generation` to know they must push their
    /// share; `n` provides the wave's chunk count without a second
    /// load.
    gen_and_n: std.atomic.Value(u64) align(64) = .init(0),

    /// Number of chunks still in flight in the current dispatch.
    /// Atomic so each worker can decrement without contending on
    /// `mu` per chunk — only the worker that brings the counter to
    /// zero takes the lock + signals `work_completed`. The
    /// dispatcher takes `mu` once around its `cond.wait` loop so
    /// the standard "check under lock + wait" pattern is preserved.
    pending_count: std.atomic.Value(u64) align(64) = .init(0),

    /// Set at deinit to make workers exit cleanly. **Atomic** because the
    /// worker spin path reads it lock-free (no `mu`) every idle round
    /// (`workerMain`), while `deinit` writes it — a non-atomic `bool` here
    /// is a data race (UB) the ReleaseFast/ReleaseSafe optimizer may hoist
    /// out of the spin loop, so a worker could spin forever on a cached
    /// `false` and never observe shutdown. `.release` store pairs with the
    /// `.acquire` loads on the read sites (M1.0.1 — surfaced while
    /// diagnosing the windows-2025/ReleaseSafe scheduler hang).
    shutdown: std.atomic.Value(bool) = .init(false),

    mu: std.Io.Mutex = .init,
    /// Signaled by `dispatch` after every new wave is published.
    /// Sleeping workers wake, observe the new generation, push their
    /// share, and resume work. The dispatcher does **not** use a
    /// matching `work_completed` condvar — it spins on
    /// `pending_count` instead (the brief's sleep/wake requirement
    /// applies to the workers' idle path; making the dispatcher
    /// also block on a condvar added measurable wake-up latency
    /// without the CPU savings, see journal entry "bench S5a
    /// regression breakdown").
    work_available: std.Io.Condition = .init,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) SchedulerError!Scheduler {
        const worker_count = std.Thread.getCpuCount() catch default_worker_count;
        return Scheduler.initWithWorkerCount(gpa, io, worker_count);
    }

    /// Test-friendly entry point — accepts an explicit worker count
    /// override so `scheduler.zig` tests can force a known topology
    /// regardless of the host CPU count.
    pub fn initWithWorkerCount(gpa: std.mem.Allocator, io: std.Io, worker_count: usize) SchedulerError!Scheduler {
        std.debug.assert(worker_count >= 1);
        const workers = try gpa.alloc(Worker, worker_count);
        errdefer gpa.free(workers);
        for (workers, 0..) |*w, i| w.* = .{ .id = @intCast(i) };

        const jobs = try gpa.alloc(Job, worker_count * per_worker_capacity);
        errdefer gpa.free(jobs);

        return .{
            .io = io,
            .workers = workers,
            .jobs = jobs,
        };
    }

    pub fn start(self: *Scheduler) SchedulerError!void {
        for (self.workers, 0..) |*w, i| {
            w.thread = try std.Thread.spawn(.{}, workerMain, .{ self, @as(u32, @intCast(i)) });
        }
    }

    pub fn deinit(self: *Scheduler, gpa: std.mem.Allocator) void {
        // Flip shutdown under the mutex and wake every parked worker
        // so they can observe the flag and exit.
        self.mu.lockUncancelable(self.io);
        self.shutdown.store(true, .release);
        self.work_available.broadcast(self.io);
        self.mu.unlock(self.io);

        for (self.workers) |*w| {
            if (w.thread) |t| {
                t.join();
                w.thread = null;
            }
        }
        gpa.free(self.workers);
        gpa.free(self.jobs);
        self.* = undefined;
    }

    /// Total worker count actually in flight. Replaces the pre-E5a
    /// `pub const worker_count` constant for callers.
    pub fn workerCount(self: *const Scheduler) usize {
        return self.workers.len;
    }

    /// Distribute the chunks of `query` across worker deques and wait
    /// for completion. Sugar over `dispatchBatch` for the common
    /// single-body case (one trampoline, one args tuple) — used by
    /// the bench, the scheduler tests, and by `JobBuilder.addJob`
    /// when a system has nothing else to bundle into the same level.
    ///
    /// Returns `error.TooManyChunks` when
    /// `query.chunkCount() > workers.len * per_worker_capacity` — the
    /// caller is expected to size queries against the scheduler's max
    /// throughput. E7 (M0.9) replaced the prior `std.debug.assert`
    /// (compiled out in ReleaseFast → out-of-bounds write on overflow)
    /// with this explicit, build-mode-independent error return.
    pub fn dispatch(self: *Scheduler, query: anytype, comptime Body: anytype, args: anytype) SchedulerError!void {
        const ChunkPtrType = @TypeOf(query.chunkAt(0));
        const ArgsType = @TypeOf(args);

        const Trampoline = struct {
            fn call(chunk_ptr: *anyopaque, ctx_ptr: *anyopaque) void {
                const cp: ChunkPtrType = @ptrCast(@alignCast(chunk_ptr));
                const ctx: *ArgsType = @ptrCast(@alignCast(ctx_ptr));
                @call(.auto, Body, .{cp} ++ ctx.*);
            }
        };

        // Args storage on the dispatch caller's stack frame. Lifetime
        // extends until `dispatch` returns. Holding `args` as a `var`
        // means non-trivially-copyable tuples (slices, function
        // pointers, deeply nested pointers) round-trip through the
        // trampoline's `ctx.*` deref without losing information
        // (D-S1-5).
        var ctx_storage = args;

        const n = query.chunkCount();
        if (n > self.jobs.len) return error.TooManyChunks;

        const trampoline_fn: TrampolineFn = &Trampoline.call;
        for (0..n) |i| {
            self.jobs[i] = .{
                .chunk_ptr = @ptrCast(query.chunkAt(i)),
                .trampoline = trampoline_fn,
                .ctx_ptr = @ptrCast(&ctx_storage),
            };
        }

        self.publishWaveAndWait(@intCast(n));
    }

    /// Dispatch a caller-provided slice of pre-built jobs and wait
    /// for completion. Each job carries its own
    /// `(trampoline, ctx_ptr)` so a single dispatch can run
    /// heterogeneous bodies — the M0.1 / E5b multi-job concurrent
    /// intra-phase scheduler interleaves chunks from multiple
    /// systems on the same workers via this entry point.
    ///
    /// `incoming` is copied into the scheduler's internal `jobs`
    /// slice before the wave is published, so the caller's slice can
    /// be freed or reused as soon as `dispatchBatch` returns.
    ///
    /// Returns `error.TooManyChunks` when
    /// `incoming.len > workers.len * per_worker_capacity` (same
    /// build-mode-independent bound as `dispatch`).
    pub fn dispatchBatch(self: *Scheduler, incoming: []const Job) SchedulerError!void {
        if (incoming.len > self.jobs.len) return error.TooManyChunks;
        @memcpy(self.jobs[0..incoming.len], incoming);
        self.publishWaveAndWait(@intCast(incoming.len));
    }

    /// Internal: publish a wave of `n` jobs already sitting in
    /// `self.jobs[0..n]`, wake parked workers, busy-yield on
    /// completion.
    fn publishWaveAndWait(self: *Scheduler, n: u32) void {
        // Publish the new wave + wake every parked worker. The
        // mutex is taken briefly only to coordinate with workers
        // that may be entering / leaving the parked path.
        self.mu.lockUncancelable(self.io);
        self.pending_count.store(n, .release);
        // M0.2.1 / E5 — atomic publish of `(gen, n)` as a single
        // 64-bit store. Replaces the pre-fix split
        // `chunk_count = n` + `generation.fetchAdd(1)` which left a
        // window where workers could see the new generation with
        // stale chunk_count (or vice versa) — the R1 race confirmed
        // by E2ter dumps. Read-modify-write of `gen_and_n` is safe
        // here because the dispatcher holds `mu` (sole writer in this
        // critical section).
        const prev = unpack(self.gen_and_n.load(.acquire));
        self.gen_and_n.store(pack(prev.gen +% 1, n), .release);
        self.work_available.broadcast(self.io);
        self.mu.unlock(self.io);

        // Busy-yield on completion. The dispatcher is the only main
        // thread, so spinning here keeps the dispatch's per-frame
        // overhead near the S1 baseline — the brief's E5a sleep/wake
        // requirement applies to the **workers**' idle path (they
        // do park on `work_available` after the spin window).
        //
        // Two comptime-selected variants. ReleaseFast (C0.1 bench + shipped
        // runtime) gets the bare loop — zero added work. Debug + ReleaseSafe
        // (tests, pre-push, AND the S1 bench) get two runtime-safety
        // invariants:
        //   1. M0.2.1 / E5 belt-and-suspenders: `pending_count <= n` across
        //      the wave — an over-decrement (R1 `u64::MAX`) signature,
        //      complementing the seat assertion at the worker `fetchSub`.
        //   2. M1.0.1 livelock watchdog: if the wave fails to drain within
        //      `livelock_budget_ns` the scheduler is livelocked (a worker that
        //      missed its wake never ran its `pushShare`, so `pending_count`
        //      is stuck POSITIVE — distinct from the impossible `u64::MAX`
        //      case 1 catches). Dump + panic instead of hanging silently
        //      until the CI build-runner kills the process at ~60 s.
        //
        // The wall-clock is sampled only every `livelock_check_stride` spins,
        // NOT per iteration: S1 runs in ReleaseSafe, so a per-spin `Clock.now`
        // would tax the measured dispatch path. A draining wave exits in far
        // fewer spins than the stride; only a genuinely stuck wave reads the
        // clock. The counter increment + mask test is ~1 ns, lost in `yield`.
        if (std.debug.runtime_safety) {
            const spin_start = std.Io.Clock.now(.awake, self.io);
            var spin_rounds: u64 = 0;
            while (self.pending_count.load(.acquire) > 0) {
                const cur = self.pending_count.load(.acquire);
                std.debug.assert(cur <= n);
                spin_rounds +%= 1;
                if ((spin_rounds & (livelock_check_stride - 1)) == 0) {
                    const now = std.Io.Clock.now(.awake, self.io);
                    if (spin_start.durationTo(now).nanoseconds > livelock_budget_ns) {
                        livelockPanic(self, n);
                    }
                }
                std.Thread.yield() catch {};
            }
        } else {
            while (self.pending_count.load(.acquire) > 0) {
                std.Thread.yield() catch {};
            }
        }
    }

    // M0.2.1 / E5 — comptime layout guard against false sharing
    // between `gen_and_n` (dispatcher-written each wave) and
    // `pending_count` (worker-written each chunk). Both fields carry
    // `align(64)`, so each lands on its own cache line; this guard
    // proves it at compile time and catches any future layout change
    // that would silently regress the bench by re-introducing
    // cache-line ping-pong between dispatcher and workers.
    comptime {
        const gen_off = @offsetOf(Scheduler, "gen_and_n");
        const pc_off = @offsetOf(Scheduler, "pending_count");
        std.debug.assert(gen_off % cache_line == 0);
        std.debug.assert(pc_off % cache_line == 0);
        std.debug.assert(pc_off - gen_off >= cache_line);
    }

    pub fn snapshotStats(self: *const Scheduler, gpa: std.mem.Allocator) SchedulerError![]WorkerStats.Snapshot {
        const out = try gpa.alloc(WorkerStats.Snapshot, self.workers.len);
        for (self.workers, 0..) |*w, i| out[i] = w.stats.snapshot();
        return out;
    }

    pub fn resetStats(self: *Scheduler) void {
        for (self.workers) |*w| w.stats.reset();
    }

    /// M0.2.1 / E2ter — diagnostic dump of the scheduler state.
    /// Read-only (`.acquire` loads + per-worker `WorkerStats.snapshot`),
    /// safe to call from any thread including a worker about to panic.
    /// Used by:
    ///   - the test-side watchdog in `tests/ecs/livelock_dump.zig`,
    ///   - the over-decrement assertion in `workerMain` (cf.
    ///     `overDecrementPanic` below).
    pub fn dumpStateTo(self: *const Scheduler, writer: *std.Io.Writer) !void {
        // M0.2.1 / E5 — single atomic load + unpack so the dump reads
        // a consistent (gen, n) snapshot rather than torn fields.
        const snapshot = unpack(self.gen_and_n.load(.acquire));
        try writer.print("=== Job scheduler ===\n", .{});
        try writer.print("  pending_count : {d}\n", .{self.pending_count.load(.acquire)});
        try writer.print("  generation    : {d}\n", .{snapshot.gen});
        try writer.print("  chunk_count   : {d}\n", .{snapshot.n});
        try writer.print("  shutdown      : {any}\n", .{self.shutdown.load(.acquire)});
        try writer.print("  worker_count  : {d}\n", .{self.workers.len});

        var sum_chunks: u64 = 0;
        var sum_parks: u64 = 0;
        var sum_steals_a: u64 = 0;
        var sum_steals_s: u64 = 0;
        for (self.workers, 0..) |*w, i| {
            const snap = w.stats.snapshot();
            sum_chunks += snap.chunks_processed;
            sum_parks += snap.parks_completed;
            sum_steals_a += snap.steals_attempted;
            sum_steals_s += snap.steals_succeeded;
            try writer.print(
                "  worker[{d:>2}] id={d:>2} chunks={d:>8} parks={d:>6} steals_a={d:>8} steals_s={d:>8} work_ns={d}\n",
                .{
                    i,
                    w.id,
                    snap.chunks_processed,
                    snap.parks_completed,
                    snap.steals_attempted,
                    snap.steals_succeeded,
                    snap.work_duration_ns,
                },
            );
        }
        try writer.print(
            "  totals: chunks={d} parks={d} steals_a={d} steals_s={d}\n",
            .{ sum_chunks, sum_parks, sum_steals_a, sum_steals_s },
        );
    }
};

/// Number of yield-spin rounds a worker does after running out of
/// work before it actually parks on the wake-up condvar. Catches
/// back-to-back dispatches (a tight `dispatchFrame` loop, as in the
/// bench) without paying the futex wake cost on every dispatch.
/// Tuning notes:
///
/// - Too low → workers park between every dispatch, wake-up
///   latency dominates the per-dispatch budget.
/// - Too high → idle workers burn CPU between actual frames; bad
///   for laptops and headless servers.
///
/// 1024 rounds × ~200 ns/yield on macOS ≈ 200 µs spin window —
/// large enough to absorb the inter-dispatch gap of a busy bench
/// (≤10 µs measured between iterations) plus the wake-up jitter
/// from OS scheduler reshuffles, and small enough that a truly idle
/// scheduler settles to the parked state in well under a frame at
/// 60 Hz.
const idle_spin_rounds: u32 = 1024;

/// M1.0.1 — dispatcher-side livelock watchdog budget. If a wave fails to
/// drain within this wall-clock window, `publishWaveAndWait` is spinning
/// forever on a stuck-positive `pending_count` (a worker missed its wake and
/// never ran its `pushShare`). runtime-safety-gated (Debug + ReleaseSafe) →
/// stripped from the ReleaseFast C0.1 bench + shipped runtime. The **S1 bench
/// runs in ReleaseSafe**, so the watchdog IS live there — its clock read is
/// amortized over `livelock_check_stride` spins (below) to keep S1's measured
/// dispatch path off the per-iteration clock. 30 s is ≫ any legitimate wave
/// yet below the CI build-runner's ~60 s no-response kill, so a fired watchdog
/// is always a real livelock, never a merely slow drain.
const livelock_budget_ns: i96 = 30 * std.time.ns_per_s;

/// Power-of-two spin stride between wall-clock samples in the dispatcher's
/// livelock watchdog. Sampling `Clock.now` once per this many spins (vs every
/// iteration) keeps the S1 ReleaseSafe dispatch path free of per-spin clock
/// syscalls — 65536 ≫ any draining wave, so the clock is read only on a wave
/// that is genuinely stuck.
const livelock_check_stride: u64 = 1 << 16;

fn workerMain(sched: *Scheduler, worker_idx: u32) void {
    const self = &sched.workers[worker_idx];
    // M0.2.1 / E5 — last_generation now u32 to match packed gen_and_n's
    // generation half. Initial 0 matches `gen_and_n: .init(0)` which
    // unpacks to gen=0, n=0; first dispatch publishes gen=1 → workers
    // observe `snapshot.gen != last_generation` and push share.
    var last_generation: u32 = 0;
    var idle_spin_count: u32 = 0;

    while (true) {
        // ── Hot path: lock-free pop / steal ───────────────────────
        const maybe_job = blk: {
            if (self.deque.pop()) |j| break :blk j;

            _ = self.stats.steals_attempted.fetchAdd(1, .acq_rel);
            const worker_count = sched.workers.len;
            const start_idx = (worker_idx + 1) % worker_count;
            var k: usize = 0;
            while (k < worker_count - 1) : (k += 1) {
                const idx = (start_idx + k) % worker_count;
                switch (sched.workers[idx].deque.steal()) {
                    .success => |stolen| {
                        _ = self.stats.steals_succeeded.fetchAdd(1, .acq_rel);
                        break :blk stolen;
                    },
                    .empty, .aborted => continue,
                }
            }
            break :blk null;
        };

        if (maybe_job) |job| {
            // Found work — execute (still lock-free). M0.1 / E5b
            // each job carries its own trampoline + ctx, so workers
            // can interleave chunks from heterogeneous bodies
            // (multi-job concurrent intra-phase dispatch).
            const t0 = std.Io.Clock.now(.awake, sched.io);
            job.trampoline(job.chunk_ptr, job.ctx_ptr);
            const t1 = std.Io.Clock.now(.awake, sched.io);

            _ = self.stats.chunks_processed.fetchAdd(1, .acq_rel);
            const elapsed = t0.durationTo(t1).nanoseconds;
            const dt: u64 = @intCast(@max(@as(i96, 0), elapsed));
            _ = self.stats.work_duration_ns.fetchAdd(dt, .acq_rel);

            // Atomic decrement keeps the hot path lock-free. The
            // dispatcher busy-yields on `pending_count`, so no
            // condvar signal is needed when the wave drains — the
            // dispatcher observes the zero on its next yield round.
            //
            // M0.2.1 / E2ter — debug assertion at the unique
            // over-decrement site (located by E3 static
            // analysis). Captures full scheduler state at the panic
            // for diagnosis (discriminate R1/R2/R3 from
            // brief § Notes). Active in Debug + ReleaseSafe via
            // `std.debug.runtime_safety`, stripped in ReleaseFast.
            const prev = sched.pending_count.fetchSub(1, .acq_rel);
            if (std.debug.runtime_safety and prev == 0) {
                overDecrementPanic(sched, worker_idx);
            }
            idle_spin_count = 0;
            continue;
        }

        // ── Spin briefly before parking ───────────────────────────
        // Cheap path the bench's tight `dispatchFrame` loop relies
        // on. The next wave usually arrives within a handful of
        // µs — yielding to the OS scheduler a couple hundred times
        // catches it without paying the futex wake cost.
        if (idle_spin_count < idle_spin_rounds) {
            idle_spin_count += 1;
            // M0.2.1 / E5 — single atomic load + unpack. Replaces
            // the split `generation.load` + later `chunk_count` read
            // in pushShare which left a race window (R1).
            const snapshot = unpack(sched.gen_and_n.load(.acquire));
            if (snapshot.gen != last_generation or sched.shutdown.load(.acquire)) {
                // Take the fast-path back to wave dispatch — the
                // park path also handles this but at higher cost.
                if (sched.shutdown.load(.acquire)) return;
                last_generation = snapshot.gen;
                pushShare(sched, self, worker_idx, snapshot.n);
                idle_spin_count = 0;
                continue;
            }
            std.Thread.yield() catch {};
            continue;
        }

        // ── Idle path: park until a new generation appears ────────
        idle_spin_count = 0;
        sched.mu.lockUncancelable(sched.io);
        const snapshot = unpack(sched.gen_and_n.load(.acquire));
        if (sched.shutdown.load(.acquire)) {
            sched.mu.unlock(sched.io);
            return;
        }
        if (snapshot.gen != last_generation) {
            // A new wave came in while we were spinning to here.
            sched.mu.unlock(sched.io);
            last_generation = snapshot.gen;
            pushShare(sched, self, worker_idx, snapshot.n);
            continue;
        }
        // Truly idle — park on the wake-up condvar.
        sched.work_available.waitUncancelable(sched.io, &sched.mu);
        _ = self.stats.parks_completed.fetchAdd(1, .acq_rel);
        const wake_snapshot = unpack(sched.gen_and_n.load(.acquire));
        const wake_shutdown = sched.shutdown.load(.acquire);
        sched.mu.unlock(sched.io);

        if (wake_shutdown) return;
        if (wake_snapshot.gen != last_generation) {
            last_generation = wake_snapshot.gen;
            pushShare(sched, self, worker_idx, wake_snapshot.n);
        }
    }
}

/// M0.2.1 / E2ter — assertion debug panic path for the over-decrement
/// at `workerMain`'s fetchSub site. Dumps the full scheduler state via
/// `Scheduler.dumpStateTo` then `std.debug.panic`s with a stable
/// parseable message (grep-able if multiple panics happen across
/// runs). `noreturn` — the process aborts after the panic handler.
fn overDecrementPanic(sched: *Scheduler, worker_idx: u32) noreturn {
    var stderr_buf: [8192]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(sched.io, &stderr_buf);
    const stderr = &stderr_writer.interface;
    stderr.print(
        "\n=== M0.2.1 / E2ter — scheduler over-decrement (worker_idx={d}) ===\n",
        .{worker_idx},
    ) catch {};
    sched.dumpStateTo(stderr) catch {};
    stderr.flush() catch {};

    const w = &sched.workers[worker_idx];
    const stats = w.stats.snapshot();
    const snapshot = unpack(sched.gen_and_n.load(.acquire));
    std.debug.panic(
        "scheduler over-decrement at jobs/scheduler.zig:333 — worker_id={d} generation={d} chunks_processed={d} steals_s={d}",
        .{
            w.id,
            snapshot.gen,
            stats.chunks_processed,
            stats.steals_succeeded,
        },
    );
}

/// M1.0.1 — livelock watchdog panic path for `publishWaveAndWait`'s
/// dispatcher spin. Mirrors `overDecrementPanic`: dump the full
/// scheduler state then `std.debug.panic` with a stable parseable
/// message. The classifier is `pending_count`: stuck POSITIVE is the
/// park-path wake-lost signature (a worker never ran its strided
/// `pushShare`, so its chunks were never processed); the impossible
/// `u64::MAX` would already have tripped `overDecrementPanic` at the
/// worker seat. The per-worker `chunks_processed` column in the dump
/// pinpoints the worker(s) that fell short of their bracket-peers.
fn livelockPanic(sched: *Scheduler, n: u32) noreturn {
    var stderr_buf: [8192]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(sched.io, &stderr_buf);
    const stderr = &stderr_writer.interface;
    stderr.print(
        "\n=== M1.0.1 — scheduler livelock (wave n={d} did not drain within {d}s) ===\n",
        .{ n, @divTrunc(livelock_budget_ns, std.time.ns_per_s) },
    ) catch {};
    sched.dumpStateTo(stderr) catch {};
    stderr.flush() catch {};

    const snapshot = unpack(sched.gen_and_n.load(.acquire));
    std.debug.panic(
        "scheduler livelock at jobs/scheduler.zig publishWaveAndWait — generation={d} chunk_count={d} pending_count={d}",
        .{ snapshot.gen, snapshot.n, sched.pending_count.load(.acquire) },
    );
}

/// Push this worker's strided share of `sched.jobs[0..n]` into its
/// own deque. Lock-free — the deque's Chase-Lev push has the
/// single-owner invariant, and the jobs array has already been
/// published by the matching `gen_and_n` store that woke us. Each
/// `Job` carries its own `(trampoline, ctx_ptr)` so the worker can
/// run it without pulling any scheduler-global state.
///
/// M0.2.1 / E5 — `n` is now passed as an explicit parameter (was a
/// non-atomic read of `sched.chunk_count` pre-fix). The caller is
/// responsible for ensuring `n` matches the generation that triggered
/// this push, by reading both halves of `gen_and_n` in a single
/// atomic load. This closes the wave-lifecycle race (R1) by
/// construction.
fn pushShare(sched: *Scheduler, self: *Worker, worker_idx: u32, n: u32) void {
    const worker_count = sched.workers.len;
    var i: u32 = worker_idx;
    while (i < n) : (i += @intCast(worker_count)) {
        while (!self.deque.push(sched.jobs[i])) {
            std.Thread.yield() catch {};
        }
    }
}
