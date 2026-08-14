//! The three artifact kinds of M1.1.14, and nothing else.
//!
//! Everything here is a pure function of a `Scenario` at a tick. No allocation
//! decision, no ordering and no threshold is taken from the engine's internals
//! by chance: each is stated, and the ones that are already normative elsewhere
//! are REUSED rather than re-invented — the deviation metric below is the sleep
//! criterion's own bound (`engine-physics-solver.md` §1.8.3), for the reason
//! that two formulas for one geometric fact is the defect class this repository
//! names.
//!
//! **Encoding: explicit little-endian, always.** Every scalar goes through
//! `std.mem.writeInt` on the integer of its own width, floats via `@bitCast`
//! first. A witness is committed in tree and read back on three targets, so the
//! host's byte order must not appear in it — and `@bitCast` rather than a
//! decimal rendering because the contract is BINARY identity and a decimal round
//! trip is exactly where it would be lost.
//!
//! **The hash is SHA-256, and that is a decision.** A witness has to survive a
//! compiler patch bump: a standardised digest is defined by its specification,
//! whereas a fast non-cryptographic hash is defined by an implementation that is
//! free to change under us. The chain is not defending against an adversary — it
//! is defending against an unannounced change of algorithm.

const std = @import("std");
const config = @import("../../config.zig");
const api = @import("weld_forge");
const Scenario = @import("scenario.zig").Scenario;

const Real = config.Real;
const BodyId = api.BodyId;

/// The integer of the solver scalar's own width — what a `Real` is `@bitCast` to
/// before it is written.
const RealBits = if (Real == f32) u32 else u64;

/// The digest the chain carries.
pub const Hash = std.crypto.hash.sha2.Sha256;
/// Length of one chain link, in bytes.
pub const digest_len = Hash.digest_length;

/// Threshold factor of the continuous deviation metric, from
/// `engine-phase-1-criteria.md` C1.1: the divergence frame is the first where a
/// body's deviation exceeds `1e-4 × body scale`.
pub const divergence_factor: f64 = 1.0e-4;

// --- primitive encoders -------------------------------------------------------

fn putU32(out: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, v: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .little);
    try out.appendSlice(gpa, &buf);
}

fn putU64(out: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, v: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, v, .little);
    try out.appendSlice(gpa, &buf);
}

fn putReal(out: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, v: Real) !void {
    const bits: RealBits = @bitCast(v);
    var buf: [@sizeOf(RealBits)]u8 = undefined;
    std.mem.writeInt(RealBits, &buf, bits, .little);
    try out.appendSlice(gpa, &buf);
}

// --- (a) the continuous state dump -------------------------------------------

/// Append the canonical binary state of every MOBILE body at the current tick.
///
/// Mobile only, and the exclusion is the brief's: a static shape with an
/// unbounded local AABB has no meaningful scale, and forcing one into a metric
/// that weights by radius would mean inventing that radius.
///
/// Thirteen scalars per body — position, rotation, linear and angular velocity —
/// in `Scenario.mobile` order, which is creation order. Velocity is in the dump
/// and not only pose, deliberately: two runs can agree on every position for
/// several ticks while their velocities have already parted, and a pose-only
/// dump would report the divergence late.
pub fn dumpState(s: *const Scenario, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    for (s.mobile.items) |id| {
        const p = s.world.bm.position(id) orelse continue;
        const q = s.world.bm.rotation(id) orelse continue;
        const lv = s.world.bm.linearVelocity(id) orelse continue;
        const av = s.world.bm.angularVelocity(id) orelse continue;
        for (p.toArray()) |c| try putReal(out, gpa, c);
        try putReal(out, gpa, q.x);
        try putReal(out, gpa, q.y);
        try putReal(out, gpa, q.z);
        try putReal(out, gpa, q.w);
        for (lv.toArray()) |c| try putReal(out, gpa, c);
        for (av.toArray()) |c| try putReal(out, gpa, c);
    }
}

/// The rolling per-frame hash chain: `h₀` is all zeros, `hₙ = H(hₙ₋₁ ‖ dumpₙ)`.
///
/// Chained rather than a hash of the concatenation, because a chain lets a
/// mismatch be located: comparing link by link against a committed witness names
/// the FIRST differing frame, and "the outputs differ" is not a diagnosis.
pub const Chain = struct {
    digest: [digest_len]u8 = @splat(0),

    pub fn advance(self: *Chain, frame_bytes: []const u8) void {
        var h = Hash.init(.{});
        h.update(&self.digest);
        h.update(frame_bytes);
        h.final(&self.digest);
    }
};

// --- (b) the four discrete traces --------------------------------------------

