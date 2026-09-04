//! ECS hybrid-storage crossover bench (M1.B / G10).
//!
//! **What it measures.** The per-tick cost of one workload — iterate a query
//! containing component `C`, and churn `C` by add/remove — with `C` stored as
//! `.table` and as `.sparse`. The quantity of interest is where one mode
//! becomes cheaper than the other.
//!
//! **REPORTED, NOT GATED, and the reason is not the usual one.** Five sibling
//! benches carry a template saying no envelope is pre-registered because this
//! is a path's first measurement and a bound before a baseline is the failure
//! mode recorded at M1.1.8 — i.e. "a bound comes later". **That is not this
//! bench's reason.** `engine-ecs-internals.md` §2 says a threshold *cannot be
//! engraved* — *"Aucune fréquence de bascule ni aucun pourcentage de population
//! ne peut être gravé ici comme seuil"* — and names this bench as what produces
//! the thresholds instead. So there is no future gate here: the output IS the
//! deliverable, permanently, and a pass threshold would grade an
//! implementation against a number this bench exists to produce.
//!
//! **THE CROSSOVER HAS SIX PARAMETERS AND NO DOCUMENT ENUMERATES THEM.** §2
//! says the crossover depends on *"la taille du composant, du nombre de
//! composants de la query, du nombre d'archétypes, de la taille des chunks et
//! du nombre de workers"* — five — while the sentence it qualifies is about a
//! *switch frequency* and a *population percentage* — two more. Those last two
//! are the crossover's COORDINATES; the other five PARAMETERISE the whole
//! surface. Chunk size is a compile-time constant here and is reported rather
//! than swept.
//!
//! Consequence, and it is the rule this file obeys twice: **every value held
//! fixed is declared at the point it is held.** The crossover is rendered as a
//! surface over (fraction, churn) — and that surface is itself a SLICE of the
//! four-parameter configuration space, so each surface names its configuration
//! and the configurations are swept one parameter at a time from a declared
//! base. A surface silent about what it holds fixed is worse than a curve
//! silent about it, because it looks complete.
//!
//! **TWO COLUMNS, NEVER AVERAGED.** `first` is the first tick a fresh world
//! ever runs; `steady` is the median of the measured window after warm-up. The
//! separation exists because the entity-keyed disjunctive path allocates its
//! map the FIRST time a sparse-driven term appears and reuses it after, and a
//! single figure averaging the two makes that disappear. **The timings alone
//! would not establish it** — they are noisy and a first tick is one sample —
//! so each column also carries an ALLOCATION COUNT (alloc + resize + remap,
//! from `CountingAllocator`), which is exact and which a median cannot blur.
//!
//! **The transportable quantity is the RATIO, not the nanoseconds.** Absolute
//! ns move with machine, build mode and allocator; `table_ns / sparse_ns` per
//! cell is what survives. The realised carrier count is reported per cell too,
//! measured and never assumed.
//!
//! **THE BRACKET IS A VERDICT THIS BENCH OWES.** A sweep in which one mode wins
//! at every cell has measured a BOUND, not a crossing, and the frontier it
//! would report sits at an endpoint of its own axis. Per configuration the
//! output says whether both modes win somewhere inside the swept range, and
//! when they do not it says the crossover is outside it rather than drawing a
//! contour through an extrapolation.
//!
//! ReleaseFast for the absolute ns; the ratio is meaningful in any mode.
//! Writes `bench/results/ecs_hybrid_crossover.md`.

const std = @import("std");
const builtin = @import("builtin");
const weld_core = @import("weld_core");

const World = weld_core.ecs.World;
const EntityId = weld_core.ecs.EntityId;
const ComponentId = weld_core.ecs.ComponentId;
const StorageKind = weld_core.ecs.StorageKind;
const hybrid = weld_core.ecs.hybrid_query;
const Scheduler = weld_core.jobs.scheduler.Scheduler;
const JobBuilder = weld_core.ecs.JobBuilder;
const CountingAllocator = weld_core.testing.alloc_counting.CountingAllocator;

// ─── The declared configuration set ────────────────────────────────────────
//
// `engine-ecs-internals.md` §2 mandates the bench measure "sur les
// configurations de validation". That phrase appears EXACTLY ONCE in the whole
// spec corpus — at the site that invokes it — and is defined nowhere, so the
// set is the bench author's to choose and to DECLARE. It is declared here.

/// One point of the four-parameter configuration space.
const Config = struct {
    /// Component payload in bytes — §2's "taille du composant".
    payload: u16,
    /// How many components the query asks for, `C` included — §2's "nombre de
    /// composants de la query".
    members: u8,
    /// The filler modulus that spreads the population over archetypes — §2's
    /// "nombre d'archétypes". A REQUEST, not a promise: the realised count is
    /// measured off the world and reported per cell, because the carrier /
    /// non-carrier split multiplies it and four filler types cap it.
    archetypes: u16,
    /// Worker count — §2's "nombre de workers". Measurable at all only since
    /// M1.B/G10's B1: before it, no dense range reached a worker, so this axis
    /// would have varied the table arm alone and reported the sparse mode
    /// losing for a reason that is not storage.
    workers: u8,
    label: []const u8,
};

const base_config: Config = .{ .payload = 16, .members = 2, .archetypes = 4, .workers = 1, .label = "base" };

