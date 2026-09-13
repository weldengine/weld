//! Pose buffer layout: AoS against SoA, on the two operations that pull in
//! opposite directions.
//!
//! **THIS BENCH DECIDES A DESIGN, and there is no target to clear.** The pose
//! type crosses `sampleClip`, `blendPoses` and `additivePose`, it freezes with
//! `AnimationModule`, and it is snapshotted by rollback — so changing it later
//! is a reopened frozen interface plus a save-format migration. Three documents
//! asserted a layout for it and none had measured one. What is measured here is
//! the number the ruling rests on.
//!
//! **The two operations are chosen because they disagree.** A pose BLEND is
//! bone-by-bone with no dependency between bones, so the columns are
//! independent and the SoA forms can stream them. FORWARD KINEMATICS is
//! serialised by the parent → child dependency and reads a whole transform per
//! bone, which is what AoS gives in one cache line. A ruling taken on blend
//! alone is a ruling taken on half the evidence.
//!
//! **Three layouts, not two, and the third is why.** The corpus defines SoA as
//! "three arrays, one per component", and at `Vec3`/`Quat` element width that
//! form has the same 48 bytes per bone as AoS and the same per-bone gather —
//! it buys locality per channel, not vectorisation. The argument the corpus
//! makes FOR SoA is vectorisation, and only the per-channel form (ten scalar
//! arrays) can deliver it. Measuring the corpus form alone would have given SoA
//! its worst case and called the result a verdict.
//!
//! **Four layouts, because three left a confound open.** The AoS candidate the
//! corpus names is "one `Transform` per bone", and `Transform` is an
//! `extern struct` of `[3]f32` / `[4]f32` — so the AoS row differs from the SoA
//! rows in element REPRESENTATION as well as in memory order, and a reader
//! could charge the whole gap to the conversion rather than to the layout.
//! `AoS-vec` is the same interleaving with `@Vector`-backed elements: identical
//! 48 bytes, identical alignment, no conversion. It isolates the layout.
//!
//! **Interleaved, never best-of-three.** The layouts are measured round by
//! round in the same process, so a thermal or scheduling drift moves all three
//! together instead of favouring whichever ran first. A best-of-three across
//! separate runs has already failed to resolve a sub-5 % question in this
//! repository.
//!
//! ReleaseFast for the absolute ns. Writes `bench/results/pose_layout.md`.

const std = @import("std");
const builtin = @import("builtin");

const foundation = @import("foundation");
const core = @import("weld_core");

const math = foundation.math;
const Vec3 = math.Vec3;
const Quatf = math.Quatf;
const Transform = core.ecs.components.Transform;

const bone_counts = [_]usize{ 32, 64, 128 };
const rounds = 9;
const iters_per_round = 20_000;

// --- Monotonic clock (same construction as the forge benches: `clock_gettime`
// on POSIX, QPC on Windows; `std.time.Timer` is avoided for the same
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

// --- Deterministic skeleton ------------------------------------------------

/// Parent index per bone, `parent[0] == 0` marking the root.
///
/// The topological invariant the whole design rests on — a parent precedes its
/// child — is built in here rather than hoped for: `parent[i] < i` by
/// construction. The branching factor of 3 gives a chain depth around
/// `log3(n)`, which is the shape of a real rig's spine-and-limbs tree and not a
/// degenerate list (a straight chain would make FK maximally serial and flatter
/// AoS, a star would make it maximally parallel and flatter SoA).
fn buildParents(gpa: std.mem.Allocator, n: usize) ![]u16 {
    const parents = try gpa.alloc(u16, n);
    parents[0] = 0;
    for (1..n) |i| parents[i] = @intCast((i - 1) / 3);
    return parents;
}

/// A reproducible pseudo-random pose, seeded per bone so every layout is filled
/// from the SAME numbers and no layout wins on different data.
fn poseAt(i: usize, salt: u64) struct { pos: Vec3, rot: Quatf, scale: Vec3 } {
    var rng = std.Random.DefaultPrng.init(i *% 0x9E3779B97F4A7C15 +% salt);
    const r = rng.random();
    const q = Quatf.fromAxisAngle(
        Vec3.fromArray(.{ r.float(f32) - 0.5, r.float(f32) - 0.5, r.float(f32) - 0.5 }).normalize(),
        r.float(f32) * 3.0,
    );
    return .{
        .pos = Vec3.fromArray(.{ r.float(f32) - 0.5, r.float(f32) - 0.5, r.float(f32) - 0.5 }),
        .rot = q,
        .scale = Vec3.fromArray(.{ 0.5 + r.float(f32), 0.5 + r.float(f32), 0.5 + r.float(f32) }),
    };
}

