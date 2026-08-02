//! forge_3d static-triangle-mesh bench (M1.1.11.1).
//!
//! Three things are measured, and only the third exists to settle a decision:
//!
//!   1. **BUILD time against triangle count** — validation, the owned copy, the binned-SAH
//!      tree and the edge adjacency, at three sizes. Reported.
//!   2. **TRAVERSAL time against triangle count** — the ray family through a mesh, at the
//!      same three sizes, so the logarithmic claim is visible as a curve rather than
//!      asserted as a bound. Reported.
//!   3. **The `worldAabb` O(V) pass on the `aabbOverlapsBody` path.** This one is a
//!      DECISION, promised at gate A and taken here on figures: a mesh's world AABB is the
//!      TIGHT box over its transported vertices, which is a pass over every vertex, and
//!      `overlapAabb` runs it once per candidate body per query. The alternative — a
//!      per-body box cached at `addBody`, with no invalidation logic because a mesh forces a
//!      static body — is measured beside it. If the gap matters, the cache lands; if it does
//!      not, nothing is added and the figures say why.
//!
//! **Reported, not gated** for rows 1 and 2: no baseline for this path has ever been
//! measured, and registering an envelope before measuring it is the failure mode recorded
//! at M1.1.8.
//!
//! ReleaseFast for the absolute ns (a Debug / ReleaseSafe run prints a warning and stays
//! useful for relative comparisons). Writes `bench/results/forge_3d_mesh.md`.

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

/// The three sizes. Chosen so the middle one is the "few thousand triangles" the
/// `worldAabb` decision is to be taken on, and the outer two bracket it by a factor of four
/// each so a linear term is visible as one.
const sizes = [_]u32{ 1_000, 4_000, 16_000 };
const n_queries = 2_000;
const n_reps = 5;

// --- Monotonic clock (identical to `bench/forge_3d_shapecast.zig`: `clock_gettime` on
// POSIX, QPC on Windows — `std.time.Timer` avoided for the same cross-platform reason). ---

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

/// A pseudo-random mesh descriptor of `triangle_count` triangles spread over a 40 m cube,
/// each about a metre across. The caller owns both arrays.
const MeshArrays = struct {
    vertices: []@TypeOf(av3(0, 0, 0)),
    indices: []u32,

    fn deinit(self: MeshArrays, gpa: std.mem.Allocator) void {
        gpa.free(self.vertices);
        gpa.free(self.indices);
    }
};

fn buildMeshArrays(gpa: std.mem.Allocator, triangle_count: u32, seed: u64) !MeshArrays {
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();
    const vertices = try gpa.alloc(@TypeOf(av3(0, 0, 0)), triangle_count * 3);
    const indices = try gpa.alloc(u32, triangle_count * 3);
    for (0..triangle_count) |t| {
        const bx = rand.float(f32) * 40 - 20;
        const by = rand.float(f32) * 40 - 20;
        const bz = rand.float(f32) * 40 - 20;
        // Two roughly-orthogonal offsets of at least 0.2, so the cross product is bounded
        // away from zero and `createShape` never refuses the descriptor.
        const a = 0.2 + rand.float(f32) * 1.3;
        const c = 0.2 + rand.float(f32) * 1.3;
        vertices[t * 3 + 0] = av3(bx, by, bz);
        vertices[t * 3 + 1] = av3(bx + a, by, bz);
        vertices[t * 3 + 2] = av3(bx, by + c, bz);
        indices[t * 3 + 0] = @intCast(t * 3 + 0);
        indices[t * 3 + 1] = @intCast(t * 3 + 1);
        indices[t * 3 + 2] = @intCast(t * 3 + 2);
    }
    return .{ .vertices = vertices, .indices = indices };
}

