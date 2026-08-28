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
const sensor_mod = @import("../../pipeline/sensor.zig");

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

    // THE CHARACTER, and its absence here was a defect and not an omission of
    // detail. `mobile` holds rigid bodies; a virtual character owns no simulated
    // body, so it entered NO artifact — the controller ran for 1000 frames, swept,
    // depenetrated, classified its ground, and every bit of that was discarded.
    // The scenario header listed it as an element the whole time — numbered 7 of 7
    // then, 9 of 9 now that the sleeper and the split terrain entry exist.
    //
    // ITS OWN STATE, never its presence body's. The presence is a broadphase
    // artifact whose pose is the capsule's CENTRE and whose velocities are always
    // zero; the authoritative quantity is the BASE position the store holds, and
    // routing through the body would serialise a derived value plus six zeros.
    //
    // THE GROUND VERDICT IS WHAT MAKES `cos_max_slope` OBSERVABLE, and therefore
    // the deterministic cosine. Written as an integer-valued `Real` so the record
    // stays one uniform stream of scalars: the three values are exactly
    // representable at both precisions, so the encoding costs no information.
    const ch = s.chars.get(s.character) orelse return;
    for (ch.position.toArray()) |c| try putReal(out, gpa, c);
    try putReal(out, gpa, @floatFromInt(@intFromEnum(ch.reported_ground)));

    // THE SENSOR STATE, and its absence was a LEVEL-1 coverage hole rather than a
    // level-2 one. A trigger resolves no impulse: `current`, `entered` and `exited`
    // can all diverge without displacing a single body, so the chain, the four
    // discrete traces and the reference window would every one of them stay
    // identical while the sensor pass disagreed between two machines. The scenario
    // listed the sensor as an element the whole time, and its output reached NO
    // artifact — presence in the scene mistaken for coverage.
    //
    // All THREE sets, and each for its own reason. `current` is the membership §1.13
    // makes the source of truth, since the bus drops its oldest entry on saturation
    // and a set rebuilt from the flow would be wrong on the first one. `entered` and
    // `exited` are the two deltas, and a state that agreed while a delta did not
    // would be a real divergence this dump would hide.
    //
    // The identity is written INDEX THEN GENERATION, both halves: a recycled slot
    // reuses the index, so an index-only record would read two different entities as
    // one. Length-prefixed, like every other length in this file.
    try dumpSensorSets(s, gpa, out, all_sensor_sets);
}

/// Which of the three sensor sets a dump carries. Index order is `current`,
/// `entered`, `exited` — the order `dumpSensorSets` writes them in.
pub const SensorSetMask = [3]bool;

/// Production always carries all three.
pub const all_sensor_sets: SensorSetMask = .{ true, true, true };

/// Append the three sensor sets, each one either in full or AS AN EMPTY SET.
///
/// **A SUPPRESSED SET IS WRITTEN AS LENGTH ZERO, NEVER OMITTED, and that is what
/// makes the test above it discriminate an INSTANT rather than a shape.** Omitting
/// a set removes its length prefix too, so the bytes would differ even at a frame
/// where the set is legitimately empty — and a probe that changes the output
/// unconditionally proves nothing about the frame it was evaluated at. Written as
/// length zero, a suppression is invisible exactly when the set is empty and
/// visible exactly when it is not.
///
/// The mask exists for the test and production passes `all_sensor_sets`; there is
/// one implementation, so the thing tested is the thing shipped.
pub fn dumpSensorSets(
    s: *const Scenario,
    gpa: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    include: SensorSetMask,
) !void {
    const sets = [_][]const sensor_mod.EntityPair{
        s.world.sensors.current.items,
        s.world.sensors.entered.items,
        s.world.sensors.exited.items,
    };
    for (sets, include) |set, on| {
        const n: usize = if (on) set.len else 0;
        try putU32(out, gpa, @intCast(n));
        if (!on) continue;
        for (set) |pair| {
            try putU32(out, gpa, pair.trigger.index);
            try putU32(out, gpa, pair.trigger.generation);
            try putU32(out, gpa, pair.other.index);
            try putU32(out, gpa, pair.other.generation);
        }
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

        if (bodyExceeds(@sqrt(dx), dq, r)) return true;
    }
    return false;
}

/// Whether ONE body's deviation exceeds its own threshold.
///
/// Extracted so the SHAPE OF THE THRESHOLD is testable in isolation, and that is
/// not tidiness. C1.1 says `1e-4 × body scale`, so the comparison is PER BODY
/// against that body's own `r`. An absolute threshold would pass on the
/// canonical scenario — its THIRTEEN mobile bodies are all of comparable size —
/// and would break silently the day a body of another scale entered the scene.
/// That is the "assertion valid only through a tacit property of its fixture"
/// class the brief names, and it becomes undetectable once a witness is
/// committed over the scene that hides it. Hence the two-scale test below, which
/// an absolute form cannot pass.
///
/// `translation` is `‖Δx‖`, `rotation_chord` is `‖vec(Δq)‖`, `r` the body's
/// `sleep_radius`.
pub fn bodyExceeds(translation: Real, rotation_chord: Real, r: Real) bool {
    const deviation = translation + 2 * r * rotation_chord;
    return @as(f64, deviation) > divergence_factor * @as(f64, r);
}

// --- Tests -------------------------------------------------------------------

const testing = std.testing;