/// ONE PARAMETER AT A TIME from the base, and that is a declared limitation
/// rather than an oversight: a full cross of four parameters is 81 surfaces
/// whose reading no one would attempt, and "across" in the frozen brief admits
/// this reading. What it costs is any interaction between two parameters, which
/// is named here and not measured.
const configs = [_]Config{
    base_config,
    .{ .payload = 4, .members = 2, .archetypes = 4, .workers = 1, .label = "payload=4B" },
    .{ .payload = 64, .members = 2, .archetypes = 4, .workers = 1, .label = "payload=64B" },
    .{ .payload = 16, .members = 1, .archetypes = 4, .workers = 1, .label = "members=1" },
    .{ .payload = 16, .members = 4, .archetypes = 4, .workers = 1, .label = "members=4" },
    .{ .payload = 16, .members = 2, .archetypes = 1, .workers = 1, .label = "spread=1" },
    .{ .payload = 16, .members = 2, .archetypes = 2, .workers = 1, .label = "spread=2" },
    .{ .payload = 16, .members = 2, .archetypes = 4, .workers = 2, .label = "workers=2" },
    .{ .payload = 16, .members = 2, .archetypes = 4, .workers = 4, .label = "workers=4" },
};

/// LOGARITHMIC on purpose. The retracted `etch-reference-part3.md` figure was
/// "moins de 5 % des entités", so the interesting region is fractions of a
/// percent to a few percent; a linear grid from 0.1 to 1.0 would put ZERO
/// samples where the crossing plausibly lives and then render a contour by
/// interpolating across a decade. The corpus already records that failure in
/// another form — a probe whose step, sized as a fraction of the coordinate,
/// was coarser than the band it was probing.
const fractions = [_]f64{ 0.001, 0.003, 0.01, 0.03, 0.1, 0.3, 1.0 };

/// Add/remove events per carrier per second, the quantity the retracted
/// "plus de ~10× par seconde par entité" measured. 0 is a real regime (a
/// component that never moves) and 60 is one event per tick at 60 Hz.
const churns = [_]u32{ 0, 1, 10, 60 };

const n_entities: u32 = 20_000;
const warmup_ticks: u32 = 30;
const measured_ticks: u32 = 60;
const range_target: usize = 64;

/// `engine-ecs-internals.md` §2 lists chunk size among the five parameters the
/// crossover depends on. It is a compile-time constant, so it is REPORTED and
/// not swept — sweeping it would need a rebuild per value, which is a different
/// instrument.
const chunk_bytes: usize = 16 * 1024;

// ─── The measured types ────────────────────────────────────────────────────
//
// THE TWO ARMS USE DIFFERENT ITERATION PROTOCOLS, AND THAT IS NOT A CONFOUND —
// it is what each mode gives its user, and the bench would be dishonest the
// other way round. Measured: `registerComponent(T)` delegates to
// `registerComponentRaw` WITHOUT passing `.storage`, so a comptime Zig type is
// always `.table`; and `DynamicQuery` offers neither `chunkAt` nor
// `chunkCount`, so a dynamically registered component has no dispatch entry at
// all. `ARCH-005` posits archetype SoA WITH COMPTIME QUERIES as the default and
// the sparse set as opt-in, so the comptime query IS the table mode's protocol
// and `SparseDrivenQuery` is the sparse mode's. Comparing them compares the
// modes as they are actually used.
//
// The alternative — giving `DynamicQuery` a chunk protocol — is foreclosed by
// the frozen Scope, which limits `query.zig` to "header comment only: no
// signature change, no behaviour change".

/// Payload variants. A distinct Zig type per size, because the table arm needs
/// a type and the payload size is one of the four swept parameters.
const P4 = extern struct { b: [4]u8 = @splat(0) };
const P16 = extern struct { b: [16]u8 = @splat(0) };
const P64 = extern struct { b: [64]u8 = @splat(0) };

/// Extra query members. Distinct types, same shape: what the axis varies is
/// how many components the query asks for, not what they hold.
const M1 = extern struct { v: u32 = 0 };
const M2 = extern struct { v: u32 = 0 };
const M3 = extern struct { v: u32 = 0 };

/// Archetype spread. An entity carrying `Fi` and not `Fj` lands in a different
/// archetype, which is how the population is spread over `config.archetypes`
/// of them without changing the query.
const F0 = extern struct { v: u8 = 0 };
const F1 = extern struct { v: u8 = 0 };
const F2 = extern struct { v: u8 = 0 };
const F3 = extern struct { v: u8 = 0 };

/// The table arm's component list for `c` — the payload plus `c.members - 1`
/// extras.
fn tableTypes(comptime c: Config) []const type {
    const Pay = switch (c.payload) {
        4 => P4,
        16 => P16,
        64 => P64,
        else => @compileError("unswept payload size"),
    };
    return switch (c.members) {
        1 => &.{Pay},
        2 => &.{ Pay, M1 },
        4 => &.{ Pay, M1, M2, M3 },
        else => @compileError("unswept member count"),
    };
}

// ─── One measured cell ─────────────────────────────────────────────────────

/// What one (config, fraction, churn, mode) cell reports.
///
/// `first_ns` and `steady_ns` are NEVER averaged into one figure, and each
/// carries its own allocation count — the exact quantity a median cannot blur,
/// and the only one that can establish a first-occurrence cost from a single
/// sample.
const Cell = struct {
    /// Non-zero when the job system REFUSED this cell's wave: the chunk count
    /// at the refusal. Not a bench limitation — a measured engine behaviour,
    /// reported and excluded from the bracket rather than skipped in silence.
    overflow_chunks: usize = 0,
    carriers: u32,
    first_ns: u64,
    first_allocs: u64,
    steady_ns: u64,
    steady_allocs: u64,
};