const Row = struct {
    triangles: u32,
    build_ns: i64,
    ray_ns: f64,
    ray_hits: u32,
    world_aabb_ns: f64,
    cached_aabb_ns: f64,
    overlap_aabb_ns: f64,
};

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{ .safety = true }) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);

    var rows: [sizes.len]Row = undefined;

    for (sizes, 0..) |triangle_count, row_index| {
        const arrays = try buildMeshArrays(gpa, triangle_count, 0xB0A7 + row_index);
        defer arrays.deinit(gpa);

        // --- 1. BUILD: the median of `n_reps` creations, each destroyed immediately so the
        // allocator state is comparable between reps.
        var build_samples: [n_reps]i64 = undefined;
        for (0..n_reps) |rep| {
            var store = ShapeStore{};
            defer store.deinit(gpa);
            const t0 = nowNs();
            const id = try store.createShape(gpa, .{ .triangle_mesh = .{
                .vertices = arrays.vertices,
                .indices = arrays.indices,
            } });
            const t1 = nowNs();
            build_samples[rep] = t1 - t0;
            std.mem.doNotOptimizeAway(id);
        }
        std.mem.sort(i64, &build_samples, {}, std.sort.asc(i64));

        // --- The scene the two query rows share: ONE static mesh body at the origin.
        var store = ShapeStore{};
        defer store.deinit(gpa);
        var bm = BodyManager{};
        defer bm.deinit(gpa);
        var bp = Broadphase.init(.{});
        defer bp.deinit(gpa);

        const shape = try store.createShape(gpa, .{ .triangle_mesh = .{
            .vertices = arrays.vertices,
            .indices = arrays.indices,
        } });
        const body = try bm.addBody(gpa, &store, .{
            .shape = shape,
            .body_type = .static,
            .entity = .{ .index = 0, .generation = 0 },
        });
        _ = try bp.insert(gpa, .static, bm.bodyAabb(&store, body).?, body);

        // --- 2. TRAVERSAL: rays aimed at the mesh from 60 m out, so the walk is real work
        // and not a root rejection.
        var prng = std.Random.DefaultPrng.init(0x1234 + row_index);
        const rand = prng.random();
        var ray_ns: i64 = 0;
        var ray_hits: u32 = 0;
        for (0..n_queries) |_| {
            const raw = Vec3r.fromArray(.{
                rand.float(Real) * 2 - 1,
                rand.float(Real) * 2 - 1,
                rand.float(Real) * 2 - 1,
            });
            if (@reduce(.Max, @abs(raw.data)) == 0) continue;
            const unit = raw.scale(1 / raw.length());
            const q = query.RayQuery{
                .origin = unit.scale(60),
                .direction = unit.neg(),
                .max_distance = 200,
            };
            const t0 = nowNs();
            const hit = query.raycast(&bp, &bm, &store, q);
            ray_ns += nowNs() - t0;
            if (hit != null) ray_hits += 1;
        }

        // --- 3. THE `worldAabb` DECISION. Three measurements on the same body:
        //   * `worldAabb` alone — the O(V) pass, which is what `aabbOverlapsBody` runs;
        //   * the same value read from a local variable — the cache that would replace it;
        //   * `overlapAabb` end to end, so the pass is seen against the cost it sits in.
        const record = store.get(shape).?;
        const pose_position = bm.position(body).?;
        const pose_rotation = bm.rotation(body).?;
        var world_aabb_ns: i64 = 0;
        var cached_aabb_ns: i64 = 0;
        const cached = forge.worldAabb(record, pose_position, pose_rotation);
        for (0..n_queries) |_| {
            const t0 = nowNs();
            const computed = forge.worldAabb(record, pose_position, pose_rotation);
            world_aabb_ns += nowNs() - t0;
            std.mem.doNotOptimizeAway(computed.min.data[0]);

            const t1 = nowNs();
            const reused = cached;
            cached_aabb_ns += nowNs() - t1;
            std.mem.doNotOptimizeAway(reused.min.data[0]);
        }

        var overlap_ns: i64 = 0;
        var buf: [8]api.BodyId = undefined;
        for (0..n_queries) |_| {
            const half: Real = 5;
            const centre = Vec3r.fromArray(.{
                rand.float(Real) * 40 - 20,
                rand.float(Real) * 40 - 20,
                rand.float(Real) * 40 - 20,
            });
            const t0 = nowNs();
            const found = query.overlapAabb(
                &bp,
                &bm,
                &store,
                centre.sub(Vec3r.splat(half)),
                centre.add(Vec3r.splat(half)),
                .{},
                &buf,
            );
            overlap_ns += nowNs() - t0;
            std.mem.doNotOptimizeAway(found);
        }

        rows[row_index] = .{
            .triangles = triangle_count,
            .build_ns = build_samples[n_reps / 2],
            .ray_ns = @as(f64, @floatFromInt(ray_ns)) / @as(f64, n_queries),
            .ray_hits = ray_hits,
            .world_aabb_ns = @as(f64, @floatFromInt(world_aabb_ns)) / @as(f64, n_queries),
            .cached_aabb_ns = @as(f64, @floatFromInt(cached_aabb_ns)) / @as(f64, n_queries),
            .overlap_aabb_ns = @as(f64, @floatFromInt(overlap_ns)) / @as(f64, n_queries),
        };
    }

    // The report is assembled with `allocPrint` into a plain byte list, the shape
    // `bench/forge_3d_shapecast.zig` uses: an `ArrayListUnmanaged` carries no writer in
    // Zig 0.16, and reaching for one is the mistake this comment exists to prevent.
    const append = struct {
        fn f(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
            const text = try std.fmt.allocPrint(allocator, fmt, args);
            defer allocator.free(text);
            try list.appendSlice(allocator, text);
        }
    }.f;

    try out.appendSlice(gpa, "# forge_3d mesh bench (M1.1.11.1)\n\n");
    if (builtin.mode != .ReleaseFast) {
        try out.appendSlice(gpa,
            \\> **Not a ReleaseFast run.** The absolute figures below are not comparable with
            \\> a ReleaseFast baseline; the relative columns still are.
            \\
            \\
        );
        std.debug.print("warning: build mode is {s}; absolute ns are only meaningful in ReleaseFast\n", .{@tagName(builtin.mode)});
    }
    try append(&out, gpa, "Scalar `Real` = `{s}`, optimize = `{s}`.\n\n", .{ @typeName(Real), @tagName(builtin.mode) });
    try out.appendSlice(gpa,
        \\| triangles | build (median) | raycast | hits | `worldAabb` | cached box | `overlapAabb` |
        \\|---|---|---|---|---|---|---|
        \\
    );
    for (rows) |r| {
        try append(&out, gpa, "| {d} | {d:.3} ms | {d:.1} ns | {d}/{d} | {d:.1} ns | {d:.1} ns | {d:.1} ns |\n", .{
            r.triangles,
            @as(f64, @floatFromInt(r.build_ns)) / 1_000_000.0,
            r.ray_ns,
            r.ray_hits,
            n_queries,
            r.world_aabb_ns,
            r.cached_aabb_ns,
            r.overlap_aabb_ns,
        });
    }
    try out.appendSlice(gpa,
        \\
        \\`worldAabb` is the O(V) pass over the mesh's transported vertices; `cached box` is
        \\the same value read from a variable, i.e. the floor a per-body cache could reach.
        \\The difference between the two columns IS the cost of the decision taken at gate A,
        \\and `overlapAabb` is the query it sits inside.
        \\
    );

    // `fopen`/`fwrite` through libc, exactly as `bench/forge_3d_raycast.zig` does — the
    // sibling convention, not an improvisation.
    const bytes = out.items;
    const path: [:0]const u8 = "bench/results/forge_3d_mesh.md";
    const fp = fopen(path.ptr, "w");
    if (fp == null) return error.WriteReportFailed;
    defer _ = fclose(fp.?);
    _ = fwrite(bytes.ptr, 1, bytes.len, fp.?);
    std.debug.print("{s}", .{bytes});
}

extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, n: usize, stream: *anyopaque) usize;
extern "c" fn fclose(stream: *anyopaque) c_int;
