//! `forge_3d/pipeline/narrowphase/manifold.zig` — the contact manifold types and
//! (M1.1.3/E3) the supporting-face clipping generator.
//!
//! M1.1.3/E1 lands the FROZEN `ContactManifold(T)` / `ContactPoint(T)` types and
//! the normal / depth / feature-id convention (brief Notes) — no generator yet.
//! E3 adds the single-shot generator: `supportingFace(+n)` on A clipped against
//! `supportingFace(−n)` on B (Sutherland-Hodgman), reduced to ≤ 4 points, with
//! the inflation radii applied to place surface points and per-point depth.
//!
//! **Convention (FROZEN, brief Notes).** `normal` is unit, world-space, A→B (the
//! axis to translate B along to reduce penetration). `penetration ≥ 0` when
//! overlapping. Order-independence is a hard requirement: `collide(A,B)` and
//! `collide(B,A)` give negated normals, equal `count`, the same point set, and
//! equal per-point `penetration`. Depth is continuous across the shallow↔deep
//! boundary: shallow `= r_sum − dist`, deep `= core_depth + r_sum`.
//!
//! **Dependency discipline (brief Notes).** Imports `foundation` (math) and the
//! sibling `support.zig` / `gjk.zig` / `epa.zig` ONLY — never `weld_forge`,
//! `body*.zig`, `config.zig`, or `broadphase.zig`. The scalar is the comptime
//! `T`; `forge_3d` instantiates it at `config.Real`.

const std = @import("std");
const math = @import("foundation").math;

/// The contact manifold between two shapes: a shared world-space contact
/// `normal` (A→B) plus up to 4 `ContactPoint`s. FROZEN convention (brief Notes);
/// produced by the M1.1.3/E3 supporting-face clipper.
pub fn ContactManifold(comptime T: type) type {
    return struct {
        /// Unit, world-space, points from A to B — the axis along which to
        /// translate B to reduce penetration.
        normal: math.Vec(3, T),
        /// Up to 4 contact points (box face-face max after reduction).
        points: [4]ContactPoint(T),
        /// Valid entries in `points`, 1..4.
        count: u8,
    };
}

/// One contact point of a `ContactManifold`. FROZEN convention (brief Notes).
pub fn ContactPoint(comptime T: type) type {
    return struct {
        /// World-space point on the contact plane (midpoint of the two
        /// surface points at this contact).
        position: math.Vec(3, T),
        /// Surface penetration along `normal`, >= 0 when overlapping.
        penetration: T,
        /// Deterministic, frame-stable per-contact identity for M1.1.6
        /// warm-starting (reference-feature id << 16 | incident-feature id).
        /// Populated now; consumed at M1.1.6. Packing is an impl detail.
        feature_id: u32,
    };
}

const testing = std.testing;

test "manifold contact types round-trip" {
    const T = f32;
    const V = math.Vec(3, T);
    const M = ContactManifold(T);
    const P = ContactPoint(T);

    const zero_pt = P{ .position = V.zero, .penetration = 0, .feature_id = 0 };
    const m = M{
        .normal = V.unit_x,
        .points = .{
            P{ .position = V.fromArray(.{ 1, 2, 3 }), .penetration = 0.25, .feature_id = 0x0003_0007 },
            P{ .position = V.fromArray(.{ -1, 0, 4 }), .penetration = 0.5, .feature_id = 0x0002_0005 },
            zero_pt,
            zero_pt,
        },
        .count = 2,
    };

    try testing.expect(m.normal.approxEql(V.unit_x, 1e-6));
    try testing.expectEqual(@as(u8, 2), m.count);
    try testing.expect(m.points[0].position.approxEql(V.fromArray(.{ 1, 2, 3 }), 1e-6));
    try testing.expectEqual(@as(T, 0.25), m.points[0].penetration);
    try testing.expectEqual(@as(u32, 0x0003_0007), m.points[0].feature_id);
    try testing.expect(m.points[1].position.approxEql(V.fromArray(.{ -1, 0, 4 }), 1e-6));
    try testing.expectEqual(@as(T, 0.5), m.points[1].penetration);
    try testing.expectEqual(@as(u32, 0x0002_0005), m.points[1].feature_id);

    // Generic over the scalar: the same types instantiate at f64.
    const M64 = ContactManifold(f64);
    const V64 = math.Vec(3, f64);
    const m64 = M64{
        .normal = V64.unit_y,
        .points = .{
            ContactPoint(f64){ .position = V64.zero, .penetration = 1.5, .feature_id = 1 },
            ContactPoint(f64){ .position = V64.zero, .penetration = 0, .feature_id = 0 },
            ContactPoint(f64){ .position = V64.zero, .penetration = 0, .feature_id = 0 },
            ContactPoint(f64){ .position = V64.zero, .penetration = 0, .feature_id = 0 },
        },
        .count = 1,
    };
    try testing.expectEqual(@as(f64, 1.5), m64.points[0].penetration);
    try testing.expect(m64.normal.approxEql(V64.unit_y, 1e-12));
}