/// alloc + resize_ok + remap — the three the repository has recorded as
/// necessary together: counting `alloc` alone reads zero for a list that grew,
/// because `ArrayListUnmanaged` tries `remap` first.
fn allocOps(d: CountingAllocator.Snapshot) u64 {
    return d.alloc_count + d.resize_ok_count + d.remap_count;
}

fn medianOf(samples: []u64) u64 {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    return samples[samples.len / 2];
}

fn carriersFor(fraction: f64) u32 {
    const n: f64 = @floatFromInt(n_entities);
    const c: u32 = @intFromFloat(@round(fraction * n));
    return @max(c, 1);
}

/// Churn events per tick, from a per-carrier-per-second rate at 60 Hz.
fn churnPerTick(carriers: u32, churn: u32) u32 {
    if (churn == 0) return 0;
    const total = @as(u64, carriers) * @as(u64, churn);
    return @intCast(@max(@as(u64, 1), total / 60));
}

// ─── The dispatched bodies ─────────────────────────────────────────────────
//
// Both sum the SAME bytes over the SAME carriers, so the checksum is an
// equivalence oracle across the two arms as well as an anti-DCE fold: a cell
// whose two arms disagree measured two different workloads.

/// TWO quantities, because only one of them is comparable across the arms.
///
/// `bytes` is the anti-DCE fold and is NOT an inter-arm oracle: the table arm's
/// payload is `Pay{}`'s default zeros and the sparse arm's is written by
/// `addComponentDynamic`, so the two sums have no reason to agree and making
/// them agree would mean fudging one side's data. `visits` IS comparable and
/// carries the real equivalence claim — both arms visited the same entities —
/// and doubles as the non-vacuity guard a timing cannot give.
const Probe = struct {
    bytes: std.atomic.Value(u64) = .init(0),
    visits: std.atomic.Value(u64) = .init(0),
};

fn tableBody(chunk: *weld_core.ecs.Chunk, payload_off: u16, elem_size: u16, probe: *Probe) void {
    const count = chunk.entityCount();
    var local: u64 = 0;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const base = @as(usize, payload_off) + @as(usize, i) * @as(usize, elem_size);
        local +%= chunk.bytes[base];
    }
    _ = probe.bytes.fetchAdd(local, .monotonic);
    _ = probe.visits.fetchAdd(count, .monotonic);
}

fn sparseBody(r: hybrid.DenseRange, rows: []const u8, elem_size: u16, probe: *Probe) void {
    var local: u64 = 0;
    for (r.from..r.to) |i| {
        local +%= rows[i * @as(usize, elem_size)];
    }
    _ = probe.bytes.fetchAdd(local, .monotonic);
    _ = probe.visits.fetchAdd(r.len(), .monotonic);
}

// ─── The table arm ─────────────────────────────────────────────────────────

/// Register the four archetype-splitting fillers by NAME.
///
/// `registerComponentRaw` is the public path; `World.ensureRegistered` is NOT
/// `pub` (measured, `world.zig:567`), so a bench cannot resolve a comptime
/// type's id directly. For the table arm's MEMBERS that is solved by building
/// the comptime query first and reading its `required_ids` — the query is what
/// registers them. The fillers are not query members, so they take the raw path.
fn registerFillers(gpa: std.mem.Allocator, world: *World, out: *[4]ComponentId) !void {
    const zero = [_]u8{0};
    inline for (0..4) |k| {
        out[k] = try world.registry.registerComponentRaw(gpa, .{
            .name = "BenchFiller" ++ .{'0' + @as(u8, k)},
            .size = 1,
            .alignment = 1,
            .default_bytes = &zero,
            .fields = &.{},
            .storage = .table,
        });
    }
}

/// The sparse arm's measured component, registered by NAME so `.storage` can be
/// `.sparse` — the only path there, `registerComponent(T)` passing no storage.
fn registerSparsePayload(gpa: std.mem.Allocator, world: *World, payload: u16) !ComponentId {
    const zeros: [64]u8 = @splat(0);
    return world.registry.registerComponentRaw(gpa, .{
        .name = "BenchSparsePayload",
        .size = payload,
        .alignment = 4,
        .default_bytes = zeros[0..payload],
        .fields = &.{},
        .storage = .sparse,
    });
}

/// The sparse arm's non-measured members, by name and of the same count and
/// size as the table arm's extras.
///
/// They are DIFFERENT component ids from the table arm's `M1`/`M2`/`M3`, which
/// is stated rather than hidden: what the member-count axis varies is how many
/// components the query asks for and how wide an archetype's row is, and both
/// are identical here. Making them the same ids would require the sparse arm to
/// build a comptime query it has no other use for.
fn registerSparseExtras(gpa: std.mem.Allocator, world: *World, count: u8, out: *[3]ComponentId) !void {
    const zero = [_]u8{ 0, 0, 0, 0 };
    var k: u8 = 0;
    while (k < count) : (k += 1) {
        out[k] = try world.registry.registerComponentRaw(gpa, .{
            .name = switch (k) {
                0 => "BenchExtra0",
                1 => "BenchExtra1",
                else => "BenchExtra2",
            },
            .size = 4,
            .alignment = 4,
            .default_bytes = &zero,
            .fields = &.{},
            .storage = .table,
        });
    }
}

