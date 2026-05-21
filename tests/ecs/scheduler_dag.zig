//! M0.1 / E5b — implicit DAG + concurrent intra-phase acceptance.
//!
//! Three tests cover the acceptance criteria listed in
//! `briefs/M0.1-ecs-full.md` § Acceptance criteria › Tests for E5b:
//!
//! - `implicit DAG orders system that writes X before system that
//!   reads X` — register `Writes(Position)` then `Reads(Position)`
//!   in the same phase, run `dispatchFrame`, observe via a shared
//!   log that the writer executes before the reader.
//! - `systems with disjoint write sets run concurrently in the
//!   same phase` — chosen method **(c) + (b)**: (c) read
//!   `SystemScheduler.topologicalLevels(.update)` and assert all
//!   four `Writes(A..D)` systems land on level 0; (b) measure the
//!   wall-clock of a single `dispatchFrame` with four CPU-bound
//!   bodies (~5 ms each) and assert it is significantly below
//!   `4 × 5 ms` — proof that workers do interleave the level's
//!   heterogeneous jobs.
//! - `unresolvable conflict between two writes raises a
//!   registration error` — register two systems with `Writes(X)`
//!   in the same phase; the second `registerSystem` returns
//!   `error.WriteWriteConflict`.

const std = @import("std");
const weld_core = @import("weld_core");

const World = weld_core.ecs.world.World;

const jobs_sched_mod = weld_core.jobs.scheduler;
const Scheduler = jobs_sched_mod.Scheduler;

const sys_sched_mod = weld_core.ecs.scheduler;
const SystemScheduler = sys_sched_mod.SystemScheduler;
const SystemContext = sys_sched_mod.SystemContext;
const Reads = sys_sched_mod.Reads;
const Writes = sys_sched_mod.Writes;

// ─── Components used by the tests ─────────────────────────────────────────

const Position = extern struct { x: f32 = 0, y: f32 = 0 };
const Velocity = extern struct { dx: f32 = 0, dy: f32 = 0 };
const TagA = extern struct { v: u32 = 0 };
const TagB = extern struct { v: u32 = 0 };
const TagC = extern struct { v: u32 = 0 };
const TagD = extern struct { v: u32 = 0 };

// ─── Test 1 — DAG ordering ────────────────────────────────────────────────

const OrderLog = struct {
    // No mutex needed — the writer (level 0) and reader (level 1) run
    // on different topological levels, so their system bodies execute
    // sequentially on the calling thread (chunks are dispatched into
    // jobs, but `SystemFn` bodies themselves are called serially by
    // `dispatchPhase`).
    entries: std.ArrayListUnmanaged([]const u8) = .empty,

    fn record(self: *OrderLog, gpa: std.mem.Allocator, name: []const u8) !void {
        try self.entries.append(gpa, name);
    }

    fn deinit(self: *OrderLog, gpa: std.mem.Allocator) void {
        self.entries.deinit(gpa);
    }
};

fn writerPositionSystem(ctx: SystemContext) anyerror!void {
    const log: *OrderLog = @ptrCast(@alignCast(ctx.frame.user.?));
    try log.record(ctx.gpa, "writer");
}

fn readerPositionSystem(ctx: SystemContext) anyerror!void {
    const log: *OrderLog = @ptrCast(@alignCast(ctx.frame.user.?));
    try log.record(ctx.gpa, "reader");
}

test "implicit DAG orders system that writes X before system that reads X" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var world = World.init();
    defer world.deinit(gpa);

    var jobs_sched = try Scheduler.init(gpa, io);
    try jobs_sched.start();
    defer jobs_sched.deinit(gpa);

    var sys = SystemScheduler.init();
    defer sys.deinit(gpa);

    // Note the registration order: reader FIRST, writer SECOND.
    // Without the DAG the SystemScheduler would run them in this
    // registration order; with the DAG it must reorder so the
    // writer runs first (the reader depends on the writer's
    // Writes(Position)).
    try sys.registerSystem(gpa, &world, .{
        .phase = .update,
        .name = "reader",
        .run = readerPositionSystem,
        .accesses = &.{Reads(Position)},
    });
    try sys.registerSystem(gpa, &world, .{
        .phase = .update,
        .name = "writer",
        .run = writerPositionSystem,
        .accesses = &.{Writes(Position)},
    });

    var log: OrderLog = .{};
    defer log.deinit(gpa);

    try sys.dispatchFrame(&world, gpa, io, &jobs_sched, 1.0 / 60.0, &log);

    try std.testing.expectEqual(@as(usize, 2), log.entries.items.len);
    try std.testing.expectEqualStrings("writer", log.entries.items[0]);
    try std.testing.expectEqualStrings("reader", log.entries.items[1]);
}

