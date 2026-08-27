//! The C1.1 verification instrument for `forge_3d` (M1.1.15.1).
//!
//! `engine-phase-1-criteria.md` C1.1 names this file as the point where the frame column is
//! measured, and until M1.1.15.1 **it did not exist**. Two files of the repository cited it
//! in the present tense, which made it read as delivered; `bench/forge_3d_raycast.zig` and
//! `bench/forge_3d_shapecast.zig` do reach 10 000 bodies, but they interrogate a STATIC
//! scene — they never tick. So C1.1's two figures were neither met nor refuted: they were
//! not measured, which is not the same thing.
//!
//! **WHAT IS GATED, and what is only reported.**
//!
//!   - GATED: frame time `<= 16.6 ms` at 1 000 dynamic + 10 000 static bodies, 60 Hz.
//!   - GATED: **zero allocations in steady state**, under an instrumented allocator. This
//!     one is DUE because `step` became `anyerror!void` at M1.1.15.1 over eight measured
//!     allocation sites: a fallible signature with no such measurement would silently
//!     legitimise per-frame allocation, when the eight are amortised growths on
//!     capacity-retaining lists. The signature says the tick MAY fail; this says that once
//!     the scene is stable it does not allocate. Neither substitutes for the other.
//!   - REPORTED: the step-2 retention shape, `M1.D.13`'s first oracle, with P and N measured
//!     at two sizes.
//!
//! **"STEADY STATE" IS DEFINED BEFORE IT IS MEASURED, AND THE DEFINITION IS NOT CIRCULAR.**
//! Defining it as "the frames after allocation stops" would make the zero-allocation result
//! true by choice of window and unable to fail. It is defined on the SCENE instead: steady
//! state begins at the first frame after which the retained candidate pair count AND the
//! constraint count are unchanged for `stability_window` consecutive frames. Those are
//! structural quantities the allocator knows nothing about, so "no allocation from there on"
//! is a PREDICTION this bench can falsify — and the frame at which it began is reported, so
//! a reader can see the window rather than take it.
//!
//! **A SLEEPING SCENE MEASURES NOTHING, so the gated run keeps its bodies awake.** C1.1 asks
//! for 1 000 dynamic bodies at 60 Hz, and a scene that has fallen asleep is not simulating
//! them: its frame time and its allocation count would both be excellent and both
//! meaningless. The gated run therefore uses `initNoSleep`, and the AWAKE BODY COUNT is
//! reported per window — the denominator without which neither figure can be read. The
//! sleeping-enabled variant is reported beside it, ungated, because the contrast is the
//! evidence that the choice matters.

const std = @import("std");
const builtin = @import("builtin");
const forge_3d = @import("forge_3d");
const api = @import("weld_forge");

const PhysicsWorld = forge_3d.PhysicsWorld;
const Vec3r = forge_3d.Vec3r;
const Real = forge_3d.Real;

/// C1.1's dynamic population.
const n_dynamic: usize = 1000;
/// C1.1's static population, and the second size the retention shape is measured at.
const n_static_full: usize = 10_000;
const n_static_small: usize = 2_500;

/// A frame budget of 60 Hz, in nanoseconds. C1.1 says "60 FPS (fixed step 60 Hz)".
const frame_budget_ns: i64 = 16_600_000;

/// How many consecutive unchanged frames define structural convergence. Thirty is half a
/// second at 60 Hz — long enough that a scene still settling cannot pass it by accident,
/// short enough that the warm-up does not dominate the run.
const stability_window: usize = 30;
/// Frames measured once steady state has begun.
const measure_frames: usize = 240;
/// Hard bound on the warm-up, so a scene that never converges FAILS LOUDLY instead of
/// running forever.
const max_warmup_frames: usize = 1200;

const fixed_dt: Real = 1.0 / 60.0;

fn av3(x: f32, y: f32, z: f32) @TypeOf(@as(api.BodyDescriptor, undefined).position) {
    return .{ .data = .{ x, y, z } };
}

