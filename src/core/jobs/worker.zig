//! FROZEN — see engine-phase-0-criteria.md C0.5
//!
//! Own deque, then peers in a FIXED rotation, then yield; the trampoline and the
//! context pointer are picked up with ACQUIRE ordering.

const std = @import("std");
const deque_mod = @import("deque.zig");

/// Type-erased trampoline called from `Worker.run` for each job.
pub const TrampolineFn = *const fn (chunk_ptr: *anyopaque, ctx_ptr: *anyopaque) void;

/// Type-erased work unit on a worker's Chase-Lev deque.
pub const Job = struct {
    /// Type-erased chunk pointer; the trampoline knows its concrete type.
    chunk_ptr: *anyopaque,
    trampoline: TrampolineFn,
    /// Per-job context pointer, owned by the dispatcher's frame.
    ctx_ptr: *anyopaque,
};

/// Maximum jobs per worker deque; `--workers=1` is the bound that sizes it.
pub const DequeCapacity: usize = 8192;
const WorkerDeque = deque_mod.Deque(Job, DequeCapacity);

/// Per-worker atomic counters, surfaced in the bench report.
pub const WorkerStats = struct {
    chunks_processed: std.atomic.Value(u64) = .init(0),
    steals_attempted: std.atomic.Value(u64) = .init(0),
    steals_succeeded: std.atomic.Value(u64) = .init(0),
    work_duration_ns: std.atomic.Value(u64) = .init(0),
    /// Parks ENTERED, bumped under the park mutex immediately BEFORE the wait.
    ///
    /// Always bumped before `parks_completed`, so `completed <= entered` holds at
    /// every observation — which is why `snapshot` reads completed FIRST.
    parks_entered: std.atomic.Value(u64) = .init(0),
    /// Parks COMPLETED — a wait that actually slept rather than busy-yielded.
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
        // Completed FIRST, or a park→wake cycle between the loads breaks the bound.
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

/// One work-stealing thread; owns its deque and its stats.
pub const Worker = struct {
    id: u32,
    deque: WorkerDeque align(64) = .init(),
    stats: WorkerStats = .{},
    thread: ?std.Thread = null,
};
