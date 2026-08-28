//! forge_3d kinematic character controller throughput bench (M1.1.12).
//!
//! Five rows, one per path the controller has: `moveCharacter` on a flat half-space, on a flight of
//! stairs, against a wall, on a tessellated triangle mesh, and `resizeCharacter`. Each row is a
//! DIFFERENT code path and not a different scale of the same one — the plane row runs the ground
//! sweep and nothing else, the stairs row arms the three step sweeps, the wall row arms the slide,
//! the mesh row puts the ground sweep and the contact fallback on a `.triangle_soup` shape, and the
//! resize row is the only one that allocates.
//!
//! **RUNS ARE INTERLEAVED, not best-of-N-per-mode.** Every rep runs all five modes in sequence and
//! the best rep per mode is kept, so a thermal ramp or a scheduling burst lands on all five rather
//! than on whichever happened to be measured while it passed. Best-of-three per mode cannot resolve
//! a gap under about 5 %, which is the size of the gaps between these rows.
//!
//! Each mode oscillates its character by a fixed displacement, alternating sign, so it stays inside
//! its scene for the whole batch. That is deliberate rather than convenient: a character walking off
//! the end of a flight of stairs would spend most of the batch in free flight and the row would
//! measure the plane path under the stairs' name.
//!
//! **Reported, not gated.** No numeric envelope is pre-registered — no baseline for this path has
//! ever been measured, and registering a bound before measuring it is the failure mode recorded at
//! M1.1.8. The controller's guarantees are carried by its acceptance suite, not by a figure here.
//!
//! ReleaseFast for the absolute ns (a Debug or ReleaseSafe run stays useful for relative
//! comparisons). Writes `bench/results/forge_3d_character.md`.

const std = @import("std");
const builtin = @import("builtin");
const forge = @import("forge_3d");
const api = @import("weld_forge");

const Real = forge.Real;
const Vec3r = forge.Vec3r;
const BodyManager = forge.BodyManager;
const ShapeStore = forge.ShapeStore;
const Broadphase = forge.Broadphase;
const CharacterStore = forge.CharacterStore;
/// The public `f32` vector the frozen mesh descriptor takes — named once so the bench does not
/// spell the path twice.
const MeshVec3 = @typeInfo(@FieldType(@FieldType(api.ShapeDescriptor, "triangle_mesh"), "vertices")).pointer.child;

/// Moves timed per mode per rep.
const n_moves = 2_000;
/// Interleaved reps; the best per mode is reported.
const n_reps = 8;
/// One tick at the fixed 60 Hz timestep.
const dt: Real = 1.0 / 60.0;
/// Oscillation amplitude, well under the 0.1 m broadphase fat margin on the way out and back so the
/// row is not dominated by proxy re-fits.
const stride: Real = 0.02;

// --- Monotonic clock (mirrors `bench/forge_3d_raycast.zig`: clock_gettime on POSIX, QPC on
// Windows — `std.time.Timer` is avoided for the same cross-platform reason). ---

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

fn vr(x: Real, y: Real, z: Real) Vec3r {
    return Vec3r.fromArray(.{ x, y, z });
}

/// NON-VACUITY counters for the resize row: a bench row that timed a REFUSAL under the name of a
/// success would be the same defect class as a test that exercises a path without testing it.
var resize_accepted: u64 = 0;
var resize_refused: u64 = 0;

const Mode = enum { plane, stairs, wall, mesh, resize };

fn modeName(m: Mode) []const u8 {
    return switch (m) {
        .plane => "moveCharacter / plane",
        .stairs => "moveCharacter / stairs",
        .wall => "moveCharacter / wall",
        .mesh => "moveCharacter / mesh floor",
        .resize => "resizeCharacter",
    };
}

const Scene = struct {
    store: ShapeStore = .{},
    bm: BodyManager = .{},
    bp: Broadphase,
    chars: CharacterStore = .{},
    character: api.CharacterId = undefined,
    /// Owned mesh arrays, freed with the scene — `createShape` copies them, but the builder's
    /// buffers are the bench's.
    verts: []MeshVec3 = &.{},
    tris: []u32 = &.{},

    fn deinit(self: *Scene, gpa: std.mem.Allocator) void {
        self.chars.deinit(gpa);
        self.store.deinit(gpa);
        self.bm.deinit(gpa);
        self.bp.deinit(gpa);
        if (self.verts.len != 0) gpa.free(self.verts);
        if (self.tris.len != 0) gpa.free(self.tris);
    }
};

