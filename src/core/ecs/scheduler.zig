//! M0.1 / E5b system scheduler — phase pipeline + implicit DAG +
//! concurrent intra-phase dispatch.
//!
//! Sits above `core/jobs/scheduler.zig`. Owns the registry of
//! `SystemDescriptor`s grouped by `Phase` plus the per-phase
//! topological DAG built from `Reads(T)` / `Writes(T)` access
//! declarations. `dispatchFrame` walks each phase, then each
//! topological level inside that phase, collecting chunked work
//! from every system in the level into a single `JobBuilder`. The
//! resulting heterogeneous job batch is dispatched through the job
//! system in **one wave** — workers pull chunks from any system in
//! the level, so compatible systems share the worker pool at chunk
//! granularity.
//!
//! Phase pipeline. Six canonical phases dispatched in declaration
//! order: `pre_update`, `fixed_update`, `update`, `post_update`,
//! `late_update`, `pre_render`. The end-of-phase barrier is
//! implicit since `jobs.Scheduler.dispatchBatch` blocks until
//! `pending_count` reaches zero.
//!
//! DAG construction. Done **incrementally** at `registerSystem`:
//! every new system's `Reads(T)` / `Writes(T)` set is compared
//! against the already-registered systems in the same phase. The
//! semantic is **forward dataflow** — `Writes(X)` always runs before
//! `Reads(X)` regardless of registration order. The conflict matrix
//! is:
//!
//!   |               | Reads(X)        | Writes(X)        |
//!   |---------------|-----------------|------------------|
//!   | Reads(X)      | no edge         | edge (W→R)       |
//!   | Writes(X)     | edge (W→R)      | conflict → error |
//!
//! Two writes on the same component in the same phase are a hard
//! registration error (`error.WriteWriteConflict`) — Bevy's silent
//! serialization is explicitly not the model (cf. brief Notes).
//! E5b does NOT introduce `runs_before` / `runs_after` declarative
//! ordering — every conflict is unresolvable by construction, so
//! the registration error is the only outcome. A later milestone
//! can add explicit ordering if a real-world case requires it.
//!
//! Resource placeholders. `ReadsResource(R)` / `WritesResource(R)`
//! share the DAG construction path with components — the resource
//! API itself (M0.2) is out of scope, but the placeholders compile
//! and contribute to conflict detection so the SystemDescriptor
//! signature is stable across the M0.1 → M0.2 boundary.
//!
//! Topological levels. Computed lazily on first `dispatchFrame` via
//! Kahn's algorithm and cached per phase. The DAG's edges are
//! frozen after the first dispatch — re-registration between
//! frames is a programmer error and asserts in debug.
//!
//! Concurrency. Within a level, every system stages chunks into a
//! shared `JobBuilder`. The builder's arena owns a per-system args
//! storage so each system's body has a stable `ctx_ptr` for the
//! duration of the level's dispatch. Heterogeneous trampolines on
//! every job let workers interleave chunks from different systems
//! freely — this is the "multi-job concurrent intra-phase" pattern
//! the E5b brief requires.
//!
//! What E5b does NOT include (per the brief Execution Steps):
//! - No command buffers (E6).
//! - No observers (E6).
//! - No lazy query re-scan on archetype creation mid-frame (E6).
//! - No actual resource storage / lookup (M0.2).

const std = @import("std");
const world_mod = @import("world.zig");
const jobs_sched_mod = @import("../jobs/scheduler.zig");
const worker_mod = @import("../jobs/worker.zig");
const registry_mod = @import("registry.zig");

const World = world_mod.World;
const Job = worker_mod.Job;
const TrampolineFn = worker_mod.TrampolineFn;
const ComponentId = registry_mod.ComponentId;

// ─── Phase pipeline ────────────────────────────────────────────────────────

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

// ─── Access descriptors ────────────────────────────────────────────────────

