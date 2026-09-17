//! The implicit DAG: a writer of X ordered before a reader of X, disjoint
//! write sets landing on one topological level, and the two refusals
//! `registerSystem` decides.
//!
//! The second refusal is the one the per-component conflict matrix cannot
//! express: two systems whose declarations CROSS close a cycle in the phase's
//! DAG while conflicting on no single id. The tests for it pin the refusal, the
//! transitive case that tells a real graph walk from a comparison of two sets,
//! and the crossing declaration that is legal and must still register.

const std = @import("std");
const weld_core = @import("weld_core");
const watchdog = @import("test_watchdog");

const World = weld_core.ecs.world.World;

const jobs_sched_mod = weld_core.jobs.scheduler;
const Scheduler = jobs_sched_mod.Scheduler;

const sys_sched_mod = weld_core.ecs.scheduler;
const Access = weld_core.ecs.Access;
const SystemContextOf = weld_core.ecs.SystemContextOf;
const SystemScheduler = sys_sched_mod.SystemScheduler;
const SystemContext = sys_sched_mod.SystemContext;
const Reads = sys_sched_mod.Reads;
const Writes = sys_sched_mod.Writes;

const Position = extern struct { x: f32 = 0, y: f32 = 0 };
const Velocity = extern struct { dx: f32 = 0, dy: f32 = 0 };
const TagA = extern struct { v: u32 = 0 };
const TagB = extern struct { v: u32 = 0 };
const TagC = extern struct { v: u32 = 0 };
const TagD = extern struct { v: u32 = 0 };

// One declared access set per registered system, named after it.
// `registerSystem` derives BOTH the DAG's descriptors and the body's context
// type from the set named here, so a body cannot be paired with a declaration
// that does not describe it.
const spec_reader: []const Access = &.{Access.reads(Position)};
const spec_writer: []const Access = &.{Access.writes(Position)};
const spec_heavy_a: []const Access = &.{Access.writes(TagA)};
const spec_heavy_b: []const Access = &.{Access.writes(TagB)};
const spec_heavy_c: []const Access = &.{Access.writes(TagC)};
const spec_heavy_d: []const Access = &.{Access.writes(TagD)};
const spec_writer_a: []const Access = &.{Access.writes(Position)};
const spec_writer_post: []const Access = &.{Access.writes(Position)};
const spec_reader_a: []const Access = &.{Access.reads(Velocity)};
const spec_reader_b: []const Access = &.{Access.reads(Velocity)};
const spec_cross_a: []const Access = &.{ Access.reads(TagA), Access.writes(TagB) };
const spec_ww_first: []const Access = &.{Access.writes(TagC)};
const spec_chain_a: []const Access = &.{ Access.reads(TagA), Access.writes(TagB) };
const spec_chain_b: []const Access = &.{ Access.reads(TagB), Access.writes(TagC) };
const spec_source: []const Access = &.{Access.writes(TagA)};
const spec_sink: []const Access = &.{Access.reads(TagB)};
const spec_middle: []const Access = &.{ Access.reads(TagA), Access.writes(TagB) };
const spec_ring_a: []const Access = &.{ Access.reads(TagA), Access.writes(TagB) };
const spec_ring_b: []const Access = &.{ Access.reads(TagB), Access.writes(TagC) };
const spec_ring_c: []const Access = &.{ Access.reads(TagC), Access.writes(TagD) };
const spec_dia_root: []const Access = &.{ Access.reads(Position), Access.writes(TagA) };
const spec_dia_left: []const Access = &.{ Access.reads(TagA), Access.writes(TagB) };
const spec_dia_right: []const Access = &.{ Access.reads(TagA), Access.writes(TagC) };
const spec_dia_join: []const Access = &.{ Access.reads(TagB), Access.reads(TagC), Access.writes(TagD) };
const spec_dia_aside: []const Access = &.{Access.writes(Velocity)};
const spec_dia_probe: []const Access = &.{ Access.reads(Velocity), Access.writes(Position) };
const spec_writer_b: []const Access = &.{Access.writes(Position)};
const spec_cross_b: []const Access = &.{ Access.writes(TagA), Access.reads(TagB) };
const spec_ww_second: []const Access = &.{Access.writes(TagC)};
const spec_chain_c: []const Access = &.{ Access.reads(TagC), Access.writes(TagA) };
const spec_ring_d: []const Access = &.{ Access.reads(TagD), Access.writes(TagA) };

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

fn writerPositionSystem(ctx: SystemContextOf(spec_writer)) anyerror!void {
    const log: *OrderLog = @ptrCast(@alignCast(ctx.frame.user.?));
    try log.record(ctx.gpa, "writer");
}

fn readerPositionSystem(ctx: SystemContextOf(spec_reader)) anyerror!void {
    const log: *OrderLog = @ptrCast(@alignCast(ctx.frame.user.?));
    try log.record(ctx.gpa, "reader");
}

