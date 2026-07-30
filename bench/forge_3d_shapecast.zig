//! forge_3d shape-cast and overlap throughput bench (M1.1.10).
//!
//! Sphere / box / capsule casts and shape overlaps over a STATIC scene of 10 000
//! bodies (spheres, boxes and capsules on a grid). The scene and the clock are the
//! raycast bench's, deliberately: the two are meant to be read side by side, and a
//! second grid would make the comparison an artefact of the scenery.
//!
//! Four rows, plus two that isolate what a cast costs over a ray on the SAME query
//! set — a zero-radius sphere cast, whose swept volume is a point, against the
//! raycast entry on the same origins and directions. That pair separates the cast
//! kernel's cost from the swept traversal's: at a zero extent the traversal is
//! `queryRay` exactly (the M1.1.10/E2 bit-identity pin), so the difference is the GJK
//! march against the analytic ray kernels and nothing else.
//!
//! **Reported, not gated.** No numeric envelope is pre-registered: no baseline for
//! this path has ever been measured, and registering a bound before measuring it is
//! the failure mode recorded at M1.1.8. The structural guarantees this milestone owes
//! are carried by the acceptance suites — the swept traversal's pruning test, the
//! kernel's closed-form oracles — not by a figure here.
//!
//! ReleaseFast for the absolute ns (a Debug / ReleaseSafe run prints a warning and
//! stays useful for relative comparisons). Writes
//! `bench/results/forge_3d_shapecast.md`.

const std = @import("std");
const builtin = @import("builtin");
const forge = @import("forge_3d");
const api = @import("weld_forge");

const Real = forge.Real;
const Vec3r = forge.Vec3r;
const BodyManager = forge.BodyManager;
const ShapeStore = forge.ShapeStore;
const Broadphase = forge.Broadphase;
const query = forge.query;

const n_bodies = 10_000;
const n_queries = 10_000;
const n_reps = 10;

// --- Monotonic clock (mirrors `bench/forge_3d_raycast.zig`: clock_gettime on POSIX,
// QPC on Windows — `std.time.Timer` is avoided for the same cross-platform reason). ---

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

const Scene = struct {
    store: ShapeStore = .{},
    bm: BodyManager = .{},
    bp: Broadphase,

    fn deinit(self: *Scene, gpa: std.mem.Allocator) void {
        self.store.deinit(gpa);
        self.bm.deinit(gpa);
        self.bp.deinit(gpa);
    }
};

/// The raycast bench's scene, reproduced construction for construction: a
/// 22 × 22 × 21 grid truncated to `n_bodies`, alternating spheres / boxes / capsules
/// 3 m apart, all STATIC — which is the scene a query cares about, the tree being
/// built once and never moved.
/// With `with_plane`, one static half-space `{ y <= 0 }` joins the SAME scene — the
/// M1.1.11 delta measurement (see `bench/forge_3d_raycast.zig` for the reasoning: an
/// unbounded list has no box to prune on, so every query is offered it).
fn buildScene(gpa: std.mem.Allocator, with_plane: bool) !Scene {
    var scene = Scene{ .bp = Broadphase.init(.{}) };
    const sphere = try scene.store.createShape(gpa, .{ .sphere = .{ .radius = 0.6 } });
    const box = try scene.store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });
    const capsule = try scene.store.createShape(gpa, .{ .capsule = .{ .radius = 0.3, .half_height = 0.5 } });

    var placed: u32 = 0;
    var x: u32 = 0;
    outer: while (x < 22) : (x += 1) {
        var y: u32 = 0;
        while (y < 22) : (y += 1) {
            var z: u32 = 0;
            while (z < 21) : (z += 1) {
                if (placed == n_bodies) break :outer;
                const shape = switch (placed % 3) {
                    0 => sphere,
                    1 => box,
                    else => capsule,
                };
                const id = try scene.bm.addBody(gpa, &scene.store, .{
                    .shape = shape,
                    .body_type = .static,
                    .entity = .{ .index = placed, .generation = 0 },
                    .position = av3(
                        @as(f32, @floatFromInt(x)) * 3,
                        @as(f32, @floatFromInt(y)) * 3,
                        @as(f32, @floatFromInt(z)) * 3,
                    ),
                });
                const aabb = scene.bm.bodyAabb(&scene.store, id).?;
                _ = try scene.bp.insert(gpa, .static, aabb, id);
                placed += 1;
            }
        }
    }
    if (with_plane) {
        const plane = try scene.store.createShape(gpa, .{ .plane = .{ .normal = av3(0, 1, 0), .distance = 0 } });
        const id = try scene.bm.addBody(gpa, &scene.store, .{
            .shape = plane,
            .body_type = .static,
            .entity = .{ .index = n_bodies, .generation = 0 },
        });
        // Default pose ⇒ the world half-space is the local one, no transport needed.
        _ = try scene.bp.insertUnbounded(gpa, .static, .{ .normal = Vec3r.unit_y, .distance = 0 }, id);
    }
    return scene;
}