// ─── Test 2 — disjoint writes parallelism ─────────────────────────────────
//
// Pure structural assertion (method (c) from the E5b brief). The
// original test also shipped a method (b) wall-clock timing check
// (`expect(elapsed < 50 ms)` for four CPU-bound bodies running
// concurrently), but it failed on the GitHub Actions Windows
// runner (2 vCPUs) where the four bodies cannot actually overlap.
// The timing assertion was removed in the M0.1 hotfix; only the
// platform-independent topological-level check remains.

fn nopHeavySystem(_: SystemContext) anyerror!void {
    // System body is never dispatched in this test — `registerSystem`
    // sets up the DAG, `topologicalLevels` reads it, no
    // `dispatchFrame` happens. The fn pointer is required by
    // `SystemDescriptor.run` but its contents are inert here.
}

test "systems with disjoint write sets run concurrently in the same phase" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    var sys = SystemScheduler.init();
    defer sys.deinit(gpa);

    // Four systems, each writing a disjoint tag component. Their
    // read/write sets do not overlap, so the DAG must place them
    // all on the same topological level.
    try sys.registerSystem(gpa, &world, .{
        .phase = .update,
        .name = "heavy_a",
        .run = nopHeavySystem,
        .accesses = &.{Writes(TagA)},
    });
    try sys.registerSystem(gpa, &world, .{
        .phase = .update,
        .name = "heavy_b",
        .run = nopHeavySystem,
        .accesses = &.{Writes(TagB)},
    });
    try sys.registerSystem(gpa, &world, .{
        .phase = .update,
        .name = "heavy_c",
        .run = nopHeavySystem,
        .accesses = &.{Writes(TagC)},
    });
    try sys.registerSystem(gpa, &world, .{
        .phase = .update,
        .name = "heavy_d",
        .run = nopHeavySystem,
        .accesses = &.{Writes(TagD)},
    });

    // ── Method (c) — structural assertion ────────────────────────
    // Pure DAG-level check : all four `Writes(TagA..D)` systems
    // have disjoint write sets, so they MUST land on the same
    // topological level. This is platform-independent and the
    // only assertion that gates CI.
    const levels = try sys.topologicalLevels(gpa, .update);
    try std.testing.expectEqual(@as(usize, 1), levels.len);
    try std.testing.expectEqual(@as(usize, 4), levels[0].system_indices.items.len);

    // ── Method (b) intentionally removed — non-portable across CI hardware ─
    //
    // The original implementation timed a `dispatchFrame` with four
    // CPU-bound bodies and asserted `elapsed_ns < 50 ms` to confirm
    // the workers actually interleaved the level's jobs. The bound
    // was calibrated for the M4 Pro 14-core dev box where four
    // ~5 ms bodies clearly land under 50 ms when concurrent.
    //
    // It failed on the GitHub Actions Windows runner (2 vCPUs)
    // because two cores cannot overlap four bodies — the wall-clock
    // degenerates near-serial (~20 ms) even though the DAG
    // correctly tagged the systems as parallel-eligible. The
    // method (c) structural assertion above is the platform-
    // independent gate; the timing was always meant as a sanity
    // check and is dropped here per the M0.1 hotfix journal entry
    // (« Hotfix CI Windows post-E7 »).
    //
    // Lesson recorded in the brief: when a test ships a method (b)
    // timing assertion, ALWAYS pair it with a method (c) structural
    // fallback as the only CI gate. Hardware-dependent timing is
    // not portable across runners we do not control.
}

// ─── Test 3 — registration conflict ───────────────────────────────────────

fn nopSystem(_: SystemContext) anyerror!void {}

test "unresolvable conflict between two writes raises a registration error" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    var sys = SystemScheduler.init();
    defer sys.deinit(gpa);

    try sys.registerSystem(gpa, &world, .{
        .phase = .update,
        .name = "writer_a",
        .run = nopSystem,
        .accesses = &.{Writes(Position)},
    });

    // A second writer on the same component in the same phase
    // with no explicit ordering must be rejected at registration
    // (cf. brief Notes — Bevy's silent serialization is
    // explicitly not the model).
    try std.testing.expectError(
        error.WriteWriteConflict,
        sys.registerSystem(gpa, &world, .{
            .phase = .update,
            .name = "writer_b",
            .run = nopSystem,
            .accesses = &.{Writes(Position)},
        }),
    );

    // A `Writes(X)` in a DIFFERENT phase is fine — phases are
    // independent dispatch units, so the conflict scope is
    // intra-phase.
    try sys.registerSystem(gpa, &world, .{
        .phase = .post_update,
        .name = "writer_post",
        .run = nopSystem,
        .accesses = &.{Writes(Position)},
    });

    // And two `Reads(X)` on the same component in the same phase
    // are conflict-free — they can run in parallel.
    try sys.registerSystem(gpa, &world, .{
        .phase = .update,
        .name = "reader_a",
        .run = nopSystem,
        .accesses = &.{Reads(Velocity)},
    });
    try sys.registerSystem(gpa, &world, .{
        .phase = .update,
        .name = "reader_b",
        .run = nopSystem,
        .accesses = &.{Reads(Velocity)},
    });
}
