//! FROZEN — see engine-phase-0-criteria.md C0.5
//!
//! Phase pipeline, implicit DAG, concurrent intra-phase dispatch, above
//! `core/jobs/scheduler.zig`. A topological level's systems stage into ONE
//! `JobBuilder` dispatched in a single wave, so workers interleave chunks from
//! different systems.
//!
//! THE DAG SEMANTIC IS FORWARD DATAFLOW: `Writes(X)` runs before `Reads(X)`
//! whatever the registration order. Two writes on the same id in the same phase are
//! a HARD registration error — there is no `runs_before`/`runs_after` to break the
//! tie, so silent serialisation is deliberately not the model.
//!
//! Edges are built incrementally at `registerSystem` and the levels are cached on
//! first dispatch, so re-registering between frames is programmer error.
//!
//! The end-of-phase barrier is IMPLICIT: `dispatchBatch` blocks until
//! `pending_count` reaches zero.

const std = @import("std");
const world_mod = @import("world.zig");
const jobs_sched_mod = @import("../jobs/scheduler.zig");
const worker_mod = @import("../jobs/worker.zig");
const registry_mod = @import("registry.zig");
const command_buffer_mod = @import("command_buffer.zig");
const hybrid_query_mod = @import("hybrid_query.zig");
const observers_mod = @import("observers.zig");

const World = world_mod.World;
const Job = worker_mod.Job;
const TrampolineFn = worker_mod.TrampolineFn;
const ComponentId = registry_mod.ComponentId;
const CommandBuffer = command_buffer_mod.CommandBuffer;

/// The canonical phase pipeline, dispatched once per frame in DECLARATION ORDER.
pub const Phase = enum(u8) {
    pre_update,
    fixed_update,
    update,
    post_update,
    late_update,
    pre_render,

    pub const count = std.meta.fields(@This()).len;
};

/// Components and resources share one DAG path and one conflict matrix; only the
/// lookup namespace differs.
pub const AccessKind = enum { reads, writes, reads_resource, writes_resource };

/// Resolved at `registerSystem` time, so the DAG reasons about STABLE runtime ids.
pub const AccessResolveFn = *const fn (world: *World, gpa: std.mem.Allocator) anyerror!ComponentId;

/// `type_name` survives for the `WriteWriteConflict` diagnostic.
pub const AccessDescriptor = struct {
    kind: AccessKind,
    type_name: []const u8,
    resolve: AccessResolveFn,
};

/// Build a `Reads(T)` access descriptor.
pub fn Reads(comptime T: type) AccessDescriptor {
    const Wrapper = struct {
        fn resolve(world: *World, gpa: std.mem.Allocator) anyerror!ComponentId {
            return try world.ensureComponentRegistered(gpa, T);
        }
    };
    return .{
        .kind = .reads,
        .type_name = @typeName(T),
        .resolve = &Wrapper.resolve,
    };
}

/// Build a `Writes(T)` access descriptor.
pub fn Writes(comptime T: type) AccessDescriptor {
    const Wrapper = struct {
        fn resolve(world: *World, gpa: std.mem.Allocator) anyerror!ComponentId {
            return try world.ensureComponentRegistered(gpa, T);
        }
    };
    return .{
        .kind = .writes,
        .type_name = @typeName(T),
        .resolve = &Wrapper.resolve,
    };
}

/// Placeholder — the resource lookup API does not exist yet.
pub fn ReadsResource(comptime R: type) AccessDescriptor {
    const Wrapper = struct {
        fn resolve(world: *World, gpa: std.mem.Allocator) anyerror!ComponentId {
            // Resources share the component-id pool so the DAG can reason about them.
            return try world.ensureComponentRegistered(gpa, R);
        }
    };
    return .{
        .kind = .reads_resource,
        .type_name = @typeName(R),
        .resolve = &Wrapper.resolve,
    };
}