/// Normalised lerp with the shortest-path sign fix, the blend every pose
/// operation in the pipeline performs on rotations.
fn nlerp(a: Quatf, b: Quatf, t: f32) Quatf {
    const d = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
    const s: f32 = if (d < 0) -1 else 1;
    return (Quatf{
        .x = a.x + (s * b.x - a.x) * t,
        .y = a.y + (s * b.y - a.y) * t,
        .z = a.z + (s * b.z - a.z) * t,
        .w = a.w + (s * b.w - a.w) * t,
    }).normalize();
}

// --- Layout 1: AoS, one `Transform` per bone -------------------------------

const Aos = struct {
    t: []Transform,

    fn alloc(gpa: std.mem.Allocator, n: usize) !Aos {
        return .{ .t = try gpa.alloc(Transform, n) };
    }
    fn free(self: Aos, gpa: std.mem.Allocator) void {
        gpa.free(self.t);
    }
    fn fill(self: Aos, salt: u64) void {
        for (self.t, 0..) |*e, i| {
            const p = poseAt(i, salt);
            e.* = .{ .pos = p.pos.toArray(), .rot = p.rot.toArray(), .scale = p.scale.toArray() };
        }
    }

    /// Written with the SAME vector operations as `Soa3.blend`, so the only
    /// thing that differs between the two is where the bytes live. A first
    /// version looped over `[3]f32` elements here while the SoA side used
    /// `Vec3.add`/`scale`: that measured one body written scalar against one
    /// written vector, and would have credited the layout with a difference
    /// the code made.
    fn blend(a: Aos, b: Aos, out: Aos, t: f32) void {
        for (a.t, b.t, out.t) |x, y, *o| {
            const xp = Vec3.fromArray(x.pos);
            const xs = Vec3.fromArray(x.scale);
            o.pos = xp.add(Vec3.fromArray(y.pos).sub(xp).scale(t)).toArray();
            o.scale = xs.add(Vec3.fromArray(y.scale).sub(xs).scale(t)).toArray();
            o.rot = nlerp(Quatf.fromArray(x.rot), Quatf.fromArray(y.rot), t).toArray();
        }
    }

    /// Same composition as `Soa3.fk`, operation for operation.
    fn fk(local: Aos, world: Aos, parents: []const u16) void {
        world.t[0] = local.t[0];
        for (1..local.t.len) |i| {
            const p = world.t[parents[i]];
            const l = local.t[i];
            const pr = Quatf.fromArray(p.rot);
            const ps = Vec3.fromArray(p.scale);
            const rotated = pr.rotateVec3(Vec3.fromArray(l.pos).mul(ps));
            world.t[i] = .{
                .pos = Vec3.fromArray(p.pos).add(rotated).toArray(),
                .rot = pr.mul(Quatf.fromArray(l.rot)).toArray(),
                .scale = ps.mul(Vec3.fromArray(l.scale)).toArray(),
            };
        }
    }

    fn checksum(self: Aos) f64 {
        var acc: f64 = 0;
        for (self.t) |e| {
            acc += @as(f64, e.pos[0]) + @as(f64, e.rot[3]) + @as(f64, e.scale[1]);
        }
        return acc;
    }
};

// --- Layout 1b: AoS with vector elements — the confound control -----------

/// One bone, interleaved, with `@Vector`-backed members instead of `Transform`'s
/// `[N]f32`. Same 48 bytes and same 16-byte alignment as `Transform`, so the
/// ONLY difference from `Aos` is that no `fromArray` / `toArray` sits between
/// the store and the arithmetic.
const VecPose = struct { pos: Vec3, rot: Quatf, scale: Vec3 };

