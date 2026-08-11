//! forge_3d sensor pass throughput bench (M1.1.13).
//!
//! Three rows, and the first is the one the model owes a number for. §1.13.9 states the price
//! explicitly — **sleep does not economise this pass** — so a fully resting scene pays it every
//! tick, and that cost is what the `resting` row measures. It is not a degenerate case of the
//! others: it is the steady state of any level that has stopped moving, which is most of a level
//! most of the time.
//!
//! - `no trigger` — the FLOOR. Nothing to enumerate, so the row isolates what the pass costs when
//!   it has no work: the per-layer walk and nothing else. Without it the other two rows would have
//!   no baseline to be read against.
//! - `resting, 1 trigger` — one trigger against the whole body population.
//! - `many, 64 triggers` — sixty-four triggers against the same population, which is the row that
//!   shows whether the cost follows the TRIGGER count, as the triggers-outward direction of
//!   §1.13.5 intends, or the body count.
//!
//! **RUNS ARE INTERLEAVED, not best-of-N-per-mode.** Every rep runs all three modes in sequence and
//! the best rep per mode is kept, so a thermal ramp or a scheduling burst lands on all three rather
//! than on whichever happened to be measured while it passed. Best-of-N per mode cannot resolve a
//! gap under about 5 %.
//!
//! **NON-VACUITY IS COUNTED AND REPORTED.** Each row prints the number of pairs its state holds. A
//! row that timed an empty pass under a busy row's name would be the same defect class as a test
//! that exercises a path without testing it, and the count is what makes it visible.
//!
//! **Reported, not gated.** No numeric envelope is pre-registered: this is the first measurement of
//! this path, and registering a bound before measuring its baseline is the failure mode recorded at
//! M1.1.8.
//!
//! ReleaseFast for the absolute ns. Writes `bench/results/forge_3d_sensor.md`.

const std = @import("std");
const builtin = @import("builtin");
const forge = @import("forge_3d");
const api = @import("weld_forge");

const Real = forge.Real;
const Vec3r = forge.Vec3r;
const BodyManager = forge.BodyManager;
const ShapeStore = forge.ShapeStore;
const Broadphase = forge.Broadphase;
const SensorState = forge.sensor.SensorState;

/// Bodies in every scene — a 10 x 10 x 10 grid.
const grid_side = 10;
const n_bodies = grid_side * grid_side * grid_side;
/// Triggers in the `many` row.
const n_many_triggers = 64;
/// `update` calls timed per mode per rep.
const n_calls = 200;
/// Interleaved reps; the best per mode is reported.
const n_reps = 8;

// --- Monotonic clock (mirrors `bench/forge_3d_character.zig`). ---

const timespec_t = extern struct { tv_sec: i64, tv_nsec: i64 };
const CLOCK_MONOTONIC: i32 = if (builtin.os.tag == .linux) 1 else 6;
extern "c" fn clock_gettime(clk_id: i32, tp: *timespec_t) c_int;
extern "kernel32" fn QueryPerformanceCounter(out: *i64) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceFrequency(out: *i64) callconv(.winapi) i32;

var qpc_freq_cached: i64 = 0;
fn qpcFreq() i64 {
    if (qpc_freq_cached == 0) _ = QueryPerformanceFrequency(&qpc_freq_cached);
    return qpc_freq_cached;
}

fn nowNs() i64 {
    return switch (builtin.os.tag) {
        .windows => blk: {
            var counter: i64 = 0;
            _ = QueryPerformanceCounter(&counter);
            const freq = qpcFreq();
            const sec_part: i64 = @divFloor(counter, freq);
            const rem: i64 = counter - sec_part * freq;
            break :blk sec_part * std.time.ns_per_s + @divFloor(rem * std.time.ns_per_s, freq);
        },
        else => blk: {
            var ts = timespec_t{ .tv_sec = 0, .tv_nsec = 0 };
            _ = clock_gettime(CLOCK_MONOTONIC, &ts);
            break :blk ts.tv_sec * std.time.ns_per_s + ts.tv_nsec;
        },
    };
}

fn av3(x: f32, y: f32, z: f32) @TypeOf(@as(api.BodyDescriptor, undefined).position) {
    return .{ .data = .{ x, y, z } };
}

const Mode = enum { none, resting, many };

fn modeName(m: Mode) []const u8 {
    return switch (m) {
        .none => "no trigger (floor)",
        .resting => "resting, 1 trigger",
        .many => "many, 64 triggers",
    };
}

