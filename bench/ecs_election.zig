//! M1.B / P2-1 — what the per-walk driver election costs, and how often it flips.
//!
//! REPORTED, NOT GATED, and permanently: `engine-ecs-internals.md` §2 refuses to
//! engrave a threshold for the mixed-query planner and names a bench as what
//! produces figures instead, so a pass threshold here would grade an
//! implementation against a number this file exists to produce.
//!
//! **Two tracks, because the design's two open questions are different
//! quantities.** Track A is the COST of one election, isolated and separated by
//! arm: `population` is `store.len()` for a sparse member and a sum over
//! archetypes — with a signature walk inside `hasComponent` — for a table one,
//! so the election is O(t · A) in the table members of the with-set and the
//! world's archetype count. Track B is the FLIP RATE: how often the elected
//! driver actually changes from one tick to the next.
//!
//! **Track B doubles the churn axis, and the reason is a measurement.**
//! `ecs_hybrid_crossover.zig`'s churn removes then re-adds the same component on
//! the same carriers — its own comment states the carrier count is unchanged by
//! construction — so it CANNOT flip a cardinality election. A flip rate of zero
//! read off that axis alone would be a property of the churn and nothing about
//! the election. The preserving cells are therefore reported beside
//! population-MOVING ones, which are the non-vacuity control of the first.
//!
//! Writes `bench/results/ecs_election.md`.

const std = @import("std");
const weld_core = @import("weld_core");

const World = weld_core.ecs.World;
const EntityId = weld_core.ecs.EntityId;
const ComponentId = weld_core.ecs.ComponentId;
const hybrid = weld_core.ecs.hybrid_query;

// ─── Declared axes ─────────────────────────────────────────────────────────

const archetype_counts = [_]u32{ 1, 4, 16, 64, 256 };
const entities_per_archetype: u32 = 4;

const ElectConfig = struct {
    members: u8,
    table_members: u8,
    label: []const u8,
};

/// The with-set shapes. `t = 0` isolates the O(1) arm, `t = m` the O(t · A) one,
/// and `t = 1` is the mixed case a real rule writes — which separates "the term
/// carries a table member at all" from "how many".
const elect_configs = [_]ElectConfig{
    .{ .members = 2, .table_members = 0, .label = "2 sparse" },
    .{ .members = 8, .table_members = 0, .label = "8 sparse" },
    .{ .members = 2, .table_members = 1, .label = "1 table + 1 sparse" },
    .{ .members = 8, .table_members = 1, .label = "1 table + 7 sparse" },
    .{ .members = 2, .table_members = 2, .label = "2 table" },
    .{ .members = 8, .table_members = 8, .label = "8 table" },
};

/// Same values as `ecs_hybrid_crossover.zig`'s churn axis, reused so the two
/// reports speak of the same rates.
const churns = [_]u32{ 0, 1, 10, 60 };

const elections_per_sample: u32 = 20_000;
const cost_samples: u32 = 5;
const flip_ticks: u32 = 60;

const n_flip_entities: u32 = 4000;
const table_carriers: u32 = 1000;

const max_members: usize = 8;
const max_fillers: usize = 8;

// ─── Registration ──────────────────────────────────────────────────────────

const filler_names = [max_fillers][]const u8{
    "ElecFiller0", "ElecFiller1", "ElecFiller2", "ElecFiller3",
    "ElecFiller4", "ElecFiller5", "ElecFiller6", "ElecFiller7",
};
const table_names = [max_members][]const u8{
    "ElecTable0", "ElecTable1", "ElecTable2", "ElecTable3",
    "ElecTable4", "ElecTable5", "ElecTable6", "ElecTable7",
};
const sparse_names = [max_members][]const u8{
    "ElecSparse0", "ElecSparse1", "ElecSparse2", "ElecSparse3",
    "ElecSparse4", "ElecSparse5", "ElecSparse6", "ElecSparse7",
};

fn registerAll(
    gpa: std.mem.Allocator,
    world: *World,
    names: []const []const u8,
    storage: weld_core.ecs.StorageKind,
    out: []ComponentId,
) !void {
    const zero = [_]u8{ 0, 0, 0, 0 };
    for (names, 0..) |name, k| {
        out[k] = try world.registry.registerComponentRaw(gpa, .{
            .name = name,
            .size = 4,
            .alignment = 4,
            .default_bytes = &zero,
            .fields = &.{},
            .storage = storage,
        });
    }
}

// ─── Track A — the cost of one election ────────────────────────────────────