const AosV = struct {
    t: []VecPose,

    fn alloc(gpa: std.mem.Allocator, n: usize) !AosV {
        return .{ .t = try gpa.alloc(VecPose, n) };
    }
    fn free(self: AosV, gpa: std.mem.Allocator) void {
        gpa.free(self.t);
    }
    fn fill(self: AosV, salt: u64) void {
        for (self.t, 0..) |*e, i| {
            const p = poseAt(i, salt);
            e.* = .{ .pos = p.pos, .rot = p.rot, .scale = p.scale };
        }
    }

    fn blend(a: AosV, b: AosV, out: AosV, t: f32) void {
        for (a.t, b.t, out.t) |x, y, *o| {
            o.pos = x.pos.add(y.pos.sub(x.pos).scale(t));
            o.scale = x.scale.add(y.scale.sub(x.scale).scale(t));
            o.rot = nlerp(x.rot, y.rot, t);
        }
    }

    fn fk(local: AosV, world: AosV, parents: []const u16) void {
        world.t[0] = local.t[0];
        for (1..local.t.len) |i| {
            const p = world.t[parents[i]];
            const l = local.t[i];
            world.t[i] = .{
                .pos = p.pos.add(p.rot.rotateVec3(l.pos.mul(p.scale))),
                .rot = p.rot.mul(l.rot),
                .scale = p.scale.mul(l.scale),
            };
        }
    }

    fn checksum(self: AosV) f64 {
        var acc: f64 = 0;
        for (self.t) |e| {
            acc += @as(f64, e.pos.data[0]) + @as(f64, e.rot.w) + @as(f64, e.scale.data[1]);
        }
        return acc;
    }
};

// --- Layout 2: SoA, three arrays — the corpus's own definition -------------

const Soa3 = struct {
    pos: []Vec3,
    rot: []Quatf,
    scale: []Vec3,

    fn alloc(gpa: std.mem.Allocator, n: usize) !Soa3 {
        return .{
            .pos = try gpa.alloc(Vec3, n),
            .rot = try gpa.alloc(Quatf, n),
            .scale = try gpa.alloc(Vec3, n),
        };
    }
    fn free(self: Soa3, gpa: std.mem.Allocator) void {
        gpa.free(self.pos);
        gpa.free(self.rot);
        gpa.free(self.scale);
    }
    fn fill(self: Soa3, salt: u64) void {
        for (0..self.pos.len) |i| {
            const p = poseAt(i, salt);
            self.pos[i] = p.pos;
            self.rot[i] = p.rot;
            self.scale[i] = p.scale;
        }
    }

    fn blend(a: Soa3, b: Soa3, out: Soa3, t: f32) void {
        for (a.pos, b.pos, out.pos) |x, y, *o| o.* = x.add(y.sub(x).scale(t));
        for (a.scale, b.scale, out.scale) |x, y, *o| o.* = x.add(y.sub(x).scale(t));
        for (a.rot, b.rot, out.rot) |x, y, *o| o.* = nlerp(x, y, t);
    }

    fn fk(local: Soa3, world: Soa3, parents: []const u16) void {
        world.pos[0] = local.pos[0];
        world.rot[0] = local.rot[0];
        world.scale[0] = local.scale[0];
        for (1..local.pos.len) |i| {
            const pi = parents[i];
            const ps = world.scale[pi];
            const pr = world.rot[pi];
            const rotated = pr.rotateVec3(local.pos[i].mul(ps));
            world.pos[i] = world.pos[pi].add(rotated);
            world.rot[i] = pr.mul(local.rot[i]);
            world.scale[i] = ps.mul(local.scale[i]);
        }
    }

    fn checksum(self: Soa3) f64 {
        var acc: f64 = 0;
        for (0..self.pos.len) |i| {
            acc += @as(f64, self.pos[i].data[0]) + @as(f64, self.rot[i].w) + @as(f64, self.scale[i].data[1]);
        }
        return acc;
    }
};

// --- Layout 3: SoA per channel — ten scalar arrays -------------------------