/// Spawn `n_entities`, the first `carriers` of them carrying `member_ids[0]`.
///
/// One builder for both arms: the arms differ in WHICH ids they pass, never in
/// how the population is shaped, so a difference in shape cannot creep in
/// between two copies of this loop.
fn buildWorld(
    gpa: std.mem.Allocator,
    world: *World,
    spread: u16,
    carriers: u32,
    payload_id: ?ComponentId,
    other_ids: []const ComponentId,
    fillers: []const ComponentId,
    sparse_payload: ?struct { id: ComponentId, size: u16 },
    carrier_out: []EntityId,
) !void {
    std.debug.assert(carrier_out.len == carriers);
    const payload_bytes: [64]u8 = @splat(1);
    var ids_buf: [8]ComponentId = undefined;
    var i: u32 = 0;
    var next: u32 = 0;
    while (i < n_entities) : (i += 1) {
        const carries = i < carriers;
        var n: usize = 0;
        if (carries) if (payload_id) |pid| {
            ids_buf[n] = pid;
            n += 1;
        };
        for (other_ids) |cid| {
            ids_buf[n] = cid;
            n += 1;
        }
        ids_buf[n] = fillers[(i % spread) % fillers.len];
        n += 1;
        const e = try world.spawnDynamic(gpa, ids_buf[0..n]);
        if (carries) {
            if (sparse_payload) |sp| {
                try world.addComponentDynamic(gpa, e, sp.id, payload_bytes[0..sp.size]);
            }
            carrier_out[next] = e;
            next += 1;
        }
    }
    std.debug.assert(next == carriers);
}

// ─── The two arms, structurally parallel ───────────────────────────────────
//
// Each arm exposes `iterate` and `churn` and NOTHING else, and one shared
// `tick` drives both. That is deliberate: a measurement loop written twice can
// favour one arm by an accident of where its clock reads sit, and this one
// cannot, because there is only one loop.

fn tick(comptime Arm: type, arm: *Arm, tick_no: u32) !void {
    try arm.iterate();
    try arm.churn(tick_no);
}

/// Table arm — the comptime query, which is the table mode's own protocol.
fn TableArm(comptime c: Config) type {
    const Types = tableTypes(c);
    return struct {
        const Self = @This();
        const QueryT = weld_core.ecs.query.Query(Types, .{});

        world: *World,
        gpa: std.mem.Allocator,
        q: *QueryT,
        builder: *JobBuilder,
        sched: *Scheduler,
        pay_id: ComponentId,
        payload_off: u16,
        elem_size: u16,
        probe: *Probe,
        handles: []const EntityId,
        ops: u32,
        cursor: u32 = 0,
        /// The job count at the FIRST tick and the largest ever staged —
        /// MEASURED, and the pair is what discriminates: the chunk count is
        /// what `TooManyChunks` reports on, and "there were always this many"
        /// and "the churn grew them" are different facts that one figure
        /// cannot separate.
        first_jobs: usize = 0,
        max_jobs: usize = 0,

        fn iterate(self: *Self) !void {
            self.builder.reset();
            try self.builder.addJob(self.q, tableBody, .{ self.payload_off, self.elem_size, self.probe });
            const n = self.builder.jobs.items.len;
            if (self.first_jobs == 0) self.first_jobs = n;
            if (n > self.max_jobs) self.max_jobs = n;
            if (n > 0) self.sched.dispatchBatch(self.builder.jobs.items) catch |err| {
                std.debug.print(
                    "[chunks: first {d}, now {d}; archetypes {d}] ",
                    .{ self.first_jobs, n, self.world.archetypes.items.len },
                );
                return err;
            };
        }

        /// Remove then re-add the measured component, which for the table mode
        /// is two archetype migrations and for the sparse mode two O(1) swaps —
        /// the comparison §2 describes. The carrier COUNT is unchanged by
        /// construction, so the fraction stays the axis value it claims.
        fn churn(self: *Self, tick_no: u32) !void {
            _ = tick_no;
            if (self.ops == 0 or self.handles.len == 0) return;
            var k: u32 = 0;
            var payload: [64]u8 = @splat(1);
            while (k < self.ops) : (k += 1) {
                const e = self.handles[(self.cursor + k) % self.handles.len];
                try self.world.removeComponentDynamic(self.gpa, e, self.pay_id);
                try self.world.addComponentDynamic(self.gpa, e, self.pay_id, payload[0..c.payload]);
            }
            self.cursor = (self.cursor +% self.ops) % @as(u32, @intCast(self.handles.len));
        }
    };
}

/// Sparse arm — `SparseDrivenQuery` and the dense-range dispatch M1.B/G10 B1
/// delivered. Without B1 this arm could not dispatch at all and the worker
/// column would have been empty by construction.
fn SparseArm(comptime c: Config) type {
    return struct {
        const Self = @This();

        world: *World,
        gpa: std.mem.Allocator,
        q: *hybrid.SparseDrivenQuery,
        builder: *JobBuilder,
        sched: *Scheduler,
        pay_id: ComponentId,
        elem_size: u16,
        probe: *Probe,
        handles: []const EntityId,
        ops: u32,
        cursor: u32 = 0,
        first_jobs: usize = 0,
        max_jobs: usize = 0,

        fn iterate(self: *Self) !void {
            self.builder.reset();
            const store = self.world.sparse_stores.getConst(self.pay_id) orelse return;
            const rows = store.rows orelse return;
            try self.builder.addDenseRangeJobs(
                self.world,
                self.q,
                range_target,
                sparseBody,
                .{ rows, self.elem_size, self.probe },
            );
            const n = self.builder.jobs.items.len;
            if (self.first_jobs == 0) self.first_jobs = n;
            if (n > self.max_jobs) self.max_jobs = n;
            if (n > 0) try self.sched.dispatchBatch(self.builder.jobs.items);
        }

        fn churn(self: *Self, tick_no: u32) !void {
            _ = tick_no;
            if (self.ops == 0 or self.handles.len == 0) return;
            var k: u32 = 0;
            var payload: [64]u8 = @splat(1);
            while (k < self.ops) : (k += 1) {
                const e = self.handles[(self.cursor + k) % self.handles.len];
                try self.world.removeComponentDynamic(self.gpa, e, self.pay_id);
                try self.world.addComponentDynamic(self.gpa, e, self.pay_id, payload[0..c.payload]);
            }
            self.cursor = (self.cursor +% self.ops) % @as(u32, @intCast(self.handles.len));
        }
    };
}