const CostCell = struct {
    archetypes: usize,
    ns_per_election: u64,
    checksum: u64,
};

fn medianOf(samples: []u64) u64 {
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    return samples[samples.len / 2];
}

/// Build a world holding exactly `target_archetypes` distinct table signatures,
/// every one of them carrying every table member of the with-set.
///
/// Every archetype carries them deliberately: `population` short-circuits on
/// `hasComponent`, so a world where most archetypes lack the member measures the
/// cheap branch. This is the MOST work the table arm can do at that archetype
/// count, and the figure is the ceiling rather than a typical case.
fn buildCostWorld(
    gpa: std.mem.Allocator,
    world: *World,
    target_archetypes: u32,
    fillers: []const ComponentId,
    table_ids: []const ComponentId,
    sparse_ids: []const ComponentId,
) !void {
    const one = [_]u8{ 1, 0, 0, 0 };
    var ids: [max_members + max_fillers]ComponentId = undefined;
    var j: u32 = 0;
    while (j < target_archetypes) : (j += 1) {
        var n: usize = 0;
        for (table_ids) |cid| {
            ids[n] = cid;
            n += 1;
        }
        for (0..max_fillers) |k| {
            if (j & (@as(u32, 1) << @intCast(k)) != 0) {
                ids[n] = fillers[k];
                n += 1;
            }
        }
        var e: u32 = 0;
        while (e < entities_per_archetype) : (e += 1) {
            const ent = try world.spawnDynamic(gpa, ids[0..n]);
            for (sparse_ids) |cid| {
                try world.addComponentDynamic(gpa, ent, cid, &one);
            }
        }
    }
}

fn measureCost(
    io: std.Io,
    gpa: std.mem.Allocator,
    comptime cfg: ElectConfig,
    target_archetypes: u32,
) !CostCell {
    var world = World.init();
    defer world.deinit(gpa);

    var fillers: [max_fillers]ComponentId = undefined;
    var tables: [max_members]ComponentId = undefined;
    var sparses: [max_members]ComponentId = undefined;
    try registerAll(gpa, &world, &filler_names, .table, &fillers);
    try registerAll(gpa, &world, &table_names, .table, &tables);
    try registerAll(gpa, &world, &sparse_names, .sparse, &sparses);

    const n_table = cfg.table_members;
    const n_sparse = cfg.members - cfg.table_members;
    try buildCostWorld(gpa, &world, target_archetypes, &fillers, tables[0..n_table], sparses[0..n_sparse]);

    // The with-set INTERLEAVES the two kinds rather than grouping them, because
    // `electDriver` breaks a population tie on the position in this slice and a
    // grouped set would put every table member before every sparse one.
    var with: [max_members]ComponentId = undefined;
    var ti: usize = 0;
    var si: usize = 0;
    for (0..cfg.members) |k| {
        if (ti < n_table and (k % 2 == 0 or si >= n_sparse)) {
            with[k] = tables[ti];
            ti += 1;
        } else {
            with[k] = sparses[si];
            si += 1;
        }
    }

    var plan = try hybrid.plan(gpa, &world, with[0..cfg.members], &.{});
    defer plan.deinit(gpa);

    var samples: [cost_samples]u64 = undefined;
    var checksum: u64 = 0;
    for (&samples) |*s| {
        const a = std.Io.Clock.now(.awake, io);
        var i: u32 = 0;
        while (i < elections_per_sample) : (i += 1) {
            checksum +%= switch (plan.elect(&world)) {
                .table => 1,
                .sparse => |idx| 2 + idx,
            };
        }
        const b = std.Io.Clock.now(.awake, io);
        const ns: u64 = @intCast(@max(@as(i96, 0), a.durationTo(b).nanoseconds));
        s.* = ns / elections_per_sample;
    }

    return .{
        .archetypes = world.archetypes.items.len,
        .ns_per_election = medianOf(&samples),
        .checksum = checksum,
    };
}

// ─── Track B — how often the driver flips ──────────────────────────────────

const ChurnMode = enum {
    /// The crossover bench's own churn: remove then re-add on the same carriers.
    /// Populations are unchanged by construction.
    preserving,
    /// A net drift: the sparse population grows past the table one.
    moving,
    /// The sparse population crosses the table one every tick, which is the
    /// most flips a cardinality election can be made to produce.
    oscillating,
};

const FlipCell = struct {
    mode: ChurnMode,
    churn: u32,
    flips: u32,
    checksum: u64,
};

