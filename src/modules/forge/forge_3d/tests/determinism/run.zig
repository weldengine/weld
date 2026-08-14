//! The determinism harness AS AN INSTRUMENT — the entry two later milestones
//! replay: M1.1.25 at N workers, M1.A on a rebuilt scheduler DAG
//! (`engine-phase-1-plan.md`). It is therefore written as a library with a
//! stable entry, and `main.zig` is a thin shell over it rather than the other
//! way round: a harness whose only caller is a `main` is not replayable.
//!
//! ONE WORKER, and that is not a limitation of this file. Resolution is
//! sequential until M1.1.25 (`engine-physics-solver.md` §1.8.8), and the
//! invariance of the result to the worker count is STRUCTURAL — the resolution
//! order is total, `(island rank, pair_key, subshape_id)`, with no hashed
//! container anywhere — so the replay at N will VERIFY that invariance rather
//! than establish it.

const std = @import("std");
const config = @import("../../config.zig");
const forge = @import("../../root.zig");
const scenario = @import("scenario.zig");
const trace = @import("trace.zig");

const Scenario = scenario.Scenario;
const Real = config.Real;

/// Frames of the level-1 continuous chain (`engine-phase-1-criteria.md` C1.1).
pub const chain_frames: u32 = 1000;
/// Frames of the level-2 discrete parity window — `K = 60`, one second at 60 Hz,
/// fixed by C1.1 and not by this file.
pub const window_frames: u32 = 60;

/// What one run produces: the three artifact kinds, and nothing derived.
pub const Artifacts = struct {
    /// `chain_frames` digests, concatenated. The level-1 witness.
    chain: std.ArrayListUnmanaged(u8) = .empty,
    /// The four discrete traces over the first `window_frames`, raw. Level 2.
    discrete: std.ArrayListUnmanaged(u8) = .empty,
    /// Raw mobile poses over the first `window_frames`. Measurement only.
    poses: std.ArrayListUnmanaged(u8) = .empty,
    /// Bytes one frame contributes to `poses` — the stride a reader needs.
    pose_stride: usize = 0,

    pub fn deinit(self: *Artifacts, gpa: std.mem.Allocator) void {
        self.chain.deinit(gpa);
        self.discrete.deinit(gpa);
        self.poses.deinit(gpa);
    }

    /// The digest of frame `i` (0-based).
    pub fn link(self: *const Artifacts, i: usize) []const u8 {
        return self.chain.items[i * trace.digest_len ..][0..trace.digest_len];
    }
};

/// Run the canonical scenario for `frames` ticks and produce all three artifacts.
///
/// The float environment is ASSERTED here rather than installed, at the same
/// seam every physics entry uses (`../../determinism.zig`) — an instrument that
/// repaired its own thread would measure a state no other consumer has.
pub fn runCanonical(gpa: std.mem.Allocator, frames: u32) !Artifacts {
    forge.assertFloatEnvironment();

    var s = try Scenario.init(gpa);
    defer s.deinit(gpa);

    var art = Artifacts{};
    errdefer art.deinit(gpa);

    var chain = trace.Chain{};
    var frame_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer frame_buf.deinit(gpa);

    var f: u32 = 0;
    while (f < frames) : (f += 1) {
        try s.step(gpa, f);

        frame_buf.clearRetainingCapacity();
        try trace.dumpState(&s, gpa, &frame_buf);
        chain.advance(frame_buf.items);
        try art.chain.appendSlice(gpa, &chain.digest);

        if (f < window_frames) {
            try trace.dumpDiscrete(&s, gpa, &art.discrete);
            const before = art.poses.items.len;
            try trace.dumpPoses(&s, gpa, &art.poses);
            if (f == 0) art.pose_stride = art.poses.items.len - before;
        }
    }
    return art;
}

/// The first frame at which the run's poses deviate from `reference` by more than
/// `1e-4 × body scale`, or `null` if none does within the window.
///
/// A MEASUREMENT, not a gate (C1.1 level 2 point 2): its value is recorded and
/// its REGRESSION is the signal — a sharp drop between two milestones denounces a
/// threshold that has become fragile. Nothing here asserts a bound on it.
pub fn divergenceFrame(gpa: std.mem.Allocator, reference: []const u8, stride: usize) !?u32 {
    forge.assertFloatEnvironment();

    var s = try Scenario.init(gpa);
    defer s.deinit(gpa);

    var f: u32 = 0;
    while (f < window_frames) : (f += 1) {
        try s.step(gpa, f);
        const off = @as(usize, f) * stride;
        if (off + stride > reference.len) return null;
        if (trace.deviationExceeded(&s, reference[off..][0..stride])) return f;
    }
    return null;
}