test "implicit DAG orders system that writes X before system that reads X" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var wd: watchdog.Watchdog = .{};
    try wd.arm(io, watchdog.default_timeout_ns, "implicit DAG orders system that writes X before system that reads X");
    defer wd.disarm();

    var world = World.init();
    defer world.deinit(gpa);

    var jobs_sched = try Scheduler.init(gpa, io);
    try jobs_sched.start();
    defer jobs_sched.deinit(gpa);
    wd.setScheduler(&jobs_sched);

    var sys = SystemScheduler.init();
    defer sys.deinit(gpa);

    // Note the registration order: reader FIRST, writer SECOND.
    // Without the DAG the SystemScheduler would run them in this
    // registration order; with the DAG it must reorder so the
    // writer runs first (the reader depends on the writer's
    // Writes(Position)).
    try sys.registerSystem(gpa, &world, .update, "reader", spec_reader, readerPositionSystem);
    try sys.registerSystem(gpa, &world, .update, "writer", spec_writer, writerPositionSystem);

    var log: OrderLog = .{};
    defer log.deinit(gpa);

    try sys.dispatchFrame(&world, gpa, io, &jobs_sched, 1.0 / 60.0, &log);

    try std.testing.expectEqual(@as(usize, 2), log.entries.items.len);
    try std.testing.expectEqualStrings("writer", log.entries.items[0]);
    try std.testing.expectEqualStrings("reader", log.entries.items[1]);
}

/// A body that does nothing, typed against the set it is registered with.
///
/// It is GENERIC because a body's parameter type is now its declaration: one
/// `nopSystem` served twenty registrations declaring twenty different sets,
/// and there is no single type that could. The generic form gives each site
/// its own, which is the property the change exists to create.
fn Nop(comptime spec: []const Access) type {
    return struct {
        fn run(_: SystemContextOf(spec)) anyerror!void {}
    };
}

/// The same, for the concurrency test whose bodies are never dispatched.
///
/// The DAG is built by `registerSystem` and read by `topologicalLevels`; no
/// `dispatchFrame` runs, so the body's contents are inert here and only its
/// TYPE matters — which is exactly what is being asserted.
fn NopHeavy(comptime spec: []const Access) type {
    return struct {
        fn run(_: SystemContextOf(spec)) anyerror!void {}
    };
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
    try sys.registerSystem(gpa, &world, .update, "heavy_a", spec_heavy_a, NopHeavy(spec_heavy_a).run);
    try sys.registerSystem(gpa, &world, .update, "heavy_b", spec_heavy_b, NopHeavy(spec_heavy_b).run);
    try sys.registerSystem(gpa, &world, .update, "heavy_c", spec_heavy_c, NopHeavy(spec_heavy_c).run);
    try sys.registerSystem(gpa, &world, .update, "heavy_d", spec_heavy_d, NopHeavy(spec_heavy_d).run);

    // The assertion is STRUCTURAL and that is the only kind that gates CI: it
    // reads the level assignment, which is platform-independent.
    const levels = try sys.topologicalLevels(gpa, .update);
    try std.testing.expectEqual(@as(usize, 1), levels.len);
    try std.testing.expectEqual(@as(usize, 4), levels[0].system_indices.items.len);

    // DO NOT RE-ADD A WALL-CLOCK ASSERTION HERE. One timed a `dispatchFrame`
    // with four CPU-bound bodies against a 50 ms bound calibrated on a 14-core
    // dev box, and it failed on a 2-vCPU Windows runner — where two cores
    // cannot overlap four bodies and the wall clock degenerates near-serial
    // (~20 ms) while the DAG has correctly tagged the systems parallel. A
    // timing bound measures the runner; the level assignment measures the DAG.
}

test "unresolvable conflict between two writes raises a registration error" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    var sys = SystemScheduler.init();
    defer sys.deinit(gpa);

    try sys.registerSystem(gpa, &world, .update, "writer_a", spec_writer_a, Nop(spec_writer_a).run);

    // A second writer on the same component in the same phase, with no explicit
    // ordering, is refused at registration — Bevy's silent serialization is
    // deliberately not the model.
    try std.testing.expectError(
        error.WriteWriteConflict,
        sys.registerSystem(gpa, &world, .update, "writer_b", spec_writer_b, Nop(spec_writer_b).run),
    );

    // A `Writes(X)` in a DIFFERENT phase is fine — phases are
    // independent dispatch units, so the conflict scope is
    // intra-phase.
    try sys.registerSystem(gpa, &world, .post_update, "writer_post", spec_writer_post, Nop(spec_writer_post).run);

    // And two `Reads(X)` on the same component in the same phase
    // are conflict-free — they can run in parallel.
    try sys.registerSystem(gpa, &world, .update, "reader_a", spec_reader_a, Nop(spec_reader_a).run);
    try sys.registerSystem(gpa, &world, .update, "reader_b", spec_reader_b, Nop(spec_reader_b).run);
}