fn measureFlips(gpa: std.mem.Allocator, mode: ChurnMode, churn: u32) !FlipCell {
    var world = World.init();
    defer world.deinit(gpa);

    var fillers: [max_fillers]ComponentId = undefined;
    var tables: [max_members]ComponentId = undefined;
    var sparses: [max_members]ComponentId = undefined;
    try registerAll(gpa, &world, &filler_names, .table, &fillers);
    try registerAll(gpa, &world, &table_names, .table, &tables);
    try registerAll(gpa, &world, &sparse_names, .sparse, &sparses);

    const t_id = tables[0];
    const s_id = sparses[0];
    const one = [_]u8{ 1, 0, 0, 0 };

    const ents = try gpa.alloc(EntityId, n_flip_entities);
    defer gpa.free(ents);
    for (ents, 0..) |*e, i| {
        e.* = if (i < table_carriers)
            try world.spawnDynamic(gpa, &.{t_id})
        else
            try world.spawnDynamic(gpa, &.{});
    }

    // EVERY MODE STARTS ONE ENTITY FROM THE BOUNDARY, or the cell measures the
    // wrong thing. Two figures were read off a first version that did not, and
    // both were vacuous: `oscillating` started AT equality and swung to
    // 1000/1001, where the declaration-order tie-break keeps the table member on
    // both sides, so it reported ZERO flips — the one cell whose purpose is to
    // produce the maximum. And `moving` started at half the table population, so
    // at churn 1 sixty ticks never reached the crossing and it reported zero for
    // want of distance rather than for want of a flip.
    //
    // `moving` starts half the window short of the boundary so the crossing
    // falls INSIDE the window at the slowest rate on the axis; the other two sit
    // at 999 against 1000, one entity from flipping.
    const start_sparse: u32 = switch (mode) {
        .preserving, .oscillating => table_carriers - 1,
        .moving => table_carriers - flip_ticks / 2,
    };
    for (ents[0..start_sparse]) |e| try world.addComponentDynamic(gpa, e, s_id, &one);
    var n_sparse = start_sparse;

    var plan = try hybrid.plan(gpa, &world, &.{ t_id, s_id }, &.{});
    defer plan.deinit(gpa);

    var flips: u32 = 0;
    var checksum: u64 = 0;
    var prev: ?usize = null;
    var cursor: u32 = 0;
    var up = true;

    var t: u32 = 0;
    while (t < flip_ticks) : (t += 1) {
        const w = plan.elect(&world);
        const key: usize = switch (w) {
            .table => 0,
            .sparse => |i| 1 + i,
        };
        checksum +%= key;
        if (prev) |p| {
            if (p != key) flips += 1;
        }
        prev = key;

        switch (mode) {
            .preserving => {
                var k: u32 = 0;
                while (k < churn and n_sparse > 0) : (k += 1) {
                    const e = ents[(cursor + k) % n_sparse];
                    try world.removeComponentDynamic(gpa, e, s_id);
                    try world.addComponentDynamic(gpa, e, s_id, &one);
                }
                if (n_sparse > 0) cursor = (cursor +% churn) % n_sparse;
            },
            .moving => {
                var k: u32 = 0;
                while (k < churn and n_sparse < ents.len) : (k += 1) {
                    try world.addComponentDynamic(gpa, ents[n_sparse], s_id, &one);
                    n_sparse += 1;
                }
            },
            .oscillating => {
                // ONE entity per tick, whatever the churn rate: the quantity
                // being measured is how the election behaves at equality, and a
                // larger step would jump over it.
                if (up) {
                    if (n_sparse < ents.len) {
                        try world.addComponentDynamic(gpa, ents[n_sparse], s_id, &one);
                        n_sparse += 1;
                    }
                } else {
                    if (n_sparse > 0) {
                        n_sparse -= 1;
                        try world.removeComponentDynamic(gpa, ents[n_sparse], s_id);
                    }
                }
                up = !up;
            },
        }
    }

    return .{ .mode = mode, .churn = churn, .flips = flips, .checksum = checksum };
}