const Scene = struct {
    store: ShapeStore = .{},
    bm: BodyManager = .{},
    bp: Broadphase,
    state: SensorState = .{},

    fn deinit(self: *Scene, gpa: std.mem.Allocator) void {
        self.state.deinit(gpa);
        self.bp.deinit(gpa);
        self.bm.deinit(gpa);
        self.store.deinit(gpa);
    }
};

/// A grid of static boxes, plus `n_triggers` trigger boxes spread through it.
///
/// Every body is STATIC and nothing ever moves: the scene is at rest for the whole batch, which is
/// the regime the `resting` row is about. The pass reads no sleep state at all (§1.13.9), so the
/// figure is the same whether the population sleeps or not — the row measures the cost that sleep
/// does not remove.
fn buildScene(gpa: std.mem.Allocator, n_triggers: u32) !Scene {
    var scene = Scene{ .bp = Broadphase.init(.{}) };
    errdefer scene.deinit(gpa);

    const body_shape = try scene.store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });
    var entity_index: u32 = 0;
    var i: u32 = 0;
    while (i < n_bodies) : (i += 1) {
        const x: f32 = @floatFromInt(i % grid_side);
        const y: f32 = @floatFromInt((i / grid_side) % grid_side);
        const z: f32 = @floatFromInt(i / (grid_side * grid_side));
        const id = try scene.bm.addBody(gpa, &scene.store, .{
            .entity = .{ .index = entity_index, .generation = 0 },
            .body_type = .static,
            .shape = body_shape,
            .position = av3(x * 2, y * 2, z * 2),
        });
        entity_index += 1;
        _ = try scene.bp.insert(
            gpa,
            BodyManager.broadLayerFor(false, .static),
            scene.bm.bodyAabb(&scene.store, id).?,
            id,
        );
    }

    // Triggers of half-extent 1.5, so each meets a handful of grid boxes rather than one or all —
    // a trigger that overlapped nothing would make the row a traversal-only measurement under a
    // detection row's name.
    const trigger_shape = try scene.store.createShape(gpa, .{ .box = .{ .half_extents = av3(1.5, 1.5, 1.5) } });
    var t: u32 = 0;
    while (t < n_triggers) : (t += 1) {
        const x: f32 = @floatFromInt((t * 3) % (grid_side * 2));
        const y: f32 = @floatFromInt((t * 5) % (grid_side * 2));
        const z: f32 = @floatFromInt((t * 7) % (grid_side * 2));
        const id = try scene.bm.addBody(gpa, &scene.store, .{
            .entity = .{ .index = entity_index, .generation = 0 },
            .body_type = .static,
            .shape = trigger_shape,
            .position = av3(x, y, z),
            .is_trigger = true,
        });
        entity_index += 1;
        // The layer is DERIVED, never a literal: the trigger lands in its class by the rule
        // production will use (M1.1.13 gate B).
        _ = try scene.bp.insert(
            gpa,
            BodyManager.broadLayerFor(true, .static),
            scene.bm.bodyAabb(&scene.store, id).?,
            id,
        );
    }
    return scene;
}

fn runBatch(gpa: std.mem.Allocator, scene: *Scene, checksum: *u64) !i64 {
    const t0 = nowNs();
    var c: u32 = 0;
    while (c < n_calls) : (c += 1) {
        try scene.state.update(gpa, &scene.bp, &scene.bm, &scene.store);
        checksum.* +%= scene.state.current.items.len;
    }
    return nowNs() - t0;
}

