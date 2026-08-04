//! Acceptance suite for the kinematic character controller (M1.1.12).
//!
//! Grows gate by gate. Gate B covers the seventh body-level adapter
//! (`BodyManager.collideShapeBody`) and the character STORE: creation, destruction, the
//! domain rejections, transactional rollback, the three outcomes of
//! `getCharacterInnerBody`, and the presence's visibility to queries. Nothing that moves —
//! `moveCharacter`, the ground verdict, resize and the push have their own gates.
//!
//! Every expectation is a CLOSED FORM computed by hand in the comment above it, never a
//! value read back from the implementation. Where a transcendental is unavoidable the angle
//! is chosen so its cosine IS a closed form: `cos(π/3) = 1/2`, `cos(π/4) = √2/2`.

const std = @import("std");
const config = @import("../config.zig");
const shape_mod = @import("../shape.zig");
const bm_mod = @import("../body_manager.zig");
const character_mod = @import("../character.zig");
const narrowphase = @import("../pipeline/narrowphase/root.zig");
const query = @import("../query/root.zig");
const api = @import("weld_forge");
const foundation = @import("foundation");
const harness = @import("solver_test.zig");
const sleep_mod = @import("../pipeline/sleep.zig");

const Real = config.Real;
const Vec3r = config.Vec3r;
const Quatr = config.Quatr;
const BodyManager = bm_mod.BodyManager;
const ShapeStore = shape_mod.ShapeStore;
const CharacterStore = character_mod.CharacterStore;
const CharacterError = character_mod.CharacterError;
const math = foundation.math;
const ApiVec3 = math.Vec3;
const SupportShapeR = narrowphase.SupportShape(Real);
const testing = std.testing;

/// Absolute tolerance for a quantity computed at SOLVER precision — float noise at the
/// unit-to-ten scale these tests work at, not geometric slack.
const tol: Real = if (Real == f32) 1e-5 else 1e-12;

/// Absolute tolerance for a quantity that arrived through the PUBLIC `f32` surface and was
/// then widened. It is `f32`-grade in BOTH builds, and deliberately so.
///
/// `CharacterDescriptor` is `f32` and stays `f32` until the grouped widening decision of
/// M1.1.15 (§1.11.8, §1.12.11), so a field authored as `0.3` is stored as `f32(0.3)` — which
/// widened is `0.30000001192…`, not `0.3`. Asserting such a value against a decimal literal
/// at `tol` would be asserting a precision the descriptor CANNOT carry, and it is what made
/// six of these tests fail at `-Dphysics_f64=true` while passing at `f32`, where the two
/// tolerances happen to coincide.
///
/// The bound is sized on `floatEps(f32)` times the largest magnitude here (about 10 m), which
/// is `1.2e-6`, with a factor of ten of headroom. Anything the solver itself computes keeps
/// `tol`: the distinction is the QUANTITY'S ORIGIN, not whether a literal is representable.
const api_tol: Real = 1e-5;

fn v(x: Real, y: Real, z: Real) Vec3r {
    return Vec3r.fromArray(.{ x, y, z });
}

fn av(x: f32, y: f32, z: f32) ApiVec3 {
    return ApiVec3.fromArray(.{ x, y, z });
}

fn ent(index: u32) api.EntityId {
    return .{ .index = index, .generation = 0 };
}

/// A descriptor whose every field is the frozen default, with only the entity supplied —
/// so a test that overrides one field is visibly testing that field.
fn baseDescriptor() api.CharacterDescriptor {
    return .{ .entity = ent(1) };
}

// ---------------------------------------------------------------------------
// B.1 — the seventh adapter: `collideShapeBody`
// ---------------------------------------------------------------------------

/// Every manifold `collideShapeBody` offers, tagged with its sub-shape. Same shape as
/// `mesh_test.zig`'s tally: the collector contract is `add(subshape_id, manifold)`.
const Tally = struct {
    ids: [32]u32 = @splat(0),
    normals: [32]Vec3r = @splat(Vec3r.zero),
    penetrations: [32]Real = @splat(0),
    count: u32 = 0,

    pub fn add(self: *Tally, subshape_id: u32, manifold: narrowphase.ContactManifold(Real)) void {
        self.ids[self.count] = subshape_id;
        self.normals[self.count] = manifold.normal;
        self.penetrations[self.count] = manifold.points[0].penetration;
        self.count += 1;
    }

    fn has(self: *const Tally, subshape_id: u32) bool {
        for (self.ids[0..self.count]) |id| {
            if (id == subshape_id) return true;
        }
        return false;
    }
};

test "collideShapeBody answers against a convex body, normal probe to body" {
    const gpa = testing.allocator;
    var store: ShapeStore = .{};
    defer store.deinit(gpa);
    var bm: BodyManager = .{};
    defer bm.deinit(gpa);

    // A 1 m half-extent box centred at the origin. Its +X face is at x = 1.
    const box = try store.createShape(gpa, .{ .box = .{ .half_extents = ApiVec3.splat(1) } });
    const body = try bm.addBody(gpa, &store, .{
        .entity = ent(7),
        .body_type = .static,
        .shape = box,
        .position = av(0, 0, 0),
    });

    // A unit sphere probe centred at x = 1.5: its surface reaches x = 0.5, so it overlaps
    // the box's +X face by exactly 1 + 1 − 1.5 = 0.5 m. The probe is A and the body is B,
    // so the normal runs probe → body, i.e. −X.
    const probe = SupportShapeR{ .core = .point, .radius = 1 };
    var tally = Tally{};
    bm.collideShapeBody(&store, body, probe, v(1.5, 0, 0), Quatr.identity, &tally);

    try testing.expectEqual(@as(u32, 1), tally.count);
    try testing.expect(tally.normals[0].approxEql(v(-1, 0, 0), tol));
    try testing.expectApproxEqAbs(@as(Real, 0.5), tally.penetrations[0], tol);
    // A shape with no sub-shape tags `0`, and that value is not read (§1.11.16).
    try testing.expectEqual(@as(u32, 0), tally.ids[0]);
}

test "collideShapeBody answers against a half-space body" {
    const gpa = testing.allocator;
    var store: ShapeStore = .{};
    defer store.deinit(gpa);
    var bm: BodyManager = .{};
    defer bm.deinit(gpa);

    // The ground half-space `{ y <= 0 }`, which forces a static body (§1.11.15).
    const plane = try store.createShape(gpa, .{ .plane = .{ .normal = av(0, 1, 0), .distance = 0 } });
    const body = try bm.addBody(gpa, &store, .{
        .entity = ent(3),
        .body_type = .static,
        .shape = plane,
        .position = av(0, 0, 0),
    });

    // A unit sphere probe centred at y = 0.75 dips to y = −0.25, so it penetrates the solid
    // by 0.25 m. Normal probe → body is −Y: the plane's outward normal is +Y and the entry
    // negates the body→probe form §1.11.15's formulas are stated in.
    const probe = SupportShapeR{ .core = .point, .radius = 1 };
    var tally = Tally{};
    bm.collideShapeBody(&store, body, probe, v(0, 0.75, 0), Quatr.identity, &tally);

    try testing.expectEqual(@as(u32, 1), tally.count);
    try testing.expect(tally.normals[0].approxEql(v(0, -1, 0), tol));
    try testing.expectApproxEqAbs(@as(Real, 0.25), tally.penetrations[0], tol);
}

test "collideShapeBody returns SEVERAL manifolds against a mesh, one per contacting triangle" {
    const gpa = testing.allocator;
    var store: ShapeStore = .{};
    defer store.deinit(gpa);
    var bm: BodyManager = .{};
    defer bm.deinit(gpa);

    // A flat quad at y = 0 spanning x, z in [−1, 1], as TWO triangles sharing the diagonal
    // from (−1, −1) to (1, 1). Winding is counter-clockwise seen from the front face, so the
    // outward normal is +Y for both — verified by hand:
    //   tri 0 = v0, v1, v2 : (v1−v0) × (v2−v0) = (2,0,2) × (2,0,0) = (0, 4, 0)  → +Y
    //   tri 1 = v0, v3, v1 : (v3−v0) × (v1−v0) = (0,0,2) × (2,0,2) = (0, 4, 0)  → +Y
    const verts = [_]ApiVec3{
        av(-1, 0, -1), // v0 — on the shared diagonal
        av(1, 0, 1), //  v1 — on the shared diagonal
        av(1, 0, -1), // v2
        av(-1, 0, 1), // v3
    };
    const idx = [_]u32{ 0, 1, 2, 0, 3, 1 };
    const mesh = try store.createShape(gpa, .{ .triangle_mesh = .{ .vertices = &verts, .indices = &idx } });
    const body = try bm.addBody(gpa, &store, .{
        .entity = ent(9),
        .body_type = .static,
        .shape = mesh,
        .position = av(0, 0, 0),
    });

    // A radius-0.5 sphere centred at (0, 0.4, 0) dips to y = −0.1. The point (0, 0) lies ON
    // the shared diagonal, hence inside BOTH triangles (the boundary is included), so the
    // closest point of each to the probe centre is (0, 0, 0) at distance 0.4 < 0.5 — both
    // overlap, and the entry must report both.
    //
    // ABOVE the plane on purpose: contact generation culls back faces unconditionally, so a
    // probe centred below y = 0 would be culled on both triangles and report nothing. That
    // is the correct behaviour and it is asserted separately below.
    const probe = SupportShapeR{ .core = .point, .radius = 0.5 };
    var tally = Tally{};
    bm.collideShapeBody(&store, body, probe, v(0, 0.4, 0), Quatr.identity, &tally);

    try testing.expectEqual(@as(u32, 2), tally.count);
    try testing.expect(tally.has(0));
    try testing.expect(tally.has(1));
    // Both normals run probe → body, i.e. downward onto the floor, and the internal-edge
    // correction (the diagonal is paired and FLAT, so inactive) pins them to exactly −Y.
    for (tally.normals[0..tally.count]) |n| {
        try testing.expect(n.approxEql(v(0, -1, 0), tol));
    }

    // THE DISCRIMINATOR, without which "2" could be an artefact of the entry offering every
    // triangle it traverses rather than every triangle it CONTACTS. A probe over the interior
    // of ONE triangle must report exactly one manifold, and its identity must be that
    // triangle's. (0.5, 0.5) in xz lies strictly on the +x side of the diagonal x = z, so it
    // is interior to triangle 0 — corners (−1,−1), (1,1), (1,−1) — and 0.5 m of clearance
    // from the diagonal is far more than the radius-0.5 sphere's 0.1 m of dip can reach.
    {
        var one = Tally{};
        bm.collideShapeBody(&store, body, probe, v(0.5, 0.4, -0.5), Quatr.identity, &one);
        try testing.expectEqual(@as(u32, 1), one.count);
        try testing.expectEqual(@as(u32, 0), one.ids[0]);
    }
}