const SoaCh = struct {
    px: []f32,
    py: []f32,
    pz: []f32,
    rx: []f32,
    ry: []f32,
    rz: []f32,
    rw: []f32,
    sx: []f32,
    sy: []f32,
    sz: []f32,

    fn alloc(gpa: std.mem.Allocator, n: usize) !SoaCh {
        var s: SoaCh = undefined;
        inline for (@typeInfo(SoaCh).@"struct".fields) |f| {
            @field(s, f.name) = try gpa.alloc(f32, n);
        }
        return s;
    }
    fn free(self: SoaCh, gpa: std.mem.Allocator) void {
        inline for (@typeInfo(SoaCh).@"struct".fields) |f| gpa.free(@field(self, f.name));
    }
    fn fill(self: SoaCh, salt: u64) void {
        for (0..self.px.len) |i| {
            const p = poseAt(i, salt);
            self.px[i] = p.pos.data[0];
            self.py[i] = p.pos.data[1];
            self.pz[i] = p.pos.data[2];
            self.rx[i] = p.rot.x;
            self.ry[i] = p.rot.y;
            self.rz[i] = p.rot.z;
            self.rw[i] = p.rot.w;
            self.sx[i] = p.scale.data[0];
            self.sy[i] = p.scale.data[1];
            self.sz[i] = p.scale.data[2];
        }
    }

    fn blend(a: SoaCh, b: SoaCh, out: SoaCh, t: f32) void {
        // The six translation and scale channels are independent scalar streams
        // — this is the loop the vectorisation argument is about.
        inline for (.{ "px", "py", "pz", "sx", "sy", "sz" }) |name| {
            const xa = @field(a, name);
            const xb = @field(b, name);
            const xo = @field(out, name);
            for (xa, xb, xo) |x, y, *o| o.* = x + (y - x) * t;
        }
        for (0..a.px.len) |i| {
            const d = a.rx[i] * b.rx[i] + a.ry[i] * b.ry[i] + a.rz[i] * b.rz[i] + a.rw[i] * b.rw[i];
            const s: f32 = if (d < 0) -1 else 1;
            var qx = a.rx[i] + (s * b.rx[i] - a.rx[i]) * t;
            var qy = a.ry[i] + (s * b.ry[i] - a.ry[i]) * t;
            var qz = a.rz[i] + (s * b.rz[i] - a.rz[i]) * t;
            var qw = a.rw[i] + (s * b.rw[i] - a.rw[i]) * t;
            const inv = 1.0 / @sqrt(((qx * qx + qy * qy) + qz * qz) + qw * qw);
            qx *= inv;
            qy *= inv;
            qz *= inv;
            qw *= inv;
            out.rx[i] = qx;
            out.ry[i] = qy;
            out.rz[i] = qz;
            out.rw[i] = qw;
        }
    }

    fn fk(local: SoaCh, world: SoaCh, parents: []const u16) void {
        inline for (@typeInfo(SoaCh).@"struct".fields) |f| {
            @field(world, f.name)[0] = @field(local, f.name)[0];
        }
        for (1..local.px.len) |i| {
            const pi = parents[i];
            const pr = Quatf{ .x = world.rx[pi], .y = world.ry[pi], .z = world.rz[pi], .w = world.rw[pi] };
            const scaled = Vec3.fromArray(.{
                world.sx[pi] * local.px[i],
                world.sy[pi] * local.py[i],
                world.sz[pi] * local.pz[i],
            });
            const rotated = pr.rotateVec3(scaled);
            world.px[i] = world.px[pi] + rotated.data[0];
            world.py[i] = world.py[pi] + rotated.data[1];
            world.pz[i] = world.pz[pi] + rotated.data[2];
            const q = pr.mul(.{ .x = local.rx[i], .y = local.ry[i], .z = local.rz[i], .w = local.rw[i] });
            world.rx[i] = q.x;
            world.ry[i] = q.y;
            world.rz[i] = q.z;
            world.rw[i] = q.w;
            world.sx[i] = world.sx[pi] * local.sx[i];
            world.sy[i] = world.sy[pi] * local.sy[i];
            world.sz[i] = world.sz[pi] * local.sz[i];
        }
    }

    fn checksum(self: SoaCh) f64 {
        var acc: f64 = 0;
        for (0..self.px.len) |i| {
            acc += @as(f64, self.px[i]) + @as(f64, self.rw[i]) + @as(f64, self.sy[i]);
        }
        return acc;
    }
};

// --- Measurement -----------------------------------------------------------

