//! Read-only dump of the job scheduler and event bus state, printed when the
//! test watchdog fires on a suspected scheduler livelock. Three signatures the
//! output is meant to tell apart:
//!
//!   - **wake lost** — `pending_count > 0` over an extended period, every
//!     worker carrying `parks_completed > 0`, and `chunk_count > 0`. A worker
//!     parked on `work_available` with a stale `last_generation` is only
//!     inferable here from the gap between `chunk_count` and
//!     `sum(chunks_processed)`, that field living on the worker's stack.
//!
//!   - **job lost (Chase-Lev race)** — `pending_count` stably positive with
//!     `sum(chunks_processed)` not progressing, and no worker parked recently
//!     (low `parks_completed`).
//!
//!   - **spin window too short** — no hang at all, but `parks_completed`
//!     unusually high: the inter-dispatch gap outgrew the spin window without
//!     exposing a lost wake.

const std = @import("std");
const weld_core = @import("weld_core");

const Scheduler = weld_core.jobs.scheduler.Scheduler;
const World = weld_core.ecs.World;

/// Print a snapshot of the job scheduler's runtime state to `writer`.
/// Delegates to `Scheduler.dumpStateTo`: the implementation lives in production
/// code so `overDecrementPanic` prints the same format, and the two never
/// drift.
pub fn dumpJobScheduler(sched: *const Scheduler, writer: *std.Io.Writer) !void {
    try sched.dumpStateTo(writer);
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