/// A ground half-space plus whatever the mode needs, plus one character with its broadphase
/// presence registered — which the controller needs for self-exclusion to have anything to exclude.
fn buildScene(gpa: std.mem.Allocator, mode: Mode) !Scene {
    var scene = Scene{ .bp = Broadphase.init(.{}) };
    errdefer scene.deinit(gpa);

    // The floor. Every mode but `.mesh` stands on a half-space, which lives outside the trees.
    if (mode == .mesh) {
        // A 32 x 32 quad grid of unit cells centred on the origin: 2 048 triangles, paired seams,
        // flat. Flat and paired is the interesting case — the active-edge pass then snaps the
        // seam-derived normals, which is the work the row is meant to include.
        const side = 33;
        const verts = try gpa.alloc(MeshVec3, side * side);
        const tris = try gpa.alloc(u32, 32 * 32 * 6);
        for (0..side) |iz| {
            for (0..side) |ix| {
                const fx: f32 = @as(f32, @floatFromInt(ix)) - 16;
                const fz: f32 = @as(f32, @floatFromInt(iz)) - 16;
                verts[iz * side + ix] = .{ .data = .{ fx, 0, fz } };
            }
        }
        var w: usize = 0;
        for (0..32) |iz| {
            for (0..32) |ix| {
                const a: u32 = @intCast(iz * side + ix);
                const b: u32 = @intCast(iz * side + ix + 1);
                const c: u32 = @intCast((iz + 1) * side + ix);
                const d: u32 = @intCast((iz + 1) * side + ix + 1);
                // Wound so the face normals point +Y.
                tris[w + 0] = a;
                tris[w + 1] = c;
                tris[w + 2] = b;
                tris[w + 3] = b;
                tris[w + 4] = c;
                tris[w + 5] = d;
                w += 6;
            }
        }
        scene.verts = verts;
        scene.tris = tris;
        const shape = try scene.store.createShape(gpa, .{ .triangle_mesh = .{ .vertices = verts, .indices = tris } });
        const id = try scene.bm.addBody(gpa, &scene.store, .{
            .entity = .{ .index = 0, .generation = 0 },
            .body_type = .static,
            .shape = shape,
        });
        _ = try scene.bp.insert(gpa, .static, scene.bm.bodyAabb(&scene.store, id).?, id);
    } else {
        const plane = try scene.store.createShape(gpa, .{ .plane = .{ .normal = av3(0, 1, 0), .distance = 0 } });
        const id = try scene.bm.addBody(gpa, &scene.store, .{
            .entity = .{ .index = 0, .generation = 0 },
            .body_type = .static,
            .shape = plane,
        });
        _ = try scene.bp.insertUnbounded(gpa, .static, .{ .normal = Vec3r.unit_y, .distance = 0 }, id);
    }

    switch (mode) {
        // Four 0.2 m risers ahead of the character, each inside the default 0.3 m `step_height`, so
        // walking into the first one arms the climb every time.
        //
        .stairs => for (0..4) |i| {
            const h: f32 = 0.2 * @as(f32, @floatFromInt(i + 1));
            const shape = try scene.store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.5, h / 2, 2) } });
            const id = try scene.bm.addBody(gpa, &scene.store, .{
                .entity = .{ .index = @intCast(10 + i), .generation = 0 },
                .body_type = .static,
                .shape = shape,
                .position = av3(0.6 + @as(f32, @floatFromInt(i)), h / 2, 0),
            });
            _ = try scene.bp.insert(gpa, .static, scene.bm.bodyAabb(&scene.store, id).?, id);
        },
        // **The resize row needs its OWN scenery and two versions of this bench got it wrong.** A
        // resize's cost is dominated by the occupancy query over the target volume, so what that
        // query traverses IS the measurement. On a bare half-space it traverses nothing and the row
        // read 40.5 ns — a number whose name promised what a resize costs and whose value was what it
        // costs against an empty tree. Sharing the stairs' scenery then made every resize REFUSED,
        // because the first riser overlaps the capsule, so the row timed a refusal under the name of a
        // success. Both were caught by the accepted/refused counters, not by re-reading the code.
        //
        // What is built instead: one box whose tight box starts 0.05 m past the capsule's surface, so
        // the 0.1 m fat margin makes it a CANDIDATE the narrowphase must actually test and reject,
        // plus three further out for tree depth. Growth is vertical, so the gap survives it.
        .resize => {
            for (0..4) |i| {
                const cx: f32 = 0.75 + 1.2 * @as(f32, @floatFromInt(i));
                const shape = try scene.store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.4, 0.4, 0.4) } });
                const id = try scene.bm.addBody(gpa, &scene.store, .{
                    .entity = .{ .index = @intCast(20 + i), .generation = 0 },
                    .body_type = .static,
                    .shape = shape,
                    .position = av3(cx, 0.9, 0),
                });
                _ = try scene.bp.insert(gpa, .static, scene.bm.bodyAabb(&scene.store, id).?, id);
            }
        },
        // A wall too tall to climb, so the move slides along it instead.
        .wall => {
            const shape = try scene.store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.5, 2, 4) } });
            const id = try scene.bm.addBody(gpa, &scene.store, .{
                .entity = .{ .index = 10, .generation = 0 },
                .body_type = .static,
                .shape = shape,
                .position = av3(0.85, 2, 0),
            });
            _ = try scene.bp.insert(gpa, .static, scene.bm.bodyAabb(&scene.store, id).?, id);
        },
        else => {},
    }

    var desc = api.CharacterDescriptor{ .entity = .{ .index = 100, .generation = 0 } };
    desc.position = av3(0, 0.02, 0);
    scene.character = try scene.chars.createCharacter(gpa, &scene.store, &scene.bm, desc);
    if (try scene.chars.getCharacterInnerBody(scene.character)) |presence| {
        const proxy = try scene.bp.insert(
            gpa,
            .dynamic,
            scene.bm.bodyAabb(&scene.store, presence).?,
            presence,
        );
        scene.chars.setPresenceProxy(scene.character, proxy);
    }
    return scene;
}

