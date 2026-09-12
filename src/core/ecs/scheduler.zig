//! FROZEN — see `engine-phase-0-criteria.md` C0.5.
//!
//! System scheduler — phase pipeline + implicit DAG +
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
//! serialization is explicitly not the model.
//! There is no `runs_before` / `runs_after` declarative
//! ordering — every conflict is unresolvable by construction, so
//! the registration error is the only outcome. A later milestone
//! can add explicit ordering if a real-world case requires it.
//!
//! The matrix reads ONE component at a time, and a second refusal
//! exists because the DAG does not. Two systems whose declarations
//! cross — `Reads(T), Writes(U)` against `Writes(T), Reads(U)` —
//! are legal in every cell of it and together force both edges,
//! closing a cycle no per-component check can see.
//! `registerSystem` walks the graph and refuses that with
//! `error.DependencyCycle`, before the declaration is committed.
//!
//! Resource placeholders. `ReadsResource(R)` / `WritesResource(R)`
//! share the DAG construction path with components — the resource
//! API itself is out of scope, but the placeholders compile
//! and contribute to conflict detection so the SystemDescriptor
//! signature is stable when it lands.
//!
//! Topological levels. Computed lazily on first `dispatchFrame` via
//! Kahn's algorithm and cached per phase. Registering a system BETWEEN frames
//! is legal: it drops the affected phase's cached levels and the next
//! `dispatchFrame` recomputes them. Nothing freezes the DAG and nothing
//! asserts, so do not write a caller on the assumption that a late
//! registration is refused — it is honoured.
//!
//! Concurrency. Within a level, every system stages chunks into a
//! shared `JobBuilder`. The builder's arena owns a per-system args
//! storage so each system's body has a stable `ctx_ptr` for the
//! duration of the level's dispatch. Heterogeneous trampolines on
//! every job let workers interleave chunks from different systems
//! freely — this is the "multi-job concurrent intra-phase" pattern
//! the scheduler implements.
//!
const std = @import("std");
const world_mod = @import("world.zig");
const jobs_sched_mod = @import("../jobs/scheduler.zig");
const worker_mod = @import("../jobs/worker.zig");
const registry_mod = @import("registry.zig");
const command_buffer_mod = @import("command_buffer.zig");
const hybrid_query_mod = @import("hybrid_query.zig");
const observers_mod = @import("observers.zig");
const view_mod = @import("view.zig");

const World = world_mod.World;
const Job = worker_mod.Job;
const TrampolineFn = worker_mod.TrampolineFn;
const ComponentId = registry_mod.ComponentId;
const CommandBuffer = command_buffer_mod.CommandBuffer;

// ─── Phase pipeline ────────────────────────────────────────────────────────

