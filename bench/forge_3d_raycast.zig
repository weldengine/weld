//! forge_3d raycast throughput bench (M1.1.9).
//!
//! Closest-hit raycast over a STATIC scene of 10 000 bodies (spheres, boxes and
//! capsules on a grid), plus the `any` and `all` selection modes over the same
//! ray set, plus a pair that isolates traversal-order locality: a ray set SWEPT
//! through the grid cell by cell (consecutive rays land in neighbouring cells, so
//! consecutive traversals reuse the same tree nodes) against the SAME set permuted
//! by Fisher-Yates from a fixed seed. The randomly-aimed set used by the first
//! three rows has no spatial order to begin with, so permuting THAT would have
//! measured array-access locality and nothing about traversal — the swept pair is
//! the comparison the question deserves. A running checksum over the hits defeats
//! dead-code elimination.
//!
//! **Reported, not gated.** No numeric envelope is pre-registered: the baseline
//! has never been measured, and inventing a bound before measuring it is the
//! failure mode recorded at M1.1.8. The structural guarantee this milestone owes
//! is carried by the logarithmic node-count test in the acceptance suite, not by a
//! figure here. The C1.1 target — 10 000 rays per frame at 60 Hz — is verified at
//! its own declared point, `bench/physics_forge_3d_integration.zig` on the demo
//! scene, which does not exist yet; the derived "rays per 16.67 ms frame" column
//! below is an indication of order of magnitude and nothing more.
//!
//! ReleaseFast for the absolute ns (a Debug / ReleaseSafe run prints a warning and
//! stays useful for relative comparisons). Writes
//! `bench/results/forge_3d_raycast.md`.

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
const n_rays = 10_000;
const n_reps = 10;

// --- Monotonic clock (mirrors `bench/forge_narrowphase.zig`: clock_gettime on
// POSIX, QPC on Windows — `std.time.Timer` is avoided for the same
// cross-platform reason). ---

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

/// A 22 × 22 × 21 grid (10 164 cells, truncated to `n_bodies`) of alternating
/// spheres / boxes / capsules, spaced 3 m apart — all STATIC, which is the scene a
/// query cares about: the broadphase tree is built once and never moved.
/// Build the bench scene. With `with_plane`, one static half-space `{ y <= 0 }` joins the
/// SAME scene — the M1.1.11 delta measurement. The grid starts at y = 0, so the plane is
/// genuinely in contact with its lowest layer; and an unbounded list has no box to prune
/// on, which is precisely why it is not in a tree, so EVERY ray is offered to it and the
/// exact kernel runs on every one. That is the worst case, and the honest one to report.
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
        // The body is at the DEFAULT pose — identity rotation, origin position — so the
        // world half-space IS the local one and no transport is needed. Stated rather than
        // silently relied on: a posed plane needs
        // `shape.halfSpace(...).transformed(rotation, position)`, which is what the test
        // harness does.
        _ = try scene.bp.insertUnbounded(gpa, .static, .{ .normal = Vec3r.unit_y, .distance = 0 }, id);
    }
    return scene;
}

/// One ray SELECTION MODE, timed on one scene — the M1.1.11 delta harness.
///
/// One function rather than three copied loops, and both scenes measured through it in the
/// same process, back to back: a delta between two separate runs would carry the machine's
/// thermal drift and a differently compiled code path, which is not the quantity asked
/// for. The only difference between the two scenes is the unbounded list.
const RayMode = enum { closest, any, all };

fn timeMode(
    mode: RayMode,
    scene: *Scene,
    origins: []const Vec3r,
    directions: []const Vec3r,
    checksum: *f64,
) i64 {
    var buf: [32]query.RayHit = undefined;
    var best_ns: i64 = std.math.maxInt(i64);
    for (0..n_reps) |_| {
        const t0 = nowNs();
        for (origins, directions) |o, d| {
            const q = query.RayQuery{ .origin = o, .direction = d, .max_distance = 200 };
            switch (mode) {
                .closest => if (query.raycast(&scene.bp, &scene.bm, &scene.store, q)) |hit| {
                    checksum.* += @floatCast(hit.distance);
                },
                .any => if (query.raycastAny(&scene.bp, &scene.bm, &scene.store, q)) {
                    checksum.* += 1;
                },
                .all => {
                    const n = query.raycastAll(&scene.bp, &scene.bm, &scene.store, q, &buf);
                    if (n > 0) checksum.* += @floatCast(buf[0].distance);
                },
            }
        }
        const dt = nowNs() - t0;
        if (dt < best_ns) best_ns = dt;
    }
    return best_ns;
}