test "crossing declarations that close a cycle are refused at registration" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    var sys = SystemScheduler.init();
    defer sys.deinit(gpa);

    // TWO NODES. Neither declaration is a write-write conflict on any id —
    // `TagA` is written once and `TagB` is written once — and together they
    // force both edges: `a` reads what `b` writes, `b` reads what `a` writes.
    // The DAG semantic is forward dataflow, so both are mandatory and there is
    // no ordering to choose.
    try sys.registerSystem(gpa, &world, .update, "cross_a", spec_cross_a, Nop(spec_cross_a).run);
    try std.testing.expectError(
        error.DependencyCycle,
        sys.registerSystem(gpa, &world, .update, "cross_b", spec_cross_b, Nop(spec_cross_b).run),
    );

    // THE ERROR IS NOT `WriteWriteConflict`, and that is the point of the
    // refusal rather than a detail of it. `expectError` above already fails on
    // any other code, so what this adds is the other direction: a real
    // duplicated write still reports the code that names it, so the two
    // refusals are told apart and cannot silently collapse into one.
    try sys.registerSystem(gpa, &world, .post_update, "ww_first", spec_ww_first, Nop(spec_ww_first).run);
    try std.testing.expectError(
        error.WriteWriteConflict,
        sys.registerSystem(gpa, &world, .post_update, "ww_second", spec_ww_second, Nop(spec_ww_second).run),
    );

    // NOTHING WAS COMMITTED by either refusal, on ALL FOUR of the things
    // `registerSystem` promises — descriptor, command buffer, edge, tracker
    // entry. A count of descriptors alone is not that contract: an
    // implementation that moved the tracker loop ahead of the cycle walk
    // would leave `writers[TagA] = [1]` naming a system that does not exist,
    // and every count in sight would still read 1.
    try expectNothingCommitted(&sys, .update, 1);
    try expectNothingCommitted(&sys, .post_update, 1);
}

/// Assert that `phase` holds exactly `expected` systems AND that nothing
/// anywhere in it names an index beyond them.
///
/// The second half is the part a count cannot give. `registerSystem` rolls
/// back its descriptor, its command buffer and its own adjacency list through
/// `errdefer`, and refuses ahead of all three — so the residue a broken
/// ordering would leave is in the structures the rollback does NOT walk: a
/// predecessor's adjacency list, and the tracker's per-component reader and
/// writer lists.
fn expectNothingCommitted(
    sys: *const SystemScheduler,
    phase: sys_sched_mod.Phase,
    expected: usize,
) !void {
    const p = &sys.phases[@intFromEnum(phase)];
    try std.testing.expectEqual(expected, p.systems.items.len);
    try std.testing.expectEqual(expected, p.command_buffers.items.len);
    try std.testing.expectEqual(expected, p.edges.items.len);

    for (p.edges.items) |adj| {
        for (adj.items) |target| try std.testing.expect(target < expected);
    }
    var readers = p.tracker.readers.valueIterator();
    while (readers.next()) |list| {
        for (list.items) |idx| try std.testing.expect(idx < expected);
    }
    var writers = p.tracker.writers.valueIterator();
    while (writers.next()) |list| {
        for (list.items) |idx| try std.testing.expect(idx < expected);
    }
}

test "a cycle closed through a third system is refused too" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    var sys = SystemScheduler.init();
    defer sys.deinit(gpa);

    // ONE HOP, and that is exactly what it discriminates — no more. A check
    // comparing the new system's predecessors against its successors DIRECTLY
    // passes the two-node test above and lets this one through: here the
    // successor is `a` and the predecessor is `b`, and they are distinct, so
    // reaching `b` takes walking `a`'s edges.
    //
    // **It does NOT pin transitivity**, and must not be read as the walk's
    // discriminating case: a bounded implementation that checks its seeds,
    // expands ONE level and stops passes this test and the one above it. The
    // four-node ring below is what refuses that form.
    try sys.registerSystem(gpa, &world, .update, "chain_a", spec_chain_a, Nop(spec_chain_a).run);
    try sys.registerSystem(gpa, &world, .update, "chain_b", spec_chain_b, Nop(spec_chain_b).run);
    try std.testing.expectError(
        error.DependencyCycle,
        sys.registerSystem(gpa, &world, .update, "chain_c", spec_chain_c, Nop(spec_chain_c).run),
    );
    try expectNothingCommitted(&sys, .update, 2);
}