test "collideShapeBody culls a mesh back face, and answers nothing on a stale handle or a separated probe" {
    const gpa = testing.allocator;
    var store: ShapeStore = .{};
    defer store.deinit(gpa);
    var bm: BodyManager = .{};
    defer bm.deinit(gpa);

    const verts = [_]ApiVec3{ av(-1, 0, -1), av(1, 0, 1), av(1, 0, -1), av(-1, 0, 1) };
    const idx = [_]u32{ 0, 1, 2, 0, 3, 1 };
    const mesh = try store.createShape(gpa, .{ .triangle_mesh = .{ .vertices = &verts, .indices = &idx } });
    const mesh_body = try bm.addBody(gpa, &store, .{
        .entity = ent(9),
        .body_type = .static,
        .shape = mesh,
        .position = av(0, 0, 0),
    });
    const probe = SupportShapeR{ .core = .point, .radius = 0.5 };

    // BELOW the surface: the probe reaches the plane, so GJK finds an overlap, but the
    // contact normal opposes the outward normal and every triangle is culled. Zero
    // manifolds — a contact generated on the back of a wall would push the body through it.
    {
        var tally = Tally{};
        bm.collideShapeBody(&store, mesh_body, probe, v(0, -0.4, 0), Quatr.identity, &tally);
        try testing.expectEqual(@as(u32, 0), tally.count);
    }

    // Separated: 10 m above the floor, nothing is offered at all.
    {
        var tally = Tally{};
        bm.collideShapeBody(&store, mesh_body, probe, v(0, 10, 0), Quatr.identity, &tally);
        try testing.expectEqual(@as(u32, 0), tally.count);
    }

    // A stale handle: the collector is never called. Distinct from "separated" only in
    // cause, but the adapter must not touch a freed slot to find that out.
    {
        const box = try store.createShape(gpa, .{ .box = .{ .half_extents = ApiVec3.splat(1) } });
        const doomed = try bm.addBody(gpa, &store, .{
            .entity = ent(4),
            .body_type = .static,
            .shape = box,
            .position = av(0, 0, 0),
        });
        bm.removeBody(doomed);
        var tally = Tally{};
        bm.collideShapeBody(&store, doomed, probe, Vec3r.zero, Quatr.identity, &tally);
        try testing.expectEqual(@as(u32, 0), tally.count);
    }
}

// ---------------------------------------------------------------------------
// B.2 — the character store
// ---------------------------------------------------------------------------

test "createCharacter stores the descriptor and poses the presence at the capsule CENTRE" {
    const gpa = testing.allocator;
    var store: ShapeStore = .{};
    defer store.deinit(gpa);
    var bm: BodyManager = .{};
    defer bm.deinit(gpa);
    var chars: CharacterStore = .{};
    defer chars.deinit(gpa);

    // Defaults except the base position and the slope: radius 0.3, height 1.8, so the
    // capsule's cylinder half-height is 1.8/2 − 0.3 = 0.6 and the capsule spans 1.8 m.
    // `max_slope = π/3` is chosen because its cosine is EXACTLY 1/2 — a closed form, where
    // the default 0.785 rad would force reading a transcendental back.
    var desc = baseDescriptor();
    desc.position = av(2, 5, -3);
    desc.max_slope = std.math.pi / 3.0;
    const id = try chars.createCharacter(gpa, &store, &bm, desc);

    try testing.expectEqual(@as(u32, 1), chars.count());
    const c = chars.get(id).?;
    try testing.expect(c.position.approxEql(v(2, 5, -3), tol));
    try testing.expectApproxEqAbs(@as(Real, 0.3), c.radius, api_tol);
    try testing.expectApproxEqAbs(@as(Real, 1.8), c.height, api_tol);
    try testing.expectApproxEqAbs(@as(Real, 0.3), c.step_height, api_tol);
    try testing.expectApproxEqAbs(@as(Real, 0.5), c.cos_max_slope, api_tol);
    try testing.expectApproxEqAbs(@as(Real, 0.02), c.padding, api_tol);
    try testing.expectApproxEqAbs(@as(Real, 0.1), c.predictive_contact_distance, api_tol);
    try testing.expectEqual(@as(u8, 0), c.collision_layer);
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), c.layer_mask);
    try testing.expectApproxEqAbs(@as(Real, 70), c.mass, api_tol);
    try testing.expectApproxEqAbs(@as(Real, 100), c.max_push_force, api_tol);
    try testing.expectEqual(ent(1), c.entity);

    // The capsule the store built, read back through the shape it owns.
    const capsule = store.get(c.shape).?;
    try testing.expectEqual(api.ShapeType.capsule, capsule.shape_type);
    try testing.expectApproxEqAbs(@as(Real, 0.3), capsule.radius, api_tol);
    try testing.expectApproxEqAbs(@as(Real, 0.6), capsule.half_height, api_tol);

    // THE OFFSET. The character's position is its BASE at y = 5; the presence is a body, so
    // its pose is the CENTRE of the capsule, half the height higher: y = 5 + 0.9 = 5.9. X
    // and Z are untouched — the offset is along up alone.
    const presence = (try chars.getCharacterInnerBody(id)).?;
    try testing.expect(bm.position(presence).?.approxEql(v(2, 5.9, -3), api_tol));
    try testing.expectEqual(api.BodyType.kinematic, bm.bodyType(presence).?);
    // The presence carries the character's own capsule, never a second shape (§1.12.2).
    try testing.expectEqual(c.shape, bm.shapeOf(presence).?);
    // Its entity is the character's, so a query that finds it names the character.
    try testing.expectEqual(ent(1), bm.entity(presence).?);
    // Its layer is `collision_layer`, with no dedicated field (§1.12.2).
    try testing.expectEqual(@as(u8, 0), bm.collisionLayer(presence).?);
}

test "the stored cosine is the single trigonometric call, and a larger cosine is a stricter limit" {
    const gpa = testing.allocator;
    var store: ShapeStore = .{};
    defer store.deinit(gpa);
    var bm: BodyManager = .{};
    defer bm.deinit(gpa);
    var chars: CharacterStore = .{};
    defer chars.deinit(gpa);

    // cos(π/4) = √2/2 ≈ 0.7071067811865476, and cos(π/3) = 1/2 — both closed forms.
    var steep = baseDescriptor();
    steep.max_slope = std.math.pi / 4.0;
    const a = try chars.createCharacter(gpa, &store, &bm, steep);

    var shallow = baseDescriptor();
    shallow.max_slope = std.math.pi / 3.0;
    const b = try chars.createCharacter(gpa, &store, &bm, shallow);

    const root2: Real = @sqrt(@as(Real, 2));
    try testing.expectApproxEqAbs(root2 / 2, chars.get(a).?.cos_max_slope, api_tol);
    try testing.expectApproxEqAbs(@as(Real, 0.5), chars.get(b).?.cos_max_slope, api_tol);

    // The direction of the comparison, pinned because it is easy to invert: the test is
    // `n · up >= cos_max_slope`, so the SMALLER angle stores the LARGER cosine and admits
    // fewer slopes.
    try testing.expect(chars.get(a).?.cos_max_slope > chars.get(b).?.cos_max_slope);

    // A slope limit of zero admits only an exactly flat floor: cos(0) = 1.
    var flat = baseDescriptor();
    flat.max_slope = 0;
    const c = try chars.createCharacter(gpa, &store, &bm, flat);
    try testing.expectApproxEqAbs(@as(Real, 1), chars.get(c).?.cos_max_slope, api_tol);
}

test "destroyCharacter releases all three resources and is a no-op on a stale handle" {
    const gpa = testing.allocator;
    var store: ShapeStore = .{};
    defer store.deinit(gpa);
    var bm: BodyManager = .{};
    defer bm.deinit(gpa);
    var chars: CharacterStore = .{};
    defer chars.deinit(gpa);

    const id = try chars.createCharacter(gpa, &store, &bm, baseDescriptor());
    const presence = (try chars.getCharacterInnerBody(id)).?;
    try testing.expectEqual(@as(u32, 1), chars.count());
    try testing.expectEqual(@as(u32, 1), store.count());
    try testing.expectEqual(@as(u32, 1), bm.count());

    chars.destroyCharacter(gpa, &store, &bm, id);

    // All three counts back to zero: the character, its capsule and its presence.
    try testing.expectEqual(@as(u32, 0), chars.count());
    try testing.expectEqual(@as(u32, 0), store.count());
    try testing.expectEqual(@as(u32, 0), bm.count());
    try testing.expect(!bm.isValid(presence));
    try testing.expectEqual(@as(?character_mod.Character, null), chars.get(id));

    // A SECOND destroy releases nothing — which is what keeps a double destroy from
    // double-freeing the capsule. It must not fault, and the counts must not go negative
    // or wrap.
    chars.destroyCharacter(gpa, &store, &bm, id);
    try testing.expectEqual(@as(u32, 0), chars.count());
    try testing.expectEqual(@as(u32, 0), store.count());
    try testing.expectEqual(@as(u32, 0), bm.count());
}

test "a recycled slot yields a different handle, so a stale one stays detectable" {
    const gpa = testing.allocator;
    var store: ShapeStore = .{};
    defer store.deinit(gpa);
    var bm: BodyManager = .{};
    defer bm.deinit(gpa);
    var chars: CharacterStore = .{};
    defer chars.deinit(gpa);

    const first = try chars.createCharacter(gpa, &store, &bm, baseDescriptor());
    chars.destroyCharacter(gpa, &store, &bm, first);
    const second = try chars.createCharacter(gpa, &store, &bm, baseDescriptor());

    // LIFO recycling puts the second character in the freed slot, so the two handles share
    // an INDEX and differ only in GENERATION — which is the whole reason the generation is
    // on the handle. Without it the stale `first` would silently address `second`.
    try testing.expectEqual(
        api.PackedId.unpack(first).index,
        api.PackedId.unpack(second).index,
    );
    try testing.expect(first != second);
    try testing.expectError(error.StaleCharacter, chars.getCharacterInnerBody(first));
    try testing.expect((try chars.getCharacterInnerBody(second)) != null);
}

test "getCharacterInnerBody has three outcomes and never conflates two of them" {
    const gpa = testing.allocator;
    var store: ShapeStore = .{};
    defer store.deinit(gpa);
    var bm: BodyManager = .{};
    defer bm.deinit(gpa);
    var chars: CharacterStore = .{};
    defer chars.deinit(gpa);

    // 1 — a live character WITH a presence: the handle.
    const with = try chars.createCharacter(gpa, &store, &bm, baseDescriptor());
    const presence = (try chars.getCharacterInnerBody(with)).?;
    try testing.expect(bm.isValid(presence));

    // 2 — a live character WITHOUT one: `null`, and no body was created for it.
    var none = baseDescriptor();
    none.inner_body = false;
    const without = try chars.createCharacter(gpa, &store, &bm, none);
    try testing.expectEqual(@as(?api.BodyId, null), try chars.getCharacterInnerBody(without));
    // Still exactly ONE body in the manager — the first character's.
    try testing.expectEqual(@as(u32, 1), bm.count());
    // But two capsules: a presence-less character still owns its shape, which the move
    // algorithm sweeps with.
    try testing.expectEqual(@as(u32, 2), store.count());

    // 3 — a stale handle: a typed ERROR, not `null`. Conflating it with outcome 2 would
    // make a dead handle indistinguishable from a live presence-less character.
    chars.destroyCharacter(gpa, &store, &bm, with);
    try testing.expectError(error.StaleCharacter, chars.getCharacterInnerBody(with));
}

