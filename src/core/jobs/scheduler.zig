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

/// Errors surfaced by `Scheduler.init`, `start`, and `dispatch`.
pub const SchedulerError = error{
    OutOfMemory,
    TooManyChunks,
    ThreadQuotaExceeded,
    SystemResources,
    LockedMemoryLimitExceeded,
    Unexpected,
};

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
    /// Number of jobs actually in the current dispatch — read by
    /// workers after the generation bump (release-acquire pair on
    /// `generation`).
    chunk_count: u32 = 0,

    /// Bumped by `dispatch` to mark a new wave of work. Workers
    /// compare against their private `last_generation` to know they
    /// must push their share into their deque.
    generation: std.atomic.Value(u64) align(64) = .init(0),

    /// Number of chunks still in flight in the current dispatch.
    /// Atomic so each worker can decrement without contending on
    /// `mu` per chunk — only the worker that brings the counter to
    /// zero takes the lock + signals `work_completed`. The
    /// dispatcher takes `mu` once around its `cond.wait` loop so
    /// the standard "check under lock + wait" pattern is preserved.
    pending_count: std.atomic.Value(u64) align(64) = .init(0),

    /// Set under `mu` at deinit to make workers exit cleanly.
    shutdown: bool = false,

    mu: std.Io.Mutex = .init,
    /// Signaled by `dispatch` after every new wave is published.
    /// Sleeping workers wake, observe the new generation, push their
    /// share, and resume work. The dispatcher does **not** use a
    /// matching `work_completed` condvar — it spins on
    /// `pending_count` instead (the brief's sleep/wake requirement
    /// applies to the workers' idle path; making the dispatcher
    /// also block on a condvar added measurable wake-up latency
    /// without the CPU savings, see journal entry « bench S5a
    /// regression breakdown »).
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

    pub fn start(self: *Scheduler) !void {
        for (self.workers, 0..) |*w, i| {
            w.thread = try std.Thread.spawn(.{}, workerMain, .{ self, @as(u32, @intCast(i)) });
        }
    }

    pub fn deinit(self: *Scheduler, gpa: std.mem.Allocator) void {
        // Flip shutdown under the mutex and wake every parked worker
        // so they can observe the flag and exit.
        self.mu.lockUncancelable(self.io);
        self.shutdown = true;
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
    /// Panics when `query.chunkCount() > workers.len * per_worker_capacity`
    /// — the caller is expected to size queries against the
    /// scheduler's max throughput (E7 will tighten this with the
    /// C0.1 1 M case).
    pub fn dispatch(self: *Scheduler, query: anytype, comptime Body: anytype, args: anytype) void {
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
        std.debug.assert(n <= self.jobs.len);

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
    pub fn dispatchBatch(self: *Scheduler, incoming: []const Job) void {
        std.debug.assert(incoming.len <= self.jobs.len);
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
        self.chunk_count = n;
        self.pending_count.store(n, .release);
        _ = self.generation.fetchAdd(1, .acq_rel);
        self.work_available.broadcast(self.io);
        self.mu.unlock(self.io);

        // Busy-yield on completion. The dispatcher is the only main
        // thread, so spinning here keeps the dispatch's per-frame
        // overhead near the S1 baseline — the brief's E5a sleep/wake
        // requirement applies to the **workers**' idle path (they
        // do park on `work_available` after the spin window).
        while (self.pending_count.load(.acquire) > 0) {
            std.Thread.yield() catch {};
        }
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
        try writer.print("=== Job scheduler ===\n", .{});
        try writer.print("  pending_count : {d}\n", .{self.pending_count.load(.acquire)});
        try writer.print("  generation    : {d}\n", .{self.generation.load(.acquire)});
        try writer.print("  chunk_count   : {d}\n", .{self.chunk_count});
        try writer.print("  shutdown      : {any}\n", .{self.shutdown});
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

fn workerMain(sched: *Scheduler, worker_idx: u32) void {
    const self = &sched.workers[worker_idx];
    var last_generation: u64 = 0;
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
            // over-decrement site (siège localisé par E3 analyse
            // statique). Captures full scheduler state at the panic
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
            const cur_gen_quick = sched.generation.load(.acquire);
            if (cur_gen_quick != last_generation or sched.shutdown) {
                // Take the fast-path back to wave dispatch — the
                // park path also handles this but at higher cost.
                if (sched.shutdown) return;
                last_generation = cur_gen_quick;
                pushShare(sched, self, worker_idx);
                idle_spin_count = 0;
                continue;
            }
            std.Thread.yield() catch {};
            continue;
        }

        // ── Idle path: park until a new generation appears ────────
        idle_spin_count = 0;
        sched.mu.lockUncancelable(sched.io);
        const cur_gen = sched.generation.load(.acquire);
        if (sched.shutdown) {
            sched.mu.unlock(sched.io);
            return;
        }
        if (cur_gen != last_generation) {
            // A new wave came in while we were spinning to here.
            sched.mu.unlock(sched.io);
            last_generation = cur_gen;
            pushShare(sched, self, worker_idx);
            continue;
        }
        // Truly idle — park on the wake-up condvar.
        sched.work_available.waitUncancelable(sched.io, &sched.mu);
        _ = self.stats.parks_completed.fetchAdd(1, .acq_rel);
        const wake_gen = sched.generation.load(.acquire);
        const wake_shutdown = sched.shutdown;
        sched.mu.unlock(sched.io);

        if (wake_shutdown) return;
        if (wake_gen != last_generation) {
            last_generation = wake_gen;
            pushShare(sched, self, worker_idx);
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
    std.debug.panic(
        "scheduler over-decrement at jobs/scheduler.zig:333 — worker_id={d} generation={d} chunks_processed={d} steals_s={d}",
        .{
            w.id,
            sched.generation.load(.acquire),
            stats.chunks_processed,
            stats.steals_succeeded,
        },
    );
}

/// Push this worker's strided share of `sched.jobs[0..chunk_count]`
/// into its own deque. Lock-free — the deque's Chase-Lev push has the
/// single-owner invariant, and the jobs array has already been
/// published by the generation bump that woke us. Each `Job` carries
/// its own `(trampoline, ctx_ptr)` so the worker can run it without
/// pulling any scheduler-global state.
fn pushShare(sched: *Scheduler, self: *Worker, worker_idx: u32) void {
    const n = sched.chunk_count;
    const worker_count = sched.workers.len;
    var i: u32 = worker_idx;
    while (i < n) : (i += @intCast(worker_count)) {
        while (!self.deque.push(sched.jobs[i])) {
            std.Thread.yield() catch {};
        }
    }
}