const Measure = struct {
    name: []const u8,
    ns_per_query: f64,
    queries_per_s: f64,
    hit_rate: f64,
};

fn report(name: []const u8, total_ns: i64, queries: usize, hits: usize) Measure {
    const per = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(queries));
    return .{
        .name = name,
        .ns_per_query = per,
        .queries_per_s = if (per > 0) @as(f64, std.time.ns_per_s) / per else 0,
        .hit_rate = @as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(queries)),
    };
}

pub fn main(init: std.process.Init) !void {
    _ = init;
    // An explicit leak-checking allocator, NOT `init.gpa`: in ReleaseFast that one
    // does not detect leaks. Every allocation here is setup or report writing, outside
    // the timed loops, so the checking cost is not measured.
    //
    // `safety` is FORCED true. Its default is `std.debug.runtime_safety`, which is
    // FALSE in ReleaseFast — so `DebugAllocator(.{})` would track nothing and report
    // "no leaks" unconditionally, which is worse than no check at all because it
    // reads like one. Verified the same way as at M1.1.9, by reintroducing a leak
    // deliberately: with the default it stayed silent, with this it reports (see the
    // brief's E7 entry for the run).
    var debug_allocator: std.heap.DebugAllocator(.{ .safety = true }) = .init;
    const gpa = debug_allocator.allocator();
    defer {
        const leaked = debug_allocator.deinit();
        if (leaked == .leak) {
            std.debug.print("LEAK DETECTED: the bench leaked memory (see the trace above)\n", .{});
        } else {
            std.debug.print("  allocator: no leaks\n", .{});
        }
    }
    if (builtin.mode != .ReleaseFast) {
        std.debug.print("warning: build mode is {s}; absolute ns are only meaningful in ReleaseFast\n", .{@tagName(builtin.mode)});
    }

    var scene = try buildScene(gpa, false);
    defer scene.deinit(gpa);
    std.debug.assert(scene.bm.count() == n_bodies);

    // The query shapes, created once: a sphere, a box and a capsule of the same order
    // of size as the scene's bodies, plus a zero-radius sphere whose swept volume is
    // a point — the row that isolates the cast kernel against the ray kernels.
    const cast_sphere = try scene.store.createShape(gpa, .{ .sphere = .{ .radius = 0.5 } });
    const cast_box = try scene.store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.4, 0.4, 0.4) } });
    const cast_capsule = try scene.store.createShape(gpa, .{ .capsule = .{ .radius = 0.25, .half_height = 0.5 } });
    const cast_point = try scene.store.createShape(gpa, .{ .sphere = .{ .radius = 0 } });

    // Deterministic query set, the raycast bench's construction: origins outside the
    // grid aimed through it, so most sweeps cross a long span of the tree rather than
    // terminating immediately.
    var prng = std.Random.DefaultPrng.init(0x5EED_CA57);
    const rng = prng.random();
    const origins = try gpa.alloc(Vec3r, n_queries);
    defer gpa.free(origins);
    const directions = try gpa.alloc(Vec3r, n_queries);
    defer gpa.free(directions);
    const centres = try gpa.alloc(Vec3r, n_queries);
    defer gpa.free(centres);
    const span: Real = 63; // the grid spans ~0..63 m on each axis
    for (origins, directions, centres) |*o, *d, *c| {
        o.* = Vec3r.fromArray(.{ rng.float(Real) * span, rng.float(Real) * span, -20 });
        const target = Vec3r.fromArray(.{ rng.float(Real) * span, rng.float(Real) * span, span + 20 });
        d.* = target.sub(o.*);
        // Overlap probes live INSIDE the grid: probing from outside would measure an
        // empty answer, which says less than a populated one.
        c.* = Vec3r.fromArray(.{
            rng.float(Real) * span,
            rng.float(Real) * span,
            rng.float(Real) * span,
        });
    }

    var checksum: f64 = 0;
    var measures: [6]Measure = undefined;

    // --- (1..3) the three cast shapes, same origins and directions -------------
    const cast_rows = [_]struct { name: []const u8, shape: api.ShapeId }{
        .{ .name = "sphere cast", .shape = cast_sphere },
        .{ .name = "box cast", .shape = cast_box },
        .{ .name = "capsule cast", .shape = cast_capsule },
    };
    for (cast_rows, 0..) |row, i| {
        var hits: usize = 0;
        var best_ns: i64 = std.math.maxInt(i64);
        for (0..n_reps) |_| {
            const t0 = nowNs();
            for (origins, directions) |o, d| {
                const q = query.CastQuery{
                    .shape = row.shape,
                    .origin = o,
                    .direction = d,
                    .max_distance = 200,
                };
                if (try query.shapeCast(&scene.bp, &scene.bm, &scene.store, q)) |hit| {
                    hits += 1;
                    checksum += @floatCast(hit.distance);
                }
            }
            const dt = nowNs() - t0;
            if (dt < best_ns) best_ns = dt;
        }
        measures[i] = report(row.name, best_ns, n_queries, hits / n_reps);
    }

    // --- (4) shape overlap, a unit sphere probe inside the grid ----------------
    {
        var out: [32]api.BodyId = undefined;
        var hits: usize = 0;
        var best_ns: i64 = std.math.maxInt(i64);
        for (0..n_reps) |_| {
            const t0 = nowNs();
            for (centres) |c| {
                const n = try query.overlapShape(&scene.bp, &scene.bm, &scene.store, .{
                    .shape = cast_sphere,
                    .position = c,
                }, &out);
                if (n > 0) {
                    hits += 1;
                    checksum += @floatFromInt(n);
                }
            }
            const dt = nowNs() - t0;
            if (dt < best_ns) best_ns = dt;
        }
        measures[3] = report("shape overlap (buffer 32)", best_ns, n_queries, hits / n_reps);
    }

    // --- (5, 6) what the cast costs over the ray, on the SAME query set --------
    //
    // A zero-radius sphere cast sweeps a point, so its swept traversal is `queryRay`
    // exactly — the zero-extent bit-identity pin of E2 — and the whole difference
    // against the raycast entry is the GJK march replacing the analytic ray kernels.
    {
        var hits: usize = 0;
        var best_ns: i64 = std.math.maxInt(i64);
        for (0..n_reps) |_| {
            const t0 = nowNs();
            for (origins, directions) |o, d| {
                const q = query.CastQuery{
                    .shape = cast_point,
                    .origin = o,
                    .direction = d,
                    .max_distance = 200,
                };
                if (try query.shapeCast(&scene.bp, &scene.bm, &scene.store, q)) |hit| {
                    hits += 1;
                    checksum += @floatCast(hit.distance);
                }
            }
            const dt = nowNs() - t0;
            if (dt < best_ns) best_ns = dt;
        }
        measures[4] = report("point cast (radius 0)", best_ns, n_queries, hits / n_reps);
    }
    {
        var hits: usize = 0;
        var best_ns: i64 = std.math.maxInt(i64);
        for (0..n_reps) |_| {
            const t0 = nowNs();
            for (origins, directions) |o, d| {
                const q = query.RayQuery{ .origin = o, .direction = d, .max_distance = 200 };
                if (query.raycast(&scene.bp, &scene.bm, &scene.store, q)) |hit| {
                    hits += 1;
                    checksum += @floatCast(hit.distance);
                }
            }
            const dt = nowNs() - t0;
            if (dt < best_ns) best_ns = dt;
        }
        measures[5] = report("raycast (same rays)", best_ns, n_queries, hits / n_reps);
    }

    // --- M1.1.11: the cost of one half-space in the scene, REPORTED, never gated ---
    //
    // The same queries, the same code, the same process — the grid alone against the grid
    // plus one static half-space in the layer's unbounded list. Both measured here rather
    // than across two runs, so the delta carries neither thermal drift nor a differently
    // compiled path. Three entries, one per structure the list touches: a shape CAST (the
    // swept traversal), a shape OVERLAP (the AABB traversal), and a POINT QUERY (the
    // cheapest entry, where a fixed per-query cost shows up most clearly).
    {
        var scene_plane = try buildScene(gpa, true);
        defer scene_plane.deinit(gpa);
        std.debug.assert(scene_plane.bm.count() == n_bodies + 1);
        std.debug.print("\n  half-space delta ({d} queries, same process, best of {d}):\n", .{ n_queries, n_reps });

        // A shape handle is PER STORE: the probe must be created in the store it is used
        // against. Passing `scene`'s handle to `scene_plane`'s store resolved the same slot
        // index to a DIFFERENT shape — the plane — and the entry answered
        // `error.UnsupportedShape`, which is the E3 channel doing exactly its job on a
        // caller mistake. Found by running it, not by reading it.
        const plane_probe = try scene_plane.store.createShape(gpa, .{ .sphere = .{ .radius = 0.5 } });
        var out_ns: [2]f64 = .{ 0, 0 };
        // (a) sphere cast
        for ([_]bool{ false, true }, 0..) |with, slot| {
            const target = if (with) &scene_plane else &scene;
            const probe = if (with) plane_probe else cast_sphere;
            var best_ns: i64 = std.math.maxInt(i64);
            for (0..n_reps) |_| {
                const t0 = nowNs();
                for (origins, directions) |o, d| {
                    const q = query.CastQuery{ .shape = probe, .origin = o, .direction = d, .max_distance = 200 };
                    if (try query.shapeCast(&target.bp, &target.bm, &target.store, q)) |hit| checksum += @floatCast(hit.distance);
                }
                const dt = nowNs() - t0;
                if (dt < best_ns) best_ns = dt;
            }
            out_ns[slot] = @as(f64, @floatFromInt(best_ns)) / @as(f64, n_queries);
        }
        std.debug.print("    {s: <18} {d: >9.1} ns -> {d: >9.1} ns   delta {d: >8.1} ns  ({d: >5.2}x)\n", .{
            "sphere cast", out_ns[0], out_ns[1], out_ns[1] - out_ns[0], out_ns[1] / out_ns[0],
        });

        // (b) point query — the cheapest entry, so a fixed per-query cost is most visible.
        var ids: [32]api.BodyId = undefined;
        for ([_]bool{ false, true }, 0..) |with, slot| {
            const target = if (with) &scene_plane else &scene;
            var best_ns: i64 = std.math.maxInt(i64);
            for (0..n_reps) |_| {
                const t0 = nowNs();
                for (origins) |o| {
                    checksum += @floatFromInt(query.pointQuery(&target.bp, &target.bm, &target.store, o, .{}, &ids));
                }
                const dt = nowNs() - t0;
                if (dt < best_ns) best_ns = dt;
            }
            out_ns[slot] = @as(f64, @floatFromInt(best_ns)) / @as(f64, n_queries);
        }
        std.debug.print("    {s: <18} {d: >9.1} ns -> {d: >9.1} ns   delta {d: >8.1} ns  ({d: >5.2}x)\n", .{
            "point query", out_ns[0], out_ns[1], out_ns[1] - out_ns[0], out_ns[1] / out_ns[0],
        });

        // (c) world-AABB overlap — the entry whose exact kernel the half-space arm replaces.
        for ([_]bool{ false, true }, 0..) |with, slot| {
            const target = if (with) &scene_plane else &scene;
            var best_ns: i64 = std.math.maxInt(i64);
            for (0..n_reps) |_| {
                const t0 = nowNs();
                for (origins) |o| {
                    const lo = o.sub(Vec3r.splat(1));
                    const hi = o.add(Vec3r.splat(1));
                    checksum += @floatFromInt(query.overlapAabb(&target.bp, &target.bm, &target.store, lo, hi, .{}, &ids));
                }
                const dt = nowNs() - t0;
                if (dt < best_ns) best_ns = dt;
            }
            out_ns[slot] = @as(f64, @floatFromInt(best_ns)) / @as(f64, n_queries);
        }
        std.debug.print("    {s: <18} {d: >9.1} ns -> {d: >9.1} ns   delta {d: >8.1} ns  ({d: >5.2}x)\n", .{
            "overlapAabb", out_ns[0], out_ns[1], out_ns[1] - out_ns[0], out_ns[1] / out_ns[0],
        });
    }

    const frame_ns: f64 = @as(f64, std.time.ns_per_s) / 60.0;
    std.debug.print("\nforge_3d shapecast/overlap bench ({s}, {d} static bodies, {d} queries x {d} reps, best rep)\n", .{ @tagName(builtin.mode), n_bodies, n_queries, n_reps });
    std.debug.print("  {s:<26} {s:>12} {s:>14} {s:>18} {s:>9}\n", .{ "mode", "ns/query", "queries/s", "queries/frame @60Hz", "hit rate" });
    for (measures) |m| {
        std.debug.print("  {s:<26} {d:>9.1} ns {d:>13.0} {d:>18.0} {d:>8.2}\n", .{
            m.name, m.ns_per_query, m.queries_per_s, frame_ns / m.ns_per_query, m.hit_rate,
        });
    }
    std.debug.print("  (reported, not gated; checksum {d:.3})\n", .{checksum});

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.print(gpa,
        \\# forge_3d shape-cast and overlap throughput bench
        \\
        \\- Build mode: {s}
        \\- Scene: {d} STATIC bodies (spheres / boxes / capsules on a 3 m grid) — the
        \\  raycast bench's scene, so the two tables are comparable
        \\- Queries: {d} per rep, {d} reps, best rep reported
        \\- Anti-DCE checksum: {d:.3}
        \\
        \\| mode | ns/query | queries/s | queries per 16.67 ms frame | hit rate |
        \\|---|---|---|---|---|
        \\
    , .{ @tagName(builtin.mode), n_bodies, n_queries, n_reps, checksum });
    for (measures) |m| {
        try buf.print(gpa, "| {s} | {d:.1} | {d:.0} | {d:.0} | {d:.2} |\n", .{
            m.name, m.ns_per_query, m.queries_per_s, frame_ns / m.ns_per_query, m.hit_rate,
        });
    }
    try buf.appendSlice(gpa,
        \\
        \\**Reported, not gated.** No envelope is pre-registered: this is the first
        \\measurement of this path, and registering a bound before measuring its
        \\baseline is the failure mode recorded at M1.1.8. The structural guarantees are
        \\the swept traversal's pruning test and the cast kernel's closed-form oracles
        \\in the acceptance suites.
        \\
        \\The last two rows are a PAIR on the same query set: a radius-0 sphere cast
        \\sweeps a point, so its traversal is `queryRay` exactly (the zero-extent
        \\bit-identity pin), and the difference against the raycast entry is the GJK
        \\march standing in for the analytic ray kernels — nothing else.
        \\
    );

    const bytes = buf.items;
    const path: [:0]const u8 = "bench/results/forge_3d_shapecast.md";
    const fp = fopen(path.ptr, "w");
    if (fp == null) return error.WriteReportFailed;
    defer _ = fclose(fp.?);
    _ = fwrite(bytes.ptr, 1, bytes.len, fp.?);
}

extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, n: usize, stream: *anyopaque) usize;
extern "c" fn fclose(stream: *anyopaque) c_int;