const Measure = struct {
    name: []const u8,
    ns_per_ray: f64,
    rays_per_s: f64,
    hit_rate: f64,
};

fn report(name: []const u8, total_ns: i64, rays: usize, hits: usize) Measure {
    const per = @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(rays));
    return .{
        .name = name,
        .ns_per_ray = per,
        .rays_per_s = if (per > 0) @as(f64, std.time.ns_per_s) / per else 0,
        .hit_rate = @as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(rays)),
    };
}

pub fn main(init: std.process.Init) !void {
    _ = init;
    // An explicit leak-checking allocator, NOT `init.gpa`: in ReleaseFast that one
    // does not detect leaks, which is why seven of them here — a report header plus
    // six table rows, each `allocPrint`ed and then copied away — survived three
    // rounds of review invisibly. Every allocation on this path is setup or report
    // writing, outside the timed loops, so the checking cost is not measured.
    // `safety` is FORCED true. Its default is `std.debug.runtime_safety`, which is
    // false in ReleaseFast — so `DebugAllocator(.{})` here would have tracked
    // nothing and reported "no leaks" unconditionally. Verified by reintroducing one
    // of the leaks: with the default it stayed silent, with this it reports.
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

    // Deterministic ray set: origins outside the grid, aimed through it, so most
    // rays cross a long span of the tree rather than terminating immediately.
    var prng = std.Random.DefaultPrng.init(0x9A17_C0DE);
    const rng = prng.random();
    const origins = try gpa.alloc(Vec3r, n_rays);
    defer gpa.free(origins);
    const directions = try gpa.alloc(Vec3r, n_rays);
    defer gpa.free(directions);
    const span: Real = 63; // the grid spans ~0..63 m on each axis
    for (origins, directions) |*o, *d| {
        o.* = Vec3r.fromArray(.{
            rng.float(Real) * span,
            rng.float(Real) * span,
            -20,
        });
        const target = Vec3r.fromArray(.{
            rng.float(Real) * span,
            rng.float(Real) * span,
            span + 20,
        });
        d.* = target.sub(o.*);
    }

    var checksum: f64 = 0;
    var measures: [6]Measure = undefined;

    // (1) closest — the dominant mode.
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
        measures[0] = report("closest", best_ns, n_rays, hits / n_reps);
    }

    // (2) any — should be cheaper: it terminates at the first candidate.
    {
        var hits: usize = 0;
        var best_ns: i64 = std.math.maxInt(i64);
        for (0..n_reps) |_| {
            const t0 = nowNs();
            for (origins, directions) |o, d| {
                const q = query.RayQuery{ .origin = o, .direction = d, .max_distance = 200 };
                if (query.raycastAny(&scene.bp, &scene.bm, &scene.store, q)) {
                    hits += 1;
                    checksum += 1;
                }
            }
            const dt = nowNs() - t0;
            if (dt < best_ns) best_ns = dt;
        }
        measures[1] = report("any", best_ns, n_rays, hits / n_reps);
    }

    // (3) all — never tightens, so it pays the full traversal.
    {
        var buf: [32]query.RayHit = undefined;
        var hits: usize = 0;
        var best_ns: i64 = std.math.maxInt(i64);
        for (0..n_reps) |_| {
            const t0 = nowNs();
            for (origins, directions) |o, d| {
                const q = query.RayQuery{ .origin = o, .direction = d, .max_distance = 200 };
                const n = query.raycastAll(&scene.bp, &scene.bm, &scene.store, q, &buf);
                if (n > 0) {
                    hits += 1;
                    checksum += @floatCast(buf[0].distance);
                }
            }
            const dt = nowNs() - t0;
            if (dt < best_ns) best_ns = dt;
        }
        measures[2] = report("all (buffer 32)", best_ns, n_rays, hits / n_reps);
    }

    // (4) closest on SHORT rays — a 5 m window, the ground-probe / line-of-sight
    // regime, where the bound prunes almost the whole tree. The origins are moved
    // INSIDE the grid: probing from outside it with a 5 m reach would measure
    // pruning against an empty answer, which says less than pruning against a real
    // one.
    {
        var hits: usize = 0;
        var best_ns: i64 = std.math.maxInt(i64);
        const inside = try gpa.alloc(Vec3r, n_rays);
        defer gpa.free(inside);
        for (inside, origins) |*p, o| {
            const a = o.toArray();
            p.* = Vec3r.fromArray(.{ a[0], a[1], rng.float(Real) * span });
        }
        for (0..n_reps) |_| {
            const t0 = nowNs();
            for (inside, directions) |o, d| {
                const q = query.RayQuery{ .origin = o, .direction = d, .max_distance = 5 };
                if (query.raycast(&scene.bp, &scene.bm, &scene.store, q)) |hit| {
                    hits += 1;
                    checksum += @floatCast(hit.distance);
                }
            }
            const dt = nowNs() - t0;
            if (dt < best_ns) best_ns = dt;
        }
        measures[3] = report("closest (5 m bound)", best_ns, n_rays, hits / n_reps);
    }

    // (5) and (6) — the traversal-locality pair. Rays are SWEPT through the grid,
    // one per cell in `x, y, z` order, each shooting +Z through its own column: so
    // consecutive rays traverse overlapping parts of the tree. Then the SAME rays in
    // a Fisher-Yates permutation from the fixed seed stream. The only difference
    // between the two rows is the order, and the work is identical ray for ray.
    {
        const swept_origins = try gpa.alloc(Vec3r, n_rays);
        defer gpa.free(swept_origins);
        const swept_dirs = try gpa.alloc(Vec3r, n_rays);
        defer gpa.free(swept_dirs);
        var made: usize = 0;
        var gx: u32 = 0;
        sweep: while (gx < 22) : (gx += 1) {
            var gy: u32 = 0;
            while (gy < 22) : (gy += 1) {
                var gz: u32 = 0;
                while (gz < 21) : (gz += 1) {
                    if (made == n_rays) break :sweep;
                    swept_origins[made] = Vec3r.fromArray(.{
                        @as(Real, @floatFromInt(gx)) * 3,
                        @as(Real, @floatFromInt(gy)) * 3,
                        -20,
                    });
                    swept_dirs[made] = Vec3r.fromArray(.{ 0, 0, 1 });
                    made += 1;
                }
            }
        }

        const order = try gpa.alloc(u32, n_rays);
        defer gpa.free(order);
        for (order, 0..) |*ix, i| ix.* = @intCast(i);
        var i: usize = n_rays - 1;
        while (i > 0) : (i -= 1) {
            const j = rng.intRangeAtMost(usize, 0, i);
            const tmp = order[i];
            order[i] = order[j];
            order[j] = tmp;
        }

        // Swept order.
        {
            var hits: usize = 0;
            var best_ns: i64 = std.math.maxInt(i64);
            for (0..n_reps) |_| {
                const t0 = nowNs();
                for (swept_origins, swept_dirs) |o, d| {
                    const q = query.RayQuery{ .origin = o, .direction = d, .max_distance = 200 };
                    if (query.raycast(&scene.bp, &scene.bm, &scene.store, q)) |hit| {
                        hits += 1;
                        checksum += @floatCast(hit.distance);
                    }
                }
                const dt = nowNs() - t0;
                if (dt < best_ns) best_ns = dt;
            }
            measures[4] = report("closest (swept order)", best_ns, n_rays, hits / n_reps);
        }

        // The same rays, permuted.
        {
            var hits: usize = 0;
            var best_ns: i64 = std.math.maxInt(i64);
            for (0..n_reps) |_| {
                const t0 = nowNs();
                for (order) |ix| {
                    const q = query.RayQuery{ .origin = swept_origins[ix], .direction = swept_dirs[ix], .max_distance = 200 };
                    if (query.raycast(&scene.bp, &scene.bm, &scene.store, q)) |hit| {
                        hits += 1;
                        checksum += @floatCast(hit.distance);
                    }
                }
                const dt = nowNs() - t0;
                if (dt < best_ns) best_ns = dt;
            }
            measures[5] = report("closest (swept, permuted)", best_ns, n_rays, hits / n_reps);
        }
    }

    // --- M1.1.11: the cost of one half-space in the scene, REPORTED, never gated ---
    //
    // The same 10 000 rays, the same code, the same process — once against the grid alone
    // and once against the grid plus one static half-space in the layer's unbounded list.
    // No envelope is pre-registered: it is a measurement, and what it measures is that an
    // unbounded list has no box to prune on, so the exact kernel runs on EVERY ray.
    {
        var scene_plane = try buildScene(gpa, true);
        defer scene_plane.deinit(gpa);
        std.debug.assert(scene_plane.bm.count() == n_bodies + 1);
        std.debug.print("\n  half-space delta (10k rays, same process, best of {d}):\n", .{n_reps});
        for ([_]RayMode{ .closest, .any, .all }) |mode| {
            const without = timeMode(mode, &scene, origins, directions, &checksum);
            const with = timeMode(mode, &scene_plane, origins, directions, &checksum);
            const ns_without = @as(f64, @floatFromInt(without)) / @as(f64, n_rays);
            const ns_with = @as(f64, @floatFromInt(with)) / @as(f64, n_rays);
            std.debug.print("    {s: <18} {d: >9.1} ns -> {d: >9.1} ns   delta {d: >8.1} ns  ({d: >5.2}x)\n", .{
                @tagName(mode), ns_without, ns_with, ns_with - ns_without, ns_with / ns_without,
            });
        }
    }

    const frame_ns: f64 = @as(f64, std.time.ns_per_s) / 60.0;
    std.debug.print("\nforge_3d raycast bench ({s}, {d} static bodies, {d} rays x {d} reps, best rep)\n", .{ @tagName(builtin.mode), n_bodies, n_rays, n_reps });
    std.debug.print("  {s:<22} {s:>12} {s:>14} {s:>16} {s:>9}\n", .{ "mode", "ns/ray", "rays/s", "rays/frame @60Hz", "hit rate" });
    for (measures) |m| {
        std.debug.print("  {s:<22} {d:>9.1} ns {d:>13.0} {d:>16.0} {d:>8.2}\n", .{
            m.name, m.ns_per_ray, m.rays_per_s, frame_ns / m.ns_per_ray, m.hit_rate,
        });
    }
    std.debug.print("  (reported, not gated; checksum {d:.3})\n", .{checksum});

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    // Formatted straight into the list. The previous form was
    // `appendSlice(gpa, try allocPrint(gpa, ...))`, which allocated a temporary for
    // every row, copied it in, and never freed it.
    try buf.print(gpa,
        \\# forge_3d raycast throughput bench
        \\
        \\- Build mode: {s}
        \\- Scene: {d} STATIC bodies (spheres / boxes / capsules on a 3 m grid)
        \\- Rays: {d} per rep, {d} reps, best rep reported
        \\- Anti-DCE checksum: {d:.3}
        \\
        \\| mode | ns/ray | rays/s | rays per 16.67 ms frame | hit rate |
        \\|---|---|---|---|---|
        \\
    , .{ @tagName(builtin.mode), n_bodies, n_rays, n_reps, checksum });
    for (measures) |m| {
        try buf.print(gpa, "| {s} | {d:.1} | {d:.0} | {d:.0} | {d:.2} |\n", .{
            m.name, m.ns_per_ray, m.rays_per_s, frame_ns / m.ns_per_ray, m.hit_rate,
        });
    }
    try buf.appendSlice(gpa,
        \\
        \\**Reported, not gated.** No envelope is pre-registered: this is the first
        \\measurement of this path, and registering a bound before measuring its
        \\baseline is the failure mode recorded at M1.1.8. The structural guarantee is
        \\the logarithmic visited-node test in the acceptance suite. The C1.1 target of
        \\10 000 rays/frame at 60 Hz is verified at its own declared point,
        \\`bench/physics_forge_3d_integration.zig` on the demo scene; the frame column
        \\here is an order-of-magnitude indication on a synthetic grid.
        \\
    );

    const bytes = buf.items;
    const path: [:0]const u8 = "bench/results/forge_3d_raycast.md";
    const fp = fopen(path.ptr, "w");
    if (fp == null) return error.WriteReportFailed;
    defer _ = fclose(fp.?);
    _ = fwrite(bytes.ptr, 1, bytes.len, fp.?);
}

extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, n: usize, stream: *anyopaque) usize;
extern "c" fn fclose(stream: *anyopaque) c_int;
