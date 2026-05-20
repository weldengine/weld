//! M0.1 / E5a system scheduler — phase pipeline + per-phase
//! sequential dispatch.
//!
//! The system scheduler sits **above** the job system
//! (`core/jobs/scheduler.zig`). It owns the registry of
//! `SystemDescriptor`s grouped by `Phase` and walks them in the
//! canonical Phase-0 order on every `dispatchFrame` call. Each
//! system is responsible for building its query and dispatching
//! chunked work through the job scheduler — the system scheduler
//! itself does not touch chunks.
//!
//! E5a runs **one job in flight at a time**. The end-of-phase barrier
//! is implicit: `jobs.Scheduler.dispatch` blocks until every chunk
//! has been processed, so the next system in the same phase only
//! starts once the previous one has finished. E5b will add
//! intra-phase multi-job concurrency on top of this pipeline.
//!
//! Frame open. `dispatchFrame` calls `world.beginFrame()` exactly
//! once, before the first phase. That increments the world's
//! `current_tick` and clears every chunk's dirty bitset so
//! `Changed<T>` queries see only this frame's modifications.
//!
//! What E5a does NOT include (per the brief Execution Steps):
//! - No `Reads(T)` / `Writes(T)` descriptors (E5b).
//! - No DAG of inter-system dependencies (E5b).
//! - No multi-job concurrent intra-phase dispatch (E5b).
//! - No command buffers / observers (E6).
//! - No lazy query re-scan on archetype creation mid-frame (E6).

const std = @import("std");
const world_mod = @import("world.zig");
const jobs_sched_mod = @import("../jobs/scheduler.zig");

const World = world_mod.World;

/// Canonical Phase-0 phase pipeline. Dispatched once per
/// `dispatchFrame` in declaration order:
///
/// 1. `pre_update`   — start-of-frame chores (input sampling, time
///    advance hooks).
/// 2. `fixed_update` — physics-rate fixed-step systems.
/// 3. `update`       — variable-rate gameplay (the bench S1 system
///    lives here).
/// 4. `post_update`  — variable-rate gameplay cleanup.
/// 5. `late_update`  — late-frame chores (transform propagation
///    when M0.5 lands).
/// 6. `pre_render`   — final pass before render submission
///    (camera matrix builds, culling preparation).
pub const Phase = enum(u8) {
    pre_update,
    fixed_update,
    update,
    post_update,
    late_update,
    pre_render,

    pub const count = std.meta.fields(@This()).len;
};

/// Per-frame state surfaced to every system. `dt` is the seconds
/// elapsed since the previous frame (provided by `dispatchFrame`);
/// `user` is an opaque pointer the caller can use to share custom
/// per-frame state (the bench stashes its cached query + offsets
/// here). E5b will extend this with resource accessors; E6 with the
/// command buffer flush context.
pub const FrameContext = struct {
    dt: f32,
    user: ?*anyopaque,
};

/// Argument bundle passed to every `SystemFn`. Holds the borrowed
/// `World`, the per-frame allocator (gpa for now — E5b may switch
/// to a frame arena), the io handle, the job scheduler for chunked
/// dispatch, and the `FrameContext` shared across systems.
pub const SystemContext = struct {
    world: *World,
    gpa: std.mem.Allocator,
    io: std.Io,
    jobs: *jobs_sched_mod.Scheduler,
    frame: *FrameContext,
};

/// Type-erased system entry point. The function builds whatever
/// query it needs, dispatches through `ctx.jobs.dispatch`, and
/// returns. Errors propagate up through `dispatchFrame` so the
/// caller can decide whether to abort the frame or log + continue.
pub const SystemFn = *const fn (ctx: SystemContext) anyerror!void;

/// Minimal system descriptor — phase, debug name, run callback.
/// E5b will extend this with `Reads(T)` / `Writes(T)` descriptors
/// for the DAG-building pass.
pub const SystemDescriptor = struct {
    phase: Phase,
    name: []const u8,
    run: SystemFn,
};