/// Canonical phase pipeline. Dispatched once per
/// `dispatchFrame` in declaration order:
///
/// 1. `pre_update`   — start-of-frame chores (input sampling, time
///    advance hooks).
/// 2. `fixed_update` — physics-rate fixed-step systems.
/// 3. `update`       — variable-rate gameplay (the bench system
///    lives here).
/// 4. `post_update`  — variable-rate gameplay cleanup.
/// 5. `late_update`  — late-frame chores (transform propagation
///    once it lands).
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
/// construction logic — the conflict matrix is identical,
/// only the lookup namespace differs.
///
/// Re-exported from `view.zig` rather than declared twice: the same four
/// variants decide what the DAG orders and what the view lets a body reach,
/// and two enumerations of one domain drift.
pub const AccessKind = view_mod.AccessKind;

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
/// the resource lookup API itself is unimplemented.
pub fn ReadsResource(comptime R: type) AccessDescriptor {
    const Wrapper = struct {
        fn resolve(world: *World, gpa: std.mem.Allocator) anyerror!ComponentId {
            // The component-id pool is shared with resources
            // so the DAG can reason about them. A
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
/// here). It also carries the command buffer flush
/// context.
pub const FrameContext = struct {
    dt: f32,
    user: ?*anyopaque,
};

/// Argument bundle passed to every `SystemFn`. Holds the world with its type
/// erased, the per-frame allocator, the io handle, the job scheduler for
/// chunked dispatch, the `FrameContext` shared across systems, the
/// `JobBuilder` the system stages its chunked work into, and the per-system
/// `CommandBuffer` for deferred structural mutations.
///
/// **This is the ERASED context, and the erasure is the guarantee.** A system
/// body written against a declared access set receives `SystemContextOf(spec)`
/// instead, built by the trampoline `SystemDescriptor.of` generates. What
/// remains here is what the scheduler stores behind one function pointer — and
/// it hands out no `*World`, so a body that wants one has to name the type and
/// cast, which is a decision someone can find rather than a field someone
/// reaches by habit.
pub const SystemContext = struct {
    /// The world, type-erased. Recovering a `*World` from it is a deliberate
    /// act; the generated trampoline's own recovery is the only one in the
    /// tier, and it hands the result to a `View` that restricts it.
    world_erased: *anyopaque,
    gpa: std.mem.Allocator,
    io: std.Io,
    jobs: *jobs_sched_mod.Scheduler,
    frame: *FrameContext,
    builder: *JobBuilder,
    /// Per-system command buffer. Owned by `SystemScheduler`; reset
    /// between flushes (at the end of every phase). Recording is
    /// single-threaded — only the `SystemFn` body (main thread)
    /// records; worker trampolines do not receive a cmd buffer.
    cmd: *CommandBuffer,
};

/// Type-erased system entry point. The function stages chunked
/// work into `ctx.builder` (via `builder.addJob`) instead of
/// dispatching directly through `ctx.jobs` — `SystemScheduler`
/// dispatches the accumulated batch at the end of the topological
/// level. Errors propagate through `dispatchFrame`.
pub const SystemFn = *const fn (ctx: SystemContext) anyerror!void;

/// The context a system body written against a declared access set receives.
///
/// Identical to `SystemContext` but for its first member: where the erased
/// form carries an opaque pointer, this one carries the `View` the declaration
/// parameterises. One instantiation per declared set — which is exactly why it
/// cannot be what `SystemFn` points at, and why a trampoline exists.
pub fn SystemContextOf(comptime spec: []const view_mod.Access) type {
    return struct {
        view: view_mod.View(spec),
        gpa: std.mem.Allocator,
        io: std.Io,
        jobs: *jobs_sched_mod.Scheduler,
        frame: *FrameContext,
        builder: *JobBuilder,
        cmd: *CommandBuffer,
    };
}

/// Turn a declared access set into the runtime descriptors the DAG reads.
///
/// The result is a comptime constant, so it has static lifetime — which also
/// retires a hazard the inline `&.{ … }` form carries at every hand-written
/// registration: `registerSystem` stores the caller's slice without duplicating
/// it, and a temporary dangles the moment the registering function returns.
fn descriptorsOf(comptime spec: []const view_mod.Access) []const AccessDescriptor {
    // Held as a container-level `const` rather than built in a `comptime`
    // block and returned by pointer: a container-level constant has static
    // storage, which is the whole property this function exists to give the
    // scheduler. A block-local would be a pointer into comptime memory that
    // Zig refuses to hand to a run-time caller.
    const Derived = struct {
        const list = blk: {
            var out: [spec.len]AccessDescriptor = undefined;
            for (spec, 0..) |a, i| {
                out[i] = switch (a.kind) {
                    .reads => Reads(a.T),
                    .writes => Writes(a.T),
                    .reads_resource => ReadsResource(a.T),
                    .writes_resource => WritesResource(a.T),
                };
            }
            const frozen = out;
            break :blk frozen;
        };
    };
    return &Derived.list;
}

/// System descriptor with access declarations for DAG construction.
///
/// `accesses` has NO default. Omitting it does not produce a system that
/// conflicts with nobody and lands on level 0 — it fails to compile. An
/// implicit empty set is the most dangerous value the field can hold, since it
/// declares zero conflicts against everything else, and it is exactly what a
/// forgotten field used to yield.
///
/// An EXPLICITLY empty set stays legal: a system that touches no component and
/// no resource has an empty declaration, and saying so is a declaration.
pub const SystemDescriptor = struct {
    phase: Phase,
    name: []const u8,
    run: SystemFn,
    accesses: []const AccessDescriptor,

    /// Describe a system from ONE declaration.
    ///
    /// `spec` parameterises the view the body receives AND produces the
    /// descriptors the DAG orders on, so the two cannot disagree: there is no
    /// second list to keep in step. The returned `run` is a trampoline
    /// generated for this `spec` — it recovers the world from the erased
    /// context, wraps it in `View(spec)`, and calls `body`.
    ///
    /// Write `spec` once as a named constant and reference it in both places;
    /// two separate `&.{ … }` literals of identical content are two values,
    /// and a generic type instantiated on each is two types.
    pub fn of(
        comptime phase: Phase,
        comptime name: []const u8,
        comptime spec: []const view_mod.Access,
        comptime body: fn (SystemContextOf(spec)) anyerror!void,
    ) SystemDescriptor {
        const Generated = struct {
            fn call(ctx: SystemContext) anyerror!void {
                return body(.{
                    // The ONE cast on this path, and it is generated rather
                    // than written: `SystemContext` carries the world as
                    // `*anyopaque` because it is the storage the dispatcher
                    // fills before any spec is in view. Narrowing it to this
                    // system's own erased type happens here, once per
                    // registration, where the spec is known.
                    .view = view_mod.View(spec).fromErased(@ptrCast(ctx.world_erased)),
                    .gpa = ctx.gpa,
                    .io = ctx.io,
                    .jobs = ctx.jobs,
                    .frame = ctx.frame,
                    .builder = ctx.builder,
                    .cmd = ctx.cmd,
                });
            }
        };
        return .{
            .phase = phase,
            .name = name,
            .run = &Generated.call,
            .accesses = descriptorsOf(spec),
        };
    }
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
        // No job body receives a command buffer. This entry hands `args` to a
        // body the worker pool runs, and it is one of FOUR such entries — the
        // count is not a remark: a derived enumeration in the suite asserts it,
        // so adding a fifth without its bound goes red. The bound lives on the
        // TYPE (`command_buffer.refuseCommandBufferInArgs`) precisely so each
        // reaches it from its own imports rather than one carrying it alone.
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

    /// Stage the dense ranges of a sparse-driven query into the builder, one
    /// job per range, with `Body` as the trampoline target.
    ///
    /// **This is the entry that makes `engine-ecs-internals.md` §7's parity
    /// real**: a chunk becomes a unit of work by being handed to `addJob`
    /// above, and until this existed a dense range was split, bounded and
    /// never dispatched — `forEachDenseRange` runs its bodies on the CALLING
    /// thread, exactly like `Query.forEachChunk`. The split was delivered at
    /// The consumption is here.
    ///
    /// Parity is EXACT on the property that matters, and inexact on one point
    /// that is stated rather than implied. Exact: the same `Body` serves the
    /// same-thread entry and this one, because `forEachDenseRange` calls it
    /// with a `DenseRange` BY VALUE and this trampoline dereferences and
    /// passes the same value — the way one chunk body serves `forEachChunk`,
    /// `runChunkAt` and `addJob` alike. Inexact: a chunk is a heap allocation
    /// and IS its own `chunk_ptr`, while a `DenseRange` is two integers with
    /// no storage identity, so the ranges are materialised into the builder's
    /// arena and the job carries a pointer to one of them. The arena's
    /// lifetime is the level (`reset` is `.retain_capacity`), which is exactly
    /// the lifetime `args` already has.
    ///
    /// `target` is the caller's, as it is on `forEachDenseRange` — the natural
    /// granularity of a chunk query is `chunkCount()` and a dense array has
    /// no equivalent given quantity. Overflow is caught where `addJob`'s is,
    /// at `dispatchBatch`, which returns `error.TooManyChunks`; staging does
    /// not check, and that is parity and not an omission.
    pub fn addDenseRangeJobs(
        self: *JobBuilder,
        world: *world_mod.World,
        sq: *const hybrid_query_mod.SparseDrivenQuery,
        target: usize,
        comptime Body: anytype,
        args: anytype,
    ) !void {
        const ArgsType = @TypeOf(args);
        // The same bound as `addJob`, for the same reason: a worker owns its
        // range and nothing else.
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

// ─── DAG ───────────────────────────────────────────────────────────────────

/// Per-phase access tracker: which already-registered systems read
/// or write a given component / resource id. Used by
/// `registerSystem` to compute the new system's incoming edges and
/// to detect write-write conflicts on the same id.
const PhaseAccessTracker = struct {
    /// `ComponentId → readers (system indices in by_phase[phase])`.
    readers: std.AutoHashMapUnmanaged(ComponentId, std.ArrayListUnmanaged(u32)) = .empty,
    /// `ComponentId → writers (system indices)`. The scheduler allows
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
    /// Per-system command buffer, parallel to `systems`. Indexed by
    /// the same `u32` index used in `edges` / `tracker` / `levels`.
    /// Lifetime tied to the phase — created on `registerSystem`,
    /// deinit'd on the phase's own `deinit`.
    command_buffers: std.ArrayListUnmanaged(CommandBuffer) = .empty,
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

// ─── Errors ────────────────────────────────────────────────────────────────

/// The two refusals `SystemScheduler.registerSystem` decides, plus the usual
/// `OutOfMemory`.
///
/// **It is NOT the error set that function returns, and a caller must not
/// annotate against it.** `registerSystem` is declared `!void` with an
/// inferred set, and it `try`s `AccessDescriptor.resolve`, which is
/// `anyerror!ComponentId` — so the inferred set collapses to `anyerror`, and
/// `fn wire(…) RegistrationError!void { try sched.registerSystem(…); }` does
/// not compile. What this alias is good for is naming the refusals in a
/// `switch` or an `expectError`, which is every use of it in the tree
/// (measured). The gap is the resolver's `anyerror`, which predates this set
/// and is not narrowed here: it is a public function-pointer type, so
/// narrowing it is a frozen-surface change.
///
/// The two refusals name two different facts and are deliberately NOT one code.
/// A write-write conflict is a property of ONE component: two systems claim to
/// write it. A dependency cycle is a property of a SET of components and of no
/// single one of them — every declaration in the cycle is individually legal,
/// and it is their composition that has no ordering. A caller told
/// `WriteWriteConflict` for a cycle would look for the duplicated write that
/// does not exist.
pub const RegistrationError = error{
    /// Two systems declare `Writes(T)` on the same component (or resource) in the same
    /// phase, with no explicit ordering to break the tie. It is rejected at
    /// registration — Bevy's silent serialization is explicitly not the model used
    /// here.
    WriteWriteConflict,
    /// The declaration closes a cycle in the phase's dataflow DAG: the new
    /// system must run after one already registered and before another that
    /// reaches it. Two systems suffice — one declaring `Reads(T), Writes(U)`
    /// and the other `Writes(T), Reads(U)` — and neither declaration is a
    /// write-write conflict on any id.
    ///
    /// There is no ordering to choose. The DAG semantic is forward dataflow,
    /// so both edges are forced by the declarations themselves and no
    /// `runs_before` exists to break the tie; the only outcome is refusal.
    ///
    /// `computeLevels` returns it too, as a backstop on an invariant
    /// registration maintains — so `dispatchFrame` and `topologicalLevels`
    /// can surface it. A reader who meets it there should NOT look for a
    /// declaration just made: it means the phase's DAG holds a cycle nothing
    /// refused, which is a defect in the scheduler and not in the caller.
    DependencyCycle,
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
    /// in the same phase, then checks that the new edges close no
    /// cycle. Returns `error.WriteWriteConflict` or
    /// `error.DependencyCycle` on a refusal; in either case NOTHING
    /// OF THE SCHEDULER is touched — no descriptor, no edge, no
    /// tracker entry, no command buffer — both checks running ahead
    /// of the commit.
    ///
    /// **The WORLD is not covered by that, and the difference is
    /// real rather than pedantic.** Resolving the accesses calls
    /// `ensureComponentRegistered` for every type the declaration
    /// names, so a refused registration leaves those types present
    /// in the registry. It is benign because that call is idempotent
    /// and monotone — a corrected declaration resolves to the same
    /// ids — and it is stated because a reader who takes "nothing
    /// was mutated" literally would be wrong about the registry.
    ///
    /// `OutOfMemory` splits, and the split is not pedantry. An
    /// allocation that fails BEFORE the commit — resolving the
    /// accesses, or the cycle walk's own scratch — returns with the
    /// scheduler byte-unchanged, like the two refusals. An allocation
    /// that fails INSIDE the commit leaves edges and tracker entries
    /// the `errdefer`s do not all undo, naming an index the rollback
    /// popped, and THAT scheduler is unusable: the next registration's
    /// walk and the next `computeLevels` both index on it out of
    /// bounds. A caller cannot tell the two apart from the error
    /// alone, so the conservative reading is the right one — but the
    /// sentence that said every allocation failure here leaves an
    /// unusable scheduler was false for most of them. The debt is
    /// recorded in `engine-ecs-internals.md`.
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
        // id in the same phase = registration error. No state OF THE
        // SCHEDULER is mutated until we know the system is admissible;
        // the resolution above has already registered the named types
        // in the world's registry, idempotently, and that survives a
        // refusal.
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

        // Third pass — cycle detection, still ahead of the commit.
        //
        // Pass 1 refuses two writers of the SAME id and nothing more. Two
        // systems that CROSS — one declaring `Reads(T), Writes(U)`, the other
        // `Writes(T), Reads(U)` — pass it individually and together force both
        // edges, closing a two-node cycle that no per-component check can see:
        // the cycle is a property of the pair, and pass 1 only ever looks at
        // one id at a time.
        //
        // Left to `computeLevels`, that failure surfaces at the FIRST DISPATCH
        // instead of at the registration that caused it, under an error naming
        // a duplicated write that does not exist, and with the offending
        // descriptor already committed. So it is refused here, where the
        // caller still holds the declaration that is wrong.
        //
        // The walk is a plain reachability over the EXISTING edges, and two
        // properties make that enough. The graph before this registration is
        // acyclic — this check is what keeps it so, from an empty graph
        // onwards — hence any new cycle passes through `new_idx`, and such a
        // cycle is exactly `new_idx → s → … → p → new_idx` for some successor
        // `s` and some predecessor `p`. And a two-colour visited set suffices
        // where `registry.zig`'s `@requires` closure needs three, because the
        // question here is REACHABILITY and not cycle-finding: a diamond is
        // simply a node reached twice, and revisiting it could not change the
        // answer.
        //
        // The acyclicity it rests on holds for a scheduler whose registrations
        // all returned. `registerSystem` is not transactional for itself —
        // `engine-ecs-internals.md` carries that Tier 0 debt, and
        // `forge/sync.zig`'s preflight states the consequence — so a scheduler
        // that has seen an `OutOfMemory` here is unusable, and this invariant
        // is not what rescues it.
        if (incoming.items.len > 0 and outgoing.items.len > 0) {
            const visited = try gpa.alloc(bool, phase.systems.items.len);
            defer gpa.free(visited);
            @memset(visited, false);

            var stack = std.ArrayListUnmanaged(u32).empty;
            defer stack.deinit(gpa);
            for (outgoing.items) |succ| {
                if (visited[succ]) continue;
                visited[succ] = true;
                try stack.append(gpa, succ);
            }
            while (stack.pop()) |node| {
                // Tested on the node itself, which is what catches the
                // two-node case where one system is both predecessor and
                // successor of the new one.
                for (incoming.items) |dep| {
                    if (dep == node) return error.DependencyCycle;
                }
                for (phase.edges.items[node].items) |next| {
                    if (visited[next]) continue;
                    visited[next] = true;
                    try stack.append(gpa, next);
                }
            }
        }

        // Fourth pass — commit. Append the new system, extend edges,
        // record accesses in the tracker, invalidate cached levels.
        try phase.systems.append(gpa, desc);
        errdefer _ = phase.systems.pop();

        // Allocate the per-system command buffer alongside the
        // descriptor. It borrows no world — a buffer that did would hand the
        // system back the unrestricted handle its view withholds — and uses
        // `gpa` as its backing allocator.
        try phase.command_buffers.append(gpa, CommandBuffer.init(gpa));
        errdefer {
            var popped_cb = phase.command_buffers.pop();
            if (popped_cb) |*cb| cb.deinit();
        }

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
            // Drain `.phase`-lifetime event queues at
            // every phase transition (after every phase, including
            // empty ones, so the cadence is invariant to the
            // registered system topology).
            world.event_bus.drainAtBoundary(.phase);
        }
        // End-of-frame drains. The two are collapsed
        // fixed-tick and render into a single dispatch, so `.tick`
        // and `.frame` fire together. Kept distinct so the call
        // sites can diverge later.
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
                    .world_erased = @ptrCast(world),
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
            // End-of-level barrier is implicit — `dispatchBatch`
            // blocks until pending_count reaches zero.
        }

        // Phase-boundary command buffer flush. Iterate
        // systems in **submission order** (the natural order of
        // `phase.systems`), NOT in topological-level order — the
        // contract guarantees deterministic application across
        // re-orderable level layouts. Each per-system flush also
        // drains the previous flush's observer-issued cmds (queued
        // in `world.observer_registry.deferred`) so observers see
        // their effects with one flush-point of latency, never
        // re-entrantly.
        for (phase.command_buffers.items) |*cb| {
            if (cb.commandCount() == 0 and !hasPendingDeferred(&world.observer_registry)) continue;
            try observers_mod.flushWithObservers(cb, world, &world.observer_registry);
        }
    }

    fn hasPendingDeferred(reg: *observers_mod.ObserverRegistry) bool {
        const d = reg.deferred orelse return false;
        return d.commandCount() > 0;
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
                // A CYCLE. `registerSystem` refuses one before committing the
                // declaration that would close it, so on a scheduler whose
                // registrations all returned this is unreachable — and it is
                // still not written `unreachable`, for ONE reason.
                //
                // The invariant is held by a SIBLING function and not by this
                // one: it rests on registration being the only builder of
                // `edges`, which is true today and is the kind of fact a later
                // milestone can take away without this line noticing. An
                // `unreachable` proven somewhere else is a bet on a proof that
                // can move; an error costs a branch that never runs.
                //
                // **A second reason was written here and was FALSE.** It said
                // the branch also covers a scheduler left half-mutated by a
                // registration that failed on `OutOfMemory`. It does not: such
                // a scheduler carries an edge naming an index the rollback
                // popped, and the in-degree count twenty lines above faults on
                // it — `in_degree[target] += 1` with `target == n` — before
                // any level is built. The scenario cannot reach this line, so
                // citing it justified the branch with something the code does
                // not do. Nothing else about the branch changes.
                lvl.deinit(gpa);
                return error.DependencyCycle;
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

test "registerSystem with an explicitly empty declaration lands on level 0" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    var sched = SystemScheduler.init();
    defer sched.deinit(gpa);

    const T = struct {
        fn nop(_: SystemContext) anyerror!void {}
    };

    // `.accesses` is spelled. It used to be omitted, and the field's default
    // supplied the same empty set — which is the value that declares zero
    // conflict with everything and therefore the one an omission must never
    // produce. Written out, an empty set is a claim its author made.
    try sched.registerSystem(gpa, &world, .{
        .phase = .update,
        .name = "a",
        .run = T.nop,
        .accesses = &.{},
    });
    try sched.registerSystem(gpa, &world, .{
        .phase = .update,
        .name = "b",
        .run = T.nop,
        .accesses = &.{},
    });

    const levels = try sched.topologicalLevels(gpa, .update);
    // Two empty declarations share no id → no edges → one level.
    try testing.expectEqual(@as(usize, 1), levels.len);
    try testing.expectEqual(@as(usize, 2), levels[0].system_indices.items.len);
}

test "a described system's view and its DAG edges come from the same declaration" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    var sched = SystemScheduler.init();
    defer sched.deinit(gpa);

    const writer_spec = [_]view_mod.Access{view_mod.Access.writes(world_mod.Transform)};
    const reader_spec = [_]view_mod.Access{view_mod.Access.reads(world_mod.Transform)};

    const Bodies = struct {
        fn write(ctx: SystemContextOf(&writer_spec)) anyerror!void {
            _ = ctx;
        }
        fn read(ctx: SystemContextOf(&reader_spec)) anyerror!void {
            _ = ctx;
        }
    };

    try sched.registerSystem(gpa, &world, SystemDescriptor.of(
        .update,
        "writer",
        &writer_spec,
        Bodies.write,
    ));
    try sched.registerSystem(gpa, &world, SystemDescriptor.of(
        .update,
        "reader",
        &reader_spec,
        Bodies.read,
    ));

    // The edge exists BECAUSE the descriptors were derived from the same
    // specs the two bodies are typed against. Nothing was declared twice, so
    // nothing can disagree: the writer precedes the reader on the DAG.
    const levels = try sched.topologicalLevels(gpa, .update);
    try testing.expectEqual(@as(usize, 2), levels.len);
    try testing.expectEqual(@as(usize, 1), levels[0].system_indices.items.len);
    try testing.expectEqual(@as(u32, 0), levels[0].system_indices.items[0]);
    try testing.expectEqual(@as(u32, 1), levels[1].system_indices.items[0]);

    // And the derived descriptors say what the spec said.
    const registered = sched.systemsInPhase(.update);
    try testing.expectEqual(@as(usize, 1), registered[0].accesses.len);
    try testing.expect(registered[0].accesses[0].kind == .writes);
    try testing.expect(registered[1].accesses[0].kind == .reads);
}

test "a described system's accesses outlive the block that registered it" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    var sched = SystemScheduler.init();
    defer sched.deinit(gpa);

    const spec = [_]view_mod.Access{view_mod.Access.writes(world_mod.Velocity)};
    const Body = struct {
        fn run(ctx: SystemContextOf(&spec)) anyerror!void {
            _ = ctx;
        }
    };

    // Registered from a nested block that RETURNS before the read below.
    // `registerSystem` stores the caller's slice without duplicating it, so an
    // inline `&.{ … }` temporary would leave `type_name` pointing at dead
    // stack here; a derived set is a comptime constant and cannot.
    {
        try sched.registerSystem(gpa, &world, SystemDescriptor.of(
            .post_update,
            "outliver",
            &spec,
            Body.run,
        ));
    }

    const registered = sched.systemsInPhase(.post_update);
    try testing.expectEqualStrings(@typeName(world_mod.Velocity), registered[0].accesses[0].type_name);
}
