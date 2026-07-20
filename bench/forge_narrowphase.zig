//! forge_3d narrowphase fast-path microbench (M1.1.4).
//!
//! For each of the four fast pairs (sphere/sphere, sphere/box, box/box,
//! capsule/capsule) it times the REAL dispatched `collideOrdered` (which routes
//! through the analytic kernel) against the generic GJK/EPA oracle
//! `collideOrderedGeneric` on the SAME pre-computed pose set, mixing contact and
//! separated inputs. A running checksum over the manifolds is written to the
//! report to defeat dead-code elimination. Reports per-pair ns/pair and the
//! dispatched/generic ratio; the fast path must be strictly faster on every
//! pair. ReleaseFast (a Debug/ReleaseSafe run only prints a warning — the ratio
//! is still meaningful, the absolute ns are not). Writes
//! `bench/results/forge_narrowphase.md`.

const std = @import("std");
const builtin = @import("builtin");
const forge = @import("forge_3d");

const Real = forge.Real;
const Vec3r = forge.Vec3r;
const Quatr = forge.Quatr;
const SupportShape = forge.SupportShape;
const ContactManifold = forge.ContactManifold;

const n_poses = 2000; // pre-computed B poses per pair (contact + separated mix)
const n_reps = 100; // measured repetitions over the whole pose set

// --- Monotonic clock (mirrors bench/ipc_rtt.zig: clock_gettime on POSIX, QPC on
// Windows — std.time.Timer is avoided for the same cross-platform reason). ---

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

fn sphereShape(radius: Real) SupportShape {
    return .{ .core = .point, .radius = radius };
}
fn boxShape(hx: Real, hy: Real, hz: Real) SupportShape {
    return .{ .core = .{ .box = Vec3r.fromArray(.{ hx, hy, hz }) }, .radius = 0 };
}
fn capsuleShape(half_height: Real, radius: Real) SupportShape {
    return .{ .core = .{ .segment = half_height }, .radius = radius };
}

/// Fold a manifold into the anti-DCE checksum (reads normal, count, penetrations).
fn accumulate(chk: *f64, m: ?ContactManifold) void {
    if (m) |x| {
        chk.* += @as(f64, @floatFromInt(x.count)) + @as(f64, @floatCast(x.normal.toArray()[0]));
        for (0..x.count) |i| chk.* += @as(f64, @floatCast(x.points[i].penetration));
    }
}

const PairResult = struct {
    name: []const u8,
    disp_ns_per: f64,
    gen_ns_per: f64,
    ratio: f64, // dispatched / generic (< 1 ⇒ faster)
};

/// Time the dispatched path and the generic oracle over the same pose set.
fn benchPair(name: []const u8, sa: SupportShape, sb: SupportShape, positions: []const Vec3r, rotations: []const Quatr, chk: *f64) PairResult {
    const origin = Vec3r.zero;
    const id = Quatr.identity;
    // Warm-up (untimed) — one pass each.
    for (positions, rotations) |pb, rb| {
        accumulate(chk, forge.collideOrdered(sa, origin, id, sb, pb, rb));
        accumulate(chk, forge.collideOrderedGeneric(sa, origin, id, sb, pb, rb));
    }
    // Dispatched.
    const t0 = nowNs();
    var rep: usize = 0;
    while (rep < n_reps) : (rep += 1) {
        for (positions, rotations) |pb, rb| accumulate(chk, forge.collideOrdered(sa, origin, id, sb, pb, rb));
    }
    const disp_ns: f64 = @floatFromInt(nowNs() - t0);
    // Generic oracle.
    const t1 = nowNs();
    rep = 0;
    while (rep < n_reps) : (rep += 1) {
        for (positions, rotations) |pb, rb| accumulate(chk, forge.collideOrderedGeneric(sa, origin, id, sb, pb, rb));
    }
    const gen_ns: f64 = @floatFromInt(nowNs() - t1);
    const calls: f64 = @floatFromInt(n_poses * n_reps);
    return .{
        .name = name,
        .disp_ns_per = disp_ns / calls,
        .gen_ns_per = gen_ns / calls,
        .ratio = disp_ns / gen_ns,
    };
}