// ─── Measurement ───────────────────────────────────────────────────────────

const ArmResult = struct {
    cell: Cell,
    archetypes: usize,
    checksum: u64,
    visits: u64,
    first_jobs: usize = 0,
    max_jobs: usize = 0,
};

/// The first/warmup/steady loop, written ONCE and shared by both arms — see the
/// note above `tick`.
fn runArm(
    comptime Arm: type,
    arm: *Arm,
    counting: *CountingAllocator,
    io: std.Io,
    gpa: std.mem.Allocator,
    carriers: u32,
) !Cell {
    // FIRST — the first tick this world ever runs, no warm-up of any kind. Five
    // sibling benches run one untimed warm-up pass per mode, with the reason
    // written at the site that construction must not land in a timing window;
    // that convention is precisely what makes a first-occurrence column
    // impossible, so it is deliberately NOT followed here.
    const first_before = counting.snapshot();
    const t0 = std.Io.Clock.now(.awake, io);
    try tick(Arm, arm, 0);
    const t1 = std.Io.Clock.now(.awake, io);
    const first_after = counting.snapshot();

    // A REFUSED WAVE IS A RESULT, NOT A CRASH. `dispatchBatch` returns
    // `TooManyChunks` when the wave exceeds `workers x 8192`, and under
    // sustained churn the table arm's chunk count reaches it — measured, and
    // the growth is churn-driven rather than initial. The cell is recorded with
    // the chunk count and excluded from the bracket; dying here would lose the
    // finding, and skipping in silence would report a grid that looks complete.
    var w: u32 = 0;
    while (w < warmup_ticks) : (w += 1) {
        tick(Arm, arm, w + 1) catch |err| switch (err) {
            error.TooManyChunks => return .{
                .overflow_chunks = arm.max_jobs,
                .carriers = carriers,
                .first_ns = @intCast(@max(@as(i96, 0), t0.durationTo(t1).nanoseconds)),
                .first_allocs = allocOps(CountingAllocator.delta(first_after, first_before)),
                .steady_ns = 0,
                .steady_allocs = 0,
            },
            else => return err,
        };
    }

    const samples = try gpa.alloc(u64, measured_ticks);
    defer gpa.free(samples);
    const steady_before = counting.snapshot();
    var m: u32 = 0;
    while (m < measured_ticks) : (m += 1) {
        const a = std.Io.Clock.now(.awake, io);
        tick(Arm, arm, warmup_ticks + m + 1) catch |err| switch (err) {
            error.TooManyChunks => return .{
                .overflow_chunks = arm.max_jobs,
                .carriers = carriers,
                .first_ns = @intCast(@max(@as(i96, 0), t0.durationTo(t1).nanoseconds)),
                .first_allocs = allocOps(CountingAllocator.delta(first_after, first_before)),
                .steady_ns = 0,
                .steady_allocs = 0,
            },
            else => return err,
        };
        const b = std.Io.Clock.now(.awake, io);
        samples[m] = @intCast(@max(@as(i96, 0), a.durationTo(b).nanoseconds));
    }
    const steady_after = counting.snapshot();

    return .{
        .overflow_chunks = 0,
        .carriers = carriers,
        .first_ns = @intCast(@max(@as(i96, 0), t0.durationTo(t1).nanoseconds)),
        .first_allocs = allocOps(CountingAllocator.delta(first_after, first_before)),
        .steady_ns = medianOf(samples),
        .steady_allocs = allocOps(CountingAllocator.delta(steady_after, steady_before)),
    };
}

