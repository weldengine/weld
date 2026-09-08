//! FROZEN — see engine-phase-0-criteria.md C0.5
//!
//! Work-stealing scheduler over a dynamic worker pool. The job buffer is sized
//! `worker_count * Deque.capacity`, so a dispatch can never overflow one worker's
//! local deque.
//!
//! THE SINGLE-OWNER INVARIANT IS LOAD-BEARING: Chase-Lev assumes one owner per
//! deque, so each worker pushes its OWN strided share into its OWN deque. Only the
//! idle path takes the mutex; the hot path stays lock-free.
//!
//! `ctx_storage` lives on the dispatch caller's frame and the workers deref it
//! through the trampoline, so the frame must outlive the dispatch.

const std = @import("std");
const archetype_mod = @import("../ecs/archetype.zig");
const worker_mod = @import("worker.zig");
// Imported from its single definition rather than through a Tier 0 facade; the tier
// rule lives at that definition.
const float_env = @import("foundation").math.float_env;
const job_bound = @import("foundation").job_bound;

const Job = worker_mod.Job;
const TrampolineFn = worker_mod.TrampolineFn;
const Worker = worker_mod.Worker;
const WorkerStats = worker_mod.WorkerStats;

/// FROZEN — see engine-phase-0-criteria.md C0.5
/// Bumped on any breaking change to the frozen surface — a tracked migration.
pub const WELD_JOBS_PROTOCOL_VERSION: u32 = 1;

/// Fallback worker count when `std.Thread.getCpuCount` fails.
pub const default_worker_count: usize = 4;

/// Per-worker deque capacity: above this many chunks a dispatch fails loudly.
pub const per_worker_capacity: usize = worker_mod.DequeCapacity;

/// The union of `std.Thread.SpawnError` and `TooManyChunks`.
pub const SchedulerError = error{
    OutOfMemory,
    TooManyChunks,
    ThreadQuotaExceeded,
    SystemResources,
    LockedMemoryLimitExceeded,
    Unexpected,
};

/// Packed `(generation, chunk_count)`, so a worker sees both halves as ONE snapshot.
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

/// Cache line size assumed on the targets we run; drives the layout asserts below.
const cache_line: usize = 64;