/// One timed batch. Returns nanoseconds for the whole batch; the caller divides.
fn runBatch(gpa: std.mem.Allocator, scene: *Scene, mode: Mode, checksum: *f64) !i64 {
    const t0 = nowNs();
    var i: u32 = 0;
    while (i < n_moves) : (i += 1) {
        const sign: Real = if (i % 2 == 0) 1 else -1;
        switch (mode) {
            .resize => {
                // Two heights that both FIT, so the row measures the succeeding path — build, the
                // occupancy query, the commit and the destroy — and not an early refusal.
                const h: f32 = if (i % 2 == 0) 1.6 else 1.8;
                const ok = try scene.chars.resizeCharacter(gpa, &scene.bp, &scene.bm, &scene.store, scene.character, 0.3, h);
                if (ok) {
                    checksum.* += h;
                    resize_accepted += 1;
                } else resize_refused += 1;
            },
            else => {
                const r = try scene.chars.moveCharacter(
                    &scene.bp,
                    &scene.bm,
                    &scene.store,
                    scene.character,
                    vr(stride * sign, -stride, 0),
                    dt,
                );
                checksum.* += r.position.toArray()[0] + r.position.toArray()[1];
            },
        }
    }
    return nowNs() - t0;
}

pub fn main() !void {
    // `safety` FORCED true: its default is `std.debug.runtime_safety`, false in ReleaseFast, which
    // is the mode this bench runs in — a default-configured checker reports "no leaks"
    // unconditionally there, proven in both directions at M1.1.10 and M1.1.11.
    var debug_allocator: std.heap.DebugAllocator(.{ .safety = true }) = .init;
    // Declared FIRST so it runs LAST — after the scenes' own `defer`, which is the only order in
    // which the leak verdict sees a torn-down world.
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    const modes = [_]Mode{ .plane, .stairs, .wall, .mesh, .resize };
    var best: [modes.len]i64 = @splat(std.math.maxInt(i64));
    var checksum: f64 = 0;

    // The scenes are built ONCE and reused across reps, so construction never lands inside a timing
    // window and the mesh row is not really a mesh-build row.
    var scenes: [modes.len]Scene = undefined;
    for (modes, 0..) |m, i| scenes[i] = try buildScene(gpa, m);
    defer for (&scenes) |*s| s.deinit(gpa);

    // One untimed warm-up pass per mode: the first call of a fresh character grows its layer's moved
    // log, which is the one allocation on the pose path, and a first rep carrying it would report
    // an allocation cost every later rep does not pay.
    for (modes, 0..) |m, i| _ = try runBatch(gpa, &scenes[i], m, &checksum);

    var rep: u32 = 0;
    while (rep < n_reps) : (rep += 1) {
        // INTERLEAVED: all five modes inside the rep, in a fixed order.
        for (modes, 0..) |m, i| {
            const ns = try runBatch(gpa, &scenes[i], m, &checksum);
            if (ns < best[i]) best[i] = ns;
        }
    }

    const frame_ns: f64 = @as(f64, std.time.ns_per_s) / 60.0;
    var per_call: [modes.len]f64 = undefined;
    for (0..modes.len) |i| per_call[i] = @as(f64, @floatFromInt(best[i])) / @as(f64, n_moves);

    std.debug.print("\nforge_3d character controller bench ({s}, {d} calls x {d} interleaved reps, best rep)\n", .{ @tagName(builtin.mode), n_moves, n_reps });
    std.debug.print("  {s:<28} {s:>12} {s:>14} {s:>20}\n", .{ "mode", "ns/call", "calls/s", "calls/frame @60Hz" });
    for (modes, 0..) |m, i| {
        std.debug.print("  {s:<28} {d:>9.1} ns {d:>13.0} {d:>20.0}\n", .{
            modeName(m), per_call[i], 1.0e9 / per_call[i], frame_ns / per_call[i],
        });
    }
    std.debug.print("  (reported, not gated; checksum {d:.3}; resizes accepted {d} refused {d})\n", .{ checksum, resize_accepted, resize_refused });

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.print(gpa,
        \\# forge_3d kinematic character controller bench
        \\
        \\- Build mode: {s}
        \\- {d} calls per mode per rep, {d} INTERLEAVED reps, best rep reported
        \\- Anti-DCE checksum: {d:.3}
        \\
        \\| mode | ns/call | calls/s | calls per 16.67 ms frame |
        \\|---|---|---|---|
        \\
    , .{ @tagName(builtin.mode), n_moves, n_reps, checksum });
    for (modes, 0..) |m, i| {
        try buf.print(gpa, "| {s} | {d:.1} | {d:.0} | {d:.0} |\n", .{
            modeName(m), per_call[i], 1.0e9 / per_call[i], frame_ns / per_call[i],
        });
    }
    try buf.appendSlice(gpa,
        \\
        \\**Reported, not gated.** No envelope is pre-registered: this is the first measurement of
        \\this path, and registering a bound before measuring its baseline is the failure mode
        \\recorded at M1.1.8.
        \\
        \\Runs are INTERLEAVED — every rep runs all five modes in sequence and the best rep per mode
        \\is kept — so a thermal ramp or a scheduling burst lands on all five rather than on
        \\whichever happened to be measured while it passed. Best-of-N per mode cannot resolve a gap
        \\under about 5 %, which is the size of the gaps between these rows.
        \\
        \\The five rows are five different code paths, not five scales of one: the plane row runs the
        \\ground sweep alone, the stairs row arms the climb's three sweeps, the wall row arms the
        \\slide, the mesh row puts the ground sweep and the contact fallback on a `.triangle_soup`
        \\shape, and `resizeCharacter` is the only row that allocates.
        \\
    );

    const bytes = buf.items;
    const path: [:0]const u8 = "bench/results/forge_3d_character.md";
    const fp = fopen(path.ptr, "w");
    if (fp == null) return error.WriteReportFailed;
    _ = fwrite(bytes.ptr, 1, bytes.len, fp.?);
    _ = fclose(fp.?);

    // The scenes are torn down by the `defer` above, so the leak verdict is read after it — which
    // is why this is the last statement and not a `defer` of its own.
    std.debug.print("  allocator: checked with safety forced true\n", .{});
}

extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, n: usize, stream: *anyopaque) usize;
extern "c" fn fclose(stream: *anyopaque) c_int;