fn measureTable(
    comptime c: Config,
    gpa: std.mem.Allocator,
    counting: *CountingAllocator,
    io: std.Io,
    fraction: f64,
    churn: u32,
) !ArmResult {
    const carriers = carriersFor(fraction);
    const handles = try gpa.alloc(EntityId, carriers);
    defer gpa.free(handles);

    var world = World.init();
    defer world.deinit(gpa);

    // THE QUERY IS BUILT FIRST, and that is what registers the comptime types:
    // `ensureRegistered` is not `pub`, so `q.required_ids` is the only public
    // way to learn a comptime type's id. The archetypes appear AFTER, which
    // option-β's lazy tail rescan is exactly for.
    var q = try world.queryFiltered(gpa, comptime tableTypes(c), .{});
    defer q.deinit(gpa);
    const pay_id = q.required_ids[0];

    var fillers: [4]ComponentId = undefined;
    try registerFillers(gpa, &world, &fillers);
    try buildWorld(gpa, &world, c.archetypes, carriers, pay_id, q.required_ids[1..], &fillers, null, handles);

    // The payload column's offset, resolved once — a body cannot find it for
    // itself, exactly as the C0.1 bench's `integrateChunk` cannot.
    //
    // **That bench caches ONE offset and says why it may: "single-archetype
    // query, so `componentOffsetFor` on any chunk returns the same value". This
    // bench sweeps the archetype spread, so that reason does not carry.** The
    // offset happens to be uniform here — the payload registers first, so its
    // id is the lowest in every carrier archetype's sorted component list — but
    // that is a CHAIN OF INFERENCE about registration order, and this file does
    // not ship one: the uniformity is CHECKED over every matched chunk and the
    // bench fails loudly rather than summing the wrong bytes.
    const n_chunks = q.chunkCount();
    if (n_chunks == 0) return error.QueryMatchedNothing;
    const payload_off = q.componentOffsetFor(q.chunkAt(0), 0);
    for (1..n_chunks) |ci| {
        if (q.componentOffsetFor(q.chunkAt(ci), 0) != payload_off) return error.NonUniformColumnOffset;
    }
    const elem_size: u16 = world.registry.entries.items[pay_id].desc.size;

    var sched = try Scheduler.initWithWorkerCount(gpa, io, c.workers);
    try sched.start();
    defer sched.deinit(gpa);
    var builder = JobBuilder.init(gpa);
    defer builder.deinit();
    var probe: Probe = .{};

    const ArmT = TableArm(c);
    var arm: ArmT = .{
        .world = &world,
        .gpa = gpa,
        .q = &q,
        .builder = &builder,
        .sched = &sched,
        .pay_id = pay_id,
        .payload_off = payload_off,
        .elem_size = elem_size,
        .probe = &probe,
        .handles = handles,
        .ops = churnPerTick(carriers, churn),
    };
    const cell = try runArm(ArmT, &arm, counting, io, gpa, carriers);
    return .{
        .cell = cell,
        .archetypes = world.archetypes.items.len,
        .checksum = probe.bytes.load(.monotonic),
        .visits = probe.visits.load(.monotonic),
        .first_jobs = arm.first_jobs,
        .max_jobs = arm.max_jobs,
    };
}

fn measureSparse(
    comptime c: Config,
    gpa: std.mem.Allocator,
    counting: *CountingAllocator,
    io: std.Io,
    fraction: f64,
    churn: u32,
) !ArmResult {
    const carriers = carriersFor(fraction);
    const handles = try gpa.alloc(EntityId, carriers);
    defer gpa.free(handles);

    var world = World.init();
    defer world.deinit(gpa);
    const pay_id = try registerSparsePayload(gpa, &world, c.payload);
    // NON-VACUITY: without this a cell could be measuring a TABLE component
    // under a sparse label, and every column would agree with itself.
    if (world.storageOf(pay_id) != .sparse) return error.PayloadNotSparse;

    var extras: [3]ComponentId = undefined;
    try registerSparseExtras(gpa, &world, c.members - 1, &extras);
    var fillers: [4]ComponentId = undefined;
    try registerFillers(gpa, &world, &fillers);
    try buildWorld(
        gpa,
        &world,
        c.archetypes,
        carriers,
        null,
        extras[0 .. c.members - 1],
        &fillers,
        .{ .id = pay_id, .size = c.payload },
        handles,
    );

    var q = try hybrid.planSparseDriven(gpa, pay_id, &.{pay_id}, &.{});
    defer q.deinit(gpa);

    var sched = try Scheduler.initWithWorkerCount(gpa, io, c.workers);
    try sched.start();
    defer sched.deinit(gpa);
    var builder = JobBuilder.init(gpa);
    defer builder.deinit();
    var probe: Probe = .{};

    const ArmT = SparseArm(c);
    var arm: ArmT = .{
        .world = &world,
        .gpa = gpa,
        .q = &q,
        .builder = &builder,
        .sched = &sched,
        .pay_id = pay_id,
        .elem_size = c.payload,
        .probe = &probe,
        .handles = handles,
        .ops = churnPerTick(carriers, churn),
    };
    const cell = try runArm(ArmT, &arm, counting, io, gpa, carriers);
    return .{
        .cell = cell,
        .archetypes = world.archetypes.items.len,
        .checksum = probe.bytes.load(.monotonic),
        .visits = probe.visits.load(.monotonic),
        .first_jobs = arm.first_jobs,
        .max_jobs = arm.max_jobs,
    };
}

// ─── The sweep ─────────────────────────────────────────────────────────────

const CellPair = struct {
    table: ArmResult,
    sparse: ArmResult,
};

/// Whether a configuration's grid BRACKETS the crossover — both modes winning
/// somewhere inside the swept range.
///
/// A sweep in which one mode wins at every cell has measured a BOUND, not a
/// crossing, and any frontier drawn through it sits at an endpoint of its own
/// axis. That verdict is reported per configuration instead of a contour, which
/// is the difference between saying where the crossover is and saying it is
/// somewhere outside what was looked at.
const Bracket = struct {
    both_win: bool,
    excluded: usize,
    compared: usize,
};

fn bracketed(grid: []const CellPair) Bracket {
    var table_wins = false;
    var sparse_wins = false;
    var excluded: usize = 0;
    var compared: usize = 0;
    for (grid) |p| {
        if (p.table.cell.overflow_chunks != 0 or p.sparse.cell.overflow_chunks != 0) {
            excluded += 1;
            continue;
        }
        compared += 1;
        if (p.table.cell.steady_ns < p.sparse.cell.steady_ns) table_wins = true;
        if (p.sparse.cell.steady_ns < p.table.cell.steady_ns) sparse_wins = true;
    }
    return .{ .both_win = table_wins and sparse_wins, .excluded = excluded, .compared = compared };
}

fn ratio(a: u64, b: u64) f64 {
    if (b == 0) return 0;
    return @as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(b));
}