/// Placeholder `WritesResource(R)` — same caveat as `ReadsResource`.
pub fn WritesResource(comptime R: type) AccessDescriptor {
    const Wrapper = struct {
        fn resolve(world: *World, gpa: std.mem.Allocator) anyerror!ComponentId {
            return try world.ensureComponentRegistered(gpa, R);
        }
    };
    return .{
        .kind = .writes_resource,
        .type_name = @typeName(R),
        .resolve = &Wrapper.resolve,
    };
}

/// `dt` is seconds since the previous frame; `user` is an opaque pointer for the
/// caller's own per-frame state.
pub const FrameContext = struct {
    dt: f32,
    user: ?*anyopaque,
};

/// Everything a `SystemFn` body receives, all of it BORROWED for the call.
pub const SystemContext = struct {
    world: *World,
    gpa: std.mem.Allocator,
    io: std.Io,
    jobs: *jobs_sched_mod.Scheduler,
    frame: *FrameContext,
    builder: *JobBuilder,
    /// Recording is SINGLE-THREADED and main-thread only: a worker trampoline never
    /// receives a buffer.
    cmd: *CommandBuffer,
};

/// Stages into `ctx.builder` rather than dispatching through `ctx.jobs` — the
/// scheduler dispatches the accumulated batch at the end of the level.
pub const SystemFn = *const fn (ctx: SystemContext) anyerror!void;

/// A system with no declared access conflicts with nothing and lands on level 0.
pub const SystemDescriptor = struct {
    phase: Phase,
    name: []const u8,
    run: SystemFn,
    accesses: []const AccessDescriptor = &.{},
};

/// Accumulator for one level's heterogeneous job batch. Its arena stores each
/// system's args beside the `Job` array, so a body's `ctx_ptr` is stable for the
/// level; reset with `retain_capacity`, hence no allocation after the first frame.
pub const JobBuilder = struct {
    arena: std.heap.ArenaAllocator,
    jobs: std.ArrayListUnmanaged(Job) = .empty,

    pub fn init(backing_gpa: std.mem.Allocator) JobBuilder {
        return .{ .arena = std.heap.ArenaAllocator.init(backing_gpa) };
    }

    pub fn deinit(self: *JobBuilder) void {
        const backing = self.arena.child_allocator;
        self.jobs.deinit(backing);
        self.arena.deinit();
        self.* = undefined;
    }

    /// Drop this level's jobs and args; the arena's chunks stay for the next.
    pub fn reset(self: *JobBuilder) void {
        self.jobs.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
    }

    /// Stage `query`'s chunks with `Body` as the trampoline. `args` is COPIED into
    /// the arena, so its lifetime runs to the next `reset`.
    pub fn addJob(
        self: *JobBuilder,
        query: anytype,
        comptime Body: anytype,
        args: anytype,
    ) !void {
        const ChunkPtrType = @TypeOf(query.chunkAt(0));
        const ArgsType = @TypeOf(args);
        // A real dispatch point: `args` reaches a body the worker pool runs. The
        // bound lives on the TYPE so both dispatch points reach it independently.
        command_buffer_mod.refuseCommandBufferInArgs(ArgsType);

        const Trampoline = struct {
            fn call(chunk_ptr: *anyopaque, ctx_ptr: *anyopaque) void {
                const cp: ChunkPtrType = @ptrCast(@alignCast(chunk_ptr));
                const ctx: *ArgsType = @ptrCast(@alignCast(ctx_ptr));
                @call(.auto, Body, .{cp} ++ ctx.*);
            }
        };

        const arena_alloc = self.arena.allocator();
        const ctx_storage = try arena_alloc.create(ArgsType);
        ctx_storage.* = args;

        const backing = self.arena.child_allocator;
        const trampoline_fn: TrampolineFn = &Trampoline.call;
        const n = query.chunkCount();
        try self.jobs.ensureUnusedCapacity(backing, n);
        for (0..n) |i| {
            self.jobs.appendAssumeCapacity(.{
                .chunk_ptr = @ptrCast(query.chunkAt(i)),
                .trampoline = trampoline_fn,
                .ctx_ptr = @ptrCast(ctx_storage),
            });
        }
    }

    /// Stage a sparse-driven query's dense ranges, one job per range.
    ///
    /// A `DenseRange` is two integers with no storage identity, unlike a chunk which
    /// IS its own pointer — so the ranges are materialised into the builder's arena
    /// and each job carries a pointer to one. The arena's lifetime is the level,
    /// which is exactly the lifetime `args` already has.
    ///
    /// `target` is the caller's, a dense array having no equivalent of `chunkCount()`.
    /// Overflow is caught where `addJob`'s is, at `dispatchBatch`.
    pub fn addDenseRangeJobs(
        self: *JobBuilder,
        world: *world_mod.World,
        sq: *const hybrid_query_mod.SparseDrivenQuery,
        target: usize,
        comptime Body: anytype,
        args: anytype,
    ) !void {
        const ArgsType = @TypeOf(args);
        // The same bound as `addJob`: a worker owns its range and nothing else.
        command_buffer_mod.refuseCommandBufferInArgs(ArgsType);

        const n = sq.rangeCount(world, target);
        if (n == 0) return;

        const Trampoline = struct {
            fn call(range_ptr: *anyopaque, ctx_ptr: *anyopaque) void {
                const rp: *const hybrid_query_mod.DenseRange = @ptrCast(@alignCast(range_ptr));
                const ctx: *ArgsType = @ptrCast(@alignCast(ctx_ptr));
                @call(.auto, Body, .{rp.*} ++ ctx.*);
            }
        };

        const arena_alloc = self.arena.allocator();
        const ctx_storage = try arena_alloc.create(ArgsType);
        ctx_storage.* = args;
        const ranges = try arena_alloc.alloc(hybrid_query_mod.DenseRange, n);
        for (0..n) |i| ranges[i] = sq.rangeAt(world, i, target);

        const backing = self.arena.child_allocator;
        const trampoline_fn: TrampolineFn = &Trampoline.call;
        try self.jobs.ensureUnusedCapacity(backing, n);
        for (0..n) |i| {
            self.jobs.appendAssumeCapacity(.{
                .chunk_ptr = @ptrCast(&ranges[i]),
                .trampoline = trampoline_fn,
                .ctx_ptr = @ptrCast(ctx_storage),
            });
        }
    }
};