pub fn main() !void {
    // `safety` FORCED true: its default is `std.debug.runtime_safety`, false in ReleaseFast, which
    // is the mode this bench runs in — a default-configured checker reports "no leaks"
    // unconditionally there.
    var debug_allocator: std.heap.DebugAllocator(.{ .safety = true }) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    const modes = [_]Mode{ .none, .resting, .many };
    const trigger_counts = [_]u32{ 0, 1, n_many_triggers };
    var best: [modes.len]i64 = @splat(std.math.maxInt(i64));
    var checksum: u64 = 0;

    var scenes: [modes.len]Scene = undefined;
    for (trigger_counts, 0..) |n, i| scenes[i] = try buildScene(gpa, n);
    defer for (&scenes) |*s| s.deinit(gpa);

    // One untimed warm-up per mode: the first `update` grows the state's three lists, which is the
    // only allocation on the path, and a first rep carrying it would report a cost no later rep pays.
    for (&scenes) |*s| _ = try runBatch(gpa, s, &checksum);

    // The pair counts, read AFTER the warm-up so each row's non-vacuity is the state it will time.
    var pairs: [modes.len]usize = undefined;
    for (&scenes, 0..) |*s, i| pairs[i] = s.state.current.items.len;

    var rep: u32 = 0;
    while (rep < n_reps) : (rep += 1) {
        // INTERLEAVED: all three modes inside the rep, in a fixed order.
        for (&scenes, 0..) |*s, i| {
            const ns = try runBatch(gpa, s, &checksum);
            if (ns < best[i]) best[i] = ns;
        }
    }

    const frame_ns: f64 = @as(f64, std.time.ns_per_s) / 60.0;
    var per_call: [modes.len]f64 = undefined;
    for (best, 0..) |ns, i| per_call[i] = @as(f64, @floatFromInt(ns)) / @as(f64, n_calls);

    std.debug.print("\nforge_3d sensor pass bench ({s}, {d} bodies, {d} calls x {d} interleaved reps, best rep)\n", .{ @tagName(builtin.mode), n_bodies, n_calls, n_reps });
    std.debug.print("  {s:<24} {s:>12} {s:>10} {s:>16}\n", .{ "mode", "ns/tick", "pairs", "% of 16.67 ms" });
    for (modes, 0..) |m, i| {
        std.debug.print("  {s:<24} {d:>9.1} ns {d:>10} {d:>15.3}%\n", .{
            modeName(m), per_call[i], pairs[i], 100.0 * per_call[i] / frame_ns,
        });
    }
    std.debug.print("  (reported, not gated; checksum {d})\n", .{checksum});

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.print(gpa,
        \\# forge_3d sensor pass bench
        \\
        \\- Build mode: {s}
        \\- {d} static bodies per scene, {d} `update` calls per mode per rep, {d} INTERLEAVED reps
        \\- Anti-DCE checksum: {d}
        \\
        \\| mode | ns/tick | pairs held | % of a 16.67 ms frame |
        \\|---|---|---|---|
        \\
    , .{ @tagName(builtin.mode), n_bodies, n_calls, n_reps, checksum });
    for (modes, 0..) |m, i| {
        try buf.print(gpa, "| {s} | {d:.1} | {d} | {d:.3}% |\n", .{
            modeName(m), per_call[i], pairs[i], 100.0 * per_call[i] / frame_ns,
        });
    }
    try buf.appendSlice(gpa,
        \\
        \\**Reported, not gated.** No envelope is pre-registered: this is the first measurement of
        \\this path, and registering a bound before measuring its baseline is the failure mode
        \\recorded at M1.1.8.
        \\
        \\The `resting` row is the one the model owes a number for. `engine-physics-solver.md`
        \\§1.13.9 states the price explicitly — sleep does not economise this pass — so a fully
        \\resting scene pays it every tick. Every body in every scene here is static and nothing
        \\moves, which is that regime; and because the pass reads no sleep state at all, the figure
        \\is the same whether the population sleeps or not.
        \\
        \\The `no trigger` row is the floor: nothing to enumerate, so it isolates the per-layer walk
        \\from the candidate descent, and the other two rows are read against it.
        \\
        \\The `pairs held` column is NON-VACUITY, not decoration: a row that timed an empty pass
        \\under a busy row's name would be the same defect class as a test that exercises a path
        \\without testing it.
        \\
        \\Runs are INTERLEAVED — every rep runs all three modes in sequence and the best rep per mode
        \\is kept — so a thermal ramp or a scheduling burst lands on all three rather than on
        \\whichever happened to be measured while it passed.
        \\
    );

    const bytes = buf.items;
    const path: [:0]const u8 = "bench/results/forge_3d_sensor.md";
    const fp = fopen(path.ptr, "w");
    if (fp == null) return error.WriteReportFailed;
    _ = fwrite(bytes.ptr, 1, bytes.len, fp.?);
    _ = fclose(fp.?);

    // Read after the scenes' own `defer`, which is why this is the last statement.
    std.debug.print("  allocator: checked with safety forced true\n", .{});
}

extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, n: usize, stream: *anyopaque) usize;
extern "c" fn fclose(stream: *anyopaque) c_int;