test "the descriptor domain is refused by typed error and never sanitised" {
    const gpa = testing.allocator;
    var store: ShapeStore = .{};
    defer store.deinit(gpa);
    var bm: BodyManager = .{};
    defer bm.deinit(gpa);
    var chars: CharacterStore = .{};
    defer chars.deinit(gpa);

    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);

    const Case = struct {
        expected: CharacterError,
        mutate: *const fn (*api.CharacterDescriptor) void,
    };
    const cases = [_]Case{
        // radius: non-finite, and non-positive on both sides of zero.
        .{ .expected = error.InvalidDimensions, .mutate = struct {
            fn f(d: *api.CharacterDescriptor) void {
                d.radius = nan;
            }
        }.f },
        .{ .expected = error.InvalidDimensions, .mutate = struct {
            fn f(d: *api.CharacterDescriptor) void {
                d.radius = inf;
            }
        }.f },
        .{ .expected = error.InvalidDimensions, .mutate = struct {
            fn f(d: *api.CharacterDescriptor) void {
                d.radius = 0;
            }
        }.f },
        .{ .expected = error.InvalidDimensions, .mutate = struct {
            fn f(d: *api.CharacterDescriptor) void {
                d.radius = -0.3;
            }
        }.f },
        // height: same three shapes.
        .{ .expected = error.InvalidDimensions, .mutate = struct {
            fn f(d: *api.CharacterDescriptor) void {
                d.height = nan;
            }
        }.f },
        .{ .expected = error.InvalidDimensions, .mutate = struct {
            fn f(d: *api.CharacterDescriptor) void {
                d.height = 0;
            }
        }.f },
        .{ .expected = error.InvalidDimensions, .mutate = struct {
            fn f(d: *api.CharacterDescriptor) void {
                d.height = -1.8;
            }
        }.f },
        // A capsule shorter than its own diameter: height 0.4 against radius 0.3 would ask
        // for a cylinder half-height of −0.1. Refused, not clamped to a sphere.
        .{ .expected = error.InvalidDimensions, .mutate = struct {
            fn f(d: *api.CharacterDescriptor) void {
                d.height = 0.4;
            }
        }.f },
        // max_slope: non-finite, negative, and BEYOND VERTICAL. `π` is the case that has to
        // fail rather than clamp to `π/2` — clamping would read as a modelling choice.
        .{ .expected = error.InvalidSlope, .mutate = struct {
            fn f(d: *api.CharacterDescriptor) void {
                d.max_slope = nan;
            }
        }.f },
        .{ .expected = error.InvalidSlope, .mutate = struct {
            fn f(d: *api.CharacterDescriptor) void {
                d.max_slope = -0.1;
            }
        }.f },
        .{ .expected = error.InvalidSlope, .mutate = struct {
            fn f(d: *api.CharacterDescriptor) void {
                d.max_slope = std.math.pi;
            }
        }.f },
        // padding: non-finite, and NEGATIVE — which inflates the capsule inward, so the
        // character sinks `|padding|` into every surface with nothing reporting it.
        .{ .expected = error.InvalidPadding, .mutate = struct {
            fn f(d: *api.CharacterDescriptor) void {
                d.padding = nan;
            }
        }.f },
        .{ .expected = error.InvalidPadding, .mutate = struct {
            fn f(d: *api.CharacterDescriptor) void {
                d.padding = -0.01;
            }
        }.f },
        // mass: non-finite, ZERO — which would duplicate `max_push_force = 0`, the documented
        // disabler — and NEGATIVE, which inverts the impulse so the character pulls.
        .{ .expected = error.InvalidPushParameters, .mutate = struct {
            fn f(d: *api.CharacterDescriptor) void {
                d.mass = inf;
            }
        }.f },
        .{ .expected = error.InvalidPushParameters, .mutate = struct {
            fn f(d: *api.CharacterDescriptor) void {
                d.mass = 0;
            }
        }.f },
        .{ .expected = error.InvalidPushParameters, .mutate = struct {
            fn f(d: *api.CharacterDescriptor) void {
                d.mass = -70;
            }
        }.f },
        // max_push_force: non-finite and negative. Zero is the disabler and stays legal.
        .{ .expected = error.InvalidPushParameters, .mutate = struct {
            fn f(d: *api.CharacterDescriptor) void {
                d.max_push_force = nan;
            }
        }.f },
        .{ .expected = error.InvalidPushParameters, .mutate = struct {
            fn f(d: *api.CharacterDescriptor) void {
                d.max_push_force = -1;
            }
        }.f },
        // predictive_contact_distance: guarded because it is STORED, so a caller's NaN would
        // sit in the record indistinguishable from this repository's DELIBERATE poison NaN.
        .{ .expected = error.InvalidDimensions, .mutate = struct {
            fn f(d: *api.CharacterDescriptor) void {
                d.predictive_contact_distance = nan;
            }
        }.f },
        .{ .expected = error.InvalidDimensions, .mutate = struct {
            fn f(d: *api.CharacterDescriptor) void {
                d.predictive_contact_distance = -0.1;
            }
        }.f },
        // collision_layer: the mask is 32 bits, so 32 and 255 are both invisible-to-every-
        // query and both refused — the same error and the same reason as `addBody`.
        .{ .expected = error.InvalidCollisionLayer, .mutate = struct {
            fn f(d: *api.CharacterDescriptor) void {
                d.collision_layer = 32;
            }
        }.f },
        .{ .expected = error.InvalidCollisionLayer, .mutate = struct {
            fn f(d: *api.CharacterDescriptor) void {
                d.collision_layer = 255;
            }
        }.f },
    };

    for (cases) |case| {
        var desc = baseDescriptor();
        case.mutate(&desc);
        try testing.expectError(case.expected, chars.createCharacter(gpa, &store, &bm, desc));
        // NOTHING was created by a refusal — no character, no capsule, no presence. That is
        // what "validate before the first allocation" buys, and it is asserted after every
        // case rather than once at the end, so a leak cannot be masked by a later success.
        try testing.expectEqual(@as(u32, 0), chars.count());
        try testing.expectEqual(@as(u32, 0), store.count());
        try testing.expectEqual(@as(u32, 0), bm.count());
    }

    // The legal boundaries of the same fields, so the rejections above are not a blanket
    // refusal — which is what a domain test asserts second and what makes the first half
    // meaningful. `max_slope` exactly at `π/2` is admissible (a vertical wall counts as
    // walkable); `max_push_force` of zero disables pushing with no special case, and is the
    // ONLY way to do so now that `mass = 0` is refused; `padding` of zero is no margin;
    // `predictive_contact_distance` of zero is legal domain even though the reference
    // documents it as a value that gets the character stuck — a bad tuning value is not a
    // malformed one; and a capsule whose height is exactly twice its radius is a sphere.
    {
        var ok = baseDescriptor();
        ok.max_slope = std.math.pi / 2.0;
        ok.max_push_force = 0;
        ok.padding = 0;
        ok.predictive_contact_distance = 0;
        ok.height = 0.6; // exactly 2 × 0.3 → cylinder half-height 0
        ok.collision_layer = 31; // the last legal layer
        const id = try chars.createCharacter(gpa, &store, &bm, ok);
        try testing.expectApproxEqAbs(@as(Real, 0), store.get(chars.get(id).?.shape).?.half_height, api_tol);
        // cos(π/2) = 0 exactly in mathematics; in floating point it is the tiny residue of
        // the argument reduction, so the assertion is on the tolerance and not on equality.
        try testing.expectApproxEqAbs(@as(Real, 0), chars.get(id).?.cos_max_slope, api_tol);
        chars.destroyCharacter(gpa, &store, &bm, id);
    }
}

test "createCharacter is transactional: no allocation failure leaves a live slot or an orphan" {
    // The sweep runs `fail_index` upward until the call succeeds. At every failing index the
    // three stores must be EMPTY: no live character, no orphan capsule, no orphan presence.
    //
    // A sweep rather than one hand-written case per allocation site: the number of sites is
    // then MEASURED instead of predicted, and a site added later is covered without the test
    // being edited. The count it observes is reported in the brief.
    var failing_indices: u32 = 0;
    var fail_index: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        const gpa = failing.allocator();

        var store: ShapeStore = .{};
        var bm: BodyManager = .{};
        var chars: CharacterStore = .{};

        const result = chars.createCharacter(gpa, &store, &bm, baseDescriptor());

        if (result) |_| {
            // The first index at which the whole call gets through: every earlier one failed,
            // so `failing_indices` is the number of allocations this call actually performs.
            chars.deinit(gpa);
            store.deinit(gpa);
            bm.deinit(gpa);
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            failing_indices += 1;
            try testing.expectEqual(@as(u32, 0), chars.count());
            try testing.expectEqual(@as(u32, 0), store.count());
            try testing.expectEqual(@as(u32, 0), bm.count());
            chars.deinit(gpa);
            store.deinit(gpa);
            bm.deinit(gpa);
        }
    }

    // NON-VACUITY: the sweep has to have exercised at least one failure, otherwise it
    // asserted nothing at all. Four allocations are structurally required — the shape store's
    // slot metadata and its column, then the body manager's two — plus this store's own two,
    // so the count cannot be zero and cannot be one.
    try testing.expect(failing_indices >= 2);
    // And it must have TERMINATED by succeeding, not by exhausting the loop bound.
    try testing.expect(failing_indices < 64);
}

// ---------------------------------------------------------------------------
// The presence is an ordinary body to a query
// ---------------------------------------------------------------------------

/// Create a character in `world` and insert its presence's broadphase proxy, which
/// `createCharacter` deliberately does not do: no `BodyType → BroadphaseLayer` wiring exists
/// — the layer is an insertion argument — and it arrives with `PhysicsWorld` at M1.1.15.
///
/// The proxy is inserted here rather than through `harness.World.addBody`, which would need
/// the descriptor the store built internally. It is not registered in `world.bodies`, whose
/// only consumer is the W4 wake sweep, and nothing in this gate solves.
fn addCharacter(
    gpa: std.mem.Allocator,
    world: *harness.World,
    chars: *CharacterStore,
    desc: api.CharacterDescriptor,
) !api.CharacterId {
    const id = try chars.createCharacter(gpa, &world.store, &world.bm, desc);
    if (try chars.getCharacterInnerBody(id)) |presence| {
        _ = try world.bp.insert(
            gpa,
            .dynamic, // a kinematic body shares the dynamic layer, per the harness's own map
            world.bm.bodyAabb(&world.store, presence).?,
            presence,
        );
    }
    return id;
}

test "a ray from outside finds the presence, and excluding its BodyId hides it" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    var chars: CharacterStore = .{};
    defer chars.deinit(gpa);

    // Base at the origin, defaults: radius 0.3, height 1.8. The capsule therefore spans
    // y ∈ [0, 1.8] with its cylinder wall at radius 0.3 about the Y axis between y = 0.3 and
    // y = 1.5.
    var desc = baseDescriptor();
    desc.entity = ent(42);
    const id = try addCharacter(gpa, &world, &chars, desc);
    const presence = (try chars.getCharacterInnerBody(id)).?;

    // A ray from (−10, 0.9, 0) along +X strikes the cylinder wall at x = −0.3, so the
    // distance is exactly 10 − 0.3 = 9.7 and the outward normal there is −X.
    const q = query.RayQuery{ .origin = v(-10, 0.9, 0), .direction = v(1, 0, 0), .max_distance = 100 };
    const hit = (query.raycast(&world.bp, &world.bm, &world.store, q)).?;
    try testing.expectEqual(presence, hit.body);
    // The ENTITY is the character's, which is what makes the character shootable: a caller
    // resolves damage against an entity, never against a `BodyId`.
    try testing.expectEqual(ent(42), hit.entity);
    try testing.expectApproxEqAbs(@as(Real, 9.7), hit.distance, api_tol);
    try testing.expect(hit.normal.approxEql(v(-1, 0, 0), tol));

    // The SAME ray, excluding the presence: nothing. This is the anti-wall sweep of a follow
    // camera and the character's own probes — `PhysicsQueryFilter.exclude` takes `BodyId`
    // alone, which is why `getCharacterInnerBody` has to exist (§1.12.2).
    const excluded = query.RayQuery{
        .origin = v(-10, 0.9, 0),
        .direction = v(1, 0, 0),
        .max_distance = 100,
        .filter = .{ .exclude = &.{presence} },
    };
    try testing.expectEqual(@as(?query.RayHit, null), query.raycast(&world.bp, &world.bm, &world.store, excluded));
}

