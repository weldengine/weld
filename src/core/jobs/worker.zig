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

pub const Job = struct {
    /// Type-erased pointer to a chunk. The trampoline knows the concrete
    /// chunk type at the dispatch call site.
    chunk_ptr: *anyopaque,
};

/// Maximum number of jobs per worker deque. Sized at 1 024 to cover
/// the S1 bench's chunk count with margin.
pub const DequeCapacity: usize = 1024;
/// Chase-Lev deque instantiated for `Job` values, sized to `DequeCapacity`.
pub const WorkerDeque = deque_mod.Deque(Job, DequeCapacity);

/// Type-erased trampoline signature called from `Worker.run` once
/// per stolen / popped job. The chunk and context pointers are
/// recovered to their concrete types inside the trampoline.
pub const TrampolineFn = *const fn (chunk_ptr: *anyopaque, ctx_ptr: *anyopaque) void;

pub const WorkerStats = struct {
    chunks_processed: std.atomic.Value(u64) = .init(0),
    steals_attempted: std.atomic.Value(u64) = .init(0),
    steals_succeeded: std.atomic.Value(u64) = .init(0),
    work_duration_ns: std.atomic.Value(u64) = .init(0),

    pub const Snapshot = struct {
        chunks_processed: u64,
        steals_attempted: u64,
        steals_succeeded: u64,
        work_duration_ns: u64,
    };

    pub fn snapshot(self: *const WorkerStats) Snapshot {
        return .{
            .chunks_processed = self.chunks_processed.load(.acquire),
            .steals_attempted = self.steals_attempted.load(.acquire),
            .steals_succeeded = self.steals_succeeded.load(.acquire),
            .work_duration_ns = self.work_duration_ns.load(.acquire),
        };
    }

    pub fn reset(self: *WorkerStats) void {
        self.chunks_processed.store(0, .release);
        self.steals_attempted.store(0, .release);
        self.steals_succeeded.store(0, .release);
        self.work_duration_ns.store(0, .release);
    }
};

pub const Worker = struct {
    id: u32,
    deque: WorkerDeque align(64) = .init(),
    stats: WorkerStats = .{},
    thread: ?std.Thread = null,
};
