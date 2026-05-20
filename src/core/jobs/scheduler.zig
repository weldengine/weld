//! S1 work-stealing scheduler. Fixed pool of 4 worker threads, each with a
//! Chase-Lev deque (cf. `deque.zig`). One scheduler entry point —
//! `dispatch` — splits a query over its chunks and busy-waits (yielding)
//! until all workers have signaled completion via the pending counter.
//!
//! ## Ownership invariant
//!
//! Chase-Lev assumes a **single owner** per deque doing all `push`/`pop`.
//! Stealers may be plenty. The naive design where the main thread pushes
//! directly into worker deques violates this — and silently corrupts the
//! deque (concurrent writes to `bottom` from main and worker), with chunks
//! being consumed twice or dropped. We sidestep that by having **each worker
//! push its own share** of the dispatch's chunks into its own deque. The
//! share is a comptime-deterministic stride (`i mod worker_count`), so
//! workers don't coordinate during distribution. Main only writes to a
//! shared chunk-pointer array and bumps a generation counter.
//!
//! ## Dispatch protocol
//!
//! 1. Main writes the chunk pointers, the trampoline, the args context, and
//!    the pending count. All non-atomic writes are paired with a single
//!    `generation.fetchAdd(1, .acq_rel)` whose release semantics publish
//!    every prior write.
//! 2. Each worker compares the current generation against the last one it
//!    serviced. On change, it pushes its share of chunks into its own deque.
//! 3. Workers pop locally first, then steal from peers, then yield.
//! 4. Main waits for `pending_count` to reach 0, then clears the trampoline
//!    pointer and returns.
//!
//! Per `briefs/S1-mini-ecs.md` Out-of-scope: no DAG, no phases, no
//! priorities, no `wait_all` over heterogeneous job sets. Worker count is
//! hardcoded to 4 — Phase 0.1 introduces CPU-topology-driven sizing.

const std = @import("std");
const archetype_mod = @import("../ecs/archetype.zig");
const worker_mod = @import("worker.zig");

pub const Job = worker_mod.Job;
pub const TrampolineFn = worker_mod.TrampolineFn;
pub const Worker = worker_mod.Worker;
pub const WorkerStats = worker_mod.WorkerStats;

/// Number of worker threads in the S1 work-stealing pool. Hardcoded
/// at 4 for the Phase −1 spike; CPU-topology detection lands in M0.1
/// (debt D-S1, cf. `engine-phase-0-plan.md`).
pub const worker_count: usize = 4;

/// Maximum number of chunks a single dispatch can carry. 1024 covers the S1
/// bench (100 000 entities / 185 chunk capacity ≈ 541 chunks) with margin.
pub const MaxChunksPerDispatch: usize = 1024;

pub const Scheduler = struct {
    /// Shared `io` instance — needed by workers for `Clock.now` so they can
    /// record their per-job duration. Stored per `engine-zig-conventions.md`
    /// §11 (Tier 0 module, process-lifetime, multiple internal uses).
    io: std.Io,
    workers: [worker_count]Worker,
    /// Chunk pointers for the current dispatch. Filled by main, read by
    /// workers when they see a new generation.
    chunks: [MaxChunksPerDispatch]*anyopaque align(64) = undefined,
    chunk_count: u32 = 0,
    /// Trampoline + ctx are encoded as `usize` so they fit in
    /// `std.atomic.Value`. 0 means "no job set". Valid for the duration of a
    /// `dispatch` call only.
    current_fn: std.atomic.Value(usize) align(64) = .init(0),
    current_ctx: std.atomic.Value(usize) align(64) = .init(0),
    /// Bumped by `dispatch` to signal "new work available" to workers.
    /// Workers compare against their `last_generation` to detect a fresh
    /// dispatch and push their share of chunks into their own deque.
    generation: std.atomic.Value(u64) align(64) = .init(0),
    pending_count: std.atomic.Value(u64) align(64) = .init(0),
    shutdown: std.atomic.Value(bool) align(64) = .init(false),

    pub fn init(gpa: std.mem.Allocator, io: std.Io) !Scheduler {
        // gpa is unused in S1 — workers are stack-allocated as a fixed
        // [worker_count]Worker and chunks[] is a static MaxChunksPerDispatch
        // slot. Phase 0.1 introduces dynamic worker count (CPU-topology-driven)
        // and dynamic chunks capacity, both of which will allocate here. Kept
        // in the signature now to avoid a breaking change to every
        // `Scheduler.init` call site at that point.
        _ = gpa;
        var self: Scheduler = .{
            .io = io,
            .workers = undefined,
        };
        for (&self.workers, 0..) |*w, i| {
            w.* = .{ .id = @intCast(i) };
        }
        return self;
    }

    pub fn start(self: *Scheduler) !void {
        for (&self.workers, 0..) |*w, i| {
            w.thread = try std.Thread.spawn(.{}, workerMain, .{ self, @as(u32, @intCast(i)) });
        }
    }

    pub fn deinit(self: *Scheduler) void {
        self.shutdown.store(true, .release);
        for (&self.workers) |*w| {
            if (w.thread) |t| {
                t.join();
                w.thread = null;
            }
        }
        self.* = undefined;
    }

    /// Distribute the chunks of `query` across worker deques and wait for
    /// completion. `Body` is a comptime function with signature
    /// `fn (chunk: *@TypeOf(query.chunkAt(0)), ...args) void`.
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

        // Args storage on the dispatch caller's stack frame. Lifetime extends
        // until `dispatch` returns, which is after every chunk has been
        // processed — safe for workers to read.
        var ctx_storage = args;

        const n = query.chunkCount();
        std.debug.assert(n <= MaxChunksPerDispatch);

        // Fill the shared chunk-pointer array. These are plain stores; the
        // following `generation.fetchAdd(.acq_rel)` publishes them to workers.
        for (0..n) |i| {
            self.chunks[i] = @ptrCast(query.chunkAt(i));
        }
        self.chunk_count = @intCast(n);

        const trampoline_fn: TrampolineFn = &Trampoline.call;
        self.current_fn.store(@intFromPtr(trampoline_fn), .release);
        self.current_ctx.store(@intFromPtr(&ctx_storage), .release);
        self.pending_count.store(@intCast(n), .release);

        // Bump the generation last — its `.acq_rel` publishes every prior
        // write of this dispatch to any worker that performs an `.acquire`
        // load on `generation`.
        _ = self.generation.fetchAdd(1, .acq_rel);

        // Wait for completion.
        while (self.pending_count.load(.acquire) > 0) {
            std.Thread.yield() catch {};
        }

        self.current_fn.store(0, .release);
        self.current_ctx.store(0, .release);
    }

    pub fn snapshotStats(self: *const Scheduler) [worker_count]WorkerStats.Snapshot {
        var out: [worker_count]WorkerStats.Snapshot = undefined;
        for (&self.workers, 0..) |*w, i| out[i] = w.stats.snapshot();
        return out;
    }

    pub fn resetStats(self: *Scheduler) void {
        for (&self.workers) |*w| w.stats.reset();
    }
};