test "inner_body false leaves the character invisible to every query" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    var chars: CharacterStore = .{};
    defer chars.deinit(gpa);

    var desc = baseDescriptor();
    desc.inner_body = false;
    const id = try addCharacter(gpa, &world, &chars, desc);

    try testing.expectEqual(@as(?api.BodyId, null), try chars.getCharacterInnerBody(id));

    // The same ray that hit the presence above finds nothing at all — which is exactly the
    // failure mode `inner_body`'s default of `true` exists to avoid: a character nobody can
    // shoot, discovered late.
    const q = query.RayQuery{ .origin = v(-10, 0.9, 0), .direction = v(1, 0, 0), .max_distance = 100 };
    try testing.expectEqual(@as(?query.RayHit, null), query.raycast(&world.bp, &world.bm, &world.store, q));
    // Nor does an overlap, which walks the trees rather than a ray.
    var out: [4]api.BodyId = undefined;
    const probe = try world.store.createShape(gpa, .{ .sphere = .{ .radius = 5 } });
    const n = try query.overlapShape(&world.bp, &world.bm, &world.store, .{
        .shape = probe,
        .position = v(0, 0.9, 0),
    }, &out);
    try testing.expectEqual(@as(u32, 0), n);
}

test "two characters each see the other's presence and neither is hidden by the other" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    var chars: CharacterStore = .{};
    defer chars.deinit(gpa);

    // Two characters 4 m apart on X, so their capsules (radius 0.3) are nowhere near
    // touching. Self-exclusion is the CONTROLLER's business, not the store's — the store
    // hands out the handles and each caller excludes its own (§1.12.2).
    var left = baseDescriptor();
    left.entity = ent(1);
    left.position = av(-2, 0, 0);
    const a = try addCharacter(gpa, &world, &chars, left);

    var right = baseDescriptor();
    right.entity = ent(2);
    right.position = av(2, 0, 0);
    const b = try addCharacter(gpa, &world, &chars, right);

    const pa = (try chars.getCharacterInnerBody(a)).?;
    const pb = (try chars.getCharacterInnerBody(b)).?;
    try testing.expect(pa != pb);

    // A ray cast from A's own position along +X, EXCLUDING A: it must find B. The wall at
    // x = 2 − 0.3 = 1.7 is 3.7 m from x = −2.
    const q = query.RayQuery{
        .origin = v(-2, 0.9, 0),
        .direction = v(1, 0, 0),
        .max_distance = 100,
        .filter = .{ .exclude = &.{pa} },
    };
    const hit = (query.raycast(&world.bp, &world.bm, &world.store, q)).?;
    try testing.expectEqual(pb, hit.body);
    try testing.expectEqual(ent(2), hit.entity);
    try testing.expectApproxEqAbs(@as(Real, 3.7), hit.distance, api_tol);

    // And symmetrically from B, excluding B, back along −X.
    const back = query.RayQuery{
        .origin = v(2, 0.9, 0),
        .direction = v(-1, 0, 0),
        .max_distance = 100,
        .filter = .{ .exclude = &.{pb} },
    };
    const hit_back = (query.raycast(&world.bp, &world.bm, &world.store, back)).?;
    try testing.expectEqual(pa, hit_back.body);
    try testing.expectApproxEqAbs(@as(Real, 3.7), hit_back.distance, api_tol);
}

test "baseToCentre is the one offset, and it agrees at both precisions" {
    // Half the height along +Y, and nothing on X or Z.
    const off = character_mod.baseToCentre(Real, 1.8);
    try testing.expect(off.approxEql(v(0, 0.9, 0), api_tol));

    // The `f32` form the presence's descriptor is built from and the `Real` form every later
    // pose write uses must agree BIT for bit on the SAME height: halving is exact in binary
    // floating point and widening is exact, so `widen(h · 0.5) == widen(h) · 0.5`. If that ever
    // stopped holding, the base↔centre offset would exist at two values.
    //
    // The height is taken from ONE `f32` variable and widened, not written as the same decimal
    // literal at two precisions — `f32(1.8)` and `f64(1.8)` are DIFFERENT NUMBERS, so a literal
    // on each side would compare two different inputs and prove nothing about the offset. The
    // first form of this assertion made exactly that mistake and the `f64` leg caught it.
    const h_f32: f32 = 1.8;
    const h_real: Real = h_f32;
    const from_f32: Real = character_mod.baseToCentre(f32, h_f32).toArray()[1];
    const from_real = character_mod.baseToCentre(Real, h_real).toArray()[1];
    try testing.expectEqual(from_real, from_f32);
}

// ---------------------------------------------------------------------------
// C — ground determination. No motion: a character is PLACED, and asked.
// ---------------------------------------------------------------------------
//
// The mechanism is a bounded DOWNWARD SWEEP and not a manifold at the current pose, and the
// scene layout of every test below depends on knowing why: `collideOrdered` returns null on a
// separated pair, and a character at rest is `padding` ABOVE its floor, so a manifold-only
// probe would report `.in_air` for a character plainly standing up. Most tests here therefore
// place the capsule `padding` above its surface — the resting configuration — and one places
// it OVERLAPPING, to exercise the manifold fallback the sweep cannot answer.

/// A static half-space body, whose normal `groundOf` must return VERBATIM (§1.11.15).
fn addPlane(gpa: std.mem.Allocator, world: *harness.World, normal: ApiVec3, distance: f32, entity_index: u32) !api.BodyId {
    const shape = try world.store.createShape(gpa, .{ .plane = .{ .normal = normal, .distance = distance } });
    return world.addBody(gpa, .{
        .entity = ent(entity_index),
        .body_type = .static,
        .shape = shape,
        .position = av(0, 0, 0),
    });
}

/// The unit normal of a plane tilted `deg` away from horizontal, in the XY plane: its up
/// component is `cos(deg)`, so `deg` IS the slope angle the `max_slope` test compares against.
fn slopeNormal(deg: f32) ApiVec3 {
    const rad = deg * std.math.pi / 180.0;
    return av(@sin(rad), @cos(rad), 0);
}

test "a capsule resting on a plane is grounded, with the plane's own normal" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    var chars: CharacterStore = .{};
    defer chars.deinit(gpa);

    const floor = try addPlane(gpa, &world, av(0, 1, 0), 0, 11);

    // Base at y = padding = 0.02, the resting configuration. The capsule's lower core endpoint
    // is then at y = 0.02 + 0.3 = 0.32, so its separation from `{y <= 0}` is 0.32 − 0.3 = 0.02
    // — inside the 0.02 + 0.1 = 0.12 m sweep band, and STRICTLY POSITIVE, so the sweep path
    // answers and the manifold fallback is not taken.
    var desc = baseDescriptor();
    desc.entity = ent(50);
    desc.position = av(0, 0.02, 0);
    const id = try addCharacter(gpa, &world, &chars, desc);

    const g = try chars.groundOf(&world.bp, &world.bm, &world.store, id);
    try testing.expectEqual(api.GroundState.grounded, g.state);
    try testing.expect(g.normal.approxEql(v(0, 1, 0), tol));
    try testing.expectEqual(floor, g.body);
    try testing.expectEqual(ent(11), g.entity);
    // A static support has no velocity of its own, and the rotational term of a zero ω is zero.
    try testing.expect(g.velocity.approxEql(Vec3r.zero, tol));
}

test "a slope below max_slope is grounded and above it is steep, both with the slope's normal" {
    const gpa = testing.allocator;

    // The default `max_slope` is 0.785 rad ≈ 44.977°, so 30° is walkable and 60° is not, with
    // more than 14° of margin on either side — the verdict cannot turn on the f32 rendering of
    // the angle. Their up components are cos(30°) = √3/2 and cos(60°) = 1/2.
    const cases = [_]struct { deg: f32, distance: f32, expected: api.GroundState }{
        // For a plane of normal n and a capsule core endpoint P, the separation is
        // n·P − radius − distance. Base at y = 0 puts the lower endpoint at (0, 0.3, 0), so
        //   30°: n·P = cos30 · 0.3 = 0.2598 → distance = 0.2598 − 0.3 − 0.05 = −0.0902
        //   60°: n·P = cos60 · 0.3 = 0.15   → distance = 0.15   − 0.3 − 0.05 = −0.2
        // both leaving a separation of 0.05 m, inside the 0.12 m band and strictly positive.
        .{ .deg = 30, .distance = -0.0902, .expected = .grounded },
        .{ .deg = 60, .distance = -0.2, .expected = .on_steep_ground },
    };

    for (cases) |case| {
        var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
        defer world.deinit(gpa);
        var chars: CharacterStore = .{};
        defer chars.deinit(gpa);

        const n = slopeNormal(case.deg);
        const slope = try addPlane(gpa, &world, n, case.distance, 12);

        var desc = baseDescriptor();
        desc.position = av(0, 0, 0);
        const id = try addCharacter(gpa, &world, &chars, desc);

        const g = try chars.groundOf(&world.bp, &world.bm, &world.store, id);
        try testing.expectEqual(case.expected, g.state);
        // The normal is the SLOPE's in both verdicts — a steep slope is still a real surface,
        // and the verdict is the only thing that differs.
        try testing.expect(g.normal.approxEql(v(n.toArray()[0], n.toArray()[1], 0), api_tol));
        try testing.expectEqual(slope, g.body);
        // NON-NULL on `.on_steep_ground` as much as on `.grounded`: a steep slope is a support,
        // and only `.in_air` has no support at all (§1.12.5).
        try testing.expectEqual(ent(12), g.entity);
        try testing.expect(g.entity.index != api.EntityId.dead.index);
        try testing.expect(g.body != api.PackedId.dead);
    }
}

test "a capsule over the void is in_air on all five quantities" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    var chars: CharacterStore = .{};
    defer chars.deinit(gpa);

    // NOTHING in the scene but the character — whose own presence IS in the broadphase, and is
    // the only thing its downward sweep can find.
    //
    // **This does NOT prove self-exclusion, and an earlier version of this comment claimed it
    // did.** MEASURED: with the exclusion removed, this test and the four others that pin
    // `ground_body` to a real support all still pass. The reason is that what exclusion removes
    // is a contact between the probe and a body BIT-IDENTICAL to it at the same pose, whose
    // normal §3 declares geometrically UNDEFINED — and empirically that normal never qualifies
    // as ground. So the mechanism is required by §1.12.2 and implemented, but it is not
    // observable at this gate; it becomes observable at gate D, where the same contact would
    // block motion outright. Asserting it here would mean asserting on a value the narrowphase
    // documents as undefined.
    var desc = baseDescriptor();
    desc.position = av(0, 5, 0);
    const id = try addCharacter(gpa, &world, &chars, desc);
    try testing.expect((try chars.getCharacterInnerBody(id)) != null);

    const g = try chars.groundOf(&world.bp, &world.bm, &world.store, id);
    // All five quantities at their `.in_air` values, asserted one by one rather than by
    // comparing the struct: `normal` is EXACTLY up and never a poisoned value, three documents
    // reading it inside a `@replicated` component.
    try testing.expectEqual(api.GroundState.in_air, g.state);
    try testing.expect(g.normal.eql(Vec3r.unit_y));
    try testing.expectEqual(@as(Real, 1), g.normal.lengthSq());
    try testing.expectEqual(api.EntityId.dead, g.entity);
    try testing.expectEqual(@as(api.BodyId, api.PackedId.dead), g.body);
    try testing.expect(g.velocity.eql(Vec3r.zero));
    // The one thing that IS assertable about self-exclusion here: whatever the verdict, the
    // support is never the character's own presence. Cheap, and it would catch a future change
    // that made the coincident self-contact start qualifying.
    try testing.expect(g.body != (try chars.getCharacterInnerBody(id)).?);
}