/// Who already reads or writes a given id in this phase — the input to the new
/// system's incoming edges and to write-write detection.
const PhaseAccessTracker = struct {
    /// `ComponentId → readers (system indices in by_phase[phase])`.
    readers: std.AutoHashMapUnmanaged(ComponentId, std.ArrayListUnmanaged(u32)) = .empty,
    /// At most ONE writer per id per phase, so effectively `?u32`; a list for symmetry.
    writers: std.AutoHashMapUnmanaged(ComponentId, std.ArrayListUnmanaged(u32)) = .empty,

    fn deinit(self: *PhaseAccessTracker, gpa: std.mem.Allocator) void {
        var rit = self.readers.valueIterator();
        while (rit.next()) |list| list.deinit(gpa);
        self.readers.deinit(gpa);
        var wit = self.writers.valueIterator();
        while (wit.next()) |list| list.deinit(gpa);
        self.writers.deinit(gpa);
        self.* = undefined;
    }
};

/// System indices that can be dispatched together.
const Level = struct {
    system_indices: std.ArrayListUnmanaged(u32) = .empty,

    fn deinit(self: *Level, gpa: std.mem.Allocator) void {
        self.system_indices.deinit(gpa);
        self.* = undefined;
    }
};

const PhaseState = struct {
    systems: std.ArrayListUnmanaged(SystemDescriptor) = .empty,
    /// Parallel to `systems` and indexed by the same `u32` as `edges` and `levels`.
    command_buffers: std.ArrayListUnmanaged(CommandBuffer) = .empty,
    /// `edges[i]` lists the systems that must run AFTER `i`.
    edges: std.ArrayListUnmanaged(std.ArrayListUnmanaged(u32)) = .empty,
    tracker: PhaseAccessTracker = .{},
    /// `null` means NOT COMPUTED YET; the first `dispatchFrame` fills it.
    levels: ?std.ArrayListUnmanaged(Level) = null,

    fn deinit(self: *PhaseState, gpa: std.mem.Allocator) void {
        self.systems.deinit(gpa);
        for (self.command_buffers.items) |*cb| cb.deinit();
        self.command_buffers.deinit(gpa);
        for (self.edges.items) |*adj| adj.deinit(gpa);
        self.edges.deinit(gpa);
        self.tracker.deinit(gpa);
        if (self.levels) |*levels| {
            for (levels.items) |*lvl| lvl.deinit(gpa);
            levels.deinit(gpa);
        }
        self.* = undefined;
    }
};