/// Phase-based system registry. Owns a per-phase
/// `ArrayList(SystemDescriptor)`; `dispatchFrame` walks each phase
/// in order and runs its systems sequentially.
pub const SystemScheduler = struct {
    by_phase: [Phase.count]std.ArrayListUnmanaged(SystemDescriptor),

    pub fn init() SystemScheduler {
        var s: SystemScheduler = undefined;
        for (&s.by_phase) |*list| list.* = .empty;
        return s;
    }

    pub fn deinit(self: *SystemScheduler, gpa: std.mem.Allocator) void {
        for (&self.by_phase) |*list| list.deinit(gpa);
        self.* = undefined;
    }

    /// Register a system. Order of registration within a phase is the
    /// order of dispatch.
    pub fn registerSystem(self: *SystemScheduler, gpa: std.mem.Allocator, desc: SystemDescriptor) !void {
        try self.by_phase[@intFromEnum(desc.phase)].append(gpa, desc);
    }

    pub fn systemCount(self: *const SystemScheduler) usize {
        var total: usize = 0;
        for (self.by_phase) |list| total += list.items.len;
        return total;
    }

    pub fn systemsInPhase(self: *const SystemScheduler, phase: Phase) []const SystemDescriptor {
        return self.by_phase[@intFromEnum(phase)].items;
    }

    /// Open a new frame and run every registered system once, in
    /// phase order. `dt` becomes `frame.dt`; `user` is forwarded
    /// unchanged. `World.beginFrame()` is called before the first
    /// system runs — `current_tick` advances and every chunk's
    /// dirty bitset is cleared.
    ///
    /// Errors from any system abort the frame at that system; later
    /// systems in the same or following phases do not run. The
    /// caller decides what to do with the error.
    pub fn dispatchFrame(
        self: *SystemScheduler,
        world: *World,
        gpa: std.mem.Allocator,
        io: std.Io,
        jobs: *jobs_sched_mod.Scheduler,
        dt: f32,
        user: ?*anyopaque,
    ) !void {
        world.beginFrame();
        var frame = FrameContext{ .dt = dt, .user = user };
        inline for (std.meta.fields(Phase)) |pf| {
            const phase = @field(Phase, pf.name);
            for (self.by_phase[@intFromEnum(phase)].items) |sys| {
                const ctx = SystemContext{
                    .world = world,
                    .gpa = gpa,
                    .io = io,
                    .jobs = jobs,
                    .frame = &frame,
                };
                try sys.run(ctx);
                // End-of-system barrier is implicit: `jobs.dispatch`
                // blocks until pending_count reaches 0 (the
                // work_completed condition signals the dispatcher).
                // The next system therefore starts on a quiesced
                // worker pool — no extra fence required for E5a.
            }
            // End-of-phase barrier is the same implicit barrier as
            // above. E5b's multi-job intra-phase dispatch will need
            // an explicit fence here, but E5a is sequential by
            // construction.
        }
    }
};

// ─── tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "SystemScheduler.init/deinit round-trip is leak-free" {
    var sched = SystemScheduler.init();
    defer sched.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), sched.systemCount());
}

test "registerSystem groups by phase and preserves registration order" {
    const gpa = testing.allocator;
    var sched = SystemScheduler.init();
    defer sched.deinit(gpa);

    const T = struct {
        fn nop(_: SystemContext) anyerror!void {}
    };

    try sched.registerSystem(gpa, .{ .phase = .update, .name = "a", .run = T.nop });
    try sched.registerSystem(gpa, .{ .phase = .update, .name = "b", .run = T.nop });
    try sched.registerSystem(gpa, .{ .phase = .pre_update, .name = "c", .run = T.nop });

    try testing.expectEqual(@as(usize, 3), sched.systemCount());
    const update_list = sched.systemsInPhase(.update);
    try testing.expectEqual(@as(usize, 2), update_list.len);
    try testing.expectEqualStrings("a", update_list[0].name);
    try testing.expectEqualStrings("b", update_list[1].name);
    try testing.expectEqualStrings("c", sched.systemsInPhase(.pre_update)[0].name);
}