test "straddling a walkable and a steep face stands on the FLATTER one" {
    const gpa = testing.allocator;

    // Two planes both within the sweep band. Base at y = 0.02:
    //   floor  n = (0, 1, 0),  distance 0    → separation 0.32 − 0.3 = 0.02
    //   steep  n = (sin60, cos60, 0)         → n·P = 0.5 · 0.32 = 0.16,
    //                                          distance = 0.16 − 0.3 − 0.05 = −0.19
    // The floor's up component is 1 and the steep one's is 0.5, so the FLATTER must win even
    // though both qualify as contacts and the steep one is nearer in sweep distance.
    const steep = slopeNormal(60);

    {
        var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
        defer world.deinit(gpa);
        var chars: CharacterStore = .{};
        defer chars.deinit(gpa);

        const floor = try addPlane(gpa, &world, av(0, 1, 0), 0, 20);
        _ = try addPlane(gpa, &world, steep, -0.19, 21);

        var desc = baseDescriptor();
        desc.position = av(0, 0.02, 0);
        const id = try addCharacter(gpa, &world, &chars, desc);

        const g = try chars.groundOf(&world.bp, &world.bm, &world.store, id);
        try testing.expectEqual(api.GroundState.grounded, g.state);
        try testing.expect(g.normal.approxEql(v(0, 1, 0), tol));
        try testing.expectEqual(floor, g.body);
        try testing.expectEqual(ent(20), g.entity);
    }

    // THE DISCRIMINATOR. Remove the floor and keep the steep plane at the same distance: the
    // verdict must change to `.on_steep_ground` on the steep normal. Without this the test
    // above would pass just as well if the steep plane were out of range and never a candidate
    // at all — it would assert "the floor wins" against no competition.
    {
        var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
        defer world.deinit(gpa);
        var chars: CharacterStore = .{};
        defer chars.deinit(gpa);

        const only_steep = try addPlane(gpa, &world, steep, -0.19, 21);

        var desc = baseDescriptor();
        desc.position = av(0, 0.02, 0);
        const id = try addCharacter(gpa, &world, &chars, desc);

        const g = try chars.groundOf(&world.bp, &world.bm, &world.store, id);
        try testing.expectEqual(api.GroundState.on_steep_ground, g.state);
        try testing.expect(g.normal.approxEql(v(steep.toArray()[0], steep.toArray()[1], 0), api_tol));
        try testing.expectEqual(only_steep, g.body);
    }
}

test "at distance zero the manifold fallback answers, and NOT with up" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    var chars: CharacterStore = .{};
    defer chars.deinit(gpa);

    // A 30° slope the capsule OVERLAPS rather than rests above. Base at y = 0 puts the lower
    // core endpoint at (0, 0.3, 0), so n·P = cos30 · 0.3 = 0.2598 and a distance of
    // 0.2598 − 0.3 + 0.02 = −0.0202 leaves a separation of −0.02 m: the capsule is 2 cm inside
    // the solid, so the downward cast reports distance ZERO and its own normal is `−direction`,
    // i.e. exactly `+up`.
    const n = slopeNormal(30);
    _ = try addPlane(gpa, &world, n, -0.0202, 30);

    var desc = baseDescriptor();
    desc.position = av(0, 0, 0);
    const id = try addCharacter(gpa, &world, &chars, desc);

    const g = try chars.groundOf(&world.bp, &world.bm, &world.store, id);

    // THE POINT OF THIS TEST is the second assertion. The first would pass on either path.
    const expected = v(n.toArray()[0], n.toArray()[1], 0);
    try testing.expect(g.normal.approxEql(expected, api_tol));
    // `+up` is what the SWEEP would have returned at distance zero, and it is a lie on a
    // slope — it would answer "perfectly horizontal" and make every slope test pass. cos 30°
    // differs from 1 by 0.134 and the x component from 0 by 0.5, so the two answers are not
    // near each other: this asserts the fallback was taken, not merely that a normal came back.
    try testing.expect(!g.normal.approxEql(v(0, 1, 0), 0.1));
    try testing.expectApproxEqAbs(@as(Real, 0.5), g.normal.toArray()[0], api_tol);
    // 30° is walkable, so the verdict rides on the real normal and not on the sweep's.
    try testing.expectEqual(api.GroundState.grounded, g.state);
}

test "ground_velocity is the velocity AT THE CONTACT POINT of a rotating platform" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    var chars: CharacterStore = .{};
    defer chars.deinit(gpa);

    // A kinematic slab 4 m across and 1 m thick centred on the origin, so its top face is at
    // y = 0.5. Kinematic because a controller's support is exactly the moving-platform case,
    // and because a dynamic body would need the solver to hold it up.
    const slab = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av(2, 0.5, 2) } });
    const platform = try world.addBody(gpa, .{
        .entity = ent(60),
        .body_type = .kinematic,
        .shape = slab,
        .position = av(0, 0, 0),
    });

    // Spin about +Y at 2 rad/s. This is the entry that makes the field testable at all: without
    // it ω has no authorable source and the rotational term would be permanently zero.
    world.bm.setAngularVelocity(platform, v(0, 2, 0));

    // The character stands on the rim at x = 1.5, `padding` above the top face.
    var desc = baseDescriptor();
    desc.position = av(1.5, 0.52, 0);
    const id = try addCharacter(gpa, &world, &chars, desc);

    const g = try chars.groundOf(&world.bp, &world.bm, &world.store, id);
    try testing.expectEqual(api.GroundState.grounded, g.state);
    try testing.expectEqual(platform, g.body);

    // CLOSED FORM. The contact point is the witness on the body, i.e. (1.5, 0.5, 0) on the top
    // face; the centre of mass is the body's pose, the origin; so r = (1.5, 0.5, 0) and
    //   ω × r = (0,2,0) × (1.5,0.5,0)
    //         = (2·0 − 0·0.5,  0·1.5 − 0·0,  0·0.5 − 2·1.5)
    //         = (0, 0, −3)
    // with the platform's linear velocity zero. The tolerance is `api_tol` scaled by two,
    // because an error δ in the contact point's x becomes 2δ in the z component.
    try testing.expect(g.velocity.approxEql(v(0, 0, -3), 2 * api_tol));

    // NON-VACUITY of the rotational term: without it the answer would be the platform's linear
    // velocity, which is zero here. The measured value is 3 m/s, so the term is not a rounding
    // residue that a loose tolerance could hide.
    try testing.expect(g.velocity.length() > 2.9);
}

test "an exact tie is broken by the smaller BodyId under BOTH traversal orders" {
    const gpa = testing.allocator;

    // TWO IDENTICAL floors as two separate bodies, so both offer an up component of EXACTLY 1
    // — a plane returns its stored normal verbatim, so the tie is exact and not near-exact.
    //
    // **BOTH traversal orders are exercised, and only one of them discriminates.** The
    // unbounded list iterates by slot index, so the insertion order IS the traversal order.
    // Without the tie-break the code keeps the LAST candidate offered, so:
    //   forward  [first, second] → no tie-break would answer `second`; the rule answers `first`
    //   reversed [second, first] → no tie-break would answer `first` too, same as the rule
    // The forward case is therefore the one that pins the rule, and the reversed one shows the
    // answer does not depend on the order. A first version of this test ran ONLY the reversed
    // order and pinned nothing — measured: removing the tie-break broke no test at all.
    for ([_]bool{ false, true }) |reversed| {
        var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
        defer world.deinit(gpa);
        var chars: CharacterStore = .{};
        defer chars.deinit(gpa);

        const shape_a = try world.store.createShape(gpa, .{ .plane = .{ .normal = av(0, 1, 0), .distance = 0 } });
        const shape_b = try world.store.createShape(gpa, .{ .plane = .{ .normal = av(0, 1, 0), .distance = 0 } });
        const first = try world.bm.addBody(gpa, &world.store, .{
            .entity = ent(70),
            .body_type = .static,
            .shape = shape_a,
            .position = av(0, 0, 0),
        });
        const second = try world.bm.addBody(gpa, &world.store, .{
            .entity = ent(71),
            .body_type = .static,
            .shape = shape_b,
            .position = av(0, 0, 0),
        });
        // A slot index encodes creation order, so this is the premise the tie-break rests on.
        try testing.expect(first < second);

        const order = if (reversed) [_]api.BodyId{ second, first } else [_]api.BodyId{ first, second };
        for (order) |body| {
            const shape = world.store.get(world.bm.shapeOf(body).?).?;
            const plane_world = shape_mod.halfSpace(shape).transformed(
                world.bm.rotation(body).?,
                world.bm.position(body).?,
            );
            _ = try world.bp.insertUnbounded(gpa, .static, .{
                .normal = plane_world.normal,
                .distance = plane_world.distance,
            }, body);
        }

        var desc = baseDescriptor();
        desc.position = av(0, 0.02, 0);
        const id = try addCharacter(gpa, &world, &chars, desc);

        const g = try chars.groundOf(&world.bp, &world.bm, &world.store, id);
        try testing.expectEqual(api.GroundState.grounded, g.state);
        // The SMALLER `BodyId` wins in BOTH orders.
        try testing.expectEqual(first, g.body);
        try testing.expectEqual(ent(70), g.entity);
    }
}

test "groundOf reports a stale handle as a typed error" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    var chars: CharacterStore = .{};
    defer chars.deinit(gpa);

    _ = try addPlane(gpa, &world, av(0, 1, 0), 0, 80);
    const id = try addCharacter(gpa, &world, &chars, baseDescriptor());
    // Live first, so the error below is about the handle and not about the scene.
    _ = try chars.groundOf(&world.bp, &world.bm, &world.store, id);

    chars.destroyCharacter(gpa, &world.store, &world.bm, id);
    try testing.expectError(
        error.StaleCharacter,
        chars.groundOf(&world.bp, &world.bm, &world.store, id),
    );
}

test "the sweep band is padding plus predictive_contact_distance" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    var chars: CharacterStore = .{};
    defer chars.deinit(gpa);

    // The band is a closed form of two descriptor fields, and this is the assertion that names
    // `predictive_contact_distance`'s first consumer: 0.02 + 0.1 = 0.12 at the defaults.
    const id = try addCharacter(gpa, &world, &chars, baseDescriptor());
    const c = chars.get(id).?;
    try testing.expectApproxEqAbs(@as(Real, 0.12), character_mod.groundSweepDistance(c), api_tol);

    // And it BITES in both directions on a real scene. A floor 0.10 m below the capsule's lower
    // core endpoint is inside the band and answers; the same floor 0.20 m below is outside it
    // and the character is `.in_air`. Base at y = b puts that endpoint at y = b + 0.3, so a
    // plane `{y <= 0}` sits `b + 0.3 − 0.3 = b` below it: b IS the separation.
    for ([_]struct { base: f32, expected: api.GroundState }{
        .{ .base = 0.10, .expected = .grounded },
        .{ .base = 0.20, .expected = .in_air },
    }) |case| {
        var scene = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
        defer scene.deinit(gpa);
        var store: CharacterStore = .{};
        defer store.deinit(gpa);

        _ = try addPlane(gpa, &scene, av(0, 1, 0), 0, 90);
        var desc = baseDescriptor();
        desc.position = av(0, case.base, 0);
        const who = try addCharacter(gpa, &scene, &store, desc);

        const g = try store.groundOf(&scene.bp, &scene.bm, &scene.store, who);
        try testing.expectEqual(case.expected, g.state);
    }
}