/// A public alias so callers need not spell the error set out.
pub const RegistrationError = error{
    /// Two `Writes(T)` on one id in one phase, with no ordering to break the tie.
    WriteWriteConflict,
    OutOfMemory,
};

/// Phase-based system registry + implicit DAG + concurrent
/// intra-phase dispatch.
pub const SystemScheduler = struct {
    phases: [Phase.count]PhaseState,
    /// Owns the arena backing every system's per-level args. Created lazily so
    /// `init()` stays allocator-free, and reset with `retain_capacity` between
    /// levels and frames, so a tight loop pays for memory once.
    builder: ?JobBuilder = null,

    pub fn init() SystemScheduler {
        var s: SystemScheduler = undefined;
        for (&s.phases) |*p| p.* = .{};
        s.builder = null;
        return s;
    }

    pub fn deinit(self: *SystemScheduler, gpa: std.mem.Allocator) void {
        for (&self.phases) |*p| p.deinit(gpa);
        if (self.builder) |*b| b.deinit();
        self.* = undefined;
    }

    /// On `WriteWriteConflict` the descriptor is NOT inserted. Invalidates the
    /// affected phase's cached levels.
    pub fn registerSystem(
        self: *SystemScheduler,
        gpa: std.mem.Allocator,
        world: *World,
        desc: SystemDescriptor,
    ) !void {
        const phase_idx = @intFromEnum(desc.phase);
        const phase = &self.phases[phase_idx];

        // Resolve accesses to ComponentIds via the world registry.
        const resolved = try gpa.alloc(ComponentId, desc.accesses.len);
        defer gpa.free(resolved);
        for (desc.accesses, 0..) |access, i| {
            resolved[i] = try access.resolve(world, gpa);
        }

        // Nothing is mutated until the system is known conflict-free.
        for (desc.accesses, resolved) |access, cid| {
            if (access.kind == .writes or access.kind == .writes_resource) {
                if (phase.tracker.writers.get(cid)) |writers| {
                    if (writers.items.len > 0) return error.WriteWriteConflict;
                }
            }
        }

        // Forward dataflow: `Reads(X)` takes every existing writer of X as a
        // predecessor, `Writes(X)` takes every existing reader as a successor.
        // An existing WRITER of X was already refused in pass 1.
        const new_idx: u32 = @intCast(phase.systems.items.len);
        var incoming = std.ArrayListUnmanaged(u32).empty;
        defer incoming.deinit(gpa);
        var outgoing = std.ArrayListUnmanaged(u32).empty;
        defer outgoing.deinit(gpa);
        for (desc.accesses, resolved) |access, cid| {
            switch (access.kind) {
                .reads, .reads_resource => {
                    if (phase.tracker.writers.get(cid)) |writers| {
                        for (writers.items) |w| try appendUnique(gpa, &incoming, w);
                    }
                },
                .writes, .writes_resource => {
                    if (phase.tracker.readers.get(cid)) |readers| {
                        for (readers.items) |r| try appendUnique(gpa, &outgoing, r);
                    }
                },
            }
        }

        // Commit: nothing below may fail.
        try phase.systems.append(gpa, desc);
        errdefer _ = phase.systems.pop();

        // The buffer borrows `world` for type resolution and `gpa` as its backing.
        try phase.command_buffers.append(gpa, CommandBuffer.init(gpa, world));
        errdefer {
            var popped_cb = phase.command_buffers.pop();
            if (popped_cb) |*cb| cb.deinit();
        }

        try phase.edges.append(gpa, .empty);
        errdefer {
            var popped = phase.edges.pop();
            if (popped) |*p| p.deinit(gpa);
        }

        for (incoming.items) |dep| {
            try phase.edges.items[dep].append(gpa, new_idx);
        }
        for (outgoing.items) |succ| {
            try phase.edges.items[new_idx].append(gpa, succ);
        }

        // Record accesses in the tracker.
        for (desc.accesses, resolved) |access, cid| {
            const which = switch (access.kind) {
                .reads, .reads_resource => &phase.tracker.readers,
                .writes, .writes_resource => &phase.tracker.writers,
            };
            const entry = try which.getOrPut(gpa, cid);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(gpa, new_idx);
        }

        // Invalidate cached levels — DAG topology changed.
        if (phase.levels) |*levels| {
            for (levels.items) |*lvl| lvl.deinit(gpa);
            levels.deinit(gpa);
            phase.levels = null;
        }
    }

    pub fn systemCount(self: *const SystemScheduler) usize {
        var total: usize = 0;
        for (self.phases) |p| total += p.systems.items.len;
        return total;
    }

    pub fn systemsInPhase(self: *const SystemScheduler, phase: Phase) []const SystemDescriptor {
        return self.phases[@intFromEnum(phase)].systems.items;
    }

    /// Builds them on first access. Exposed so a test can inspect the DAG.
    pub fn topologicalLevels(
        self: *SystemScheduler,
        gpa: std.mem.Allocator,
        phase: Phase,
    ) ![]const Level {
        const idx = @intFromEnum(phase);
        if (self.phases[idx].levels == null) {
            try self.computeLevels(gpa, idx);
        }
        return self.phases[idx].levels.?.items;
    }

    /// One frame: every phase in order, and inside a phase every topological level
    /// staged into one builder and dispatched in a single wave.
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

        // Lazy so the arena is built once per scheduler lifetime.
        if (self.builder == null) self.builder = JobBuilder.init(gpa);
        const builder = &self.builder.?;

        inline for (std.meta.fields(Phase)) |pf| {
            const phase = @field(Phase, pf.name);
            const phase_idx = @intFromEnum(phase);
            if (self.phases[phase_idx].systems.items.len > 0) {
                if (self.phases[phase_idx].levels == null) {
                    try self.computeLevels(gpa, phase_idx);
                }
                try dispatchPhase(self, world, gpa, io, jobs, &frame, builder, phase_idx);
            }
            // At EVERY phase transition, empty phases included, so the cadence does
            // not depend on the registered system topology.
            world.event_bus.drainAtBoundary(.phase);
        }
        // `.tick` and `.frame` fire together today; kept distinct so the call sites
        // can diverge.
        world.event_bus.drainAtBoundary(.tick);
        world.event_bus.drainAtBoundary(.frame);
    }

    fn dispatchPhase(
        self: *SystemScheduler,
        world: *World,
        gpa: std.mem.Allocator,
        io: std.Io,
        jobs: *jobs_sched_mod.Scheduler,
        frame: *FrameContext,
        builder: *JobBuilder,
        phase_idx: usize,
    ) !void {
        const phase = &self.phases[phase_idx];
        const levels = phase.levels.?.items;
        for (levels) |lvl| {
            builder.reset();
            for (lvl.system_indices.items) |sys_idx| {
                const sys = phase.systems.items[sys_idx];
                const ctx = SystemContext{
                    .world = world,
                    .gpa = gpa,
                    .io = io,
                    .jobs = jobs,
                    .frame = frame,
                    .builder = builder,
                    .cmd = &phase.command_buffers.items[sys_idx],
                };
                try sys.run(ctx);
            }
            if (builder.jobs.items.len > 0) {
                try jobs.dispatchBatch(builder.jobs.items);
            }
            // The barrier is implicit — `dispatchBatch` blocks until nothing is pending.
        }

        // SUBMISSION order, never topological-level order: the contract is
        // deterministic application across re-orderable layouts. Each flush also
        // drains the previous one's observer-issued commands, so an observer sees its
        // effects one flush-point later and never re-entrantly.
        for (phase.command_buffers.items) |*cb| {
            if (cb.commandCount() == 0 and !hasPendingDeferred(&world.observer_registry)) continue;
            try observers_mod.flushWithObservers(cb, &world.observer_registry);
        }
    }

    fn hasPendingDeferred(reg: *observers_mod.ObserverRegistry) bool {
        const d = reg.deferred orelse return false;
        return d.commandCount() > 0;
    }

    /// Kahn's algorithm over the edges and per-node in-degree.
    fn computeLevels(self: *SystemScheduler, gpa: std.mem.Allocator, phase_idx: usize) !void {
        const phase = &self.phases[phase_idx];
        const n = phase.systems.items.len;

        // Compute in-degree for every node.
        const in_degree = try gpa.alloc(u32, n);
        defer gpa.free(in_degree);
        @memset(in_degree, 0);
        for (phase.edges.items) |adj| {
            for (adj.items) |target| in_degree[target] += 1;
        }

        var levels: std.ArrayListUnmanaged(Level) = .empty;
        errdefer {
            for (levels.items) |*lvl| lvl.deinit(gpa);
            levels.deinit(gpa);
        }

        var remaining: usize = n;
        while (remaining > 0) {
            var lvl: Level = .{};
            for (in_degree, 0..) |deg, i| {
                if (deg == 0) {
                    try lvl.system_indices.append(gpa, @intCast(i));
                }
            }
            if (lvl.system_indices.items.len == 0) {
                // Unreachable: conflict detection refuses the only construction path
                // that could create a cycle.
                lvl.deinit(gpa);
                return error.WriteWriteConflict;
            }
            // A sentinel in-degree high enough that the node never reappears.
            for (lvl.system_indices.items) |idx| {
                in_degree[idx] = std.math.maxInt(u32);
                for (phase.edges.items[idx].items) |target| {
                    if (in_degree[target] != std.math.maxInt(u32)) {
                        in_degree[target] -= 1;
                    }
                }
            }
            remaining -= lvl.system_indices.items.len;
            try levels.append(gpa, lvl);
        }

        phase.levels = levels;
    }
};

fn appendUnique(gpa: std.mem.Allocator, list: *std.ArrayListUnmanaged(u32), value: u32) !void {
    for (list.items) |existing| if (existing == value) return;
    try list.append(gpa, value);
}

const testing = std.testing;

test "SystemScheduler.init/deinit round-trip is leak-free" {
    var sched = SystemScheduler.init();
    defer sched.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), sched.systemCount());
}

test "registerSystem with no accesses lands on level 0" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    var sched = SystemScheduler.init();
    defer sched.deinit(gpa);

    const T = struct {
        fn nop(_: SystemContext) anyerror!void {}
    };

    try sched.registerSystem(gpa, &world, .{
        .phase = .update,
        .name = "a",
        .run = T.nop,
    });
    try sched.registerSystem(gpa, &world, .{
        .phase = .update,
        .name = "b",
        .run = T.nop,
    });

    const levels = try sched.topologicalLevels(gpa, .update);
    // No accesses means no edges, so both land on level 0.
    try testing.expectEqual(@as(usize, 1), levels.len);
    try testing.expectEqual(@as(usize, 2), levels[0].system_indices.items.len);
}