fn vr(x: Real, y: Real, z: Real) Vec3r {
    return Vec3r.fromArray(.{ x, y, z });
}

// --- Monotonic clock (mirrors `bench/forge_3d_raycast.zig`) ------------------

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

// --- The instrumented allocator ---------------------------------------------

/// Counts allocation ATTEMPTS and passes everything through.
///
/// Counting `alloc`, `resize` AND `remap` matters and is not belt-and-braces: an
/// `ArrayListUnmanaged` growth tries `remap` first and only falls back to `alloc`, so a
/// counter watching `alloc` alone reports zero for a list that grew — the exact blind spot
/// that made an OOM injection report "no allocations seen" at M1.1.12. A `free` is not an
/// allocation and is not counted.
const CountingAllocator = struct {
    child: std.mem.Allocator,
    allocs: usize = 0,
    resizes: usize = 0,
    remaps: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn total(self: *const CountingAllocator) usize {
        return self.allocs + self.resizes + self.remaps;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.allocs += 1;
        return self.child.rawAlloc(len, alignment, ra);
    }
    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.resizes += 1;
        return self.child.rawResize(buf, alignment, new_len, ra);
    }
    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.remaps += 1;
        return self.child.rawRemap(buf, alignment, new_len, ra);
    }
    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(buf, alignment, ra);
    }
};

// --- The scene ---------------------------------------------------------------

/// A tiled floor of `n_floor` unit boxes with `n_dynamic` boxes resting ON it, plus `n_far`
/// statics placed far enough away to touch nothing.
///
/// The dynamic bodies are SPAWNED IN CONTACT rather than dropped: a falling population would
/// spend the warm-up changing its contact set, so structural convergence would measure the
/// fall rather than the simulation. They are spaced three units apart so they touch the floor
/// and not each other — one dynamic-dynamic contact per neighbour would triple the constraint
/// count and make the size points below incomparable.
///
/// **`n_far` IS THE WHOLE POINT OF THE RETENTION EXPERIMENT.** Growing the floor grows the
/// body count N and the retained pair count P *together*, so a frame time that grows with it
/// says nothing about which of the two drives step 2 — the first version of this bench did
/// exactly that and its "N x3.99 -> frame x4.09" line could not discriminate Θ(P·N) from
/// Θ(P). A far static field is what separates them: statics never pair with statics
/// (`default_layer_pairs`), so these bodies enter the broadphase and the registration list
/// and contribute ZERO pairs. N moves, P does not.
fn buildScene(
    gpa: std.mem.Allocator,
    pw: *PhysicsWorld,
    n_floor: usize,
    n_far: usize,
) !void {
    const side: usize = std.math.sqrt(n_floor);
    const floor_shape = try pw.store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });
    var placed: usize = 0;
    var row: usize = 0;
    while (row < side and placed < n_floor) : (row += 1) {
        var col: usize = 0;
        while (col < side and placed < n_floor) : (col += 1) {
            const x: f32 = @floatFromInt(col);
            const z: f32 = @floatFromInt(row);
            _ = try pw.addBody(gpa, .{
                .entity = .{ .index = @intCast(placed), .generation = 0 },
                .body_type = .static,
                .shape = floor_shape,
                .position = av3(x, -0.5, z),
            });
            placed += 1;
        }
    }

    // The far field. Two units apart so they do not even touch each other, and 1 000 units
    // away so no fat AABB of the scene proper can ever reach them.
    const far_side: usize = std.math.sqrt(n_far) + 1;
    var far_made: usize = 0;
    var fr: usize = 0;
    while (fr < far_side and far_made < n_far) : (fr += 1) {
        var fc: usize = 0;
        while (fc < far_side and far_made < n_far) : (fc += 1) {
            const x: f32 = 1000.0 + @as(f32, @floatFromInt(fc * 2));
            const z: f32 = 1000.0 + @as(f32, @floatFromInt(fr * 2));
            _ = try pw.addBody(gpa, .{
                .entity = .{ .index = @intCast(placed + far_made), .generation = 0 },
                .body_type = .static,
                .shape = floor_shape,
                .position = av3(x, -0.5, z),
            });
            far_made += 1;
        }
    }

    const box_shape = try pw.store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.4, 0.4, 0.4) } });
    const span: usize = @max(1, side / 3);
    var made: usize = 0;
    var r: usize = 0;
    while (r < span and made < n_dynamic) : (r += 1) {
        var c: usize = 0;
        while (c < span and made < n_dynamic) : (c += 1) {
            const x: f32 = @floatFromInt(c * 3);
            const z: f32 = @floatFromInt(r * 3);
            var desc = api.BodyDescriptor{
                .entity = .{ .index = @intCast(placed + far_made + made), .generation = 0 },
                .body_type = .dynamic,
                .shape = box_shape,
            };
            desc.position = av3(x, 0.4, z);
            desc.mass = 1;
            desc.restitution = 0;
            _ = try pw.addBody(gpa, desc);
            made += 1;
        }
    }
}