// ---------------------------------------------------------------------------
// D — the move. No step height.
// ---------------------------------------------------------------------------

/// A character plus its presence's broadphase proxy REGISTERED with the store, so pose writes
/// keep the tree fresh. `addCharacter` above deliberately does not register it — the gate-B
/// tests had no pose write to keep fresh — and the difference is what the freshness test rides on.
fn addMover(
    gpa: std.mem.Allocator,
    world: *harness.World,
    chars: *CharacterStore,
    desc: api.CharacterDescriptor,
) !api.CharacterId {
    const id = try chars.createCharacter(gpa, &world.store, &world.bm, desc);
    if (try chars.getCharacterInnerBody(id)) |presence| {
        const proxy = try world.bp.insert(
            gpa,
            .dynamic,
            world.bm.bodyAabb(&world.store, presence).?,
            presence,
        );
        chars.setPresenceProxy(id, proxy);
    }
    return id;
}

/// A static box body of the given half-extents at the given centre.
fn addBox(gpa: std.mem.Allocator, world: *harness.World, half: ApiVec3, centre: ApiVec3, entity_index: u32) !api.BodyId {
    const shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = half } });
    return world.addBody(gpa, .{
        .entity = ent(entity_index),
        .body_type = .static,
        .shape = shape,
        .position = centre,
    });
}

test "an unobstructed move serves the whole displacement" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    var chars: CharacterStore = .{};
    defer chars.deinit(gpa);

    var desc = baseDescriptor();
    desc.position = av(0, 5, 0);
    const id = try addMover(gpa, &world, &chars, desc);

    // Nothing in the scene: the base moves by exactly the displacement asked for, and the verdict
    // at the new pose is `.in_air`.
    const r = try chars.moveCharacter(gpa, &world.bp, &world.bm, &world.store, id, v(2, 0, -3), 1.0 / 60.0);
    try testing.expect(r.position.approxEql(v(2, 5, -3), tol));
    try testing.expectEqual(api.GroundState.in_air, r.ground.state);
    // The record is authoritative and now agrees with the result.
    try testing.expect(chars.get(id).?.position.approxEql(v(2, 5, -3), tol));
}

test "a move into a wall keeps the tangential component and cancels the normal one" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    var chars: CharacterStore = .{};
    defer chars.deinit(gpa);

    // A wall occupying x >= 2: half-extents (1, 5, 5) centred at x = 3, so its −X face is at x = 2.
    _ = try addBox(gpa, &world, av(1, 5, 5), av(3, 0, 0), 100);

    var desc = baseDescriptor();
    desc.position = av(0, 0, 0);
    const id = try addMover(gpa, &world, &chars, desc);

    // Asked for (3, 0, 1) — into the wall, plus a metre along +Z the wall does not oppose.
    const r = try chars.moveCharacter(gpa, &world.bp, &world.bm, &world.store, id, v(3, 0, 1), 1.0 / 60.0);

    // **THE MOTION IS OBLIQUE, AND THAT CHANGES THE CLOSED FORM.** The capsule's radius is 0.3, so
    // its surface reaches the wall when the centre is at x = 1.7; but the character travels along
    // `d = (3,0,1)/√10`, and the sweep stops `padding` short ALONG d — so the shortfall projected
    // onto x is `padding · dₓ` and not `padding`:
    //
    //   x = 1.7 − padding · 3/√10 = 1.7 − 0.02 · 0.9486833 = 1.6810263
    //
    // A first version of this test wrote 1.68, which is the axis-aligned answer, and an oblique
    // sweep is precisely the case §1.11.4 bis makes mandatory.
    const root10: Real = @sqrt(@as(Real, 10));
    try testing.expectApproxEqAbs(1.7 - 0.02 * (3.0 / root10), r.position.toArray()[0], api_tol);

    // The TANGENTIAL component is SERVED IN FULL, and asserting it is what separates "slid along
    // the wall" from "stopped dead" — cancelling both would pass the assertion above and be wrong.
    //
    // Exactly 1, and the padding cancels out of it algebraically: the z travelled before the
    // contact is `dz·(t_hit − padding)` and what remains after the slide is `dz·(|D| − t_hit +
    // padding)`, whose sum is `dz·|D| = 1`.
    try testing.expectApproxEqAbs(@as(Real, 1), r.position.toArray()[2], api_tol);
    try testing.expectApproxEqAbs(@as(Real, 0), r.position.toArray()[1], api_tol);
}

test "a move into a crease slides along the edge, and exactly parallel normals are a THIRD answer" {
    const gpa = testing.allocator;

    // Two walls meeting at a vertical edge: one at x >= 2 (outward normal −X) and one at z >= 2
    // (outward normal −Z). Their crease is `(−1,0,0) × (0,0,−1)` — parallel to ±Y — so a character
    // driven diagonally into the corner slides VERTICALLY along the edge and nowhere else.
    {
        var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
        defer world.deinit(gpa);
        var chars: CharacterStore = .{};
        defer chars.deinit(gpa);

        _ = try addBox(gpa, &world, av(1, 5, 5), av(3, 0, 0), 110);
        _ = try addBox(gpa, &world, av(5, 5, 1), av(0, 0, 3), 111);

        var desc = baseDescriptor();
        desc.position = av(0, 0, 0);
        const id = try addMover(gpa, &world, &chars, desc);

        // Driven into both walls AND upward. The two horizontal components are cancelled by the
        // two planes and the +Y component survives along the crease.
        const r = try chars.moveCharacter(gpa, &world.bp, &world.bm, &world.store, id, v(3, 1, 3), 1.0 / 60.0);

        // Same oblique correction as the wall test, now along `d = (3,1,3)/√19`: both horizontal
        // components stop at `1.7 − padding · 3/√19 = 1.7 − 0.02 · 0.6882472 = 1.6862350`. The two
        // walls are hit at the SAME sweep distance — `dₓ == d_z` — so the tie-break picks the
        // smaller `BodyId` for the first plane and the second is met on the next iteration, where
        // its own hit already sits inside the padding margin and the advance clamps to zero.
        const root19: Real = @sqrt(@as(Real, 19));
        const stop = 1.7 - 0.02 * (3.0 / root19);
        try testing.expectApproxEqAbs(stop, r.position.toArray()[0], api_tol);
        try testing.expectApproxEqAbs(stop, r.position.toArray()[2], api_tol);

        // And the vertical component is served IN FULL along the crease — exactly 1, by the same
        // cancellation the wall test's tangential component enjoys. If the second plane had stopped
        // the motion instead of yielding an edge, this would be the 0.562 reached before the second
        // contact, so the assertion discriminates between "slid along the edge" and "stopped in the
        // corner" rather than merely being non-zero.
        try testing.expectApproxEqAbs(@as(Real, 1), r.position.toArray()[1], api_tol);
    }

    // THE THIRD ANSWER, asserted separately from "no edge". Two exactly parallel normals have NO
    // crease, and `triangleCrossDirection` says so with an exact `null` rather than a rounding
    // residue that reads as a valid direction. The primitive is asserted directly, because the
    // move's own path replaces a parallel re-contact instead of treating it as a second plane —
    // so the two situations must be distinguishable at the primitive, and they are.
    {
        const n = v(0, 1, 0);
        // Exactly parallel: no edge exists.
        try testing.expectEqual(
            @as(?Vec3r, null),
            foundation.math.triangleCrossDirection(Real, Vec3r.zero, n, n),
        );
        // Exactly ANTI-parallel: also no edge, and also an exact null rather than a small vector.
        try testing.expectEqual(
            @as(?Vec3r, null),
            foundation.math.triangleCrossDirection(Real, Vec3r.zero, n, n.neg()),
        );
        // A genuine pair of distinct normals DOES yield an edge, so the null above is a real
        // discrimination and not a function that always returns null.
        const edge = foundation.math.triangleCrossDirection(Real, Vec3r.zero, v(-1, 0, 0), v(0, 0, -1));
        try testing.expect(edge != null);
        // Parallel to ±Y: the x and z components are exactly zero.
        try testing.expectEqual(@as(Real, 0), edge.?.toArray()[0]);
        try testing.expectEqual(@as(Real, 0), edge.?.toArray()[2]);
        try testing.expect(edge.?.toArray()[1] != 0);
    }
}

test "a move that starts interpenetrated is depenetrated by the MANIFOLD, not by the sweep" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    var chars: CharacterStore = .{};
    defer chars.deinit(gpa);

    // A 30° slope as a half-space, positioned so the capsule starts 2 cm INSIDE the solid — the
    // same construction as the gate-C fallback test, and for the same reason.
    const n = slopeNormal(30);
    _ = try addPlane(gpa, &world, n, -0.0202, 120);

    var desc = baseDescriptor();
    desc.position = av(0, 0, 0);
    const id = try addMover(gpa, &world, &chars, desc);

    // Asked for nothing at all, so the ONLY thing that can move the character is depenetration.
    const r = try chars.moveCharacter(gpa, &world.bp, &world.bm, &world.store, id, Vec3r.zero, 1.0 / 60.0);

    // **THE TWO ANSWERS DIFFER MEASURABLY, which is what makes this test discriminate.** The
    // manifold pushes along the SLOPE's normal (0.5, 0.866, 0), so the correction has a non-zero X
    // component; the sweep's `−direction` at distance zero would have pushed along `+up`, i.e.
    // purely in Y. The push is 2 cm along the slope normal, so
    //   Δx = 0.02 · 0.5   = 0.01
    //   Δy = 0.02 · 0.866 = 0.01732
    try testing.expectApproxEqAbs(@as(Real, 0.01), r.position.toArray()[0], api_tol);
    try testing.expectApproxEqAbs(@as(Real, 0.017320508), r.position.toArray()[1], api_tol);
    // The X component is the discriminator: a sweep-driven push would leave it at exactly zero.
    try testing.expect(@abs(r.position.toArray()[0]) > 0.005);
    // And the character is no longer inside: the verdict is a real one on the slope.
    try testing.expectEqual(api.GroundState.grounded, r.ground.state);
}

test "self-exclusion is what lets a character move at all" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    var chars: CharacterStore = .{};
    defer chars.deinit(gpa);

    // Nothing in the scene but the character and its own presence, which sits exactly where the
    // probe does. Without self-exclusion the very first sweep hits it at distance zero, the
    // advance is `max(0, 0 − padding) = 0`, and the character cannot move a millimetre. At gate C
    // the mechanism was NOT observable — measured — and here it is, which is why the assertion
    // lives at this gate.
    var desc = baseDescriptor();
    desc.position = av(0, 5, 0);
    const id = try addMover(gpa, &world, &chars, desc);

    const r = try chars.moveCharacter(gpa, &world.bp, &world.bm, &world.store, id, v(1, 0, 0), 1.0 / 60.0);
    try testing.expectApproxEqAbs(@as(Real, 1), r.position.toArray()[0], api_tol);
}

