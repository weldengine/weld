//! M1.1.4 acceptance suite for the forge_3d narrowphase fast paths. Keyed to
//! `config.Real` so `-Dphysics_f64=true` sweeps the whole suite at f64 (local).
//!
//! **E1 (this file's current content).** The fast-path dispatcher is wired but
//! returns `.not_handled` for every pair, so `collideOrdered` must be identical
//! to the bypass oracle `collideOrderedGeneric`. Asserting that identity over a
//! representative pair set proves the E1 extraction changed no behaviour and
//! exercises `collideOrderedGeneric` (the §13 surface-coverage rule). The per-
//! pair differential sweeps, the P1d closed-forms, the separated short-circuits,
//! and the consolidated feature_id matrix land with the E2–E4 kernels.

const std = @import("std");
const config = @import("../config.zig");
const narrowphase = @import("../pipeline/narrowphase/root.zig");
const math = @import("foundation").math;

const Real = config.Real;
const Vec3r = config.Vec3r;
const Quatr = config.Quatr;
const SupportShape = narrowphase.SupportShape(Real);
const ContactManifold = narrowphase.ContactManifold(Real);
const testing = std.testing;

fn vr(x: Real, y: Real, z: Real) Vec3r {
    return Vec3r.fromArray(.{ x, y, z });
}
fn sphereShape(radius: Real) SupportShape {
    return .{ .core = .point, .radius = radius };
}
fn capsuleShape(half_height: Real, radius: Real) SupportShape {
    return .{ .core = .{ .segment = half_height }, .radius = radius };
}
fn boxShape(hx: Real, hy: Real, hz: Real) SupportShape {
    return .{ .core = .{ .box = vr(hx, hy, hz) }, .radius = 0 };
}
fn roundedBoxShape(hx: Real, hy: Real, hz: Real, radius: Real) SupportShape {
    return .{ .core = .{ .box = vr(hx, hy, hz) }, .radius = radius };
}

fn ordered(sa: SupportShape, pa: Vec3r, ra: Quatr, sb: SupportShape, pb: Vec3r, rb: Quatr) ?ContactManifold {
    return narrowphase.collideOrdered(Real, sa, pa, ra, sb, pb, rb);
}
fn generic(sa: SupportShape, pa: Vec3r, ra: Quatr, sb: SupportShape, pb: Vec3r, rb: Quatr) ?ContactManifold {
    return narrowphase.collideOrderedGeneric(Real, sa, pa, ra, sb, pb, rb);
}

/// Exact manifold equality (count, normal, every point's position/penetration/
/// feature_id). Valid at E1 because the no-op dispatcher makes `collideOrdered`
/// call `collideOrderedGeneric` directly — the results are bit-identical.
fn manifoldsIdentical(a: ?ContactManifold, b: ?ContactManifold) bool {
    if (a == null or b == null) return (a == null) == (b == null);
    const ma = a.?;
    const mb = b.?;
    if (ma.count != mb.count) return false;
    if (!ma.normal.eql(mb.normal)) return false;
    for (0..ma.count) |i| {
        if (!ma.points[i].position.eql(mb.points[i].position)) return false;
        if (ma.points[i].penetration != mb.points[i].penetration) return false;
        if (ma.points[i].feature_id != mb.points[i].feature_id) return false;
    }
    return true;
}

test "E1 dispatcher is a no-op: collideOrdered equals collideOrderedGeneric" {
    const zrot = Quatr.fromAxisAngle(Vec3r.unit_z, std.math.pi / 2.0);
    const yaw = Quatr.fromAxisAngle(Vec3r.unit_y, std.math.pi / 4.0);
    const Combo = struct { sa: SupportShape, pa: Vec3r, ra: Quatr, sb: SupportShape, pb: Vec3r, rb: Quatr };
    const combos = [_]Combo{
        // sphere/sphere: overlapping and separated.
        .{ .sa = sphereShape(1), .pa = vr(0, 0, 0), .ra = Quatr.identity, .sb = sphereShape(1), .pb = vr(1.2, 0, 0), .rb = Quatr.identity },
        .{ .sa = sphereShape(1), .pa = vr(0, 0, 0), .ra = Quatr.identity, .sb = sphereShape(1), .pb = vr(2.5, 0, 0), .rb = Quatr.identity },
        // sphere/box and box/sphere.
        .{ .sa = boxShape(1, 1, 1), .pa = vr(0, 0, 0), .ra = Quatr.identity, .sb = sphereShape(0.5), .pb = vr(0, 0, 0.4), .rb = Quatr.identity },
        .{ .sa = sphereShape(0.5), .pa = vr(0, 0, 0.4), .ra = Quatr.identity, .sb = boxShape(1, 1, 1), .pb = vr(0, 0, 0), .rb = Quatr.identity },
        // box/box: face-face and yawed.
        .{ .sa = boxShape(1, 1, 1), .pa = vr(0, 0, 0), .ra = Quatr.identity, .sb = boxShape(1, 1, 1), .pb = vr(0, 1.5, 0), .rb = Quatr.identity },
        .{ .sa = boxShape(1, 1, 1), .pa = vr(0, 0, 0), .ra = Quatr.identity, .sb = boxShape(1, 1, 1), .pb = vr(0, 1.9, 0), .rb = yaw },
        // capsule/capsule: parallel side-overlap and crossed.
        .{ .sa = capsuleShape(1, 0.5), .pa = vr(0, 0, 0), .ra = Quatr.identity, .sb = capsuleShape(1, 0.5), .pb = vr(0.8, 0, 0), .rb = Quatr.identity },
        .{ .sa = capsuleShape(1, 0.3), .pa = vr(0, 0, 0), .ra = Quatr.identity, .sb = capsuleShape(1, 0.3), .pb = vr(0, 0, 0.5), .rb = zrot },
        // rounded box (radius > 0): must stay on the generic path too.
        .{ .sa = roundedBoxShape(0.5, 0.5, 0.5, 1.0), .pa = vr(0, 0, 0), .ra = Quatr.identity, .sb = roundedBoxShape(0.5, 0.5, 0.5, 1.0), .pb = vr(0, 2.5, 0), .rb = Quatr.identity },
    };
    const globals = [_]Quatr{ Quatr.identity, Quatr.fromAxisAngle(vr(1, 2, 3).normalize(), 0.7) };
    for (combos) |c| {
        for (globals) |g| {
            const pa = g.rotateVec3(c.pa);
            const pb = g.rotateVec3(c.pb);
            const disp = ordered(c.sa, pa, g.mul(c.ra), c.sb, pb, g.mul(c.rb));
            const gen = generic(c.sa, pa, g.mul(c.ra), c.sb, pb, g.mul(c.rb));
            try testing.expect(manifoldsIdentical(disp, gen));
        }
    }
}