/// What one run of the instrument produced.
const Run = struct {
    n_bodies: usize,
    n_floor: usize,
    n_far: usize,
    /// The frame at which structural convergence was reached — the start of steady state.
    steady_from: usize,
    /// Retained candidate pairs (P) over the measured window.
    pairs: usize,
    /// Constraints over the measured window.
    constraints: usize,
    /// How many DYNAMIC bodies exist at all — the ceiling the next two are read against.
    n_dynamic_built: usize,
    /// Awake DYNAMIC bodies per frame over the measured window. THE DENOMINATOR.
    awake_min: usize,
    awake_max: usize,
    /// Allocation attempts during the warm-up, and during the measured window.
    allocs_warmup: usize,
    allocs_steady: usize,
    /// The steady-state total split by kind, so a non-zero figure names its own mechanism
    /// instead of being a number to go hunting for.
    steady_allocs: usize,
    steady_resizes: usize,
    steady_remaps: usize,
    median_ns: i64,
    max_ns: i64,
    /// A checksum over the poses, so the optimiser cannot elide the simulation.
    checksum: f64,
};

fn run(gpa: std.mem.Allocator, n_floor: usize, n_far: usize, allow_sleeping: bool) !Run {
    var counting = CountingAllocator{ .child = gpa };
    const ca = counting.allocator();

    var pw = if (allow_sleeping)
        PhysicsWorld.init(vr(0, -9.81, 0), fixed_dt)
    else
        PhysicsWorld.initNoSleep(vr(0, -9.81, 0), fixed_dt);
    defer pw.deinit(ca);

    try buildScene(ca, &pw, n_floor, n_far);
    const n_bodies = pw.bodies.items.len;

    // Count the dynamic population ONCE, up front. It is the ceiling the awake figure is read
    // against, and reading it from the scene rather than from `n_dynamic` means the guard
    // below still bites when the floor is too small to seat the full population.
    var n_dynamic_built: usize = 0;
    for (pw.bodies.items) |entry| {
        if (pw.bm.bodyType(entry.id) == .dynamic) n_dynamic_built += 1;
    }

    // WARM-UP, until the SCENE converges. The criterion is structural and the allocator is
    // not consulted, which is what lets the zero-allocation claim below be falsifiable.
    var last_pairs: usize = std.math.maxInt(usize);
    var last_constraints: usize = std.math.maxInt(usize);
    var stable: usize = 0;
    var frame: usize = 0;
    while (frame < max_warmup_frames) : (frame += 1) {
        try pw.step(ca);
        const p = pw.active.items.len;
        const c = pw.constraints.items.len;
        if (p == last_pairs and c == last_constraints) stable += 1 else stable = 0;
        last_pairs = p;
        last_constraints = c;
        if (stable >= stability_window) break;
    }
    if (stable < stability_window) return error.SceneNeverConverged;

    const steady_from = frame + 1;
    const allocs_warmup = counting.total();
    const warm_allocs = counting.allocs;
    const warm_resizes = counting.resizes;
    const warm_remaps = counting.remaps;

    // THE MEASURED WINDOW.
    var samples: [measure_frames]i64 = undefined;
    var awake_min: usize = std.math.maxInt(usize);
    var awake_max: usize = 0;
    var checksum: f64 = 0;
    var i: usize = 0;
    while (i < measure_frames) : (i += 1) {
        const t0 = nowNs();
        try pw.step(ca);
        samples[i] = nowNs() - t0;

        // AWAKE **DYNAMIC** BODIES, and the qualifier is the correction: `isSleeping` answers
        // `false` for a static, which never carries the flag at all. The first version of this
        // bench counted every body and reported "11000..11000 awake" for a scene whose 1 000
        // dynamics had all fallen asleep — a denominator that could not fall below 10 000 and
        // a guard that could therefore never fire. The type filter is what makes both real.
        var awake: usize = 0;
        for (pw.bodies.items) |entry| {
            const pos = pw.bm.position(entry.id).?.toArray();
            checksum += @floatCast(pos[1]);
            if (pw.bm.bodyType(entry.id) != .dynamic) continue;
            const sleeping = pw.bm.isSleeping(entry.id) orelse continue;
            if (!sleeping) awake += 1;
        }
        awake_min = @min(awake_min, awake);
        awake_max = @max(awake_max, awake);
    }

    std.mem.sort(i64, &samples, {}, std.sort.asc(i64));
    var max_ns: i64 = 0;
    for (samples) |v| max_ns = @max(max_ns, v);

    return .{
        .n_bodies = n_bodies,
        .n_floor = n_floor,
        .n_far = n_far,
        .steady_from = steady_from,
        .pairs = pw.active.items.len,
        .constraints = pw.constraints.items.len,
        .n_dynamic_built = n_dynamic_built,
        .awake_min = awake_min,
        .awake_max = awake_max,
        .allocs_warmup = allocs_warmup,
        .allocs_steady = counting.total() - allocs_warmup,
        .steady_allocs = counting.allocs - warm_allocs,
        .steady_resizes = counting.resizes - warm_resizes,
        .steady_remaps = counting.remaps - warm_remaps,
        .median_ns = samples[measure_frames / 2],
        .max_ns = max_ns,
        .checksum = checksum,
    };
}