test "after a move a ray finds the entity at the NEW pose and never at the old one" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    var chars: CharacterStore = .{};
    defer chars.deinit(gpa);

    var desc = baseDescriptor();
    desc.entity = ent(130);
    desc.position = av(0, 0, 0);
    const id = try addMover(gpa, &world, &chars, desc);
    const presence = (try chars.getCharacterInnerBody(id)).?;

    // Before: the capsule's cylinder wall is at x = ±0.3 about the Y axis, so a ray from
    // (−10, 0.9, 0) along +X hits at 10 − 0.3 = 9.7.
    const before = query.RayQuery{ .origin = v(-10, 0.9, 0), .direction = v(1, 0, 0), .max_distance = 100 };
    try testing.expectApproxEqAbs(
        @as(Real, 9.7),
        (query.raycast(&world.bp, &world.bm, &world.store, before)).?.distance,
        api_tol,
    );

    _ = try chars.moveCharacter(gpa, &world.bp, &world.bm, &world.store, id, v(5, 0, 0), 1.0 / 60.0);

    // After: the capsule is at x = 5, so the same ray hits at 15 − 0.3 = 14.7. Both halves matter —
    // the NEW distance, and the fact that nothing answers at the OLD one any more, which is what
    // catches a stale broadphase proxy. A body-only update would leave the tree at the old box and
    // the ray would still find something near 9.7.
    const hit = (query.raycast(&world.bp, &world.bm, &world.store, before)).?;
    try testing.expectEqual(presence, hit.body);
    try testing.expectEqual(ent(130), hit.entity);
    try testing.expectApproxEqAbs(@as(Real, 14.7), hit.distance, api_tol);

    // And a ray aimed at where the character USED to be finds nothing: bounded just short of the
    // new position so a hit there cannot be the new pose answering.
    const at_old = query.RayQuery{ .origin = v(-10, 0.9, 0), .direction = v(1, 0, 0), .max_distance = 12 };
    try testing.expectEqual(
        @as(?query.RayHit, null),
        query.raycast(&world.bp, &world.bm, &world.store, at_old),
    );

    // **THE ASSERTION THAT ACTUALLY CATCHES A STALE BROADPHASE PROXY, and none of the three above
    // does.** MEASURED: with the proxy update removed, every assertion so far still passes. The
    // reason is structural — the broadphase box is only a CONSERVATIVE FILTER, and the exact answer
    // comes from the body's pose, which the same write path updates. A stale fat box that the ray
    // still crosses therefore yields the correct distance anyway.
    //
    // What a stale proxy loses is a candidate the tree no longer offers at all. So the ray has to
    // approach the NEW position from a direction the OLD box does not intersect: from −Z at x = 5,
    // where the stale box sits around x = 0 with a 0.1 m fat margin and is nowhere near. Without
    // the update the presence is never offered and this MISSES.
    const across = query.RayQuery{ .origin = v(5, 0.9, -10), .direction = v(0, 0, 1), .max_distance = 100 };
    const side = query.raycast(&world.bp, &world.bm, &world.store, across);
    // Checked before unwrapping so a stale proxy reads as a failed expectation rather than as a
    // panic on a null optional — the failure mode is "the tree no longer offers the candidate",
    // which deserves to say so.
    try testing.expect(side != null);
    const side_hit = side.?;
    try testing.expectEqual(presence, side_hit.body);
    try testing.expectApproxEqAbs(@as(Real, 9.7), side_hit.distance, api_tol);
}

test "moveCharacter wakes a sleeping body it touches" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    var chars: CharacterStore = .{};
    defer chars.deinit(gpa);

    // A dynamic box the character will walk into, put to sleep DIRECTLY rather than by running
    // thirty ticks: the tick count is not what this test is about, and `sleep.putToSleep` is the
    // same transition step 11 of the cycle applies.
    const box_shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av(0.5, 0.5, 0.5) } });
    const sleeper = try world.addBody(gpa, .{
        .entity = ent(140),
        .body_type = .dynamic,
        .shape = box_shape,
        .position = av(2, 0, 0),
    });
    sleep_mod.putToSleep(&world.bm, sleeper);
    try testing.expectEqual(true, world.bm.isSleeping(sleeper).?);

    var desc = baseDescriptor();
    desc.position = av(0, 0, 0);
    const id = try addMover(gpa, &world, &chars, desc);

    // Walk into it. The box's −X face is at x = 1.5, the capsule's radius is 0.3, so contact is
    // made and the sweep reports it.
    _ = try chars.moveCharacter(gpa, &world.bp, &world.bm, &world.store, id, v(3, 0, 0), 1.0 / 60.0);

    // WAKE CAUSE W4, and not W3: a presence moved by pose write keeps velocity columns of exactly
    // zero while it crosses the scene, so W3's true-zero velocity test never sees it move
    // (§1.12.10). What this entry owes is the bodies it TOUCHED; the wider W4 — waking sleepers
    // merely RETAINED in a pair with the presence — belongs to the orchestrator that owns the
    // retained set, at M1.1.15.
    try testing.expectEqual(false, world.bm.isSleeping(sleeper).?);
}

test "the move consumes no predictive_contact_distance, and the ceilings stop short" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    var chars: CharacterStore = .{};
    defer chars.deinit(gpa);

    // The sweep's distance is the REMAINING DISPLACEMENT and nothing else, so two characters
    // differing only in `predictive_contact_distance` reach the same place against the same wall.
    // That is the answer to gate D's question about the field: the ground probe is still its only
    // consumer, and the move does not read it.
    _ = try addBox(gpa, &world, av(1, 5, 5), av(3, 0, 0), 150);

    var lean = baseDescriptor();
    lean.entity = ent(151);
    lean.position = av(0, 0, 0);
    lean.predictive_contact_distance = 0;
    const a = try addMover(gpa, &world, &chars, lean);

    var generous = baseDescriptor();
    generous.entity = ent(152);
    generous.position = av(0, 0, 3);
    generous.predictive_contact_distance = 0.5;
    const b = try addMover(gpa, &world, &chars, generous);

    const ra = try chars.moveCharacter(gpa, &world.bp, &world.bm, &world.store, a, v(3, 0, 0), 1.0 / 60.0);
    const rb = try chars.moveCharacter(gpa, &world.bp, &world.bm, &world.store, b, v(3, 0, 0), 1.0 / 60.0);
    // Both stop at 2 − 0.3 − 0.02 = 1.68, the wall face minus the radius minus the padding.
    try testing.expectApproxEqAbs(@as(Real, 1.68), ra.position.toArray()[0], api_tol);
    try testing.expectApproxEqAbs(ra.position.toArray()[0], rb.position.toArray()[0], api_tol);

    // The two ceilings are NAMED and their failure direction is SHORT: a character never ends up
    // further along than it asked for. Pinned as an inequality on the served distance, which holds
    // whatever the scene does to the loop.
    try testing.expect(ra.position.toArray()[0] <= 3);
    try testing.expectEqual(@as(u32, 4), character_mod.max_slide_iterations);
    try testing.expectEqual(@as(u32, 4), character_mod.max_depenetration_iterations);
}

test "moveCharacter reports a stale handle as a typed error" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    var chars: CharacterStore = .{};
    defer chars.deinit(gpa);

    const id = try addMover(gpa, &world, &chars, baseDescriptor());
    _ = try chars.moveCharacter(gpa, &world.bp, &world.bm, &world.store, id, Vec3r.zero, 1.0 / 60.0);
    chars.destroyCharacter(gpa, &world.store, &world.bm, id);
    try testing.expectError(
        error.StaleCharacter,
        chars.moveCharacter(gpa, &world.bp, &world.bm, &world.store, id, v(1, 0, 0), 1.0 / 60.0),
    );
}

// ---------------------------------------------------------------------------
// E — step height: climbing and descending.
// ---------------------------------------------------------------------------

/// A ground plane plus a step of height `h` whose front face is at x = 1, spanning x ∈ [1, 3].
/// Returns the character, placed at x = 0 and `padding` above the ground so it enters `.grounded`.
fn stepScene(
    gpa: std.mem.Allocator,
    world: *harness.World,
    chars: *CharacterStore,
    h: f32,
    step_height: f32,
) !api.CharacterId {
    _ = try addPlane(gpa, world, av(0, 1, 0), 0, 200);
    _ = try addBox(gpa, world, av(1, h / 2, 1), av(2, h / 2, 0), 201);
    var desc = baseDescriptor();
    desc.entity = ent(202);
    desc.position = av(0, 0.02, 0);
    desc.step_height = step_height;
    return addMover(gpa, world, chars, desc);
}

test "a step below step_height is climbed and a step above it blocks — both directions" {
    const gpa = testing.allocator;

    // CLIMBED: a 0.25 m step against the default 0.3 m `step_height`.
    {
        var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
        defer world.deinit(gpa);
        var chars: CharacterStore = .{};
        defer chars.deinit(gpa);
        const id = try stepScene(gpa, &world, &chars, 0.25, 0.3);

        const r = try chars.moveCharacter(gpa, &world.bp, &world.bm, &world.store, id, v(1.5, 0, 0), 1.0 / 60.0);

        // The character ends RESTING on the step top: `padding` above y = 0.25, so base = 0.27.
        // The lift is exactly `step_height` — the padding cancels between the two resting
        // configurations — so the base rises to 0.32, the down-sweep finds the top 0.07 below and
        // stops `padding` short of it, landing at 0.32 − 0.05 = 0.27.
        try testing.expectApproxEqAbs(@as(Real, 0.27), r.position.toArray()[1], api_tol);
        // And it is PAST the riser at x = 1, which a blocked character never is.
        try testing.expect(r.position.toArray()[0] > 1);
        // Standing on the step, not falling off it.
        try testing.expectEqual(api.GroundState.grounded, r.ground.state);
    }

    // BLOCKED: a 0.35 m step against the same 0.3 m `step_height`. Both directions asserted, and
    // this half is the one that would pass vacuously if the climb simply never fired.
    {
        var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
        defer world.deinit(gpa);
        var chars: CharacterStore = .{};
        defer chars.deinit(gpa);
        const id = try stepScene(gpa, &world, &chars, 0.35, 0.3);

        const r = try chars.moveCharacter(gpa, &world.bp, &world.bm, &world.store, id, v(1.5, 0, 0), 1.0 / 60.0);

        // The height is UNCHANGED: no lift survives a failed attempt.
        try testing.expectApproxEqAbs(@as(Real, 0.02), r.position.toArray()[1], api_tol);
        // And the normal component is cancelled — it stops short of the riser at x = 1. The capsule
        // is widest 0.3 m from its axis, so the slide stops at 1 − 0.3 − padding = 0.68.
        try testing.expectApproxEqAbs(@as(Real, 0.68), r.position.toArray()[0], api_tol);
        try testing.expect(r.position.toArray()[0] < 1);
    }
}

test "a step is NOT a slope: a climb onto something too steep to stand on is refused" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    var chars: CharacterStore = .{};
    defer chars.deinit(gpa);

    // A ramp at 70° from horizontal, well past the default 45° limit, whose surface passes through
    // the region the character would step onto. If the landing surface were not slope-tested, the
    // character would climb it in `step_height` increments — each increment individually legitimate
    // — and the slope limit the engine holds would be unenforceable. That is the case, not a remark.
    const n = slopeNormal(70);
    _ = try addPlane(gpa, &world, av(0, 1, 0), 0, 210);
    // Positioned so the ramp's surface sits just ahead of the character: with the lower core
    // endpoint at (0, 0.32, 0), `n·P = cos70 · 0.32 = 0.10944`, and a distance of
    // 0.10944 − 0.3 − 0.4 = −0.59056 leaves it 0.4 m ahead along the normal.
    _ = try addPlane(gpa, &world, n, -0.59056, 211);

    var desc = baseDescriptor();
    desc.position = av(0, 0.02, 0);
    const id = try addMover(gpa, &world, &chars, desc);

    const r = try chars.moveCharacter(gpa, &world.bp, &world.bm, &world.store, id, v(1.5, 0, 0), 1.0 / 60.0);

    // It never ends up standing on the ramp: the verdict is not `.grounded` on a 70° face, and the
    // height has not been ratcheted upward by a climb that should not have been accepted.
    try testing.expect(r.position.toArray()[1] < 0.1);
    if (r.ground.state == .grounded) {
        // If it is grounded at all it is on the FLOOR, whose normal is +Y — never on the ramp.
        try testing.expect(r.ground.normal.approxEql(v(0, 1, 0), api_tol));
    }
}

