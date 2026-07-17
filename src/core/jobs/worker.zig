//! FROZEN — see engine-phase-0-criteria.md C0.5 (M0.9)
//!
//! Worker thread loop. Each worker owns a Chase-Lev deque and runs a tight
//! loop: pop from its own deque, then try to steal from peers in a fixed
//! rotation, then yield if both fail. The scheduler holds the trampoline
//! function pointer and an opaque context pointer for the current dispatch;
//! workers pick those up atomically with `acquire` ordering after their own
//! `acquire` load on the deque.
//!
//! Per-worker stats (chunks processed, steals attempted/succeeded, total
//! work duration in nanoseconds) feed the bench Markdown report so the
//! load-imbalance metric and steal hit rate can be inspected after a run.

const std = @import("std");
const deque_mod = @import("deque.zig");

/// Type-erased trampoline signature called from `Worker.run` once
/// per stolen / popped job. The chunk and context pointers are
/// recovered to their concrete types inside the trampoline.
pub const TrampolineFn = *const fn (chunk_ptr: *anyopaque, ctx_ptr: *anyopaque) void;

/// Type-erased work unit stored on each worker's Chase-Lev deque.
/// M0.1 / E5b each job carries its own `trampoline` + `ctx_ptr` so
/// a single dispatch can run heterogeneous bodies — required by the
/// E5b multi-job concurrent intra-phase scheduler which interleaves
/// chunks from different systems on the same workers.
pub const Job = struct {
    /// Type-erased pointer to a chunk. The trampoline knows the concrete
    /// chunk type at the dispatch call site.
    chunk_ptr: *anyopaque,
    /// Per-job trampoline. Workers call `trampoline(chunk_ptr, ctx_ptr)`
    /// rather than pulling a global trampoline from the scheduler.
    trampoline: TrampolineFn,
    /// Per-job context pointer (args storage owned by the dispatcher's
    /// stack frame or by the system scheduler's job arena).
    ctx_ptr: *anyopaque,
};

/// Maximum number of jobs per worker deque. Sized at 8192 to cover
/// the M0.1 / E7 C0.1 bench worst case: 1 000 000 entities across 4
/// archetypes ≈ 6 800 chunks per wave on the widest query (every
/// archetype matched). At `--workers=1` the single worker must hold
/// the full wave in its deque — 8192 leaves margin. Lower worker
/// counts (the S1 baseline at 4 workers handles ~640 chunks per
/// worker; well below the ceiling) and higher worker counts (14
/// workers per CPU handle ~500 chunks each — also well below)
/// inherit the same per-worker cap.
///
/// Each Job is 24 bytes (chunk_ptr + trampoline + ctx_ptr) so the
/// per-worker deque footprint is 8192 × 24 = 192 KiB. On a 14-worker
/// machine the cross-scheduler footprint is ~2.7 MiB — negligible.
///
/// Exposed so the M0.1 / E5a scheduler can size the dynamic
/// `MaxChunksPerDispatch` buffer at `worker_count * DequeCapacity`.
pub const DequeCapacity: usize = 8192;
const WorkerDeque = deque_mod.Deque(Job, DequeCapacity);

/// Atomic counters surfaced by each worker — chunks processed,
/// steal attempts / hits, total work-thread CPU time, and the
/// number of times the worker parked on the `work_available`
/// condvar (M0.1 / E5a, sleep/wake replacement of S1's busy-yield).
pub const WorkerStats = struct {
    chunks_processed: std.atomic.Value(u64) = .init(0),
    steals_attempted: std.atomic.Value(u64) = .init(0),
    steals_succeeded: std.atomic.Value(u64) = .init(0),
    work_duration_ns: std.atomic.Value(u64) = .init(0),
    /// Number of times the worker ENTERED the parked path — incremented under
    /// the park mutex immediately BEFORE `work_available.waitUncancelable`, the
    /// mirror of `parks_completed` (which counts the wake-ups after the wait
    /// returns). Because entered is always bumped before completed, the
    /// invariant `parks_completed <= parks_entered` holds at every observation
    /// (`snapshot` reads completed first — see below); a strict
    /// `parks_entered > parks_completed` means at least one worker has entered a
    /// park it has not yet woken from. Once a dispatched wave has drained (no
    /// park↔wake churn — the state the E9 test relies on) that is a worker
    /// parked right now. The M1.1.1-HF3 E9 deterministic parking test observes
    /// this in place of a fixed sleep window.
    parks_entered: std.atomic.Value(u64) = .init(0),
    /// Number of times the worker successfully completed a
    /// `work_available.waitUncancelable` (i.e. actually slept rather
    /// than busy-yielded). Used by the E5a "idle workers sleep"
    /// acceptance test as the observable proof that the worker
    /// reached the parked path.
    parks_completed: std.atomic.Value(u64) = .init(0),

    pub const Snapshot = struct {
        chunks_processed: u64,
        steals_attempted: u64,
        steals_succeeded: u64,
        work_duration_ns: u64,
        parks_entered: u64,
        parks_completed: u64,
    };

    pub fn snapshot(self: *const WorkerStats) Snapshot {
        // Read `parks_completed` BEFORE `parks_entered` so the snapshot always
        // satisfies `parks_completed <= parks_entered`, even if a worker cycles
        // park→wake between the two atomic loads (entered is bumped before
        // completed under the park mutex, so reading completed first can never
        // observe a completed value that outruns the later-read entered value).
        const completed = self.parks_completed.load(.acquire);
        return .{
            .chunks_processed = self.chunks_processed.load(.acquire),
            .steals_attempted = self.steals_attempted.load(.acquire),
            .steals_succeeded = self.steals_succeeded.load(.acquire),
            .work_duration_ns = self.work_duration_ns.load(.acquire),
            .parks_entered = self.parks_entered.load(.acquire),
            .parks_completed = completed,
        };
    }

    pub fn reset(self: *WorkerStats) void {
        self.chunks_processed.store(0, .release);
        self.steals_attempted.store(0, .release);
        self.steals_succeeded.store(0, .release);
        self.work_duration_ns.store(0, .release);
        self.parks_entered.store(0, .release);
        self.parks_completed.store(0, .release);
    }
};

/// One work-stealing thread in the scheduler pool. Owns its
/// `WorkerDeque`, holds atomic stats, and runs until `shutdown` is
/// flipped by the scheduler.
pub const Worker = struct {
    id: u32,
    deque: WorkerDeque align(64) = .init(),
    stats: WorkerStats = .{},
    thread: ?std.Thread = null,
};