pub fn main(init: std.process.Init) !void {
    _ = init;
    // A leak-checking allocator with `safety` FORCED true. Its default is
    // `std.debug.runtime_safety`, false in ReleaseFast — so the default would report "no
    // leaks" unconditionally, which is not a weaker check but one that cannot fail.
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

    std.debug.print("\nforge_3d integration bench (C1.1) — mode={s} precision={s}\n", .{
        @tagName(builtin.mode),
        if (Real == f64) "f64" else "f32",
    });
    std.debug.print("  steady state := the frame after which retained pairs AND constraints\n", .{});
    std.debug.print("  are unchanged for {d} consecutive frames; {d} frames measured after it.\n", .{
        stability_window, measure_frames,
    });
    std.debug.print("  awake = awake DYNAMIC bodies (a static never carries the flag).\n\n", .{});

    // THE GATED RUN — bodies kept awake, because C1.1 asks for 1 000 dynamic bodies
    // SIMULATING and a sleeping scene does not simulate them.
    const gated = try run(gpa, n_static_full, 0, false);
    // The contrast, ungated: the same scene allowed to sleep.
    const sleeping = try run(gpa, n_static_full, 0, true);
    // The retention pair. SAME floor, SAME dynamics, SAME P — only N differs.
    const ret_a = try run(gpa, n_static_small, 0, false);
    const ret_b = try run(gpa, n_static_small, n_static_full - n_static_small, false);

    printRun("GATED  awake (no sleep)", gated);
    printRun("       sleeping allowed", sleeping);
    printRun("       retention A (P held)", ret_a);
    printRun("       retention B (P held)", ret_b);

    std.debug.print("\n  retention shape of step 2 (M1.D.13's first oracle, REPORTED not gated):\n", .{});
    std.debug.print("    A: N={d} P={d} -> median {d} ns\n", .{ ret_a.n_bodies, ret_a.pairs, ret_a.median_ns });
    std.debug.print("    B: N={d} P={d} -> median {d} ns   (+{d} far statics, zero pairs)\n", .{
        ret_b.n_bodies, ret_b.pairs, ret_b.median_ns, ret_b.n_far,
    });
    const rn = @as(f64, @floatFromInt(ret_b.n_bodies)) / @as(f64, @floatFromInt(ret_a.n_bodies));
    const rt = @as(f64, @floatFromInt(ret_b.median_ns)) / @as(f64, @floatFromInt(ret_a.median_ns));
    std.debug.print("    N x{d:.2} at CONSTANT P -> frame x{d:.2}\n", .{ rn, rt });
    std.debug.print("    a Theta(P*N) step 2 would cost {d} resolutions/frame at B against {d} at A (x{d:.2})\n", .{
        2 * ret_b.pairs * ret_b.n_bodies, 2 * ret_a.pairs * ret_a.n_bodies, rn,
    });
    // The confounded pair, shown BECAUSE it is confounded: it is the reading the first
    // version of this bench offered, and on its own it discriminates nothing.
    std.debug.print("    (confounded, for contrast: growing the FLOOR moves N and P together —\n", .{});
    std.debug.print("     N={d} P={d} -> {d} ns  vs  N={d} P={d} -> {d} ns)\n", .{
        ret_a.n_bodies, ret_a.pairs, ret_a.median_ns, gated.n_bodies, gated.pairs, gated.median_ns,
    });

    std.debug.print("\n  checksum (anti-DCE): {d:.6}\n", .{
        gated.checksum + sleeping.checksum + ret_a.checksum + ret_b.checksum,
    });

    // --- the two gates ---
    var failed = false;
    if (gated.median_ns > frame_budget_ns) {
        std.debug.print("\nGATE FAILED: median frame {d} ns exceeds the 60 Hz budget of {d} ns\n", .{ gated.median_ns, frame_budget_ns });
        failed = true;
    }
    if (gated.allocs_steady != 0) {
        std.debug.print("\nGATE FAILED: {d} allocation attempts in steady state (expected 0)\n", .{gated.allocs_steady});
        failed = true;
    }
    // TWO GUARDS ON THE GATE ITSELF. A window in which the dynamics are asleep, or a scene
    // whose floor was too small to seat them, makes both figures excellent and meaningless.
    if (gated.n_dynamic_built < n_dynamic) {
        std.debug.print("\nGATE FAILED: the scene seated {d} dynamic bodies, C1.1 asks for {d}\n", .{ gated.n_dynamic_built, n_dynamic });
        failed = true;
    }
    if (gated.awake_min < gated.n_dynamic_built) {
        std.debug.print("\nGATE FAILED: only {d} of {d} dynamic bodies awake at the minimum — the window measured a sleeping scene\n", .{ gated.awake_min, gated.n_dynamic_built });
        failed = true;
    }
    if (failed) return error.BenchGateFailed;
    std.debug.print("\n  both gates PASS, on {d} awake dynamic bodies of {d} total.\n", .{
        gated.awake_min, gated.n_bodies,
    });
}

fn printRun(label: []const u8, r: Run) void {
    std.debug.print(
        "  {s}: N={d} (floor {d} + far {d}) steady_from=frame {d} P={d} constraints={d}\n" ++
            "      awake dyn/frame {d}..{d} of {d}  median={d} ns max={d} ns\n" ++
            "      allocs warmup={d} steady={d} (alloc {d} / resize {d} / remap {d})\n",
        .{
            label,           r.n_bodies,        r.n_floor,       r.n_far,
            r.steady_from,   r.pairs,           r.constraints,   r.awake_min,
            r.awake_max,     r.n_dynamic_built, r.median_ns,     r.max_ns,
            r.allocs_warmup, r.allocs_steady,   r.steady_allocs, r.steady_resizes,
            r.steady_remaps,
        },
    );
}