const Row = struct {
    bones: usize,
    aos_ns: f64,
    aosv_ns: f64,
    soa3_ns: f64,
    soach_ns: f64,
    /// One checksum PER LAYOUT, kept apart on purpose.
    ///
    /// **Summing them into one scalar computes the agreement and then destroys
    /// it**, which is what an earlier form did: four identically-shaped
    /// `checksum()` functions were written, added together, and the total
    /// reported for one bone count — so a layout whose body had diverged would
    /// have produced a different total against no baseline, and would still
    /// have been timed and still have decided the ruling. Kept apart, they
    /// answer the question the four functions were plainly written for: do the
    /// four layouts compute the SAME pose?
    checksums: [4]f64,
};

fn median(xs: []f64) f64 {
    std.mem.sort(f64, xs, {}, std.sort.asc(f64));
    return xs[xs.len / 2];
}

const Op = enum { blend, fk };

/// The blend factor of iteration `k`. Named so the `.fk` arm does not compute
/// one it never uses — which it did, and which reads as a loop that varies when
/// it does not.
fn alphaAt(k: usize) f32 {
    return @as(f32, @floatFromInt(k % 64)) / 64.0;
}

fn measure(gpa: std.mem.Allocator, n: usize, op: Op) !Row {
    const parents = try buildParents(gpa, n);
    defer gpa.free(parents);

    const a_aos = try Aos.alloc(gpa, n);
    defer a_aos.free(gpa);
    const b_aos = try Aos.alloc(gpa, n);
    defer b_aos.free(gpa);
    const o_aos = try Aos.alloc(gpa, n);
    defer o_aos.free(gpa);
    a_aos.fill(1);
    b_aos.fill(2);

    const a_av = try AosV.alloc(gpa, n);
    defer a_av.free(gpa);
    const b_av = try AosV.alloc(gpa, n);
    defer b_av.free(gpa);
    const o_av = try AosV.alloc(gpa, n);
    defer o_av.free(gpa);
    a_av.fill(1);
    b_av.fill(2);

    const a_s3 = try Soa3.alloc(gpa, n);
    defer a_s3.free(gpa);
    const b_s3 = try Soa3.alloc(gpa, n);
    defer b_s3.free(gpa);
    const o_s3 = try Soa3.alloc(gpa, n);
    defer o_s3.free(gpa);
    a_s3.fill(1);
    b_s3.fill(2);

    const a_sc = try SoaCh.alloc(gpa, n);
    defer a_sc.free(gpa);
    const b_sc = try SoaCh.alloc(gpa, n);
    defer b_sc.free(gpa);
    const o_sc = try SoaCh.alloc(gpa, n);
    defer o_sc.free(gpa);
    a_sc.fill(1);
    b_sc.fill(2);

    var aos_rounds: [rounds]f64 = undefined;
    var aosv_rounds: [rounds]f64 = undefined;
    var s3_rounds: [rounds]f64 = undefined;
    var sc_rounds: [rounds]f64 = undefined;
    var checksums = [_]f64{ 0, 0, 0, 0 };

    // One untimed warm round so the first timed round is not the one that
    // faults every page in.
    for (0..3) |_| {
        switch (op) {
            .blend => {
                Aos.blend(a_aos, b_aos, o_aos, 0.5);
                AosV.blend(a_av, b_av, o_av, 0.5);
                Soa3.blend(a_s3, b_s3, o_s3, 0.5);
                SoaCh.blend(a_sc, b_sc, o_sc, 0.5);
            },
            .fk => {
                Aos.fk(a_aos, o_aos, parents);
                AosV.fk(a_av, o_av, parents);
                Soa3.fk(a_s3, o_s3, parents);
                SoaCh.fk(a_sc, o_sc, parents);
            },
        }
    }

    for (0..rounds) |r| {
        // INTERLEAVED: the three layouts are measured inside the same round, so
        // drift moves them together.
        var t0 = nowNs();
        for (0..iters_per_round) |k| {
            switch (op) {
                .blend => Aos.blend(a_aos, b_aos, o_aos, alphaAt(k)),
                .fk => Aos.fk(a_aos, o_aos, parents),
            }
        }
        aos_rounds[r] = @as(f64, @floatFromInt(nowNs() - t0)) / @as(f64, iters_per_round);
        checksums[0] += o_aos.checksum();

        t0 = nowNs();
        for (0..iters_per_round) |k| {
            const alpha = @as(f32, @floatFromInt(k % 64)) / 64.0;
            switch (op) {
                .blend => AosV.blend(a_av, b_av, o_av, alpha),
                .fk => AosV.fk(a_av, o_av, parents),
            }
        }
        aosv_rounds[r] = @as(f64, @floatFromInt(nowNs() - t0)) / @as(f64, iters_per_round);
        checksums[1] += o_av.checksum();

        t0 = nowNs();
        for (0..iters_per_round) |k| {
            const alpha = @as(f32, @floatFromInt(k % 64)) / 64.0;
            switch (op) {
                .blend => Soa3.blend(a_s3, b_s3, o_s3, alpha),
                .fk => Soa3.fk(a_s3, o_s3, parents),
            }
        }
        s3_rounds[r] = @as(f64, @floatFromInt(nowNs() - t0)) / @as(f64, iters_per_round);
        checksums[2] += o_s3.checksum();

        t0 = nowNs();
        for (0..iters_per_round) |k| {
            const alpha = @as(f32, @floatFromInt(k % 64)) / 64.0;
            switch (op) {
                .blend => SoaCh.blend(a_sc, b_sc, o_sc, alpha),
                .fk => SoaCh.fk(a_sc, o_sc, parents),
            }
        }
        sc_rounds[r] = @as(f64, @floatFromInt(nowNs() - t0)) / @as(f64, iters_per_round);
        checksums[3] += o_sc.checksum();
    }

    return .{
        .bones = n,
        .aos_ns = median(&aos_rounds),
        .aosv_ns = median(&aosv_rounds),
        .soa3_ns = median(&s3_rounds),
        .soach_ns = median(&sc_rounds),
        .checksums = checksums,
    };
}