/// Kind tag distinguishing component reads/writes from resource
/// reads/writes. Components and resources share the same DAG
/// construction logic in E5b — the conflict matrix is identical,
/// only the lookup namespace differs (and resources have no
/// concrete API yet, so the placeholders just record the intent).
pub const AccessKind = enum { reads, writes, reads_resource, writes_resource };

/// Closure that ensures the access's component / resource type is
/// registered with the world's `Registry` and returns its
/// `ComponentId`. Resolved at `registerSystem` time so the DAG can
/// reason about access conflicts using stable runtime ids.
pub const AccessResolveFn = *const fn (world: *World, gpa: std.mem.Allocator) anyerror!ComponentId;

/// One read/write access declaration on a system. The `type_name`
/// is `@typeName(T)` from the factory function and is kept around
/// for diagnostic messages on `WriteWriteConflict`.
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

/// Placeholder `ReadsResource(R)` — wired into DAG construction but
/// the resource lookup API itself lands in M0.2.
pub fn ReadsResource(comptime R: type) AccessDescriptor {
    const Wrapper = struct {
        fn resolve(world: *World, gpa: std.mem.Allocator) anyerror!ComponentId {
            // M0.1 / E5b shares the component-id pool for resources
            // so the DAG can reason about them. M0.2 introduces a
            // proper resource registry.
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

// ─── Frame / system context ────────────────────────────────────────────────

/// Per-frame state surfaced to every system. `dt` is the seconds
/// elapsed since the previous frame (provided by `dispatchFrame`);
/// `user` is an opaque pointer the caller can use to share custom
/// per-frame state (the bench stashes its cached query + offsets
/// here). E6 will extend this with the command buffer flush
/// context.
pub const FrameContext = struct {
    dt: f32,
    user: ?*anyopaque,
};

/// Argument bundle passed to every `SystemFn`. Holds the borrowed
/// `World`, the per-frame allocator, the io handle, the job
/// scheduler for chunked dispatch, the `FrameContext` shared
/// across systems, and the `JobBuilder` the system stages its
/// chunked work into.
pub const SystemContext = struct {
    world: *World,
    gpa: std.mem.Allocator,
    io: std.Io,
    jobs: *jobs_sched_mod.Scheduler,
    frame: *FrameContext,
    builder: *JobBuilder,
};

/// Type-erased system entry point. The function stages chunked
/// work into `ctx.builder` (via `builder.addJob`) instead of
/// dispatching directly through `ctx.jobs` — `SystemScheduler`
/// dispatches the accumulated batch at the end of the topological
/// level. Errors propagate through `dispatchFrame`.
pub const SystemFn = *const fn (ctx: SystemContext) anyerror!void;

/// System descriptor with access declarations for DAG construction.
/// `accesses` defaults to empty — a system with no declared
/// accesses is treated as having no conflicts with any other
/// system and lands on topological level 0.
pub const SystemDescriptor = struct {
    phase: Phase,
    name: []const u8,
    run: SystemFn,
    accesses: []const AccessDescriptor = &.{},
};

// ─── JobBuilder ────────────────────────────────────────────────────────────

/// Accumulator for the heterogeneous job batch dispatched at the
/// end of a topological level. Owns an arena allocator that stores
/// the per-system args alongside the `Job` array — each system's
/// `ctx_ptr` points at args owned by this arena for the duration
/// of the level's dispatch. Reset between levels via
/// `resetRetainingCapacity` so the bench's 1000-iteration loop
/// doesn't allocate after the first frame.
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

    /// Drop the current level's jobs + args without freeing the
    /// arena's allocated chunks. The next level reuses the same
    /// memory.
    pub fn reset(self: *JobBuilder) void {
        self.jobs.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
    }

    /// Stage the chunks of `query` into the builder with `Body`
    /// as the trampoline target and `args` as the per-job context.
    /// `args` is copied into the arena so its lifetime extends
    /// until the next `reset` / `deinit`.
    pub fn addJob(
        self: *JobBuilder,
        query: anytype,
        comptime Body: anytype,
        args: anytype,
    ) !void {
        const ChunkPtrType = @TypeOf(query.chunkAt(0));
        const ArgsType = @TypeOf(args);

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
};

// ─── DAG ───────────────────────────────────────────────────────────────────

/// Per-phase access tracker: which already-registered systems read
/// or write a given component / resource id. Used by
/// `registerSystem` to compute the new system's incoming edges and
/// to detect write-write conflicts on the same id.
const PhaseAccessTracker = struct {
    /// `ComponentId → readers (system indices in by_phase[phase])`.
    readers: std.AutoHashMapUnmanaged(ComponentId, std.ArrayListUnmanaged(u32)) = .empty,
    /// `ComponentId → writers (system indices)`. M0.1 / E5b allows
    /// at most one writer per id per phase, so this is effectively
    /// `?u32` per id (stored as ArrayList for symmetry + future
    /// growth when explicit ordering arrives).
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

/// Topological level — list of system indices (in
/// `by_phase[phase]`) that can be dispatched together.
const Level = struct {
    system_indices: std.ArrayListUnmanaged(u32) = .empty,

    fn deinit(self: *Level, gpa: std.mem.Allocator) void {
        self.system_indices.deinit(gpa);
        self.* = undefined;
    }
};

const PhaseState = struct {
    systems: std.ArrayListUnmanaged(SystemDescriptor) = .empty,
    /// `edges[i]` lists the system indices that must run AFTER
    /// system `i` (i.e. depend on `i`). Used by Kahn's algorithm
    /// to compute topological levels.
    edges: std.ArrayListUnmanaged(std.ArrayListUnmanaged(u32)) = .empty,
    tracker: PhaseAccessTracker = .{},
    /// Cached topological levels. `null` means "not computed yet"
    /// — the first `dispatchFrame` populates it.
    levels: ?std.ArrayListUnmanaged(Level) = null,

    fn deinit(self: *PhaseState, gpa: std.mem.Allocator) void {
        self.systems.deinit(gpa);
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

// ─── Errors ────────────────────────────────────────────────────────────────

/// Errors surfaced by `SystemScheduler.registerSystem`. Currently
/// limited to `WriteWriteConflict` (two writes on the same id in
/// the same phase) plus the usual `OutOfMemory`. Promoted to a
/// public alias so callers do not have to spell the error set out.
pub const RegistrationError = error{
    /// Two systems declare `Writes(T)` on the same component (or
    /// resource) in the same phase, with no explicit ordering to
    /// break the tie. M0.1 / E5b rejects this at registration —
    /// Bevy's silent serialization is explicitly not the model
    /// (cf. brief Notes).
    WriteWriteConflict,
    OutOfMemory,
};

// ─── SystemScheduler ───────────────────────────────────────────────────────

/// Phase-based system registry + implicit DAG + concurrent
/// intra-phase dispatch.
pub const SystemScheduler = struct {
    phases: [Phase.count]PhaseState,
    /// Cross-frame `JobBuilder` — owns the arena that backs every
    /// system's per-level args storage. Created lazily on the first
    /// `dispatchFrame` (so `init()` stays allocator-free) and reused
    /// for the lifetime of the scheduler. The arena is reset with
    /// `retain_capacity` between levels and between frames so the
    /// bench's tight 1000-iteration loop pays for memory once.
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

    /// Register a system. Resolves the system's accesses against
    /// the world's registry, then computes incoming edges + checks
    /// for write-write conflicts against systems already registered
    /// in the same phase. Returns `error.WriteWriteConflict` on a
    /// conflict; the descriptor is NOT inserted in that case.
    ///
    /// Invalidates any cached topological levels for the affected
    /// phase — the next `dispatchFrame` recomputes them.
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

        // First pass — conflict detection. Two writes on the same
        // id in the same phase = registration error. No state is
        // mutated until we know the system is conflict-free.
        for (desc.accesses, resolved) |access, cid| {
            if (access.kind == .writes or access.kind == .writes_resource) {
                if (phase.tracker.writers.get(cid)) |writers| {
                    if (writers.items.len > 0) return error.WriteWriteConflict;
                }
            }
        }

        // Second pass — compute the new system's edges. The DAG
        // semantic is **forward dataflow** (W→R) regardless of
        // registration order. For each access:
        //   - Reads(X) : every existing writer of X is a predecessor
        //                (writer runs before this reader).
        //   - Writes(X): every existing reader of X is a successor
        //                (this writer runs before existing readers).
        //                Existing writers would have already raised
        //                `WriteWriteConflict` in pass 1.
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

        // Third pass — commit. Append the new system, extend edges,
        // record accesses in the tracker, invalidate cached levels.
        try phase.systems.append(gpa, desc);
        errdefer _ = phase.systems.pop();

        try phase.edges.append(gpa, .empty);
        errdefer {
            var popped = phase.edges.pop();
            if (popped) |*p| p.deinit(gpa);
        }

        // For each incoming dependency, append `new_idx` to that
        // system's outgoing list (predecessor → new_idx).
        for (incoming.items) |dep| {
            try phase.edges.items[dep].append(gpa, new_idx);
        }
        // For each outgoing dependency, append the successor to the
        // new system's outgoing list (new_idx → successor).
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

    /// Returns the cached topological levels for `phase`, building
    /// them on first access. Exposed for tests that want to inspect
    /// the DAG structure directly (the "disjoint writes run
    /// concurrently" acceptance test reads from here).
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

    /// Open a new frame and run every registered system once, in
    /// phase order. Within each phase, systems are batched by
    /// topological level — all systems at level N stage their
    /// chunks into a single `JobBuilder` and the batch is dispatched
    /// in one wave (chunks from different systems share workers).
    ///
    /// The shared `JobBuilder` lives on the caller's stack frame and
    /// is reset between levels so the inter-frame allocation footprint
    /// is bounded by the largest level's job + args storage.
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

        // Lazy-init the cross-frame JobBuilder on first use so the
        // arena is built only once per scheduler lifetime.
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
        }
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
        const levels = self.phases[phase_idx].levels.?.items;
        for (levels) |lvl| {
            builder.reset();
            for (lvl.system_indices.items) |sys_idx| {
                const sys = self.phases[phase_idx].systems.items[sys_idx];
                const ctx = SystemContext{
                    .world = world,
                    .gpa = gpa,
                    .io = io,
                    .jobs = jobs,
                    .frame = frame,
                    .builder = builder,
                };
                try sys.run(ctx);
            }
            if (builder.jobs.items.len > 0) {
                jobs.dispatchBatch(builder.jobs.items);
            }
            // End-of-level barrier is implicit — `dispatchBatch`
            // blocks until pending_count reaches zero.
        }
    }

    /// Kahn's algorithm — compute topological levels for one phase
    /// from the edges + per-node in-degree.
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
                // Cycle in the DAG — should never happen since the
                // conflict detection at registerSystem rejects the
                // only construction path that creates one.
                lvl.deinit(gpa);
                return error.WriteWriteConflict;
            }
            // Mark these nodes as scheduled by setting their
            // in_degree to a sentinel high enough to never reappear.
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

// ─── helpers ───────────────────────────────────────────────────────────────

fn appendUnique(gpa: std.mem.Allocator, list: *std.ArrayListUnmanaged(u32), value: u32) !void {
    for (list.items) |existing| if (existing == value) return;
    try list.append(gpa, value);
}

// ─── tests ────────────────────────────────────────────────────────────────

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
    // Both systems have no accesses → no edges → both land on
    // level 0.
    try testing.expectEqual(@as(usize, 1), levels.len);
    try testing.expectEqual(@as(usize, 2), levels[0].system_indices.items.len);
}