test "the divergence threshold scales WITH the body, not against a constant" {
    // THE DISCRIMINATING TEST, and the one an absolute threshold cannot pass.
    //
    // Two bodies three orders of magnitude apart in scale, each given a
    // translation of exactly half its own threshold and then of twice it. A
    // per-body form answers `false` then `true` for BOTH. Any absolute
    // threshold — whatever constant it picks — necessarily answers the same for
    // the two rows of one of the two columns, because the same displacement is
    // above the constant for one body and below it for the other.
    const small: Real = 0.01; // a 1 cm body
    const large: Real = 10.0; // a 10 m body

    for ([_]Real{ small, large }) |r| {
        const threshold: Real = @floatCast(divergence_factor * @as(f64, r));
        try testing.expect(!bodyExceeds(threshold * 0.5, 0, r));
        try testing.expect(bodyExceeds(threshold * 2.0, 0, r));
    }

    // And the cross-check that names the failure mode explicitly: the LARGE
    // body's half-threshold displacement is far ABOVE the small body's whole
    // threshold. A shared constant sized for either one misclassifies the other,
    // and this line is what makes that arithmetic visible rather than implied.
    const large_half: Real = @floatCast(divergence_factor * @as(f64, large) * 0.5);
    try testing.expect(@as(f64, large_half) > divergence_factor * @as(f64, small));
    try testing.expect(!bodyExceeds(large_half, 0, large));
    try testing.expect(bodyExceeds(large_half, 0, small));
}

test "the rotation term is weighted by the body radius" {
    // The second half of "weighting translation and rotation by the body radius".
    // With zero translation, the same angular chord must clear the threshold for
    // a body of any radius — the `2·r` numerator and the `1e-4·r` denominator
    // cancel — so the predicate is a pure comparison of the chord against
    // `1e-4/2`. Pinned because dropping the `r` from EITHER side would leave the
    // translation tests above green while silently changing the rotation
    // criterion by three orders of magnitude between the two bodies.
    const chord_below: Real = @floatCast(divergence_factor / 2 * 0.5);
    const chord_above: Real = @floatCast(divergence_factor / 2 * 2);
    for ([_]Real{ 0.01, 1.0, 10.0 }) |r| {
        try testing.expect(!bodyExceeds(0, chord_below, r));
        try testing.expect(bodyExceeds(0, chord_above, r));
    }
}

test "the character IS in the continuous state, and the proof is a discrimination" {
    // WHY THIS TEST EXISTS. Until M1.1.14's review the character reached NO
    // artifact: `dumpState` walked `s.mobile`, which holds rigid bodies, and a
    // virtual character owns none — so the controller ran a thousand frames and its
    // whole output was discarded. Adding it to the dump is one line, and one line
    // is exactly what a later refactor removes without noticing.
    //
    // A LENGTH ASSERTION WOULD NOT DO. Counting scalars would pass on a dump that
    // appended four zeros, or the wrong character, or the same body twice. What is
    // asserted instead is a DISCRIMINATION on the object: move the character and
    // NOTHING else, and the stream must change. If the character is not in it, the
    // two dumps are byte-identical and this test fails — which is the state `main`
    // was in when it was written.
    const gpa = testing.allocator;

    var a = try Scenario.init(gpa);
    defer a.deinit(gpa);
    var b = try Scenario.init(gpa);
    defer b.deinit(gpa);

    // Both worlds are stepped identically, so every RIGID body agrees bit for bit.
    var f: u32 = 0;
    while (f < 20) : (f += 1) {
        try a.step(gpa, f);
        try b.step(gpa, f);
    }

    var da: std.ArrayListUnmanaged(u8) = .empty;
    defer da.deinit(gpa);
    var db: std.ArrayListUnmanaged(u8) = .empty;
    defer db.deinit(gpa);
    try dumpState(&a, gpa, &da);
    try dumpState(&b, gpa, &db);

    // Control first: identical scenarios give identical dumps. Without this the
    // discrimination below could be passing for any reason at all.
    try testing.expectEqualSlices(u8, da.items, db.items);

    // Now move ONLY the character in `b`. A teleport writes the character's own
    // position and its presence body's pose; the presence is not in `mobile`, so no
    // rigid-body record can carry this change.
    const moved = a.chars.get(a.character).?.position.add(.{ .data = .{ 0.5, 0, 0 } });
    b.chars.setCharacterPosition(&b.world.bp, &b.world.bm, &b.world.store, b.character, moved);

    db.clearRetainingCapacity();
    try dumpState(&b, gpa, &db);
    try testing.expect(!std.mem.eql(u8, da.items, db.items));

    // And the ground VERDICT is in the stream too, which is what carries
    // `cos_max_slope` into the witness. `setCharacterPosition` invalidates the
    // verdict to `.in_air` by contract (§1.12.8), so this second discrimination
    // isolates the verdict field: the position is restored to its original value,
    // leaving the verdict as the only difference left.
    b.chars.setCharacterPosition(&b.world.bp, &b.world.bm, &b.world.store, b.character, a.chars.get(a.character).?.position);
    try testing.expectEqual(api.GroundState.in_air, b.chars.get(b.character).?.reported_ground);
    try testing.expectEqual(api.GroundState.grounded, a.chars.get(a.character).?.reported_ground);

    db.clearRetainingCapacity();
    try dumpState(&b, gpa, &db);
    try testing.expect(!std.mem.eql(u8, da.items, db.items));
}