/// Top-level work-stealing scheduler.
pub const Scheduler = struct {
    /// Shared `io`, for the workers' `Clock.now` and for the sync primitives.
    io: std.Io,
    /// Worker pool, sized at `init` from the host CPU count.
    workers: []Worker,
    /// Job buffer for the in-flight dispatch, sized so a per-worker stride cannot
    /// overflow a local deque. Each job carries its own `(trampoline, ctx_ptr)`.
    jobs: []Job,

    /// Packed `(generation: u32, chunk_count: u32)` in ONE atomic.
    ///
    /// SPLITTING THESE BACK INTO TWO FIELDS REINTRODUCES A RACE: a worker preempted
    /// between the two reads could pair an old generation with a new chunk count,
    /// push its share twice, and over-decrement `pending_count`.
    gen_and_n: std.atomic.Value(u64) align(64) = .init(0),

    /// Chunks still in flight. Atomic so a worker decrements without taking `mu`;
    /// only the worker that brings it to zero signals.
    pending_count: std.atomic.Value(u64) align(64) = .init(0),

    /// Set at deinit so workers exit.
    ///
    /// ATOMIC IS NOT OPTIONAL: the spin path reads it lock-free while `deinit`
    /// writes, and a plain `bool` here is a race the optimizer may hoist out of the
    /// loop — the worker would spin forever on a cached `false`.
    shutdown: std.atomic.Value(bool) = .init(false),

    mu: std.Io.Mutex = .init,
    /// Signalled after every published wave; sleeping workers wake and push. The
    /// dispatcher has NO matching condvar — it spins on `pending_count`.
    work_available: std.Io.Condition = .init,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) SchedulerError!Scheduler {
        const worker_count = std.Thread.getCpuCount() catch default_worker_count;
        return Scheduler.initWithWorkerCount(gpa, io, worker_count);
    }

    /// Entry point taking an explicit worker count, so a test can force a topology.
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

    /// Worker count actually in flight.
    pub fn workerCount(self: *const Scheduler) usize {
        return self.workers.len;
    }

    /// Distribute `query`'s chunks across the worker deques and wait for completion.
    ///
    /// `error.TooManyChunks` above `workers.len * per_worker_capacity` — an assert
    /// would be compiled out in ReleaseFast and become an out-of-bounds write.
    pub fn dispatch(self: *Scheduler, query: anytype, comptime Body: anytype, args: anytype) SchedulerError!void {
        const ChunkPtrType = @TypeOf(query.chunkAt(0));
        const ArgsType = @TypeOf(args);
        // Placement on the type makes a guard AVAILABLE, not called — this call is
        // what invokes it. The predicate lives in `foundation` so this tier reaches
        // it without importing the ECS.
        job_bound.refuseMarkedArgs(ArgsType);

        const Trampoline = struct {
            fn call(chunk_ptr: *anyopaque, ctx_ptr: *anyopaque) void {
                const cp: ChunkPtrType = @ptrCast(@alignCast(chunk_ptr));
                const ctx: *ArgsType = @ptrCast(@alignCast(ctx_ptr));
                @call(.auto, Body, .{cp} ++ ctx.*);
            }
        };

        // On the caller's frame, and its lifetime must extend past the dispatch: the
        // workers deref it through the trampoline, so a moved or dropped `args` dangles.
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

    /// Dispatch a caller-built slice of jobs and wait, so one wave can run
    /// heterogeneous bodies.
    ///
    /// `incoming` is COPIED before the wave is published, so the caller may free or
    /// reuse its slice as soon as this returns. Same `TooManyChunks` bound as
    /// `dispatch`.
    pub fn dispatchBatch(self: *Scheduler, incoming: []const Job) SchedulerError!void {
        // No argument type is interrogable here — a `Job` carries an erased
        // `ctx_ptr`. The bound is owed by the two entries that BUILD those records.
        if (incoming.len > self.jobs.len) return error.TooManyChunks;
        @memcpy(self.jobs[0..incoming.len], incoming);
        self.publishWaveAndWait(@intCast(incoming.len));
    }

    /// Publish a wave of `n` jobs already sitting in the buffer, then wait for it.
    fn publishWaveAndWait(self: *Scheduler, n: u32) void {
        // Publish the wave and wake every parked worker under the mutex.
        self.mu.lockUncancelable(self.io);
        self.pending_count.store(n, .release);
        // One 64-bit store publishes `(gen, n)` together. The read-modify-write is
        // safe only because the dispatcher holds `mu` and is the sole writer here.
        const prev = unpack(self.gen_and_n.load(.acquire));
        self.gen_and_n.store(pack(prev.gen +% 1, n), .release);
        self.work_available.broadcast(self.io);
        self.mu.unlock(self.io);

        // The dispatcher busy-yields; the sleep/wake requirement is the WORKERS'
        // idle path. Debug and ReleaseSafe add two invariants that ReleaseFast drops:
        // `pending_count <= n` catches an over-decrement, and the watchdog catches a
        // wave stuck POSITIVE because a worker missed its wake — two distinct
        // signatures. The clock is sampled once per `livelock_check_stride` spins and
        // NOT per iteration, because the S1 bench runs in ReleaseSafe and a per-spin
        // `Clock.now` would tax the path it measures.
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

    // `gen_and_n` is dispatcher-written per wave and `pending_count` worker-written
    // per chunk: this proves at compile time that they stay on separate cache lines.
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

    /// Diagnostic dump of the scheduler state. Read-only, so it is safe from any
    /// thread — including a worker about to panic.
    pub fn dumpStateTo(self: *const Scheduler, writer: *std.Io.Writer) !void {
        // One load + unpack, so the dump cannot report torn fields.
        const snapshot = unpack(self.gen_and_n.load(.acquire));
        try writer.print("=== Job scheduler ===\n", .{});
        try writer.print("  pending_count : {d}\n", .{self.pending_count.load(.acquire)});
        try writer.print("  generation    : {d}\n", .{snapshot.gen});
        try writer.print("  chunk_count   : {d}\n", .{snapshot.n});
        try writer.print("  shutdown      : {any}\n", .{self.shutdown.load(.acquire)});
        try writer.print("  worker_count  : {d}\n", .{self.workers.len});

        var sum_chunks: u64 = 0;
        var sum_parks: u64 = 0;
        var sum_parks_entered: u64 = 0;
        var sum_steals_a: u64 = 0;
        var sum_steals_s: u64 = 0;
        for (self.workers, 0..) |*w, i| {
            const snap = w.stats.snapshot();
            sum_chunks += snap.chunks_processed;
            sum_parks += snap.parks_completed;
            sum_parks_entered += snap.parks_entered;
            sum_steals_a += snap.steals_attempted;
            sum_steals_s += snap.steals_succeeded;
            try writer.print(
                "  worker[{d:>2}] id={d:>2} chunks={d:>8} parks_entered={d:>6} parks={d:>6} steals_a={d:>8} steals_s={d:>8} work_ns={d}\n",
                .{
                    i,
                    w.id,
                    snap.chunks_processed,
                    snap.parks_entered,
                    snap.parks_completed,
                    snap.steals_attempted,
                    snap.steals_succeeded,
                    snap.work_duration_ns,
                },
            );
        }
        try writer.print(
            "  totals: chunks={d} parks_entered={d} parks={d} steals_a={d} steals_s={d} (invariant parks<=parks_entered: {any})\n",
            .{ sum_chunks, sum_parks_entered, sum_parks, sum_steals_a, sum_steals_s, sum_parks <= sum_parks_entered },
        );
    }
};

/// Yield-spin rounds a worker does before it parks. Both directions cost: too low and
/// wake latency dominates a back-to-back dispatch, too high and idle workers burn CPU.
const idle_spin_rounds: u32 = 1024;

/// Dispatcher-side livelock budget: a wave that has not drained within it is stuck on
/// a POSITIVE `pending_count`, a worker having missed its wake.
///
/// Runtime-safety-gated, so live in the ReleaseSafe S1 bench and stripped from
/// ReleaseFast. Below the CI runner's own no-response kill, so a fired watchdog is
/// always a real livelock and never a slow drain.
const livelock_budget_ns: i96 = 30 * std.time.ns_per_s;

/// Spin stride between clock samples, which is what keeps the measured ReleaseSafe
/// dispatch path off a per-spin clock syscall.
const livelock_check_stride: u64 = 1 << 16;

fn workerMain(sched: *Scheduler, worker_idx: u32) void {
    // FIRST statement of every engine worker thread. The float environment is
    // per-thread and its default is not portable, and work stealing makes WHICH
    // worker runs WHICH job unstable — one worker with denormals flushed would make
    // a result depend on scheduling.
    float_env.install();

    const self = &sched.workers[worker_idx];
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
            const t0 = std.Io.Clock.now(.awake, sched.io);
            job.trampoline(job.chunk_ptr, job.ctx_ptr);
            const t1 = std.Io.Clock.now(.awake, sched.io);

            _ = self.stats.chunks_processed.fetchAdd(1, .acq_rel);
            const elapsed = t0.durationTo(t1).nanoseconds;
            const dt: u64 = @intCast(@max(@as(i96, 0), elapsed));
            _ = self.stats.work_duration_ns.fetchAdd(dt, .acq_rel);

            // Atomic keeps the hot path lock-free; the dispatcher observes the zero
            // on its next yield round, so no signal is owed. The assertion at this
            // unique over-decrement site is stripped in ReleaseFast.
            const prev = sched.pending_count.fetchSub(1, .acq_rel);
            if (std.debug.runtime_safety and prev == 0) {
                overDecrementPanic(sched, worker_idx);
            }
            idle_spin_count = 0;
            continue;
        }

        if (idle_spin_count < idle_spin_rounds) {
            idle_spin_count += 1;
            // One load + unpack: the two halves must not be read separately.
            const snapshot = unpack(sched.gen_and_n.load(.acquire));
            if (snapshot.gen != last_generation or sched.shutdown.load(.acquire)) {
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
        _ = self.stats.parks_entered.fetchAdd(1, .acq_rel);
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

/// Panic path for the over-decrement assertion, dumping the scheduler state.
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

/// Panic path for the livelock watchdog, dumping the scheduler state.
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

/// Push this worker's strided share of `sched.jobs[0..n]` into its own deque.
///
/// Lock-free on the Chase-Lev single-owner invariant. `n` MUST come from the same
/// atomic load of `gen_and_n` as the generation that triggered this push — reading
/// the two halves separately is the race this parameter exists to close.
fn pushShare(sched: *Scheduler, self: *Worker, worker_idx: u32, n: u32) void {
    const worker_count = sched.workers.len;
    var i: u32 = worker_idx;
    while (i < n) : (i += @intCast(worker_count)) {
        while (!self.deque.push(sched.jobs[i])) {
            std.Thread.yield() catch {};
        }
    }
}