pub fn main(init: std.process.Init) !void {
    // `safety` FORCED true: its default is `std.debug.runtime_safety`, false in
    // ReleaseFast, which is the mode this bench runs in — a default-configured
    // checker reports "no leaks" unconditionally there, which is not a weaker
    // check but one that cannot fail.
    var debug_allocator: std.heap.DebugAllocator(.{ .safety = true }) = .init;
    var counting = CountingAllocator.init(debug_allocator.allocator());
    const gpa = counting.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var smoke = false;
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--smoke")) smoke = true;
    }

    // One (fraction, churn) cell of one configuration, so CI's compile-and-run
    // path exercises every code path without paying the full sweep.
    const n_fr: usize = if (smoke) 1 else fractions.len;
    const n_ch: usize = if (smoke) 1 else churns.len;

    var grids: [configs.len][fractions.len][churns.len]CellPair = undefined;

    inline for (configs, 0..) |c, ci| {
        for (fractions[0..n_fr], 0..) |f, fi| {
            for (churns[0..n_ch], 0..) |ch, chi| {
                std.debug.print("  {s} f={d:.3} churn={d} ... ", .{ c.label, f, ch });
                const t = measureTable(c, gpa, &counting, io, f, ch) catch |err| {
                    std.debug.print("TABLE {s}\n", .{@errorName(err)});
                    return err;
                };
                const s = measureSparse(c, gpa, &counting, io, f, ch) catch |err| {
                    std.debug.print("SPARSE {s}\n", .{@errorName(err)});
                    return err;
                };
                std.debug.print("T {d} ns / S {d} ns\n", .{ t.cell.steady_ns, s.cell.steady_ns });
                // THE INTER-ARM ORACLE, and it is what makes a ratio meaningful:
                // a cell whose arms visited different entity counts measured two
                // different workloads and its ratio compares nothing.
                // The inter-arm oracle applies only where BOTH arms ran to
                // completion: an overflowed arm stopped mid-window by
                // construction, so a visit-count comparison there would fire on
                // the refusal rather than on a disagreement.
                if (t.cell.overflow_chunks == 0 and s.cell.overflow_chunks == 0) {
                    if (t.visits != s.visits) return error.ArmsDisagreeOnVisitedCount;
                    const expect = @as(u64, t.cell.carriers) * @as(u64, 1 + warmup_ticks + measured_ticks);
                    if (t.visits != expect) return error.VisitedCountNotTheCarrierSet;
                }
                grids[ci][fi][chi] = .{ .table = t, .sparse = s };
            }
        }
    }

    try writeReport(io, gpa, &grids, n_fr, n_ch, smoke);

    std.debug.print("\n  (reported, not gated — the owning spec refuses to engrave a threshold)\n", .{});
    const leaked = debug_allocator.deinit();
    if (leaked == .leak) {
        std.debug.print("  LEAK DETECTED: the bench leaked memory (see the trace above)\n", .{});
    } else {
        std.debug.print("  allocator: no leaks (safety forced true)\n", .{});
    }
}

// ─── The report ────────────────────────────────────────────────────────────

