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
        // padding, mass, max_push_force: non-finite.
        .{ .expected = error.InvalidPadding, .mutate = struct {
            fn f(d: *api.CharacterDescriptor) void {
                d.padding = nan;
            }
        }.f },
        .{ .expected = error.InvalidPushParameters, .mutate = struct {
            fn f(d: *api.CharacterDescriptor) void {
                d.mass = inf;
            }
        }.f },
        .{ .expected = error.InvalidPushParameters, .mutate = struct {
            fn f(d: *api.CharacterDescriptor) void {
                d.max_push_force = nan;
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

    // The legal boundaries of the same fields, so the rejections above are not merely a
    // blanket refusal: `max_slope` exactly at `π/2` is admissible (a vertical wall counts as
    // walkable), `max_push_force` of zero disables pushing with no special case, and a
    // capsule whose height is exactly twice its radius is a sphere and is legal.
    {
        var ok = baseDescriptor();
        ok.max_slope = std.math.pi / 2.0;
        ok.max_push_force = 0;
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