test "descent sticks to the floor only when the character ENTERED grounded" {
    const gpa = testing.allocator;

    // TWO SCENES and not one parameterised pair, because the two halves need different geometry and
    // a first version shared one — measured, and the shared form could not fail. Both halves ask
    // "does the floor-sticking fire", so BOTH must put a floor inside the 0.3 m sweep's reach; the
    // shared version left the airborne character 0.4 m above the lower floor, out of reach, where
    // nothing could be stuck whatever the condition said.

    // (a) ENTERED GROUNDED — walking off a ledge onto a floor 0.2 m below, inside `step_height`.
    {
        var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
        defer world.deinit(gpa);
        var chars: CharacterStore = .{};
        defer chars.deinit(gpa);

        // Upper floor top at y = 0 spanning x ∈ [−2, 0]; lower floor top at y = −0.2 beyond it.
        _ = try addBox(gpa, &world, av(1, 0.5, 1), av(-1, -0.5, 0), 220);
        _ = try addBox(gpa, &world, av(2, 0.5, 1), av(2, -0.7, 0), 221);

        var desc = baseDescriptor();
        desc.position = av(-0.5, 0.02, 0);
        const id = try addMover(gpa, &world, &chars, desc);

        const r = try chars.moveCharacter(gpa, &world.bp, &world.bm, &world.store, id, v(1.5, 0, 0), 1.0 / 60.0);
        // Landed on the lower floor, `padding` above it: −0.2 + 0.02 = −0.18.
        try testing.expectApproxEqAbs(@as(Real, -0.18), r.position.toArray()[1], api_tol);
        try testing.expectEqual(api.GroundState.grounded, r.ground.state);
    }

    // (b) ENTERED IN THE AIR, with the floor WELL INSIDE reach so the entry condition is the only
    // thing that can decide. One flat floor, and the character starts 0.2 m above it: the ground
    // band is `padding + predictive_contact_distance = 0.12`, so 0.2 reads `.in_air`, while
    // 0.2 < `step_height` = 0.3 puts that same floor inside the step-down sweep.
    {
        var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
        defer world.deinit(gpa);
        var chars: CharacterStore = .{};
        defer chars.deinit(gpa);

        _ = try addPlane(gpa, &world, av(0, 1, 0), 0, 222);

        var desc = baseDescriptor();
        desc.position = av(0, 0.2, 0);
        const id = try addMover(gpa, &world, &chars, desc);
        // Verified in the fixture rather than assumed: the premise of this half is that the entry
        // state really is `.in_air`.
        try testing.expectEqual(api.GroundState.in_air, (try chars.groundOf(&world.bp, &world.bm, &world.store, id)).state);

        const r = try chars.moveCharacter(gpa, &world.bp, &world.bm, &world.store, id, v(1.5, 0, 0), 1.0 / 60.0);
        // Height UNCHANGED: a falling character is not pulled down, even with the floor in reach.
        // Without the entry condition it would be stuck to 0.02 — which is what makes this the
        // discriminating half.
        try testing.expectApproxEqAbs(@as(Real, 0.2), r.position.toArray()[1], api_tol);
        try testing.expectEqual(api.GroundState.in_air, r.ground.state);
    }
}

test "an intermediate wall buys no horizontal progress — the reference's v5.6.0 bug class" {
    const gpa = testing.allocator;

    // The case the reference names: a wall LOW ENOUGH to arm stair walking and HIGH ENOUGH that the
    // climb cannot complete. Quoted from `jrouwe/JoltPhysics` release notes v5.6.0, Bug Fixes,
    // verified on the source: "Fixed `CharacterVirtual` speeding up beyond requested speed when
    // sliding along a wall that was low enough to trigger stair walking yet high enough to not step
    // up completely."
    //
    // THE DIFFERENTIAL IS THE ASSERTION. The same scene is run twice, differing only in
    // `step_height`: at 0 no climb is possible at all, at 0.3 the attempt fires and fails. If the
    // failed attempt bought any horizontal progress, the two would end at different x — which is
    // exactly the speed-up the reference fixed. A bound on "no further than requested" would NOT
    // catch it: 0.849 against a request of 1.5 violates no such bound.
    const requested = v(1.5, 0, 0);

    // TWO intermediate heights, because the two halves of the acceptance condition reject two
    // DIFFERENT failures and one height exercises only one of them — measured, after a first version
    // of this test used 0.35 alone and left the second half unexercised:
    //
    //   0.35 m — the lifted capsule ends WEDGED against the obstacle's top edge, `drop` clamping to
    //            zero. Rejected by the `drop > 0` half.
    //   0.45 m — the lifted capsule's cross-section is narrower there (half-width 0.247 against
    //            0.3 unlifted), so it SQUEEZES 0.053 m closer, and the down-sweep then finds the
    //            ground with `drop = 0.3 > 0` and lands it back where it started. Rejected by the
    //            climbed-higher half alone.
    for ([_]f32{ 0.35, 0.45 }) |h| {
        var reached: [2]Real = @splat(0);
        for ([_]f32{ 0, 0.3 }, 0..) |step_height, i| {
            var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
            defer world.deinit(gpa);
            var chars: CharacterStore = .{};
            defer chars.deinit(gpa);
            const id = try stepScene(gpa, &world, &chars, h, step_height);

            const r = try chars.moveCharacter(gpa, &world.bp, &world.bm, &world.store, id, requested, 1.0 / 60.0);
            reached[i] = r.position.toArray()[0];
            // No lift survives either way.
            try testing.expectApproxEqAbs(@as(Real, 0.02), r.position.toArray()[1], api_tol);
        }

        // The same stopping place: the failed climb bought nothing at all.
        try testing.expectApproxEqAbs(reached[0], reached[1], api_tol);

        // And the invariant the reference's bug violated, on the HORIZONTAL component — a legitimate
        // climb adds vertical displacement, which is what climbing IS, so the bound belongs on the
        // horizontal part and not on the norm of the whole.
        try testing.expect(reached[1] <= @sqrt(requested.lengthSq()) + api_tol);
    }
}

test "a slope steeper than max_slope is never reported grounded, and the CLIMB is not what lifts the character there" {
    const gpa = testing.allocator;

    // A 50° ramp — just past the default 45° limit — built as a BOX rotated about +Z, so its top
    // face normal is `(−sin50, cos50, 0) = (−0.766, 0.643, 0)`. Fifty and not seventy because a face
    // rises `tan(θ)` per metre of forward reach while a lift buys only `step_height / tan(θ)` of it:
    // at 70° the face climbs 0.75 m over the 0.11 m afforded and nothing can land on it.
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    var chars: CharacterStore = .{};
    defer chars.deinit(gpa);

    _ = try addPlane(gpa, &world, av(0, 1, 0), 0, 230);
    const theta: f32 = 50.0 * std.math.pi / 180.0;
    const ramp = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av(2, 0.5, 2) } });
    _ = try world.addBody(gpa, .{
        .entity = ent(231),
        .body_type = .static,
        .shape = ramp,
        // Top face through (0.5, 0, 0), just ahead of the character: `centre = p − 0.5 · n`.
        .position = av(0.883, -0.3215, 0),
        .rotation = math.Quatf.fromAxisAngle(av(0, 0, 1), theta),
    });

    var desc = baseDescriptor();
    desc.position = av(0, 0.02, 0);
    const id = try addMover(gpa, &world, &chars, desc);
    const r = try chars.moveCharacter(gpa, &world.bp, &world.bm, &world.store, id, v(1.5, 0, 0), 1.0 / 60.0);

    // THE VERDICT is enforced: 50° is past the limit, so the character is on steep ground and never
    // `.grounded`, and the normal reported is the ramp's own `cos50 = 0.6428`.
    try testing.expectEqual(api.GroundState.on_steep_ground, r.ground.state);
    // `cos(50°) = 0.6427876097`, to more digits than `api_tol` needs — a four-decimal rounding of it
    // is 1.2e-5 away and fails, which is the tolerance doing its job.
    try testing.expectApproxEqAbs(@as(Real, 0.6427876), r.ground.normal.toArray()[1], api_tol);

    // **AND THE HEIGHT GAIN IS THE SLIDE'S, NOT THE CLIMB'S — measured, and pinned here because the
    // next milestone will meet it.** Projecting a horizontal displacement onto a 50° plane leaves an
    // upward component, so a character pushed into the ramp rises whether or not any step was
    // accepted: 0.583 m in one call. Running the same scene with `max_slope` at 80°, which makes the
    // ramp walkable and suppresses the step attempt entirely, gives 0.579 m — the same height by a
    // different route. So the step's landing slope test cannot be what governs this scene, and an
    // absolute assertion on the height would measure the slide while appearing to measure the climb.
    //
    // Whether SLIDING should itself be slope-constrained is a real question and it is not this
    // gate's: the verdict is correct, the position climbs, and nothing in §1.12 settles it.
    try testing.expectApproxEqAbs(@as(Real, 0.583), r.position.toArray()[1], 0.01);
}

test "the touched-body capacity accounts for the step's sweeps exactly" {
    // The bound is a sum of iteration ceilings and not a guess: the depenetration iterations, the
    // slide iterations, the three sweeps of the single step attempt, and the one step-down sweep.
    // Asserted so a later gate that adds a sweep has to revisit the arithmetic rather than
    // discovering the assert at runtime.
    try testing.expectEqual(@as(u32, 4), character_mod.max_depenetration_iterations);
    try testing.expectEqual(@as(u32, 4), character_mod.max_slide_iterations);
}

test "a low kerb with level ground either side is stepped OVER, and the move is served in full" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    var chars: CharacterStore = .{};
    defer chars.deinit(gpa);

    _ = try addPlane(gpa, &world, av(0, 1, 0), 0, 240);
    // A THIN kerb 0.2 m high at x ∈ [1, 1.1], flat ground on both sides. Well inside the 0.3 m
    // `step_height`, and the landing is at the SAME height the character started from — which is
    // what makes this the discriminating case for the acceptance condition.
    _ = try addBox(gpa, &world, av(0.05, 0.1, 2), av(1.05, 0.1, 0), 241);

    var desc = baseDescriptor();
    desc.position = av(0, 0.02, 0);
    const id = try addMover(gpa, &world, &chars, desc);
    const r = try chars.moveCharacter(gpa, &world.bp, &world.bm, &world.store, id, v(2, 0, 0), 1.0 / 60.0);

    // The whole 2 m is served and the height is unchanged: over the kerb and down the other side.
    try testing.expectApproxEqAbs(@as(Real, 2), r.position.toArray()[0], api_tol);
    try testing.expectApproxEqAbs(@as(Real, 0.02), r.position.toArray()[1], api_tol);
    try testing.expectEqual(api.GroundState.grounded, r.ground.state);

    // MEASURED counter-factual, and it is why a "the landing must be higher than the start"
    // condition was removed from `tryStepUp`: with it, this move ends at x = 0.912 and y = 0.495 —
    // blocked by a 0.2 m kerb AND half a metre in the air, having ratcheted up its edge.
}