fn writeReport(
    io: std.Io,
    gpa: std.mem.Allocator,
    grids: *const [configs.len][fractions.len][churns.len]CellPair,
    n_fr: usize,
    n_ch: usize,
    smoke: bool,
) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    try buf.print(gpa,
        \\# ECS hybrid-storage crossover — M1.B / G10
        \\
        \\**REPORTED, NOT GATED, and permanently so.** `engine-ecs-internals.md` §2 states that no
        \\switch frequency and no population percentage can be engraved as a threshold, and names
        \\this bench as what produces them instead. There is no future gate here: the output IS the
        \\deliverable. A pass threshold would grade an implementation against a number this bench
        \\exists to produce.
        \\
        \\**Build mode:** {s} · **entities:** {d} · **ticks:** 1 first + {d} warm-up + {d} measured
        \\· **chunk size:** {d} B (a compile-time constant — §2 lists it among the parameters the
        \\crossover depends on, and it is reported rather than swept because sweeping it needs a
        \\rebuild per value) · **range target:** {d}{s}
        \\
        \\## What this measures, and what it holds fixed
        \\
        \\The per-tick cost of one workload — iterate a query containing component `C`, then churn
        \\`C` by remove-then-re-add — with `C` stored as `.table` and as `.sparse`.
        \\
        \\**The crossover has SIX parameters and no single document enumerates them.** §2 says it
        \\depends on component size, query member count, archetype count, chunk size and worker
        \\count — five — while the sentence it qualifies is about a switch frequency and a population
        \\percentage, which are the crossover's two COORDINATES. So the surface below is drawn over
        \\(fraction, churn) and is itself **a slice** of the four-parameter configuration space; each
        \\table names its configuration, and the configurations are swept ONE PARAMETER AT A TIME
        \\from a declared base. What that costs is any interaction between two parameters, which is
        \\named here and not measured.
        \\
        \\**The two arms use different iteration protocols, and that is not a confound.** Measured:
        \\`registerComponent(T)` passes no `.storage`, so a comptime Zig type is always `.table`;
        \\and `DynamicQuery` offers neither `chunkAt` nor `chunkCount`, so a dynamically registered
        \\component has no dispatch entry. `ARCH-005` posits archetype SoA *with comptime queries*
        \\as the default and the sparse set as opt-in, so the comptime query IS the table mode's
        \\protocol and `SparseDrivenQuery` is the sparse mode's. Comparing them compares the modes
        \\as they are used.
        \\
        \\**The transportable quantity is the RATIO.** Absolute nanoseconds move with machine, build
        \\mode and allocator; `table/sparse` per cell is what survives. A ratio **above 1** means the
        \\sparse mode is faster.
        \\
        \\**Two columns, never averaged, and the allocation count is what establishes the first.**
        \\`first` is the first tick a fresh world ever runs — no warm-up of any kind, deliberately
        \\against the house convention, which exists to keep construction out of a timing window and
        \\is exactly what makes a first-occurrence column impossible. A single timing sample proves
        \\little, so each column carries `alloc + resize + remap` from a `CountingAllocator`, which
        \\is exact and which a median cannot blur.
        \\
        \\**The realised carrier and archetype counts are measured, never assumed** — `spread` is a
        \\filler modulus and a REQUEST, and the carrier/non-carrier split multiplies it.
        \\
        \\**A `DISPATCH FAILED` CELL IS NOT A SLOW CELL, AND THE FRONTIER MUST NOT BE READ THROUGH IT.**
        \\At high churn the table arm does not lose on time — it stops dispatching: `dispatchBatch`
        \\returns `TooManyChunks` once the wave exceeds `workers x 8192`, and the arm produces no
        \\answer at all. A table of times against churn that runs a contour through such a cell would
        \\read as a smooth trade-off, and it is not one; the ratio column reads `n/a` rather than a
        \\number for exactly that reason. Those cells are excluded from the bracket and counted in
        \\its line. The mechanism is upstream of this bench and named in the milestone's debt: chunk
        \\compaction is INTRA-chunk only and `archetype.zig` releases no chunk, so the count follows
        \\the cumulative number of adds and never the live population.
        \\
        \\
    , .{
        @tagName(builtin.mode),
        n_entities,
        warmup_ticks,
        measured_ticks,
        chunk_bytes,
        range_target,
        if (smoke) " · **SMOKE RUN — one cell per configuration, not a sweep**" else "",
    });

    inline for (configs, 0..) |c, ci| {
        var flat: [fractions.len * churns.len]CellPair = undefined;
        var n_flat: usize = 0;
        for (0..n_fr) |fi| for (0..n_ch) |chi| {
            flat[n_flat] = grids[ci][fi][chi];
            n_flat += 1;
        };
        const br = bracketed(flat[0..n_flat]);

        try buf.print(gpa,
            \\### `{s}` — payload {d} B, {d} query member(s), spread {d}, {d} worker(s)
            \\
            \\**Bracket over {d} compared cell(s), {d} excluded for a refused wave: {s}**
            \\
            \\| fraction | churn/s | carriers | archetypes T/S | chunks/ranges T first-max / S | first T/S (ns) | first allocs T/S | steady T/S (ns) | ratio T/S |
            \\|---|---|---|---|---|---|---|---|---|
            \\
        , .{
            c.label,
            c.payload,
            c.members,
            c.archetypes,
            c.workers,
            br.compared,
            br.excluded,
            if (br.both_win)
                "both modes win somewhere inside the swept range, so the crossover is INSIDE it"
            else
                "ONE MODE WINS AT EVERY COMPARED CELL — this grid measured a BOUND, not a crossing, and the crossover is OUTSIDE the swept range. No contour is drawn from it",
        });

        for (fractions[0..n_fr], 0..) |f, fi| {
            for (churns[0..n_ch], 0..) |ch, chi| {
                const p = grids[ci][fi][chi];
                const refused = p.table.cell.overflow_chunks != 0 or p.sparse.cell.overflow_chunks != 0;
                if (refused) {
                    // A refused wave has no steady figure, and printing a zero
                    // there would read as "instant" rather than "the job system
                    // declined the wave".
                    try buf.print(gpa, "| {d:.3} | {d} | {d} | {d}/{d} | {d}-{d} / {d}-{d} | {d}/{d} | {d}/{d} | **DISPATCH FAILED** at {d} chunks | n/a |\n", .{
                        f,
                        ch,
                        p.table.cell.carriers,
                        p.table.archetypes,
                        p.sparse.archetypes,
                        p.table.first_jobs,
                        p.table.max_jobs,
                        p.sparse.first_jobs,
                        p.sparse.max_jobs,
                        p.table.cell.first_ns,
                        p.sparse.cell.first_ns,
                        p.table.cell.first_allocs,
                        p.sparse.cell.first_allocs,
                        @max(p.table.cell.overflow_chunks, p.sparse.cell.overflow_chunks),
                    });
                } else {
                    try buf.print(gpa, "| {d:.3} | {d} | {d} | {d}/{d} | {d}-{d} / {d}-{d} | {d}/{d} | {d}/{d} | {d}/{d} | {d:.3} |\n", .{
                        f,
                        ch,
                        p.table.cell.carriers,
                        p.table.archetypes,
                        p.sparse.archetypes,
                        p.table.first_jobs,
                        p.table.max_jobs,
                        p.sparse.first_jobs,
                        p.sparse.max_jobs,
                        p.table.cell.first_ns,
                        p.sparse.cell.first_ns,
                        p.table.cell.first_allocs,
                        p.sparse.cell.first_allocs,
                        p.table.cell.steady_ns,
                        p.sparse.cell.steady_ns,
                        ratio(p.table.cell.steady_ns, p.sparse.cell.steady_ns),
                    });
                }
            }
        }
        try buf.print(gpa, "\n", .{});
    }

    var dir = std.Io.Dir.cwd();
    dir.createDirPath(io, "bench/results") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var file = try dir.createFile(io, "bench/results/ecs_hybrid_crossover.md", .{});
    defer file.close(io);
    var wbuf: [8192]u8 = undefined;
    var w = file.writer(io, &wbuf);
    try w.interface.writeAll(buf.items);
    try w.interface.flush();

    std.debug.print("  wrote bench/results/ecs_hybrid_crossover.md ({d} bytes)\n", .{buf.items.len});
}