// ─── Report ────────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    // `safety` FORCED true: its default is `std.debug.runtime_safety`, false in
    // ReleaseFast, so a default-configured checker reports "no leaks"
    // unconditionally in the mode this bench runs in.
    var debug_allocator: std.heap.DebugAllocator(.{ .safety = true }) = .init;
    const gpa = debug_allocator.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var smoke = false;
    // Defaults to NON-opposable, on the `ecs_hybrid_crossover.zig` precedent: a
    // bench cannot detect thermal isolation, so the burden sits on the asserter,
    // and without this default CI would emit an artifact that looks like the
    // corpus measurement on every run.
    var cold_isolated = false;
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--smoke")) smoke = true;
        if (std.mem.eql(u8, a, "--cold-isolated")) cold_isolated = true;
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(gpa);

    try buf.print(gpa, "# M1.B / P2-1 — driver election: cost and flip rate\n\n", .{});
    try buf.print(gpa, "Mode `{s}`, {s}.\n\n", .{
        @tagName(@import("builtin").mode),
        if (cold_isolated)
            "cold-isolated, compliant"
        else
            "⚠ **dev-mode — not opposable** (no `--cold-isolated`)",
    });

    try buf.print(gpa,
        \\## Track A — the cost of ONE election, by with-set shape
        \\
        \\`ns/election`, median of {d} samples of {d} elections. Every archetype in
        \\the world carries every table member of the with-set, so this is the
        \\CEILING at that archetype count and not a typical case.
        \\
        \\
    , .{ cost_samples, elections_per_sample });

    try buf.print(gpa, "| with-set | ", .{});
    for (archetype_counts) |a| {
        if (smoke and a != archetype_counts[archetype_counts.len - 1]) continue;
        try buf.print(gpa, "A={d} | ", .{a});
    }
    try buf.print(gpa, "\n|---|", .{});
    for (archetype_counts) |a| {
        if (smoke and a != archetype_counts[archetype_counts.len - 1]) continue;
        try buf.print(gpa, "---|", .{});
    }
    try buf.print(gpa, "\n", .{});

    var sum_checks: u64 = 0;
    inline for (elect_configs) |cfg| {
        try buf.print(gpa, "| {s} | ", .{cfg.label});
        for (archetype_counts) |a| {
            if (smoke and a != archetype_counts[archetype_counts.len - 1]) continue;
            const cell = try measureCost(io, gpa, cfg, a);
            sum_checks +%= cell.checksum;
            try buf.print(gpa, "{d} | ", .{cell.ns_per_election});
        }
        try buf.print(gpa, "\n", .{});
    }

    try buf.print(gpa,
        \\
        \\## Track B — flips per {d} ticks
        \\
        \\One term `{{table, sparse}}`, {d} table carriers of {d} entities. The
        \\`preserving` rows are the crossover bench's own churn, which leaves both
        \\populations unchanged; the `moving` and `oscillating` rows are what make
        \\a zero there a statement about the churn.
        \\
        \\| churn mode | churn/tick | flips |
        \\|---|---|---|
        \\
    , .{ flip_ticks, table_carriers, n_flip_entities });

    for (churns) |c| {
        const cell = try measureFlips(gpa, .preserving, c);
        sum_checks +%= cell.checksum;
        try buf.print(gpa, "| preserving | {d} | {d} |\n", .{ c, cell.flips });
    }
    for (churns) |c| {
        if (c == 0) continue;
        const cell = try measureFlips(gpa, .moving, c);
        sum_checks +%= cell.checksum;
        try buf.print(gpa, "| moving | {d} | {d} |\n", .{ c, cell.flips });
    }
    {
        const cell = try measureFlips(gpa, .oscillating, 1);
        sum_checks +%= cell.checksum;
        try buf.print(gpa, "| oscillating | 1 | {d} |\n", .{cell.flips});
    }

    try buf.print(gpa, "\nAnti-DCE checksum: {d}\n", .{sum_checks});

    var dir = std.Io.Dir.cwd();
    dir.createDirPath(io, "bench/results") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var file = try dir.createFile(io, "bench/results/ecs_election.md", .{});
    defer file.close(io);
    var wbuf: [8192]u8 = undefined;
    var w = file.writer(io, &wbuf);
    try w.interface.writeAll(buf.items);
    try w.interface.flush();

    std.debug.print("{s}", .{buf.items});
    std.debug.print("  wrote bench/results/ecs_election.md ({d} bytes)\n", .{buf.items.len});

    // FREED BEFORE THE CHECK, not by the deferred `deinit` above: a `defer` runs
    // after the last statement of the function, so the leak check would see the
    // report buffer still held and call it a leak. Measured — the first run of
    // this bench reported exactly one leaked address for that reason.
    buf.deinit(gpa);
    buf = .empty;

    if (debug_allocator.deinit() == .leak) {
        std.debug.print("  LEAK DETECTED\n", .{});
        return error.Leak;
    }
    std.debug.print("  no leaks\n", .{});
}
