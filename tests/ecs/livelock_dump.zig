//! M0.2.1 / E2 — diagnostic dump of the job scheduler + event bus
//! state when the test's scheduler-livelock watchdog fires. Read-only
//! inspection of the public atomics + per-worker stats — no
//! modification of production code is required.
//!
//! The output is calibrated for the brief's E3 discriminant
//! (cf. § Notes top-1 / top-2):
//!
//!   - **H2 (wake-lost) signature** : `pending_count > 0` for an
//!     extended period, all workers carry `parks_completed > 0`,
//!     and `chunk_count > 0`. At least one worker is parked on
//!     `work_available` with `last_generation < scheduler.generation`
//!     — only inferable indirectly here from the gap between
//!     `chunk_count` and `sum(chunks_processed)` since
//!     `last_generation` lives in the worker's stack.
//!
//!   - **H4 (job lost / Chase-Lev race) signature** : `pending_count`
//!     stably positive with `sum(chunks_processed)` not progressing,
//!     and no worker parked recently (low `parks_completed`).
//!     Pattern less expected under M0.2 noise — escalates to Cas 2
//!     per the brief's § Notes if observed.
//!
//!   - **H1bis isolated signature** : test does NOT hang (watchdog
//!     never fires), but `parks_completed` is unusually high. Would
//!     hint at the inter-dispatch gap growing past the spin window
//!     without exposing the H2 latent race.

const std = @import("std");
const weld_core = @import("weld_core");

const Scheduler = weld_core.jobs.scheduler.Scheduler;
const World = weld_core.ecs.World;

/// Print a snapshot of the job scheduler's runtime state to `writer`.
/// The dump groups scheduler-wide atomics first, then per-worker
/// stats, then aggregate totals. Read with acquire ordering so the
/// numbers are coherent with respect to any worker that has
/// completed its last fetchSub on `pending_count`.
pub fn dumpJobScheduler(sched: *const Scheduler, writer: *std.Io.Writer) !void {
    try writer.print("=== Job scheduler ===\n", .{});
    try writer.print("  pending_count : {d}\n", .{sched.pending_count.load(.acquire)});
    try writer.print("  generation    : {d}\n", .{sched.generation.load(.acquire)});
    try writer.print("  chunk_count   : {d}\n", .{sched.chunk_count});
    try writer.print("  shutdown      : {any}\n", .{sched.shutdown});
    try writer.print("  worker_count  : {d}\n", .{sched.workers.len});

    var sum_chunks: u64 = 0;
    var sum_parks: u64 = 0;
    var sum_steals_a: u64 = 0;
    var sum_steals_s: u64 = 0;
    for (sched.workers, 0..) |*w, i| {
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

/// Print a snapshot of the event bus state to `writer`. Iterates
/// every registered queue and reports its lifetime, drop counter,
/// head position, and epoch.
pub fn dumpEventBus(world: *const World, writer: *std.Io.Writer) !void {
    try writer.print("=== Event bus ===\n", .{});
    try writer.print("  queue_count : {d}\n", .{world.event_bus.queueCount()});
    var it = world.event_bus.queues.valueIterator();
    var idx: usize = 0;
    while (it.next()) |entry| {
        try writer.print(
            "  queue[{d}] lifetime={s} drops={d} head={d} epoch={d}\n",
            .{
                idx,
                @tagName(entry.lifetime),
                entry.vtable.dropsSinceLastDrain(entry.ptr),
                entry.vtable.currentHead(entry.ptr),
                entry.vtable.currentEpoch(entry.ptr),
            },
        );
        idx += 1;
    }
}

/// Combined dump — convenience wrapper used by the watchdog path.
/// Emits a banner, the scheduler state, the event bus state, and a
/// closing banner suitable for grep-style post-mortem.
pub fn dumpLivelockState(
    sched: *const Scheduler,
    world: *const World,
    writer: *std.Io.Writer,
    iteration: u32,
    elapsed_ms: u64,
) !void {
    try writer.print(
        "\n=== M0.2.1 / E2 SchedulerLivelock detected (iter={d} elapsed={d}ms) ===\n",
        .{ iteration, elapsed_ms },
    );
    try dumpJobScheduler(sched, writer);
    try dumpEventBus(world, writer);
    try writer.print("=== End of livelock dump ===\n", .{});
}