/// Append the four discrete traces of the current tick, raw and unhashed.
///
/// Raw because these are the LEVEL-2 artifact: every cell compares them, ISA
/// included, and a mismatch has to say WHICH invariant moved. A digest would
/// collapse four independent claims into one bit.
///
/// All four are derived from integers — handles, counts, keys — which is what
/// makes them ISA-independent by construction (`ARCH-031`, "ce que l'invariant
/// ne promet pas"). Each is length-prefixed so the reader never has to infer a
/// boundary from content.
pub fn dumpDiscrete(s: *const Scenario, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    // (1) ISLAND PARTITION. The rank is the smallest member `BodyId` (§1.8.1) and
    // `islandMembers` returns them ascending, so `members[0]` IS the rank — read
    // rather than recomputed, so a change in either cannot pass unnoticed.
    const islands = s.world.islands.islandsSlice();
    try putU32(out, gpa, @intCast(islands.len));
    for (islands) |isl| {
        const members = s.world.islands.islandMembers(isl);
        try putU32(out, gpa, @intCast(members.len));
        for (members) |m| try putU32(out, gpa, m);
    }

    // (2) SLEEP STATE of every mobile body, in creation order. The state and not
    // the transition: a transition is a difference of two states, so recording
    // the state records the transitions too and cannot disagree with itself.
    try putU32(out, gpa, @intCast(s.mobile.items.len));
    for (s.mobile.items) |id| {
        const sleeping = s.world.bm.isSleeping(id) orelse false;
        try putU32(out, gpa, @intFromBool(sleeping));
    }

    // (3) PER-PAIR MANIFOLD CARDINALITY, as `(pair_key, subshape_id, count)`
    // triples in constraint order — which is the total order
    // `(island rank, pair_key, subshape_id)` the solver resolves in (§1.8.1), so
    // this trace also witnesses that order and not only the cardinalities.
    try putU32(out, gpa, @intCast(s.world.constraints.items.len));
    for (s.world.constraints.items) |c| {
        try putU64(out, gpa, c.pair_key);
        try putU32(out, gpa, c.subshape_id);
        try putU32(out, gpa, c.count);
    }

    // (4) THE RETAINED PAIR SET, sorted, as the harness holds it. This is the one
    // that needed the M1.1.14 pruning fix to be an oracle at all: over a set that
    // can only grow, a trace agrees with itself by accumulation.
    try putU32(out, gpa, @intCast(s.world.active.items.len));
    for (s.world.active.items) |k| try putU64(out, gpa, k);
}

// --- (c) the reference window -------------------------------------------------

/// Append the raw poses of every mobile body — the artifact the ARM64 cell reads
/// to compute its divergence frame.
///
/// Pose only, no velocity: this one is not a bit-exactness witness but the input
/// to a CONTINUOUS metric, and that metric is defined on configuration.
pub fn dumpPoses(s: *const Scenario, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) !void {
    for (s.mobile.items) |id| {
        const p = s.world.bm.position(id) orelse continue;
        const q = s.world.bm.rotation(id) orelse continue;
        for (p.toArray()) |c| try putReal(out, gpa, c);
        try putReal(out, gpa, q.x);
        try putReal(out, gpa, q.y);
        try putReal(out, gpa, q.z);
        try putReal(out, gpa, q.w);
    }
}

/// Scalars one body contributes to a pose record: 3 position + 4 rotation.
pub const pose_scalars_per_body: usize = 7;

/// Whether any body's deviation from `reference` exceeds `1e-4 × body scale`.
///
/// The per-body deviation is `‖Δx‖ + 2·r·‖vec(Δq)‖`, which is NOT a new formula:
/// it is the sleep criterion's own conservative displacement bound
/// (`engine-physics-solver.md` §1.8.3), where `2·‖vec(Δq)‖` is the exact
/// `2·sin(θ/2)` chord — trig-free, as the determinism contract requires — and the
/// sum is a triangle bound that MAJORISES the displacement of every material
/// point. Reusing it is the point: two formulas for one geometric fact is how
/// two sources come to disagree about it.
///
/// `r` is the body's `sleep_radius`, the distance from its centre to the far
/// corner of its local AABB, computed once at creation. It is the engine's own
/// notion of body scale, so the metric invents no constant.
pub fn deviationExceeded(s: *const Scenario, reference: []const u8) bool {
    const stride = @sizeOf(RealBits);
    var off: usize = 0;
    for (s.mobile.items) |id| {
        if (off + pose_scalars_per_body * stride > reference.len) return false;
        const p = s.world.bm.position(id) orelse continue;
        const q = s.world.bm.rotation(id) orelse continue;
        const r = s.world.bm.sleepRadius(id) orelse continue;

        var ref: [pose_scalars_per_body]Real = undefined;
        for (&ref, 0..) |*v, i| {
            const bits = std.mem.readInt(RealBits, reference[off + i * stride ..][0..stride], .little);
            v.* = @bitCast(bits);
        }
        off += pose_scalars_per_body * stride;

        const cur = p.toArray();
        var dx: Real = 0;
        for (0..3) |i| {
            const d = cur[i] - ref[i];
            dx += d * d;
        }
        // The relative rotation, through the SHARED `Quat` operations rather than
        // an expanded Hamilton product written here. An expansion would be a
        // second copy of a formula `foundation/math` already owns, and the sleep
        // criterion this metric reuses is expressed on exactly this quantity.
        const q_ref = config.Quatr{ .x = ref[3], .y = ref[4], .z = ref[5], .w = ref[6] };
        const dq_quat = q.mul(q_ref.conjugate());
        const dq = @sqrt(dq_quat.x * dq_quat.x + dq_quat.y * dq_quat.y + dq_quat.z * dq_quat.z);

        const deviation = @sqrt(dx) + 2 * r * dq;
        if (@as(f64, deviation) > divergence_factor * @as(f64, r)) return true;
    }
    return false;
}