fn emitConsole(title: []const u8, rows: []const Row) void {
    std.debug.print("\n  {s}\n", .{title});
    std.debug.print("  {s:<7} {s:>10} {s:>11} {s:>11} {s:>13} {s:>12} {s:>12} {s:>12}\n", .{
        "bones",         "AoS (ns)",      "AoS-vec (ns)", "SoA-3 (ns)",
        "SoA-chan (ns)", "AoS-vec / AoS", "SoA-3 / AoS",  "SoA-ch / AoS",
    });
    for (rows) |r| {
        std.debug.print("  {d:<7} {d:>10.1} {d:>11.1} {d:>11.1} {d:>13.1} {d:>11.3}x {d:>11.3}x {d:>11.3}x\n", .{
            r.bones,              r.aos_ns,              r.aosv_ns,
            r.soa3_ns,            r.soach_ns,            r.aosv_ns / r.aos_ns,
            r.soa3_ns / r.aos_ns, r.soach_ns / r.aos_ns,
        });
    }
}

fn emitMarkdown(gpa: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), title: []const u8, rows: []const Row) !void {
    try buf.print(gpa, "\n### {s}\n\n", .{title});
    try buf.print(gpa, "| bones | AoS (ns) | AoS-vec (ns) | SoA-3 (ns) | SoA-channel (ns) | AoS-vec / AoS | SoA-3 / AoS | SoA-ch / AoS |\n", .{});
    try buf.print(gpa, "|---|---|---|---|---|---|---|---|\n", .{});
    for (rows) |r| {
        try buf.print(gpa, "| {d} | {d:.1} | {d:.1} | {d:.1} | {d:.1} | {d:.3}x | {d:.3}x | {d:.3}x |\n", .{
            r.bones,              r.aos_ns,              r.aosv_ns,
            r.soa3_ns,            r.soach_ns,            r.aosv_ns / r.aos_ns,
            r.soa3_ns / r.aos_ns, r.soach_ns / r.aos_ns,
        });
    }
}