test "a crossing declaration that closes no cycle is registered" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    var sys = SystemScheduler.init();
    defer sys.deinit(gpa);

    // NON-VACUITY, and on the walk itself rather than on the refusal. The
    // third system has a predecessor AND a successor, so the search really
    // runs — a check that refused whenever both sets are non-empty would pass
    // both tests above and fail here. It walks from `sink` and comes back
    // empty because `sink` declares no write of its own.
    try sys.registerSystem(gpa, &world, .update, "source", spec_source, Nop(spec_source).run);
    try sys.registerSystem(gpa, &world, .update, "sink", spec_sink, Nop(spec_sink).run);
    try sys.registerSystem(gpa, &world, .update, "middle", spec_middle, Nop(spec_middle).run);

    // Three systems, and the edges are the ones the declarations force:
    // `source` → `middle` → `sink`, one system per level.
    const levels = try sys.topologicalLevels(gpa, .update);
    try std.testing.expectEqual(@as(usize, 3), levels.len);
    for (levels) |lvl| {
        try std.testing.expectEqual(@as(usize, 1), lvl.system_indices.items.len);
    }
}

test "a cycle two hops deep is refused, which a bounded walk would miss" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    var sys = SystemScheduler.init();
    defer sys.deinit(gpa);

    // THE DISCRIMINATING CASE FOR THE WALK ITSELF, and the reason the two
    // tests above are not: in both of them the predecessor sits ONE hop from
    // a seed, so an implementation that checks its seeds, expands a single
    // level and stops passes them. Here the ring is four deep — `ring_d`'s
    // only successor is `ring_a` and its only predecessor is `ring_c`, two
    // hops apart — so refusing it requires the transitive closure the stack
    // computes and nothing less.
    try sys.registerSystem(gpa, &world, .update, "ring_a", spec_ring_a, Nop(spec_ring_a).run);
    try sys.registerSystem(gpa, &world, .update, "ring_b", spec_ring_b, Nop(spec_ring_b).run);
    try sys.registerSystem(gpa, &world, .update, "ring_c", spec_ring_c, Nop(spec_ring_c).run);

    // The three registered so far form a CHAIN and no cycle — asserted, so
    // the refusal below is attributable to the fourth declaration and not to
    // a graph that was already closed.
    const before = try sys.topologicalLevels(gpa, .update);
    try std.testing.expectEqual(@as(usize, 3), before.len);

    try std.testing.expectError(
        error.DependencyCycle,
        sys.registerSystem(gpa, &world, .update, "ring_d", spec_ring_d, Nop(spec_ring_d).run),
    );
    try expectNothingCommitted(&sys, .update, 3);
}

test "a walk that reconverges on one node still terminates and admits" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    var sys = SystemScheduler.init();
    defer sys.deinit(gpa);

    // A DIAMOND, so the walk reaches one node by TWO paths. Nothing else in
    // this file does: every other case discovers each node once, which leaves
    // `visited`'s second guard — the one on an expanded neighbour — never
    // taken, and the reasoning at its site measured by nothing.
    //
    // What it establishes is TERMINATION AND THE ANSWER, not necessity: in a
    // graph the registration keeps acyclic the walk halts either way, so
    // deleting the guard would not change this verdict. That is what the
    // source says too — the set bounds the work and cannot move the answer —
    // and the honest test is one that runs the shape rather than one that
    // claims the guard is load-bearing.
    try sys.registerSystem(gpa, &world, .update, "dia_root", spec_dia_root, Nop(spec_dia_root).run);
    try sys.registerSystem(gpa, &world, .update, "dia_left", spec_dia_left, Nop(spec_dia_left).run);
    try sys.registerSystem(gpa, &world, .update, "dia_right", spec_dia_right, Nop(spec_dia_right).run);
    // TWO predecessors, where every other case in this file has exactly one.
    // An implementation reading `incoming.items[0]` alone — skipping the
    // membership loop — is indistinguishable from the shipped one everywhere
    // else in the suite.
    try sys.registerSystem(gpa, &world, .update, "dia_join", spec_dia_join, Nop(spec_dia_join).run);
    try sys.registerSystem(gpa, &world, .update, "dia_aside", spec_dia_aside, Nop(spec_dia_aside).run);

    // The probe's walk seeds at `dia_root`, opens both branches, reaches
    // `dia_join` through one of them and meets it again through the other.
    // Its predecessor is `dia_aside`, which the diamond does not reach, so
    // the answer is admission.
    try sys.registerSystem(gpa, &world, .update, "dia_probe", spec_dia_probe, Nop(spec_dia_probe).run);

    // Six systems, and the SHAPE is a diamond rather than a chain: five
    // levels for six systems, the fourth holding the two branches. A chain
    // would give six levels of one and would pass a bare count.
    const levels = try sys.topologicalLevels(gpa, .update);
    try std.testing.expectEqual(@as(usize, 5), levels.len);
    try std.testing.expectEqual(@as(usize, 2), levels[3].system_indices.items.len);
}