// --- Tests -------------------------------------------------------------------

const testing = std.testing;

test "harness is self-reproducible" {
    // THE Gate B exit criterion. Two consecutive in-process runs must produce
    // byte-identical outputs of ALL THREE kinds — not merely of the chain, since
    // the chain is a digest and would hide which of the three moved.
    //
    // Self-reproducibility is the weakest of the milestone's claims and the one
    // everything else rests on: a harness that cannot repeat itself on ONE
    // machine cannot say anything about two.
    const gpa = testing.allocator;
    const frames: u32 = 120;

    var a = try runCanonical(gpa, frames);
    defer a.deinit(gpa);
    var b = try runCanonical(gpa, frames);
    defer b.deinit(gpa);

    // SIZE FIRST, and reported as a size rather than asserted as equality alone:
    // two empty artifacts are byte-identical too, and that is the vacuity this
    // milestone has already met twice.
    try testing.expectEqual(@as(usize, frames * trace.digest_len), a.chain.items.len);
    try testing.expect(a.discrete.items.len > 0);
    try testing.expect(a.poses.items.len > 0);
    try testing.expectEqual(a.pose_stride * window_frames, a.poses.items.len);

    try testing.expectEqualSlices(u8, a.chain.items, b.chain.items);
    try testing.expectEqualSlices(u8, a.discrete.items, b.discrete.items);
    try testing.expectEqualSlices(u8, a.poses.items, b.poses.items);
}

test "the chain actually advances — no two frames share a link" {
    // The chain is the level-1 witness, and a chain that stopped advancing would
    // compare equal to itself for ever. Adjacent links are asserted DISTINCT,
    // which is what a scene where something moves must produce.
    const gpa = testing.allocator;
    var a = try runCanonical(gpa, 30);
    defer a.deinit(gpa);

    var i: usize = 1;
    var distinct: usize = 0;
    while (i < 30) : (i += 1) {
        if (!std.mem.eql(u8, a.link(i - 1), a.link(i))) distinct += 1;
    }
    try testing.expectEqual(@as(usize, 29), distinct);
}

test "the discrete trace is not constant across the window" {
    // Same guard, on the level-2 artifact and for the same reason. The four
    // invariants are supposed to CHANGE over the window — the stack falls asleep,
    // the two groups merge, the visitor crosses the trigger — so a window whose
    // every frame encoded the same bytes would be a scene where nothing happened,
    // and its parity across two ISAs would prove nothing.
    const gpa = testing.allocator;
    var a = try runCanonical(gpa, window_frames);
    defer a.deinit(gpa);

    // The frames are variable-length, so constancy is tested on the whole window
    // against its own first half rather than frame by frame.
    const half = a.discrete.items.len / 2;
    try testing.expect(half > 0);
    try testing.expect(!std.mem.eql(u8, a.discrete.items[0..half], a.discrete.items[half..][0..half]));
}

test "the deviation metric fires on a run against a shifted reference" {
    // DISCRIMINATION for `divergenceFrame`. Measured against its own poses, the
    // metric must never fire — that is the self-consistency half. Against a
    // reference deliberately displaced by a metre it must fire at the FIRST
    // frame, which is what proves the comparison is wired to the reference at all
    // and not answering from the run alone.
    const gpa = testing.allocator;
    var a = try runCanonical(gpa, window_frames);
    defer a.deinit(gpa);

    try testing.expectEqual(@as(?u32, null), try divergenceFrame(gpa, a.poses.items, a.pose_stride));

    const shifted = try gpa.dupe(u8, a.poses.items);
    defer gpa.free(shifted);
    // Displace the X of the first body of every frame by one metre.
    const w = @sizeOf(if (Real == f32) u32 else u64);
    var f: usize = 0;
    while (f < window_frames) : (f += 1) {
        const off = f * a.pose_stride;
        const bits = std.mem.readInt(if (Real == f32) u32 else u64, shifted[off..][0..w], .little);
        const v: Real = @bitCast(bits);
        const moved: Real = v + 1;
        std.mem.writeInt(if (Real == f32) u32 else u64, shifted[off..][0..w], @bitCast(moved), .little);
    }
    try testing.expectEqual(@as(?u32, 0), try divergenceFrame(gpa, shifted, a.pose_stride));
}