pub fn main(init: std.process.Init) !void {
    _ = init;
    // `ARCH-031` rule 5: installation belongs to the ACT of entering a process,
    // and the rule admits no exception for a program that compares nothing today.
    // It matters most here of all: the numbers this binary prints are what
    // decided the pose layout, and a float measurement taken under an unowned
    // rounding mode measures a configuration that exists on no machine.
    foundation.math.float_env.install();

    // `safety` is FORCED true: its default is `std.debug.runtime_safety`, which
    // is false in ReleaseFast, so the default would report "no leaks"
    // unconditionally. Every allocation here is setup or report writing,
    // outside the timed loops.
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

    var blend_rows: [bone_counts.len]Row = undefined;
    var fk_rows: [bone_counts.len]Row = undefined;
    for (bone_counts, 0..) |n, i| {
        blend_rows[i] = try measure(gpa, n, .blend);
        fk_rows[i] = try measure(gpa, n, .fk);
    }

    const soa3_bytes = @sizeOf(Vec3) * 2 + @sizeOf(Quatf);
    std.debug.print("\npose buffer layout bench ({s}, {d} interleaved rounds x {d} iterations)\n", .{
        @tagName(builtin.mode), rounds, iters_per_round,
    });
    std.debug.print("  per-bone footprint: AoS {d} B, AoS-vec {d} B, SoA-3 {d} B, SoA-channel 40 B\n", .{
        @sizeOf(Transform), @sizeOf(VecPose), soa3_bytes,
    });
    emitConsole("Blend (no dependency between bones)", &blend_rows);
    emitConsole("Forward kinematics (serialised parent -> child)", &fk_rows);
    // **THE AGREEMENT IS ASSERTED, not printed and left to a reader.** Four
    // layouts that compute different poses can be timed against each other all
    // day and the comparison means nothing; this is the check that says the
    // ruling is about memory and not about four different functions. It is
    // reported per bone count, because a divergence that only appears at one
    // size is exactly the kind a single row hides.
    //
    // What the checksum does NOT do is prevent dead-code elimination of the
    // inner loop: it is read once per round, so it forces the LAST iteration.
    // Nothing is hoisted today — tripling the iteration count leaves ns/iter
    // flat — and that is the measurement this claim rests on, not the checksum.
    var disagreements: usize = 0;
    for ([_][]const Row{ &blend_rows, &fk_rows }, [_][]const u8{ "blend", "fk" }) |rows, label| {
        for (rows) |r| {
            for (r.checksums[1..], 1..) |c, i| {
                if (c == r.checksums[0]) continue;
                disagreements += 1;
                std.debug.print(
                    "  LAYOUTS DISAGREE: {s} n={d}, layout {d} checksum {d:.9} against {d:.9}\n",
                    .{ label, r.bones, i, c, r.checksums[0] },
                );
            }
        }
    }
    if (disagreements == 0) {
        std.debug.print("\n  all four layouts agree at every bone count (blend {d:.9}, fk {d:.9})\n", .{
            blend_rows[0].checksums[0], fk_rows[0].checksums[0],
        });
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.print(gpa,
        \\## Pose buffer layout -- AoS against SoA
        \\
        \\Mode: {s}. {d} interleaved rounds of {d} iterations, median per round.
        \\Per-bone footprint: AoS {d} B, AoS-vec {d} B, SoA-3 {d} B, SoA-channel 40 B.
        \\
        \\Decides a design; no target to clear.
        \\
    , .{ @tagName(builtin.mode), rounds, iters_per_round, @sizeOf(Transform), @sizeOf(VecPose), soa3_bytes });
    try emitMarkdown(gpa, &buf, "Blend (no dependency between bones)", &blend_rows);
    try emitMarkdown(gpa, &buf, "Forward kinematics (serialised parent -> child)", &fk_rows);
    try buf.print(gpa, "\nLayout agreement: {s} (blend {d:.9}, fk {d:.9} at 32 bones)\n", .{
        if (disagreements == 0) "all four compute the same pose" else "LAYOUTS DISAGREE",
        blend_rows[0].checksums[0],
        fk_rows[0].checksums[0],
    });

    const path: [:0]const u8 = "bench/results/pose_layout.md";
    const fp = fopen(path.ptr, "w");
    if (fp == null) return error.WriteReportFailed;
    defer _ = fclose(fp.?);
    _ = fwrite(buf.items.ptr, 1, buf.items.len, fp.?);
}

extern "c" fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
extern "c" fn fwrite(ptr: [*]const u8, size: usize, n: usize, stream: *anyopaque) usize;
extern "c" fn fclose(stream: *anyopaque) c_int;