pub fn main() !void {
    if (builtin.mode != .ReleaseFast) {
        std.debug.print("warning: forge-narrowphase bench should run in ReleaseFast (got {s}); the dispatched/generic ratio is still meaningful, absolute ns are not.\n", .{@tagName(builtin.mode)});
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    // Deterministic pose set (fixed seed): B positions in a cube around A (a mix
    // of overlapping and clearly separated) + a random orientation each. Shared
    // by all pairs so the dispatched and generic paths see identical inputs.
    var prng = std.Random.DefaultPrng.init(0xF03B_1149);
    const rng = prng.random();
    const positions = try gpa.alloc(Vec3r, n_poses);
    const rotations = try gpa.alloc(Quatr, n_poses);
    const range: Real = 2.5;
    for (positions, rotations) |*p, *r| {
        p.* = Vec3r.fromArray(.{
            (rng.float(Real) * 2 - 1) * range,
            (rng.float(Real) * 2 - 1) * range,
            (rng.float(Real) * 2 - 1) * range,
        });
        var axis = Vec3r.fromArray(.{ rng.float(Real) * 2 - 1, rng.float(Real) * 2 - 1, rng.float(Real) * 2 - 1 });
        if (axis.dot(axis) < 1.0e-6) axis = Vec3r.unit_y;
        r.* = Quatr.fromAxisAngle(axis.normalize(), rng.float(Real) * 2 * std.math.pi);
    }

    var chk: f64 = 0;
    var results: [4]PairResult = undefined;
    results[0] = benchPair("sphere/sphere", sphereShape(1), sphereShape(1), positions, rotations, &chk);
    results[1] = benchPair("sphere/box", sphereShape(0.7), boxShape(1, 1, 1), positions, rotations, &chk);
    results[2] = benchPair("box/box", boxShape(1, 1, 1), boxShape(1, 1, 1), positions, rotations, &chk);
    results[3] = benchPair("capsule/capsule", capsuleShape(1, 0.3), capsuleShape(1, 0.3), positions, rotations, &chk);

    var all_faster = true;
    std.debug.print("\nforge narrowphase fast-path bench ({s}, {d} poses x {d} reps)\n", .{ @tagName(builtin.mode), n_poses, n_reps });
    std.debug.print("  {s:<16} {s:>12} {s:>12} {s:>8}\n", .{ "pair", "dispatched", "generic", "ratio" });
    for (results) |res| {
        if (res.ratio >= 1.0) all_faster = false;
        std.debug.print("  {s:<16} {d:>9.2} ns {d:>9.2} ns {d:>7.3}\n", .{ res.name, res.disp_ns_per, res.gen_ns_per, res.ratio });
    }
    std.debug.print("  verdict: {s} (checksum {d})\n", .{ if (all_faster) "GO — dispatched faster on every pair" else "NO-GO", chk });

    // Markdown report (arena-allocated pieces concatenated).
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(gpa, try std.fmt.allocPrint(gpa,
        \\# forge_3d narrowphase fast-path bench
        \\
        \\- Build mode: {s}
        \\- Poses per pair: {d} (contact + separated mix), reps: {d}
        \\- Anti-DCE checksum: {d}
        \\
        \\| pair | dispatched (ns/pair) | generic (ns/pair) | ratio (disp/gen) |
        \\|---|---|---|---|
        \\
    , .{ @tagName(builtin.mode), n_poses, n_reps, chk }));
    for (results) |res| {
        try buf.appendSlice(gpa, try std.fmt.allocPrint(gpa, "| {s} | {d:.2} | {d:.2} | {d:.3} |\n", .{ res.name, res.disp_ns_per, res.gen_ns_per, res.ratio }));
    }
    try buf.appendSlice(gpa, try std.fmt.allocPrint(gpa,
        \\
        \\**Verdict:** {s} — the dispatched fast path must be strictly faster than
        \\the generic GJK/EPA oracle on every pair (ratio < 1). Absolute ns are only
        \\meaningful in ReleaseFast.
        \\
    , .{if (all_faster) "GO" else "NO-GO"}));

    const bytes = buf.items;
    const path: [:0]const u8 = "bench/results/forge_narrowphase.md";
    const fp = fopen(path.ptr, "w");
    if (fp == null) return error.WriteReportFailed;
    defer _ = fclose(fp.?);
    _ = fwrite(bytes.ptr, 1, bytes.len, fp.?);
}

extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, n: usize, stream: *anyopaque) usize;
extern "c" fn fclose(stream: *anyopaque) c_int;