fn workerMain(sched: *Scheduler, worker_idx: u32) void {
    const self = &sched.workers[worker_idx];
    var last_generation: u64 = 0;

    while (!sched.shutdown.load(.acquire)) {
        // Detect a new dispatch by comparing the generation. On change, push
        // this worker's share of chunks into its own deque. The share is the
        // strided subset `worker_idx, worker_idx + N, worker_idx + 2N, ...`
        // which is computed independently per worker — no cross-worker sync.
        const cur_gen = sched.generation.load(.acquire);
        if (cur_gen != last_generation) {
            last_generation = cur_gen;
            const n = sched.chunk_count;
            var i: u32 = worker_idx;
            while (i < n) : (i += @intCast(worker_count)) {
                while (!self.deque.push(.{ .chunk_ptr = sched.chunks[i] })) {
                    std.Thread.yield() catch {};
                }
            }
        }

        var maybe_job: ?Job = self.deque.pop();

        if (maybe_job == null) {
            _ = self.stats.steals_attempted.fetchAdd(1, .acq_rel);
            const start_idx = (worker_idx + 1) % worker_count;
            var k: usize = 0;
            while (k < worker_count - 1) : (k += 1) {
                const idx = (start_idx + k) % worker_count;
                switch (sched.workers[idx].deque.steal()) {
                    .success => |stolen| {
                        maybe_job = stolen;
                        _ = self.stats.steals_succeeded.fetchAdd(1, .acq_rel);
                        break;
                    },
                    .empty, .aborted => continue,
                }
            }
        }

        if (maybe_job) |job| {
            const fn_int = sched.current_fn.load(.acquire);
            const ctx_int = sched.current_ctx.load(.acquire);
            // Hard invariant: if the worker has a job in hand, dispatch must
            // have published a non-zero (fn, ctx) pair before bumping the
            // generation that caused the worker to enqueue this job in the
            // first place. The release-acquire pair on `generation` and the
            // matching pair on the deque's `bottom` both establish that
            // happens-before. A zero load here means the protocol is
            // broken — fail loudly.
            std.debug.assert(fn_int != 0 and ctx_int != 0);
            const fn_ptr: TrampolineFn = @ptrFromInt(fn_int);
            const ctx_ptr: *anyopaque = @ptrFromInt(ctx_int);

            const t0 = std.Io.Clock.now(.awake, sched.io);
            fn_ptr(job.chunk_ptr, ctx_ptr);
            const t1 = std.Io.Clock.now(.awake, sched.io);

            _ = self.stats.chunks_processed.fetchAdd(1, .acq_rel);
            const elapsed = t0.durationTo(t1).nanoseconds;
            const dt: u64 = @intCast(@max(@as(i96, 0), elapsed));
            _ = self.stats.work_duration_ns.fetchAdd(dt, .acq_rel);

            _ = sched.pending_count.fetchSub(1, .acq_rel);
        } else {
            std.Thread.yield() catch {};
        }
    }
}
