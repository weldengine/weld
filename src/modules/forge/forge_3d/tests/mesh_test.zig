//! M1.1.11.1 acceptance suite for the static triangle mesh.
//!
//! A mesh is a SURFACE, not a solid, and that is CATEGORICAL rather than a setting
//! (`engine-physics-forge.md` §1.11.17). It is also the first shape the store OWNS
//! memory for, the first that carries sub-shapes, and the twelfth and last of the C1.1
//! list.
//!
//! Every expectation below is a CLOSED FORM computed in the comment above it, never a
//! value read back from the implementation.

const std = @import("std");
const config = @import("../config.zig");
const shape_mod = @import("../shape.zig");
const mesh_mod = @import("../mesh.zig");
const bm_mod = @import("../body_manager.zig");
const broadphase_mod = @import("../pipeline/broadphase.zig");
const query = @import("../query/root.zig");
const api = @import("weld_forge");
const foundation = @import("foundation");

const Real = config.Real;
const Vec3r = config.Vec3r;
const Quatr = config.Quatr;
const Aabbr = config.Aabbr;
const BodyManager = bm_mod.BodyManager;
const ShapeStore = shape_mod.ShapeStore;
const ShapeClass = shape_mod.ShapeClass;
const MeshData = mesh_mod.MeshData;
const math = foundation.math;
const ApiVec3 = math.Vec3;
const testing = std.testing;

/// A descriptor-precision (`f32`) `Vec3` literal — the mesh descriptor's own type.
fn av3(x: f32, y: f32, z: f32) ApiVec3 {
    return ApiVec3.fromArray(.{ x, y, z });
}

/// A `Vec3r` literal at solver precision.
fn vr(x: Real, y: Real, z: Real) Vec3r {
    return Vec3r.fromArray(.{ x, y, z });
}

/// One well-formed triangle in the XZ plane, front face up: `(0,0,0)`, `(1,0,0)`,
/// `(0,0,-1)`. Counter-clockwise seen from `+Y`, so `(v₁−v₀) × (v₂−v₀)`
/// `= (1,0,0) × (0,0,−1) = (0·(−1) − 0·0, 0·0 − 1·(−1), 0) = (0, 1, 0)`.
const one_triangle_vertices = [_]ApiVec3{
    av3(0, 0, 0),
    av3(1, 0, 0),
    av3(0, 0, -1),
};
const one_triangle_indices = [_]u32{ 0, 1, 2 };

/// The descriptor for that single triangle.
fn oneTriangle() api.ShapeDescriptor {
    return .{ .triangle_mesh = .{
        .vertices = &one_triangle_vertices,
        .indices = &one_triangle_indices,
    } };
}

/// An entity handle keyed by an ordinal, so distinct bodies carry distinct entities.
fn entityOf(index: u32) api.EntityId {
    return .{ .index = index, .generation = 0 };
}

// ---------------------------------------------------------------------------
// Descriptor domain — five conditions, each refused by its OWN typed error
// ---------------------------------------------------------------------------

test "an index count not a multiple of three is refused" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);

    // Four indices describe one triangle and a third of another: the last triangle is
    // incomplete, so the descriptor is malformed and not merely truncated.
    const verts = [_]ApiVec3{ av3(0, 0, 0), av3(1, 0, 0), av3(0, 0, -1), av3(1, 0, -1) };
    const idx = [_]u32{ 0, 1, 2, 3 };
    try testing.expectError(
        error.InvalidMeshIndexCount,
        store.createShape(gpa, .{ .triangle_mesh = .{ .vertices = &verts, .indices = &idx } }),
    );
    // Refused means refused: no slot, and nothing owned.
    try testing.expectEqual(@as(u32, 0), store.count());
}

test "an out-of-range index is refused" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);

    // Three vertices, so the valid index domain is `{0, 1, 2}`; `3` is one past it.
    const idx = [_]u32{ 0, 1, 3 };
    try testing.expectError(
        error.MeshIndexOutOfRange,
        store.createShape(gpa, .{ .triangle_mesh = .{ .vertices = &one_triangle_vertices, .indices = &idx } }),
    );
    try testing.expectEqual(@as(u32, 0), store.count());
}

test "a non-finite vertex is refused" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);

    // A NaN component and an infinite one are the same condition, and both are caught:
    // `@abs(NaN) < inf` is false, so one test covers the two.
    inline for (.{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) }) |bad| {
        const verts = [_]ApiVec3{ av3(0, 0, 0), av3(1, bad, 0), av3(0, 0, -1) };
        try testing.expectError(
            error.MeshVertexNotFinite,
            store.createShape(gpa, .{ .triangle_mesh = .{ .vertices = &verts, .indices = &one_triangle_indices } }),
        );
    }

    // And a non-finite vertex NO INDEX REFERENCES is refused too. It is copied into the
    // owned storage either way, and it alone poisons the local AABB — which the
    // broadphase and the sleep radius both read. A suite that only fed bad vertices to
    // referenced slots would pass with the check written over the indices instead.
    const with_orphan = [_]ApiVec3{ av3(0, 0, 0), av3(1, 0, 0), av3(0, 0, -1), av3(0, std.math.inf(f32), 0) };
    try testing.expectError(
        error.MeshVertexNotFinite,
        store.createShape(gpa, .{ .triangle_mesh = .{ .vertices = &with_orphan, .indices = &one_triangle_indices } }),
    );
    try testing.expectEqual(@as(u32, 0), store.count());
}

test "an empty mesh is refused" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);

    // `0` IS a multiple of three, so an empty index array does NOT fail the count check
    // and reaches the emptiness check — which is what keeps the two errors
    // distinguishable rather than one masking the other.
    const no_indices = [_]u32{};
    try testing.expectError(
        error.MeshEmpty,
        store.createShape(gpa, .{ .triangle_mesh = .{ .vertices = &one_triangle_vertices, .indices = &no_indices } }),
    );

    // A mesh with no vertex at all is empty by the same rule, reached the same way.
    const no_vertices = [_]ApiVec3{};
    try testing.expectError(
        error.MeshEmpty,
        store.createShape(gpa, .{ .triangle_mesh = .{ .vertices = &no_vertices, .indices = &no_indices } }),
    );
    try testing.expectEqual(@as(u32, 0), store.count());
}

test "an exactly degenerate triangle is refused and a sliver is served" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);

    // REFUSED — three COLLINEAR vertices on the X axis. `(v₁−v₀) × (v₂−v₀)`
    // `= (1,0,0) × (2,0,0) = (0·0 − 0·0, 0·2 − 1·0, 1·0 − 0·2) = (0, 0, 0)`, exactly, at
    // every precision, since every product is a product with an exact zero.
    const collinear = [_]ApiVec3{ av3(0, 0, 0), av3(1, 0, 0), av3(2, 0, 0) };
    try testing.expectError(
        error.MeshTriangleDegenerate,
        store.createShape(gpa, .{ .triangle_mesh = .{ .vertices = &collinear, .indices = &one_triangle_indices } }),
    );

    // REFUSED — two COINCIDENT vertices, the other degenerate shape. `v₂ − v₀` is the
    // zero vector, so the cross product is exactly zero for the same reason.
    const duplicated = [_]ApiVec3{ av3(0, 0, 0), av3(1, 0, 0), av3(0, 0, 0) };
    try testing.expectError(
        error.MeshTriangleDegenerate,
        store.createShape(gpa, .{ .triangle_mesh = .{ .vertices = &duplicated, .indices = &one_triangle_indices } }),
    );
    try testing.expectEqual(@as(u32, 0), store.count());

    // SERVED — a sliver of minuscule but NON-ZERO area. This is the discriminating half
    // of the pair: a suite that only rejected degenerates would pass just as well with
    // an area threshold in the code, and this case is what refuses that.
    //
    // `v₂.y = 2⁻⁴⁰` is a power of two, so the arithmetic is exact at both precisions:
    // `(v₁−v₀) × (v₂−v₀) = (1,0,0) × (1,2⁻⁴⁰,0) = (0·0 − 0·2⁻⁴⁰, 0·1 − 1·0, 1·2⁻⁴⁰ − 0·1)`
    // `= (0, 0, 2⁻⁴⁰)`. Its squared length is `2⁻⁸⁰`, normal at f32 (min normal `2⁻¹²⁶`),
    // its square root is `2⁻⁴⁰` exactly, and the normalised vector is EXACTLY `(0, 0, 1)`.
    // The triangle's area is `½·2⁻⁴⁰ ≈ 4.5e-13` — non-zero, and far below anything an
    // area threshold would keep.
    const sliver_y: f32 = @as(f32, 1) / @as(f32, 1 << 40);
    const sliver = [_]ApiVec3{ av3(0, 0, 0), av3(1, 0, 0), av3(1, sliver_y, 0) };
    const id = try store.createShape(gpa, .{ .triangle_mesh = .{ .vertices = &sliver, .indices = &one_triangle_indices } });
    try testing.expectEqual(@as(u32, 1), store.count());

    // Its normal is EXACTLY `(0, 0, 1)` — asserted bit for bit, not within a tolerance,
    // because the closed form above says it is exact and a tolerance here would hide the
    // very thing being claimed.
    const data = store.get(id).?.mesh.?;
    try testing.expect(data.faceNormal(0).eql(vr(0, 0, 1)));
    // And unit, which is the property the whole suite reads off it.
    try testing.expectEqual(@as(Real, 1), data.faceNormal(0).lengthSq());
}

test "the winding convention fixes the outward normal" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);

    // Counter-clockwise seen from `+Y` (see `one_triangle_vertices`): the cross product
    // is `(0, 1, 0)` and the normal is `+Y`, exactly.
    const up = try store.createShape(gpa, oneTriangle());
    try testing.expect(store.get(up).?.mesh.?.faceNormal(0).eql(vr(0, 1, 0)));

    // Reversing the winding reverses the normal EXACTLY — `(v₂−v₀) × (v₁−v₀)` is the
    // negation of `(v₁−v₀) × (v₂−v₀)` term by term, with no rounding anywhere. This is
    // what pins the FIXED evaluation order: the normal is a function of the stored
    // vertex order and of nothing else.
    const flipped_indices = [_]u32{ 0, 2, 1 };
    const down = try store.createShape(gpa, .{ .triangle_mesh = .{
        .vertices = &one_triangle_vertices,
        .indices = &flipped_indices,
    } });
    try testing.expect(store.get(down).?.mesh.?.faceNormal(0).eql(vr(0, -1, 0)));
}

// ---------------------------------------------------------------------------
// The shape record — class, owned data, local box, poisoned inertia
// ---------------------------------------------------------------------------

test "a mesh carries the triangle_soup class and owns a copy of its arrays" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);

    // The descriptor's arrays are BORROWED for the duration of the call, so they are
    // built on the STACK here and go out of scope before the mesh is read — which a
    // borrowed-slice implementation would fail under the test allocator's poisoning.
    const id = blk: {
        var verts = [_]ApiVec3{ av3(0, 0, 0), av3(2, 0, 0), av3(0, 0, -3) };
        var idx = [_]u32{ 0, 1, 2 };
        const created = try store.createShape(gpa, .{ .triangle_mesh = .{ .vertices = &verts, .indices = &idx } });
        // Overwrite the caller's arrays: an owned copy is unaffected, a borrowed one is
        // not. This is the observable difference between the two, and the only one.
        verts = [_]ApiVec3{ av3(9, 9, 9), av3(9, 9, 9), av3(9, 9, 9) };
        idx = [_]u32{ 0, 0, 0 };
        break :blk created;
    };

    const record = store.get(id).?;
    try testing.expectEqual(ShapeClass.triangle_soup, record.class());
    try testing.expectEqual(api.ShapeType.triangle_mesh, record.shape_type);

    const data = record.mesh.?;
    try testing.expectEqual(@as(u32, 1), data.triangleCount());
    const v = data.triangle(0);
    try testing.expect(v[0].eql(vr(0, 0, 0)));
    try testing.expect(v[1].eql(vr(2, 0, 0)));
    try testing.expect(v[2].eql(vr(0, 0, -3)));
}

test "a mesh has a valid local aabb and a NaN unit inertia" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);

    // Two triangles spanning `x ∈ [−1, 4]`, `y ∈ [0, 2]`, `z ∈ [−3, 0]`, so the tight
    // local bound is exactly that box — deliberately NOT centred on the origin, which is
    // the property a mesh has and the three primitives do not.
    const verts = [_]ApiVec3{
        av3(-1, 0, 0),
        av3(4, 0, 0),
        av3(0, 0, -3),
        av3(0, 2, -1),
    };
    const idx = [_]u32{ 0, 1, 2, 0, 2, 3 };
    const id = try store.createShape(gpa, .{ .triangle_mesh = .{ .vertices = &verts, .indices = &idx } });
    const record = store.get(id).?;

    try testing.expect(record.local_aabb.min.eql(vr(-1, 0, -3)));
    try testing.expect(record.local_aabb.max.eql(vr(4, 2, 0)));
    // The `Shape` copy and the `MeshData` carry the SAME value, one computation and two
    // readers rather than two sources of truth.
    try testing.expect(record.mesh.?.local_aabb.min.eql(record.local_aabb.min));
    try testing.expect(record.mesh.?.local_aabb.max.eql(record.local_aabb.max));

    // Two triangles, so two sub-shape ids, `0` and `1`.
    try testing.expectEqual(@as(u32, 2), record.mesh.?.triangleCount());

    // The inertia is NaN on every component — an open surface encloses no volume, so no
    // tensor derives from it. NaN and not a plausible zero, which would pass unnoticed
    // in ReleaseFast where the class dispatches guarding this field compile out.
    const inertia = record.unit_inertia.toArray();
    for (inertia) |component| try testing.expect(std.math.isNan(component));
    // And the local box is emphatically NOT NaN, which is where the mesh and the
    // half-space part company: a half-space poisons both fields, a mesh only this one.
    try testing.expect(std.math.isFinite(record.local_aabb.min.toArray()[0]));
}

// ---------------------------------------------------------------------------
// Owned memory — the transaction, and the two release paths
// ---------------------------------------------------------------------------

test "createShape is transactional under OOM" {
    // A failing allocator at EACH successive allocation point in turn. After every
    // failure the store must hold no live mesh slot and leak nothing — the second half
    // being what the leak-checking backing allocator asserts at `deinit`.
    //
    // The count is discovered rather than assumed: the loop runs until a creation
    // succeeds, which is the first index at which no allocation fails.
    var failing_index: usize = 0;
    while (failing_index < 16) : (failing_index += 1) {
        var backing: std.heap.DebugAllocator(.{ .safety = true }) = .init;
        defer std.debug.assert(backing.deinit() == .ok); // no leak, whatever failed
        var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = failing_index });
        const gpa = failing.allocator();

        var store = ShapeStore{};
        defer store.deinit(gpa);

        const result = store.createShape(gpa, oneTriangle());
        if (result) |_| {
            // First index at which nothing failed: every earlier index exercised a real
            // allocation point, so the sweep above was complete.
            try testing.expect(failing_index > 0);
            try testing.expectEqual(@as(u32, 1), store.count());
            break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            // NOTHING was mutated: no slot, hence no half-built mesh reachable through
            // one. A store that had allocated the slot before the mesh would report 1.
            try testing.expectEqual(@as(u32, 0), store.count());
        }
    } else {
        // The mesh path allocates a bounded number of times; sixteen is far past it, so
        // exhausting the loop means creation never succeeded and the test proves nothing.
        try testing.expect(false);
    }
}

test "destroyShape frees, and deinit walks the live slots" {
    // A leak-checking allocator with `safety` FORCED true, not left at its default: the
    // default is `std.debug.runtime_safety`, which is false in ReleaseFast, and a check
    // that reports success unconditionally is not a check.
    var backing: std.heap.DebugAllocator(.{ .safety = true }) = .init;
    const gpa = backing.allocator();
    {
        var store = ShapeStore{};
        defer store.deinit(gpa); // must release the ONE mesh still live at this point

        const destroyed = try store.createShape(gpa, oneTriangle());
        const kept = try store.createShape(gpa, oneTriangle());
        try testing.expectEqual(@as(u32, 2), store.count());

        store.destroyShape(gpa, destroyed);
        try testing.expectEqual(@as(u32, 1), store.count());
        try testing.expect(store.get(destroyed) == null);
        try testing.expect(store.get(kept) != null);

        // Destroying a STALE handle frees nothing and is a no-op — which is what keeps a
        // double destroy from double-freeing the mesh. Called twice more so the claim is
        // not an accident of being called once.
        store.destroyShape(gpa, destroyed);
        store.destroyShape(gpa, destroyed);
        try testing.expectEqual(@as(u32, 1), store.count());

        // The freed slot is reused LIFO by a shape of a DIFFERENT kind, so the dead
        // slot's stale `mesh` pointer is overwritten rather than re-read. `deinit` must
        // then free the kept mesh and nothing else — a walk over the columns instead of
        // over the live slots would double-free through the dead one.
        const reused = try store.createShape(gpa, .{ .sphere = .{ .radius = 1 } });
        try testing.expectEqual(api.PackedId.unpack(destroyed).index, api.PackedId.unpack(reused).index);
        try testing.expect(store.get(reused).?.mesh == null);
    }
    try testing.expectEqual(std.heap.Check.ok, backing.deinit());
}

// ---------------------------------------------------------------------------
// The body — static only, and a world box that transports its off-centre origin
// ---------------------------------------------------------------------------

test "a mesh forces a static body" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);

    const mesh = try store.createShape(gpa, oneTriangle());

    // The refusal is the invariant's error, reused from M1.1.11 rather than a second one
    // minted for the mesh — the reason it was named for the invariant back then.
    inline for (.{ api.BodyType.dynamic, api.BodyType.kinematic }) |bt| {
        try testing.expectError(error.ShapeMustBeStatic, bm.addBody(gpa, &store, .{
            .entity = entityOf(0),
            .body_type = bt,
            .shape = mesh,
        }));
    }
    // Nothing was mutated and no handle allocated on either refusal.
    try testing.expectEqual(@as(u32, 0), bm.count());

    // And the STATIC body is accepted, which is the other half of the claim: a rule that
    // refused every body type would pass the two assertions above.
    const id = try bm.addBody(gpa, &store, .{
        .entity = entityOf(0),
        .body_type = .static,
        .shape = mesh,
    });
    try testing.expectEqual(@as(u32, 1), bm.count());

    // Its sleep radius is DEFINED and finite, unlike a half-space's NaN: the mesh is
    // bounded, so the corner furthest from the body centre exists. For the single
    // triangle `(0,0,0)`, `(1,0,0)`, `(0,0,−1)` the local box is `[0,1] × [0,0] × [−1,0]`,
    // whose furthest corner from the origin is `(1, 0, −1)`, at distance `√2`.
    try testing.expect(@abs(bm.sleepRadius(id).? - @sqrt(@as(Real, 2))) <= 4 * std.math.floatEps(Real));
}

test "a mesh world aabb transports its off-centre local box" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);

    // The single triangle's local box is `[0,1] × [0,0] × [−1,0]`, centred at
    // `(0.5, 0, −0.5)` with half-extents `(0.5, 0, 0.5)`. It is NOT centred on the
    // origin, which is exactly what the three primitives never exercise.
    const mesh = try store.createShape(gpa, oneTriangle());
    const id = try bm.addBody(gpa, &store, .{
        .entity = entityOf(0),
        .body_type = .static,
        .shape = mesh,
        .position = ApiVec3.fromArray(.{ 10, 20, 30 }),
    });

    // At identity rotation the world box is the local box translated: min
    // `(10, 20, 29)`, max `(11, 20, 30)`. A world AABB built from `pos ± half_extents` —
    // the formula the three primitives get away with — would answer
    // `(9.5, 20, 29.5) … (10.5, 20, 30.5)`, half a metre off on two axes, and a mesh
    // authored around `(0, 0, 100)` would land its box a hundred metres from its
    // triangles.
    const box = bm.bodyAabb(&store, id).?;
    try testing.expect(box.min.eql(vr(10, 20, 29)));
    try testing.expect(box.max.eql(vr(11, 20, 30)));

    // Rotated a quarter turn about `+Y`: `R = [[0,0,1],[0,1,0],[−1,0,0]]`, so
    // `R·(x, y, z) = (z, y, −x)`. The local centre `(0.5, 0, −0.5)` maps to
    // `(−0.5, 0, −0.5)`, giving a world centre of `(9.5, 20, 29.5)`; the extent is
    // `ext_i = Σ_j |R_ij|·he_j` on `he = (0.5, 0, 0.5)`, i.e. `(0.5, 0, 0.5)` — the axes
    // swap and the values happen to match. So the box is `(9, 20, 29) … (10, 20, 30)`
    // around the SAME body position, DIFFERENT from the identity box above on the X
    // axis. That difference is the whole test: a formula ignoring the local offset would
    // answer the same box in both poses.
    const quarter = Quatr.fromAxisAngle(Vec3r.unit_y, std.math.pi / @as(Real, 2));
    bm.setRotation(id, quarter);
    const rotated = bm.bodyAabb(&store, id).?;
    const tol: Real = 8 * std.math.floatEps(Real) * 30;
    try testing.expect(rotated.min.approxEql(vr(9, 20, 29), tol));
    try testing.expect(rotated.max.approxEql(vr(10, 20, 30), tol));

    // ---- The box is TIGHT over the transported vertices, not the enclosure of the
    // transported local box. The two agree at identity and at the quarter turn above —
    // the triangle's own vertices are the corners of its local box in those poses — so
    // neither case above discriminates, and this one is written because that is exactly
    // what makes a regression here invisible.
    //
    // An EIGHTH turn about `+Y`, `c = s = √2/2`: `R·(x, y, z) = (c·x + s·z, y, −s·x + c·z)`.
    //
    // TIGHT — the three vertices transported:
    //   `(0,0,0)  → (0, 0, 0)`
    //   `(1,0,0)  → (c, 0, −s)`
    //   `(0,0,−1) → (−s, 0, −c)`
    // so the local-frame box is `(−√2/2, 0, −√2/2) … (√2/2, 0, 0)` and, at the body
    // position, `(10−√2/2, 20, 30−√2/2) … (10+√2/2, 20, 30)`.
    //
    // ENCLOSURE — the refused construction, for comparison: the local centre
    // `(0.5, 0, −0.5)` transports to `(0, 0, −√2/2)` and the extent is
    // `ext_i = Σ_j |R_ij|·he_j` on `he = (0.5, 0, 0.5)`, i.e. `(√2/2, 0, √2/2)`, giving
    // `(10−√2/2, 20, 30−√2) … (10+√2/2, 20, 30)`. It agrees on five of the six bounds
    // and reaches `√2 ≈ 1.41421356` below the body on Z where the tight box reaches
    // `√2/2 ≈ 0.70710678` — a gap of 0.707 m, some fourteen orders of magnitude past the
    // tolerance, so the assertion below cannot pass under it.
    const root_half = @sqrt(@as(Real, 2)) / 2;
    const eighth = Quatr.fromAxisAngle(Vec3r.unit_y, std.math.pi / @as(Real, 4));
    bm.setRotation(id, eighth);
    const oblique = bm.bodyAabb(&store, id).?;
    try testing.expect(oblique.min.approxEql(vr(10 - root_half, 20, 30 - root_half), tol));
    try testing.expect(oblique.max.approxEql(vr(10 + root_half, 20, 30), tol));
    // Stated as its own assertion so the failure names the thing that regressed: the
    // enclosure would answer `30 − √2` here, and it does not.
    try testing.expect(oblique.min.toArray()[2] > 30 - @sqrt(@as(Real, 2)) + 0.5);

    // ---- And once more on a mesh with a NON-ZERO extent on all three axes, since the
    // triangle above is flat in Y and a formula could be tight only in the degenerate
    // direction. The corner triangle `(1,0,0)`, `(0,1,0)`, `(0,0,1)`: its cross product
    // `(−1,1,0) × (−1,0,1) = (1, 1, 1)` is non-zero, and its local box is the unit cube
    // `[0,1]³`, whose corners are NOT its vertices.
    //
    // An eighth turn about `+Z`: `R·(x, y, z) = (c·x − s·y, s·x + c·y, z)`.
    //
    // TIGHT: `(1,0,0) → (c, s, 0)`, `(0,1,0) → (−s, c, 0)`, `(0,0,1) → (0, 0, 1)`, so
    // the box is `(−√2/2, 0, 0) … (√2/2, √2/2, 1)`.
    //
    // ENCLOSURE: centre `(0.5,0.5,0.5) → (0, √2/2, 0.5)`, extent
    // `(√2/2, √2/2, 0.5)`, giving `(−√2/2, 0, 0) … (√2/2, √2, 1)`. It agrees on five
    // bounds again and reaches `√2` on `max.y` where the tight box reaches `√2/2`.
    const corner_vertices = [_]ApiVec3{ av3(1, 0, 0), av3(0, 1, 0), av3(0, 0, 1) };
    const corner = try store.createShape(gpa, .{ .triangle_mesh = .{
        .vertices = &corner_vertices,
        .indices = &one_triangle_indices,
    } });
    const corner_body = try bm.addBody(gpa, &store, .{
        .entity = entityOf(1),
        .body_type = .static,
        .shape = corner,
    });
    // The rotation is set at SOLVER precision, not carried in the descriptor. The
    // descriptor's rotation is `f32` by design (§1.11.8), so under `-Dphysics_f64` a
    // pose that arrived that way is only `f32`-accurate — measured, an eighth turn built
    // at `f32` lands about `1e-8` from the exact one, which swamps any tolerance
    // expressed in ULPs of `Real` and would make this test measure the descriptor
    // widening instead of the box construction it is written for. The eighth turn about
    // `+Y` above is set the same way, and for the same reason.
    bm.setRotation(corner_body, Quatr.fromAxisAngle(Vec3r.unit_z, std.math.pi / @as(Real, 4)));
    const corner_box = bm.bodyAabb(&store, corner_body).?;
    // The matrix entries are of order 1 and reached through a handful of operations
    // (half-angle trigonometry, then `1 − 2·sin²`), so sixteen ULPs of `Real` is a pure
    // float-noise budget on a unit-scale quantity — not a geometric tolerance.
    const corner_tol: Real = 16 * std.math.floatEps(Real);
    try testing.expect(corner_box.min.approxEql(vr(-root_half, 0, 0), corner_tol));
    try testing.expect(corner_box.max.approxEql(vr(root_half, root_half, 1), corner_tol));
    try testing.expect(corner_box.max.toArray()[1] < @sqrt(@as(Real, 2)) - 0.5);
}

// ---------------------------------------------------------------------------
// A mesh is an inadmissible PROBE — refused, never silently empty
// ---------------------------------------------------------------------------

test "a mesh probe is refused, not silently empty" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);
    var bp = broadphase_mod.Broadphase(Real).init(.{});
    defer bp.deinit(gpa);

    const mesh = try store.createShape(gpa, oneTriangle());

    // The refusal is TYPED, and it is the same member the half-space earns — a probe the
    // exact kernel cannot express — reached for a DIFFERENT reason: a half-space is not
    // BOUNDED, a mesh is not CONVEX. Returning `null` or `0` would be a silent false
    // negative, the one outcome §1.11.7 forbids, and the caller could not tell it from a
    // real miss.
    try testing.expectError(error.UnsupportedShape, query.shapeCast(&bp, &bm, &store, .{
        .shape = mesh,
        .origin = Vec3r.zero,
        .direction = Vec3r.unit_x,
        .max_distance = 10,
    }));

    var out: [4]api.BodyId = undefined;
    try testing.expectError(error.UnsupportedShape, query.overlapShape(&bp, &bm, &store, .{
        .shape = mesh,
        .position = Vec3r.zero,
    }, &out));

    // Both entries still separate the THREE outcomes: a stale handle is
    // `error.InvalidShape` and not `error.UnsupportedShape`, so the mesh refusal has not
    // swallowed the handle check.
    store.destroyShape(gpa, mesh);
    try testing.expectError(error.InvalidShape, query.shapeCast(&bp, &bm, &store, .{
        .shape = mesh,
        .origin = Vec3r.zero,
        .direction = Vec3r.unit_x,
        .max_distance = 10,
    }));

    // And an admissible probe is NOT refused, which is what keeps the two assertions
    // above from passing under a predicate that refuses everything.
    const sphere = try store.createShape(gpa, .{ .sphere = .{ .radius = 1 } });
    try testing.expectEqual(@as(?query.CastHit, null), try query.shapeCast(&bp, &bm, &store, .{
        .shape = sphere,
        .origin = Vec3r.zero,
        .direction = Vec3r.unit_x,
        .max_distance = 10,
    }));
    try testing.expectEqual(@as(u32, 0), try query.overlapShape(&bp, &bm, &store, .{
        .shape = sphere,
        .position = Vec3r.zero,
    }, &out));
}

// ---------------------------------------------------------------------------
// The static acceleration structure
// ---------------------------------------------------------------------------

/// A pseudo-random mesh of `triangle_count` triangles, owned by the caller's store.
///
/// Each triangle is built as a base point plus two roughly-orthogonal offsets, so its
/// cross product is bounded away from zero by construction rather than by luck: the
/// offsets are `(a, 0, 0) + noise` and `(0, b, 0) + noise` with `a, b >= 0.2` and the
/// noise under 0.05, so the cross product's Z component cannot fall below `0.02`.
fn randomMesh(
    gpa: std.mem.Allocator,
    store: *ShapeStore,
    seed: u64,
    triangle_count: u32,
) !api.ShapeId {
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    const verts = try gpa.alloc(ApiVec3, triangle_count * 3);
    defer gpa.free(verts);
    const idx = try gpa.alloc(u32, triangle_count * 3);
    defer gpa.free(idx);

    for (0..triangle_count) |t| {
        const base = [3]f32{
            rand.float(f32) * 20 - 10,
            rand.float(f32) * 20 - 10,
            rand.float(f32) * 20 - 10,
        };
        const a = 0.2 + rand.float(f32) * 1.3;
        const b = 0.2 + rand.float(f32) * 1.3;
        const noise = struct {
            fn v(r: std.Random) f32 {
                return r.float(f32) * 0.1 - 0.05;
            }
        };
        verts[t * 3 + 0] = av3(base[0], base[1], base[2]);
        verts[t * 3 + 1] = av3(base[0] + a, base[1] + noise.v(rand), base[2] + noise.v(rand));
        verts[t * 3 + 2] = av3(base[0] + noise.v(rand), base[1] + b, base[2] + noise.v(rand));
        idx[t * 3 + 0] = @intCast(t * 3 + 0);
        idx[t * 3 + 1] = @intCast(t * 3 + 1);
        idx[t * 3 + 2] = @intCast(t * 3 + 2);
    }
    return store.createShape(gpa, .{ .triangle_mesh = .{ .vertices = verts, .indices = idx } });
}

/// Marks every triangle handed to it, and reports a duplicate rather than asserting one:
/// a triangle lives in exactly ONE leaf, so a duplicate is a partition defect and the
/// test must name it.
const MarkCollector = struct {
    seen: []bool,
    count: u32 = 0,
    duplicate: bool = false,
    bound: Real = std.math.inf(Real),

    pub fn add(self: *MarkCollector, triangle: u32) void {
        if (self.seen[triangle]) self.duplicate = true;
        self.seen[triangle] = true;
        self.count += 1;
    }
    pub fn maxDistance(self: *const MarkCollector) Real {
        return self.bound;
    }
    pub fn shouldStop(_: *const MarkCollector) bool {
        return false;
    }
};

test "the built tree is a partition of the triangle set" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);

    const id = try randomMesh(gpa, &store, 0xA11CE, 200);
    const data = store.get(id).?.mesh.?;
    const n = data.triangleCount();

    // (1) Every triangle in EXACTLY one leaf. `tri_order` is a permutation, and the
    // leaves tile it: the offsets of the leaves, taken in tree order, cover
    // `[0, n)` without overlap.
    var covered = try gpa.alloc(bool, n);
    defer gpa.free(covered);
    @memset(covered, false);
    var leaf_slots: u32 = 0;
    for (data.nodes) |node| {
        if (!node.isLeaf()) continue;
        try testing.expect(node.count > 0);
        for (data.tri_order[node.first .. node.first + node.count]) |t| {
            try testing.expect(!covered[t]); // no triangle twice
            covered[t] = true;
            leaf_slots += 1;
        }
    }
    try testing.expectEqual(n, leaf_slots); // and none missing
    for (covered) |c| try testing.expect(c);

    // (2) A child's box is CONTAINED in its parent's. Checked on every internal node,
    // which covers the leaf-in-parent claim transitively. Containment is
    // `parent.min <= child.min` and `child.max <= parent.max`, componentwise.
    var internal: u32 = 0;
    for (data.nodes) |node| {
        if (node.isLeaf()) continue;
        internal += 1;
        for ([_]u32{ node.first, node.first + 1 }) |child| {
            const c = data.nodes[child].aabb;
            try testing.expect(@reduce(.And, node.aabb.min.data <= c.min.data));
            try testing.expect(@reduce(.And, c.max.data <= node.aabb.max.data));
        }
    }
    // A binary tree with `L` leaves has `L − 1` internal nodes and `2L − 1` in total.
    const leaves = @as(u32, @intCast(data.nodes.len)) - internal;
    try testing.expectEqual(leaves - 1, internal);
    try testing.expectEqual(2 * leaves - 1, @as(u32, @intCast(data.nodes.len)));
    // With 200 triangles and a leaf of 8 the tree really did split, so the checks above
    // are not passing on a single-node tree.
    try testing.expect(leaves > 1);

    // (3) The ROOT box is the tight bound over the vertices. Equal here because every
    // vertex of this mesh is referenced by a triangle; in general the root bounds the
    // TRIANGLES and `local_aabb` the stored vertex set, so the first is contained in the
    // second.
    try testing.expect(data.nodes[0].aabb.min.eql(data.local_aabb.min));
    try testing.expect(data.nodes[0].aabb.max.eql(data.local_aabb.max));

    // (4) Every leaf box bounds its own triangles tightly enough to contain them.
    for (data.nodes) |node| {
        if (!node.isLeaf()) continue;
        for (data.tri_order[node.first .. node.first + node.count]) |t| {
            const tri = data.triangleAabb(t);
            try testing.expect(@reduce(.And, node.aabb.min.data <= tri.min.data));
            try testing.expect(@reduce(.And, tri.max.data <= node.aabb.max.data));
        }
    }
}

/// The two exact brute-force answers a traversal is checked against, for one query.
///
///   - `per_triangle` — every triangle whose OWN box meets the query. The traversal must
///     lose none of these: that is what tests the tree, since a lost one means a node box
///     that failed to contain its subtree.
///   - `per_leaf` — every triangle of every leaf whose NODE box meets the query. The
///     traversal must yield exactly these: that is what tests the descent, since a
///     missing one means a wrongly pruned branch and an extra one a wrongly taken branch.
///
/// The first is contained in the second whenever the tree is well formed, so asserting
/// both separately is what keeps a defect in one from hiding behind the other.
const BruteForce = struct {
    per_triangle: []bool,
    per_leaf: []bool,
    triangle_count: u32,

    fn init(gpa: std.mem.Allocator, n: u32) !BruteForce {
        const a = try gpa.alloc(bool, n);
        const b = try gpa.alloc(bool, n);
        @memset(a, false);
        @memset(b, false);
        return .{ .per_triangle = a, .per_leaf = b, .triangle_count = n };
    }
    fn deinit(self: *BruteForce, gpa: std.mem.Allocator) void {
        gpa.free(self.per_triangle);
        gpa.free(self.per_leaf);
    }
    fn reset(self: *BruteForce) void {
        @memset(self.per_triangle, false);
        @memset(self.per_leaf, false);
    }
    /// Mark every triangle of every leaf whose node box satisfies `boxMeets`.
    fn markLeaves(self: *BruteForce, data: *const MeshData, context: anytype) void {
        for (data.nodes) |node| {
            if (!node.isLeaf()) continue;
            if (!context.boxMeets(node.aabb)) continue;
            for (data.tri_order[node.first .. node.first + node.count]) |t| self.per_leaf[t] = true;
        }
    }
    /// Mark every triangle whose own box satisfies `boxMeets`.
    fn markTriangles(self: *BruteForce, data: *const MeshData, context: anytype) void {
        var t: u32 = 0;
        while (t < self.triangle_count) : (t += 1) {
            if (context.boxMeets(data.triangleAabb(t))) self.per_triangle[t] = true;
        }
    }
    /// The traversal's output must equal `per_leaf` exactly and contain `per_triangle`.
    fn check(self: *const BruteForce, seen: []const bool) !u32 {
        var hits: u32 = 0;
        for (seen, self.per_leaf, self.per_triangle) |got, leaf, tri| {
            try testing.expectEqual(leaf, got);
            if (tri) try testing.expect(got);
            if (tri) hits += 1;
        }
        return hits;
    }
};

test "traversal agrees with brute force" {
    const gpa = testing.allocator;

    // Enough seeds and enough queries per seed that a wrong slab test or a wrong descent
    // order cannot survive: a mis-ordered descent shows up as a wrongly pruned branch the
    // moment a bound tightens, and a wrong slab test as a leaf-set mismatch on any ray
    // that grazes a box.
    for ([_]u64{ 1, 2, 3, 5, 8, 13, 21 }) |seed| {
        var store = ShapeStore{};
        defer store.deinit(gpa);
        const id = try randomMesh(gpa, &store, seed, 150);
        const data = store.get(id).?.mesh.?;
        const n = data.triangleCount();

        var brute = try BruteForce.init(gpa, n);
        defer brute.deinit(gpa);
        const seen = try gpa.alloc(bool, n);
        defer gpa.free(seen);

        var prng = std.Random.DefaultPrng.init(seed ^ 0xC0FFEE);
        const rand = prng.random();

        var ray_hits: u32 = 0;
        var cast_hits: u32 = 0;
        var box_hits: u32 = 0;
        var distance_hits: u32 = 0;

        for (0..40) |_| {
            // Every query is AIMED AT a randomly chosen triangle's centroid, from a
            // random direction 30 m out. Aiming is not a convenience: a ray fired at
            // random through a 20 m cube containing 150 triangles of about a metre
            // misses everything nearly every time, and a suite of misses agrees with
            // brute force on the empty set while testing nothing — measured, the
            // unaimed version reached zero hits over 7 seeds × 40 rays. The centroid
            // lies inside its own triangle's box, so each ray meets at least one.
            const target = data.triangleCentroid(rand.intRangeLessThan(u32, 0, n));
            const away = vr(
                rand.float(Real) * 2 - 1,
                rand.float(Real) * 2 - 1,
                rand.float(Real) * 2 - 1,
            );
            const offset = if (@reduce(.Max, @abs(away.data)) == 0) Vec3r.unit_x else away.scale(1 / away.length());
            const origin = target.add(offset.scale(30));
            const direction = offset.neg();
            const max_distance: Real = 60;
            const ray = broadphase_mod.Ray(Real).init(origin, direction);

            // --- RAY. Brute force: the triangle's own box, and the leaf's, tested with
            // the SAME slab routine the traversal uses on the same window `[0, 60]`.
            {
                const Ctx = struct {
                    r: broadphase_mod.Ray(Real),
                    bound: Real,
                    fn boxMeets(self: @This(), box: Aabbr) bool {
                        const iv = box.rayInterval(self.r.origin, self.r.inv_dir, self.r.dir_is_zero) orelse return false;
                        return iv.exit >= 0 and iv.enter <= self.bound;
                    }
                };
                const ctx = Ctx{ .r = ray, .bound = max_distance };
                brute.reset();
                brute.markLeaves(data, ctx);
                brute.markTriangles(data, ctx);
                @memset(seen, false);
                var collector = MarkCollector{ .seen = seen, .bound = max_distance };
                _ = data.traverseRay(ray, &collector);
                try testing.expect(!collector.duplicate);
                ray_hits += try brute.check(seen);
            }

            // --- SWEPT. Same, with the node box inflated by the probe's half-extents and
            // the triangle box inflated identically — the Minkowski sum of two boxes being
            // a box is exactly what makes the two comparable.
            {
                const extent = vr(0.3, 0.7, 0.5);
                const Ctx = struct {
                    r: broadphase_mod.Ray(Real),
                    e: Vec3r,
                    bound: Real,
                    fn boxMeets(self: @This(), box: Aabbr) bool {
                        const iv = box.inflate(self.e)
                            .rayInterval(self.r.origin, self.r.inv_dir, self.r.dir_is_zero) orelse return false;
                        return iv.exit >= 0 and iv.enter <= self.bound;
                    }
                };
                const ctx = Ctx{ .r = ray, .e = extent, .bound = max_distance };
                brute.reset();
                brute.markLeaves(data, ctx);
                brute.markTriangles(data, ctx);
                @memset(seen, false);
                var collector = MarkCollector{ .seen = seen, .bound = max_distance };
                _ = data.traverseCast(ray, extent, &collector);
                try testing.expect(!collector.duplicate);
                cast_hits += try brute.check(seen);
            }

            // --- AABB.
            {
                const half = vr(
                    0.5 + rand.float(Real) * 4,
                    0.5 + rand.float(Real) * 4,
                    0.5 + rand.float(Real) * 4,
                );
                const query_box = Aabbr.fromCenterHalfExtents(target, half);
                const Ctx = struct {
                    q: Aabbr,
                    fn boxMeets(self: @This(), box: Aabbr) bool {
                        return box.overlaps(self.q);
                    }
                };
                const ctx = Ctx{ .q = query_box };
                brute.reset();
                brute.markLeaves(data, ctx);
                brute.markTriangles(data, ctx);
                @memset(seen, false);
                var collector = MarkCollector{ .seen = seen };
                _ = data.traverseAabb(query_box, &collector);
                try testing.expect(!collector.duplicate);
                box_hits += try brute.check(seen);
            }

            // --- BOUNDED DISTANCE.
            {
                const point = target;
                const radius: Real = 3;
                const Ctx = struct {
                    p: Vec3r,
                    r: Real,
                    fn boxMeets(self: @This(), box: Aabbr) bool {
                        return mesh_mod.aabbDistanceSq(box, self.p) <= self.r * self.r;
                    }
                };
                const ctx = Ctx{ .p = point, .r = radius };
                brute.reset();
                brute.markLeaves(data, ctx);
                brute.markTriangles(data, ctx);
                @memset(seen, false);
                var collector = MarkCollector{ .seen = seen, .bound = radius };
                _ = data.traverseDistance(point, &collector);
                try testing.expect(!collector.duplicate);
                distance_hits += try brute.check(seen);
            }
        }

        // The sweep is not VACUOUS: each family really did hit triangles, so "agrees with
        // brute force" is not "both answered nothing". A traversal that always returned
        // the empty set would pass every assertion above and fail here.
        try testing.expect(ray_hits > 0);
        try testing.expect(cast_hits > 0);
        try testing.expect(box_hits > 0);
        try testing.expect(distance_hits > 0);
    }
}

test "the stack depth invariant holds on an adversarial mesh" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);

    // A set built to DEGRADE the SAH cut. The centroids sit at `x = 100·(1 − 2⁻ⁱ)`, a
    // geometric approach to 100 that is SELF-SIMILAR: whatever suffix of it a node holds,
    // renormalising gives the same distribution again, so the binned sweep peels a few
    // triangles off the low end at every level instead of halving. A perfectly balanced
    // build over `n` triangles with a leaf of 8 has height `⌈log₂⌈n/8⌉⌉`; this one is
    // strictly deeper, and that inequality is the discrimination guard — on a set the
    // builder happened to balance, the test would prove nothing.
    const n: u32 = 128;
    const verts = try gpa.alloc(ApiVec3, n * 3);
    defer gpa.free(verts);
    const idx = try gpa.alloc(u32, n * 3);
    defer gpa.free(idx);
    for (0..n) |i| {
        const x: f32 = 100 * (1 - std.math.pow(f32, 0.5, @floatFromInt(i)));
        verts[i * 3 + 0] = av3(x, 0, 0);
        verts[i * 3 + 1] = av3(x + 0.01, 0, 0.01);
        verts[i * 3 + 2] = av3(x, 0.01, 0);
        idx[i * 3 + 0] = @intCast(i * 3 + 0);
        idx[i * 3 + 1] = @intCast(i * 3 + 1);
        idx[i * 3 + 2] = @intCast(i * 3 + 2);
    }
    const id = try store.createShape(gpa, .{ .triangle_mesh = .{ .vertices = verts, .indices = idx } });
    const data = store.get(id).?.mesh.?;

    // THE INVARIANT: the achieved height never exceeds the ceiling the traversal stacks
    // are sized on. It holds by construction — the builder forces a leaf there — and it
    // is asserted rather than assumed.
    try testing.expect(data.max_depth <= mesh_mod.max_tree_depth);

    // And the set really is adversarial: `⌈log₂⌈128/8⌉⌉ = ⌈log₂ 16⌉ = 4`.
    const balanced: u32 = 4;
    try testing.expect(data.max_depth > balanced);

    // The traversals run on it without overflowing — the stack asserts are live in Debug
    // and ReleaseSafe, which is where this suite runs — and still agree with brute force.
    var brute = try BruteForce.init(gpa, n);
    defer brute.deinit(gpa);
    const seen = try gpa.alloc(bool, n);
    defer gpa.free(seen);

    const ray = broadphase_mod.Ray(Real).init(vr(-10, 0.005, 0.005), Vec3r.unit_x);
    const Ctx = struct {
        r: broadphase_mod.Ray(Real),
        bound: Real,
        fn boxMeets(self: @This(), box: Aabbr) bool {
            const iv = box.rayInterval(self.r.origin, self.r.inv_dir, self.r.dir_is_zero) orelse return false;
            return iv.exit >= 0 and iv.enter <= self.bound;
        }
    };
    const ctx = Ctx{ .r = ray, .bound = 1000 };
    brute.reset();
    brute.markLeaves(data, ctx);
    brute.markTriangles(data, ctx);
    @memset(seen, false);
    var collector = MarkCollector{ .seen = seen, .bound = 1000 };
    _ = data.traverseRay(ray, &collector);
    try testing.expect(!collector.duplicate);
    // The ray runs the length of the staircase, so it crosses most of it — not a vacuous
    // check on a mesh chosen to be hard.
    try testing.expect(try brute.check(seen) > n / 2);
}

// ---------------------------------------------------------------------------
// Adjacency and the active-edge flags
// ---------------------------------------------------------------------------

/// The next representable `Real` above `x`, for a positive finite `x`. Incrementing the
/// bit pattern of a positive float is exactly one ULP up — used so the threshold's
/// boundary is probed at the grain the comparison actually has, and not at a guessed
/// distance from it.
fn ulpUp(x: Real) Real {
    const Bits = if (Real == f32) u32 else u64;
    return @bitCast(@as(Bits, @bitCast(x)) + 1);
}

/// The next representable `Real` below `x`, for a positive finite `x`.
fn ulpDown(x: Real) Real {
    const Bits = if (Real == f32) u32 else u64;
    return @bitCast(@as(Bits, @bitCast(x)) - 1);
}

/// The flat unit square as two triangles: `A(0,0,0)`, `B(1,0,0)`, `C(1,1,0)`, `D(0,1,0)`.
/// `T₁ = (A,B,C)` and `T₂ = (A,C,D)` share the diagonal `A—C`, and both normals are
/// `(1,0,0) × (1,1,0) = (0,0,1)` and `(1,1,0) × (0,1,0) = (0,0,1)` — EXACTLY, every
/// product being a product with an exact zero or one.
const square_vertices = [_]ApiVec3{ av3(0, 0, 0), av3(1, 0, 0), av3(1, 1, 0), av3(0, 1, 0) };

test "edge pairing is exact on a closed mesh" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);

    // `T₁ = (0,1,2)`: edge 0 is `(0,1)`, edge 1 is `(1,2)`, edge 2 is `(2,0)`.
    // `T₂ = (0,2,3)`: edge 0 is `(0,2)`, edge 1 is `(2,3)`, edge 2 is `(3,0)`.
    // The only key appearing twice is `(0,2)` — `T₁`'s edge 2 and `T₂`'s edge 0 — so the
    // diagonal is the one PAIRED edge and the other four are boundary.
    //
    // The two normals are identical, so the cross product is EXACTLY zero, the parallel
    // branch fires, and `cos = 1` is not `< 0`: the diagonal is INACTIVE. Every boundary
    // edge is active for want of a neighbour.
    //
    // So `T₁` has bits 0 and 1 set and bit 2 clear — `0b011 = 3` — and `T₂` has bits 1
    // and 2 set and bit 0 clear — `0b110 = 6`. That asymmetry is what makes this a test
    // of PAIRING: had the diagonal failed to pair, both would read `0b111 = 7`.
    const idx = [_]u32{ 0, 1, 2, 0, 2, 3 };
    const id = try store.createShape(gpa, .{ .triangle_mesh = .{ .vertices = &square_vertices, .indices = &idx } });
    const data = store.get(id).?.mesh.?;

    try testing.expectEqual(@as(u8, 0b011), data.edgeFlags(0));
    try testing.expectEqual(@as(u8, 0b110), data.edgeFlags(1));
    // Read once more through the per-edge accessor, so the bit LAYOUT is pinned and not
    // just the byte: bit 0 is `v₀v₁`, bit 1 is `v₁v₂`, bit 2 is `v₂v₀`.
    try testing.expect(data.edgeIsActiveAt(0, 0));
    try testing.expect(data.edgeIsActiveAt(0, 1));
    try testing.expect(!data.edgeIsActiveAt(0, 2));
    try testing.expect(!data.edgeIsActiveAt(1, 0));
    try testing.expect(data.edgeIsActiveAt(1, 1));
    try testing.expect(data.edgeIsActiveAt(1, 2));
}

test "a boundary edge of an open mesh is active" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);

    // One triangle: all three edges are unpaired, so all three are active — `0b111 = 7`.
    // There is no neighbour to be smooth with.
    const id = try store.createShape(gpa, oneTriangle());
    try testing.expectEqual(@as(u8, 0b111), store.get(id).?.mesh.?.edgeFlags(0));
}

test "a non-manifold edge is active, where the same edge shared by two is not" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);

    // `A(0,0,0)`, `B(1,0,0)`, `C(0,1,0)`, `D(0,−1,0)`, `E(0,−1,1)`.
    // `T₁ = (A,B,C)` → `(1,0,0) × (0,1,0) = (0,0,1)`.
    // `T₂ = (B,A,D)` → `(−1,0,0) × (−1,−1,0) = (0,0,1)` — coplanar with `T₁`.
    // Both carry edge `(0,1)` as their edge 0, so with only these two the seam PAIRS and
    // is flat, hence inactive: `0b110 = 6` on each.
    const verts = [_]ApiVec3{ av3(0, 0, 0), av3(1, 0, 0), av3(0, 1, 0), av3(0, -1, 0), av3(0, -1, 1) };
    {
        const idx = [_]u32{ 0, 1, 2, 1, 0, 3 };
        const id = try store.createShape(gpa, .{ .triangle_mesh = .{ .vertices = &verts, .indices = &idx } });
        const data = store.get(id).?.mesh.?;
        try testing.expectEqual(@as(u8, 0b110), data.edgeFlags(0));
        try testing.expectEqual(@as(u8, 0b110), data.edgeFlags(1));
    }

    // `T₃ = (A,B,E)` carries the SAME edge `(0,1)`, making the run three long. A
    // non-manifold edge has no single neighbour, so smoothing is undefined on it and the
    // conservative answer is the boundary one: ACTIVE, on all three — `0b111 = 7`.
    // Comparing against the two-triangle case above is what makes this a test of the
    // run-length rule rather than of "everything is active anyway".
    {
        const idx = [_]u32{ 0, 1, 2, 1, 0, 3, 0, 1, 4 };
        const id = try store.createShape(gpa, .{ .triangle_mesh = .{ .vertices = &verts, .indices = &idx } });
        const data = store.get(id).?.mesh.?;
        try testing.expectEqual(@as(u8, 0b111), data.edgeFlags(0));
        try testing.expectEqual(@as(u8, 0b111), data.edgeFlags(1));
        try testing.expectEqual(@as(u8, 0b111), data.edgeFlags(2));
    }
}

test "a concave edge is inactive and a convex edge past the threshold is active" {
    const gpa = testing.allocator;

    // ---- The PREDICATE at the threshold and one ULP either side, in closed form.
    //
    // `n₁ = (0,0,1)`, `edge = (1,0,0)`, and `n₂ = (0, −s, t)` with `s = √(1 − t²) > 0`.
    // Then `n₁ × n₂ = (0·t − 1·(−s), 1·0 − 0·t, 0) = (s, 0, 0)`, whose dot with the edge
    // is `s > 0` — CONVEX — and `n₁ · n₂ = t` EXACTLY, `n₁` picking out the z component.
    // So the predicate reduces to `t < threshold`, and the boundary is probed at the
    // grain the comparison has.
    const threshold = mesh_mod.default_active_edge_cos_threshold;
    const n1 = vr(0, 0, 1);
    const edge = vr(1, 0, 0);
    const foldNormal = struct {
        fn at(t: Real) Vec3r {
            return vr(0, -@sqrt(1 - t * t), t);
        }
    };

    // AT the threshold: `t < threshold` is false, so the fold is smooth enough and the
    // edge is INACTIVE. The comparison is strict, and this is the case that says so.
    try testing.expect(!mesh_mod.edgeIsActive(n1, foldNormal.at(threshold), edge, threshold));
    // One ULP BELOW: sharper than the threshold, so ACTIVE.
    try testing.expect(mesh_mod.edgeIsActive(n1, foldNormal.at(ulpDown(threshold)), edge, threshold));
    // One ULP ABOVE: smoother, so INACTIVE.
    try testing.expect(!mesh_mod.edgeIsActive(n1, foldNormal.at(ulpUp(threshold)), edge, threshold));

    // CONCAVE at the same angles: flipping `n₂`'s y sign gives `n₁ × n₂ = (−s, 0, 0)`,
    // whose dot with the edge is negative. A concave edge is NEVER active, however sharp
    // — checked at a 90° fold, `t = 0`, far past the threshold.
    try testing.expect(!mesh_mod.edgeIsActive(n1, vr(0, 1, 0), edge, threshold));
    // PARALLEL, both branches of the true-zero case: the same normal twice is a flat seam
    // and inactive; an exactly opposite pair is back-to-back and active.
    try testing.expect(!mesh_mod.edgeIsActive(n1, n1, edge, threshold));
    try testing.expect(mesh_mod.edgeIsActive(n1, n1.neg(), edge, threshold));

    // ---- And end to end, through the build, on a real two-triangle fold.
    //
    // `A(0,0,0)`, `B(1,0,0)`, `C(0,1,0)`, `D(0, −cos α, −sin α)`.
    // `T₁ = (A,B,C)` → `(1,0,0) × (0,1,0) = (0,0,1)`.
    // `T₂ = (B,A,D)` → `(−1,0,0) × (−1, −cos α, −sin α) = (0, −sin α, cos α)`, unit, so
    // `n₁ · n₂ = cos α` and the fold is convex by the derivation above.
    // The shared edge is `(0,1)`, which is edge 0 of BOTH triangles, so the answer lands
    // in bit 0 of each and the other four edges are boundary — active.
    //
    // At `α = 4°`, `cos α = 0.99756405` is ABOVE `cos 5° = 0.99619470`: smooth, bit 0
    // clear, `0b110 = 6`. At `α = 6°`, `cos α = 0.99452190` is below it: sharp, bit 0 set,
    // `0b111 = 7`. The gap to the threshold is `1.4e-3` on either side, four orders past
    // the `f32` noise on a normalised cross product, so neither verdict is a coin toss.
    const cases = [_]struct { cos_a: f32, sin_a: f32, flags: u8 }{
        .{ .cos_a = 0.9975640502598242, .sin_a = 0.06975647374412530, .flags = 0b110 }, // 4°
        .{ .cos_a = 0.9945218953682733, .sin_a = 0.10452846326765347, .flags = 0b111 }, // 6°
    };
    for (cases) |c| {
        var store = ShapeStore{};
        defer store.deinit(gpa);
        const verts = [_]ApiVec3{ av3(0, 0, 0), av3(1, 0, 0), av3(0, 1, 0), av3(0, -c.cos_a, -c.sin_a) };
        const idx = [_]u32{ 0, 1, 2, 1, 0, 3 };
        const id = try store.createShape(gpa, .{ .triangle_mesh = .{ .vertices = &verts, .indices = &idx } });
        const data = store.get(id).?.mesh.?;
        try testing.expectEqual(c.flags, data.edgeFlags(0));
        try testing.expectEqual(c.flags, data.edgeFlags(1));
    }

    // The SAME fold made concave — `D = (0, −cos α, +sin α)` — is inactive at 45°, an
    // angle far sharper than either case above. Sharpness alone does not make an edge
    // active; convexity does.
    {
        var store = ShapeStore{};
        defer store.deinit(gpa);
        const root_half: f32 = @sqrt(@as(f32, 2)) / 2;
        const verts = [_]ApiVec3{ av3(0, 0, 0), av3(1, 0, 0), av3(0, 1, 0), av3(0, -root_half, root_half) };
        const idx = [_]u32{ 0, 1, 2, 1, 0, 3 };
        const id = try store.createShape(gpa, .{ .triangle_mesh = .{ .vertices = &verts, .indices = &idx } });
        const data = store.get(id).?.mesh.?;
        try testing.expectEqual(@as(u8, 0b110), data.edgeFlags(0));
        try testing.expectEqual(@as(u8, 0b110), data.edgeFlags(1));
    }
}

test "pairing is order-independent" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);

    // The same square, with the two triangles emitted in the OTHER order. Permuting the
    // triangles permutes the flag array with them and changes nothing else: what was
    // `[3, 6]` becomes `[6, 3]`, bit for bit. A pairing that depended on traversal order,
    // or on a hashed container's iteration, would not reproduce that.
    const forward = [_]u32{ 0, 1, 2, 0, 2, 3 };
    const reversed = [_]u32{ 0, 2, 3, 0, 1, 2 };

    const a = try store.createShape(gpa, .{ .triangle_mesh = .{ .vertices = &square_vertices, .indices = &forward } });
    const b = try store.createShape(gpa, .{ .triangle_mesh = .{ .vertices = &square_vertices, .indices = &reversed } });
    const fa = store.get(a).?.mesh.?;
    const fb = store.get(b).?.mesh.?;

    try testing.expectEqual(fa.edgeFlags(0), fb.edgeFlags(1));
    try testing.expectEqual(fa.edgeFlags(1), fb.edgeFlags(0));
    try testing.expectEqual(@as(u8, 0b011), fa.edgeFlags(0));
    try testing.expectEqual(@as(u8, 0b110), fb.edgeFlags(0));

    // And a rebuild of the identical descriptor is bit-identical, which is the other half
    // of determinism: no hashed container, no address-dependent enumeration.
    const again = try store.createShape(gpa, .{ .triangle_mesh = .{ .vertices = &square_vertices, .indices = &forward } });
    try testing.expectEqualSlices(u8, fa.edge_flags, store.get(again).?.mesh.?.edge_flags);
}

/// Keeps the nearest triangle by its own box's entry parameter and TIGHTENS its bound on
/// every improvement — the collector shape a closest-hit query uses, and the only one
/// under which the branch-and-bound pruning is observable at all.
const NearestCollector = struct {
    data: *const MeshData,
    ray: broadphase_mod.Ray(Real),
    bound: Real,
    best_triangle: ?u32 = null,
    best_enter: Real = 0,

    pub fn add(self: *NearestCollector, triangle: u32) void {
        const iv = self.data.triangleAabb(triangle)
            .rayInterval(self.ray.origin, self.ray.inv_dir, self.ray.dir_is_zero) orelse return;
        if (iv.exit < 0) return;
        const enter = @max(iv.enter, 0);
        if (enter > self.bound) return;
        const better = self.best_triangle == null or enter < self.best_enter or
            (enter == self.best_enter and triangle < self.best_triangle.?);
        if (!better) return;
        self.best_triangle = triangle;
        self.best_enter = enter;
        self.bound = enter; // TIGHTEN — this is what prunes the rest of the walk
    }
    pub fn maxDistance(self: *const NearestCollector) Real {
        return self.bound;
    }
    pub fn shouldStop(_: *const NearestCollector) bool {
        return false;
    }
};

test "the ray bound prunes and still finds the nearest triangle" {
    const gpa = testing.allocator;

    // The agreement sweep above uses a collector that never tightens, deliberately: that
    // is what makes its brute-force comparison exact. But it therefore says nothing about
    // the BOUND, since a traversal that ignored `maxDistance()` entirely would pass it.
    // This is the other half — a tightening collector, whose two observables are the
    // ANSWER, which must not change, and the VISITED COUNT, which must fall.
    for ([_]u64{ 1, 2, 3, 5, 8 }) |seed| {
        var store = ShapeStore{};
        defer store.deinit(gpa);
        const id = try randomMesh(gpa, &store, seed, 150);
        const data = store.get(id).?.mesh.?;
        const n = data.triangleCount();

        var prng = std.Random.DefaultPrng.init(seed ^ 0xBEEF);
        const rand = prng.random();

        var total_bounded: u64 = 0;
        var total_unbounded: u64 = 0;
        var answered: u32 = 0;

        for (0..40) |_| {
            const target = data.triangleCentroid(rand.intRangeLessThan(u32, 0, n));
            const away = vr(
                rand.float(Real) * 2 - 1,
                rand.float(Real) * 2 - 1,
                rand.float(Real) * 2 - 1,
            );
            const offset = if (@reduce(.Max, @abs(away.data)) == 0) Vec3r.unit_x else away.scale(1 / away.length());
            const origin = target.add(offset.scale(30));
            const ray = broadphase_mod.Ray(Real).init(origin, offset.neg());
            const max_distance: Real = 60;

            // BRUTE FORCE: the nearest triangle by its own box, over all of them, with
            // the same `(enter, index)` tie-break the collector uses.
            var brute_best: ?u32 = null;
            var brute_enter: Real = 0;
            var t: u32 = 0;
            while (t < n) : (t += 1) {
                const iv = data.triangleAabb(t)
                    .rayInterval(ray.origin, ray.inv_dir, ray.dir_is_zero) orelse continue;
                if (iv.exit < 0) continue;
                const enter = @max(iv.enter, 0);
                if (enter > max_distance) continue;
                if (brute_best == null or enter < brute_enter or (enter == brute_enter and t < brute_best.?)) {
                    brute_best = t;
                    brute_enter = enter;
                }
            }

            var nearest = NearestCollector{ .data = data, .ray = ray, .bound = max_distance };
            total_bounded += data.traverseRay(ray, &nearest);
            try testing.expectEqual(brute_best, nearest.best_triangle);
            if (brute_best != null) {
                try testing.expectEqual(brute_enter, nearest.best_enter);
                answered += 1;
            }

            // The same rays with a collector that never tightens, as the cost baseline.
            const seen = try gpa.alloc(bool, n);
            defer gpa.free(seen);
            @memset(seen, false);
            var plain = MarkCollector{ .seen = seen, .bound = max_distance };
            total_unbounded += data.traverseRay(ray, &plain);
        }

        // Non-vacuous: the rays are aimed, so nearly all of them answer.
        try testing.expect(answered > 30);
        // And the bound really prunes. A traversal that never re-read `maxDistance()`
        // would visit exactly as many nodes in both runs, so this inequality is the
        // discrimination guard for branch and bound itself — AND for the near-first
        // descent order, which is the only reason the bound tightens early enough to
        // pay. Both counter-factuals were run: measured over the five seeds, near-first
        // visits 345 / 369 / 398 / 390 / 347 nodes against 450 / 442 / 487 / 453 / 422
        // unbounded, and inverting the descent to FAR-FIRST takes this very assertion
        // down at the first seed. An ordering defect is therefore not something this
        // suite merely hopes to catch.
        try testing.expect(total_bounded < total_unbounded);
    }
}

test "the descriptor default is the mesh constant, and it is f32 in both builds" {
    // ONE value, two declarations — the public default and the solver-side name — pinned
    // equal here, which is the only place that can see both (`api/` must not import the
    // solver). A drift between them would otherwise be silent.
    const verts = one_triangle_vertices;
    const idx = one_triangle_indices;
    const d = api.ShapeDescriptor{ .triangle_mesh = .{ .vertices = &verts, .indices = &idx } };
    try testing.expectEqual(mesh_mod.default_active_edge_cos_threshold, d.triangle_mesh.active_edge_cos_threshold);

    // `f32` and NOT `Real`, and the assertion is on the TYPE because that is the defect:
    // typed `Real` the constant renders as `0.9961947202682495` in an `f32` build and
    // `0.9961946980917455` in an `f64` one, so the same authored mesh would be classified
    // against two different thresholds depending on how the engine was compiled. The
    // value is therefore pinned as an exact `f32` bit pattern, identical in both builds.
    try testing.expectEqual(f32, @TypeOf(mesh_mod.default_active_edge_cos_threshold));
    try testing.expectEqual(f32, @TypeOf(d.triangle_mesh.active_edge_cos_threshold));
    try testing.expectEqual(
        @as(u32, @bitCast(@as(f32, 0.9961947202682495))),
        @as(u32, @bitCast(mesh_mod.default_active_edge_cos_threshold)),
    );
    // And the widening the solver performs is EXACT — `Real` back to `f32` round-trips.
    const widened: Real = mesh_mod.default_active_edge_cos_threshold;
    try testing.expectEqual(mesh_mod.default_active_edge_cos_threshold, @as(f32, @floatCast(widened)));
}

test "a caller-supplied threshold changes the classification in both directions" {
    const gpa = testing.allocator;

    // The same two folds as the threshold test above, driven by the DESCRIPTOR's field
    // rather than by the default. This is what makes the parameter configurable at all:
    // `createShape` is the only path to the flags, so without the field there would be no
    // way to reach them, and after the M1.1.15 freeze there could be none.
    //
    // `A(0,0,0)`, `B(1,0,0)`, `C(0,1,0)`, `D(0, −cos α, −sin α)`; the shared edge `(0,1)`
    // is edge 0 of both triangles, so the verdict lands in bit 0 and the four boundary
    // edges are always active: SMOOTH reads `0b110 = 6`, SHARP reads `0b111 = 7`.
    //
    // A 4° fold, `cos α = 0.99756405`:
    //   against `cos 5° = 0.99619472` it is smoother than required → INACTIVE;
    //   against `cos 3° = 0.99862953` it is sharper than required → ACTIVE.
    // A 6° fold, `cos α = 0.99452190`:
    //   against `cos 5°` → ACTIVE;
    //   against `cos 8° = 0.99026807` → INACTIVE.
    // So the field moves the verdict in BOTH directions, on BOTH folds — a field that was
    // read but ignored, or read only in one branch, fails half of these.
    const cos5: f32 = 0.99619472;
    const cos3: f32 = 0.9986295347545738;
    const cos8: f32 = 0.9902680687415704;
    const cases = [_]struct { cos_a: f32, sin_a: f32, threshold: f32, flags: u8 }{
        .{ .cos_a = 0.9975640502598242, .sin_a = 0.06975647374412530, .threshold = cos5, .flags = 0b110 },
        .{ .cos_a = 0.9975640502598242, .sin_a = 0.06975647374412530, .threshold = cos3, .flags = 0b111 },
        .{ .cos_a = 0.9945218953682733, .sin_a = 0.10452846326765347, .threshold = cos5, .flags = 0b111 },
        .{ .cos_a = 0.9945218953682733, .sin_a = 0.10452846326765347, .threshold = cos8, .flags = 0b110 },
    };
    for (cases) |c| {
        var store = ShapeStore{};
        defer store.deinit(gpa);
        const verts = [_]ApiVec3{ av3(0, 0, 0), av3(1, 0, 0), av3(0, 1, 0), av3(0, -c.cos_a, -c.sin_a) };
        const idx = [_]u32{ 0, 1, 2, 1, 0, 3 };
        const id = try store.createShape(gpa, .{ .triangle_mesh = .{
            .vertices = &verts,
            .indices = &idx,
            .active_edge_cos_threshold = c.threshold,
        } });
        const data = store.get(id).?.mesh.?;
        try testing.expectEqual(c.flags, data.edgeFlags(0));
        try testing.expectEqual(c.flags, data.edgeFlags(1));
    }
}

// ---------------------------------------------------------------------------
// The ray family through a mesh
// ---------------------------------------------------------------------------

const harness = @import("solver_test.zig");
const narrowphase = @import("../pipeline/narrowphase/root.zig");

/// Three parallel triangles in the YZ plane at `x = 2`, `4`, `6`, each spanning
/// `y, z ∈ [−1, 1]` around the axis — so a ray along `+X` through the origin crosses ALL
/// THREE. Wound so the outward normal is `−X`, i.e. facing the incoming ray.
///
/// `v₀ = (x, −1, −1)`, `v₁ = (x, −1, 1)`, `v₂ = (x, 1, −1)`:
/// `(v₁−v₀) × (v₂−v₀) = (0,0,2) × (0,2,0) = (0·0 − 2·2, 2·0 − 0·0, 0·2 − 0·0) = (−4, 0, 0)`,
/// so the normal is `(−1, 0, 0)` — exactly, the cross product being a pure axis vector.
/// The point `(x, 0, 0)` is inside each triangle (`u = v = 0.5`, on the hypotenuse).
const wall_vertices = [_]ApiVec3{
    av3(2, -1, -1), av3(2, -1, 1), av3(2, 1, -1),
    av3(4, -1, -1), av3(4, -1, 1), av3(4, 1, -1),
    av3(6, -1, -1), av3(6, -1, 1), av3(6, 1, -1),
};
const wall_indices = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7, 8 };

/// A static body carrying the three-wall mesh, at the world origin, on layer `layer`.
fn addWallMesh(gpa: std.mem.Allocator, world: *harness.World, layer: u8, entity: u32) !api.BodyId {
    const shape = try world.store.createShape(gpa, .{ .triangle_mesh = .{
        .vertices = &wall_vertices,
        .indices = &wall_indices,
    } });
    return world.addBody(gpa, .{
        .shape = shape,
        .body_type = .static,
        .collision_layer = layer,
        .entity = entityOf(entity),
    });
}

test "raycast hits the nearest triangle and reports its index" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    const body = try addWallMesh(gpa, &world, 0, 0);

    // The ray runs from the origin along `+X`. The three walls sit at `x = 2`, `4`, `6`,
    // so the nearest is the FIRST triangle of the index array — index 0 — at distance
    // EXACTLY 2, with the outward normal `(−1, 0, 0)` exactly.
    const q = query.RayQuery{ .origin = Vec3r.zero, .direction = Vec3r.unit_x, .max_distance = 100 };
    const hit = query.raycast(&world.bp, &world.bm, &world.store, q).?;
    try testing.expectEqual(body, hit.body);
    try testing.expectEqual(@as(Real, 2), hit.distance);
    try testing.expect(hit.normal.eql(vr(-1, 0, 0)));
    try testing.expect(hit.position.eql(vr(2, 0, 0)));
    // The `subshape_id` IS the triangle index (§1.11.16: a mesh is root, so its path is
    // that index), and it is 0 here because the nearest wall is the first triangle.
    try testing.expectEqual(@as(u32, 0), hit.subshape_id);

    // Fired from the far side, the nearest wall is the LAST triangle — index 2 — and the
    // index therefore discriminates: a `subshape_id` left at its default would answer 0
    // here too, and this is the assertion that catches it.
    const back = query.RayQuery{
        .origin = vr(10, 0, 0),
        .direction = vr(-1, 0, 0),
        .max_distance = 100,
        // The walls face `−X`, so from `+X` they are met from BEHIND.
        .back_face_mode = .collide,
    };
    const back_hit = query.raycast(&world.bp, &world.bm, &world.store, back).?;
    try testing.expectEqual(@as(Real, 4), back_hit.distance); // 10 − 6
    try testing.expectEqual(@as(u32, 2), back_hit.subshape_id);

    // And the MIDDLE wall is reachable, so all three indices are observable rather than
    // just the two extremes: starting past the first wall, the nearest is index 1.
    const mid = query.RayQuery{ .origin = vr(3, 0, 0), .direction = Vec3r.unit_x, .max_distance = 100 };
    const mid_hit = query.raycast(&world.bp, &world.bm, &world.store, mid).?;
    try testing.expectEqual(@as(Real, 1), mid_hit.distance); // 4 − 3
    try testing.expectEqual(@as(u32, 1), mid_hit.subshape_id);
}

test "raycastAll returns one entry per body, not one per triangle" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    const mesh_body = try addWallMesh(gpa, &world, 0, 0);

    // The ray crosses THREE triangles of ONE body. `raycastAll` must answer with ONE
    // entry, the nearest accepted triangle, and it is not an optimisation: §1.11.14's key
    // `(distance, entity, BodyId)` does not discriminate two triangles of one body, so two
    // entries would be neither ordered nor invariant and their truncation arbitrary.
    var buf: [8]query.RayHit = undefined;
    const q = query.RayQuery{ .origin = Vec3r.zero, .direction = Vec3r.unit_x, .max_distance = 100 };
    const n = query.raycastAll(&world.bp, &world.bm, &world.store, q, &buf);
    try testing.expectEqual(@as(u32, 1), n);
    try testing.expectEqual(mesh_body, buf[0].body);
    try testing.expectEqual(@as(Real, 2), buf[0].distance);
    try testing.expectEqual(@as(u32, 0), buf[0].subshape_id);

    // A SECOND mesh body further along gives two entries — one per BODY — which is what
    // shows the rule is per body and not "at most one entry ever". Placed at `x = 20`, its
    // nearest wall is at `20 + 2 = 22`.
    const second_shape = try world.store.createShape(gpa, .{ .triangle_mesh = .{
        .vertices = &wall_vertices,
        .indices = &wall_indices,
    } });
    _ = try world.addBody(gpa, .{
        .shape = second_shape,
        .body_type = .static,
        .position = harness.av3(20, 0, 0),
        .entity = entityOf(1),
    });
    const two = query.raycastAll(&world.bp, &world.bm, &world.store, q, &buf);
    try testing.expectEqual(@as(u32, 2), two);
    try testing.expectEqual(@as(Real, 2), buf[0].distance);
    try testing.expectEqual(@as(Real, 22), buf[1].distance);

    // `raycastAny` stops at the first accepted candidate; `raycast` agrees with the
    // truncated `all`.
    try testing.expect(query.raycastAny(&world.bp, &world.bm, &world.store, q));
    const closest = query.raycast(&world.bp, &world.bm, &world.store, q).?;
    try testing.expectEqual(buf[0].body, closest.body);
    try testing.expectEqual(buf[0].distance, closest.distance);
    try testing.expectEqual(buf[0].subshape_id, closest.subshape_id);
}

test "a ray from behind is ignored by default and hit under collide" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    _ = try addWallMesh(gpa, &world, 0, 0);

    // The three walls face `−X`. A ray travelling `−X` from `x = 10` therefore meets every
    // one of them from BEHIND: `n · direction = (−1,0,0) · (−1,0,0) = +1 > 0`.
    const from_behind = query.RayQuery{
        .origin = vr(10, 0, 0),
        .direction = vr(-1, 0, 0),
        .max_distance = 100,
    };
    // DEFAULT is `.ignore`: nothing answers, on all three entries.
    try testing.expect(query.raycast(&world.bp, &world.bm, &world.store, from_behind) == null);
    try testing.expect(!query.raycastAny(&world.bp, &world.bm, &world.store, from_behind));
    var buf: [8]query.RayHit = undefined;
    try testing.expectEqual(@as(u32, 0), query.raycastAll(&world.bp, &world.bm, &world.store, from_behind, &buf));

    // Under `.collide` the SAME geometry answers, at the nearest wall — `10 − 6 = 4`.
    var collide = from_behind;
    collide.back_face_mode = .collide;
    const hit = query.raycast(&world.bp, &world.bm, &world.store, collide).?;
    try testing.expectEqual(@as(Real, 4), hit.distance);
    try testing.expectEqual(@as(u32, 2), hit.subshape_id);
    try testing.expect(query.raycastAny(&world.bp, &world.bm, &world.store, collide));
    try testing.expectEqual(@as(u32, 1), query.raycastAll(&world.bp, &world.bm, &world.store, collide, &buf));

    // And a FRONT hit answers in both modes, which is what keeps the two assertions above
    // from passing under a predicate that simply rejects everything.
    const from_front = query.RayQuery{ .origin = Vec3r.zero, .direction = Vec3r.unit_x, .max_distance = 100 };
    var front_collide = from_front;
    front_collide.back_face_mode = .collide;
    try testing.expectEqual(
        @as(Real, 2),
        query.raycast(&world.bp, &world.bm, &world.store, from_front).?.distance,
    );
    try testing.expectEqual(
        @as(Real, 2),
        query.raycast(&world.bp, &world.bm, &world.store, front_collide).?.distance,
    );
}

test "a back-face hit returns a flipped normal" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    _ = try addWallMesh(gpa, &world, 0, 0);

    // §1.11.4 declares `normal · direction <= 0` on EVERY hit, and the `−direction` choice
    // at distance zero draws its justification from it. A back-face hit returning the
    // outward normal unchanged would give `+1` and puncture it. So the returned normal is
    // `−n = (+1, 0, 0)` against a `−X` ray, exactly.
    var collide = query.RayQuery{
        .origin = vr(10, 0, 0),
        .direction = vr(-1, 0, 0),
        .max_distance = 100,
    };
    collide.back_face_mode = .collide;
    const back = query.raycast(&world.bp, &world.bm, &world.store, collide).?;
    try testing.expect(back.normal.eql(vr(1, 0, 0)));
    try testing.expectEqual(@as(Real, -1), back.normal.dot(collide.direction));

    // The FRONT hit keeps the outward normal, and the invariant holds there too — which is
    // what shows the flip is conditional on the facing and not applied blindly.
    const front = query.RayQuery{ .origin = Vec3r.zero, .direction = Vec3r.unit_x, .max_distance = 100 };
    const front_hit = query.raycast(&world.bp, &world.bm, &world.store, front).?;
    try testing.expect(front_hit.normal.eql(vr(-1, 0, 0)));
    try testing.expectEqual(@as(Real, -1), front_hit.normal.dot(front.direction));

    // The invariant asserted on EVERY hit of a sweep over both modes and many directions,
    // oblique included, and on the norm as well: unit tight, everywhere.
    var prng = std.Random.DefaultPrng.init(0x51DE);
    const rand = prng.random();
    var hits: u32 = 0;
    for (0..200) |_| {
        const raw = vr(
            rand.float(Real) * 2 - 1,
            rand.float(Real) * 2 - 1,
            rand.float(Real) * 2 - 1,
        );
        if (@reduce(.Max, @abs(raw.data)) == 0) continue;
        const direction = raw.scale(1 / raw.length());
        const origin = vr(4, 0, 0).sub(direction.scale(20));
        inline for (.{ api.BackFaceMode.ignore, api.BackFaceMode.collide }) |mode| {
            const q = query.RayQuery{
                .origin = origin,
                .direction = direction,
                .max_distance = 100,
                .back_face_mode = mode,
            };
            if (query.raycast(&world.bp, &world.bm, &world.store, q)) |h| {
                hits += 1;
                try testing.expect(h.normal.dot(direction) <= 0);
                try testing.expect(@abs(h.normal.lengthSq() - 1) <= 8 * std.math.floatEps(Real));
            }
        }
    }
    // Non-vacuous: the rays are aimed at the middle wall from 20 m out, so most connect.
    try testing.expect(hits > 100);
}

test "a grazing ray is refused at true zero" {
    const T = Real;
    const V = Vec3r;
    // The kernel grain, in the triangle's own frame — the only grain at which "exactly
    // parallel" is expressible, since a rigid transform does not preserve exact
    // orthogonality (§1.11.15's frame-local corollary, which applies verbatim here).
    //
    // The triangle lies in the XY plane with normal `+Z`. A ray along `+X` at `z = 0` is
    // EXACTLY parallel to the plane: `det = −d · n = 0` exactly, since `d` has no Z
    // component and `n` is a pure `+Z`. The guard is at TRUE ZERO and the answer is a
    // miss — in the plane and out of it alike.
    const tri = [3]V{ vr(0, 0, 0), vr(1, 0, 0), vr(0, 1, 0) };
    try testing.expect(narrowphase.triangle.rayTriangle(T, tri, vr(-1, 0.25, 0), Vec3r.unit_x) == null);
    try testing.expect(narrowphase.triangle.rayTriangle(T, tri, vr(-1, 0.25, 5), Vec3r.unit_x) == null);

    // A ray ONE ULP off parallel is NOT refused — it is served, which is what shows the
    // guard absorbs nothing but an exact zero. To hit at all it must start within an ULP
    // of the plane: with `d_z ≈ floatEps` and the origin at `z = −floatEps`, the crossing
    // is at `t ≈ 1`, and the ray is then still inside the triangle's footprint.
    const tilt = std.math.floatEps(T);
    const near_parallel = vr(1, 0, tilt).normalize();
    const served = narrowphase.triangle.rayTriangle(T, tri, vr(-0.5, 0.25, -tilt), near_parallel);
    try testing.expect(served != null);
    try testing.expect(served.?.distance > 0.9 and served.?.distance < 1.1);

    // **A TRIANGLE IS NOT A HALF-SPACE HERE, and the difference is worth stating.**
    // §1.11.15 records that a near-parallel ray against a plane crosses at
    // `sep / floatEps`, an enormous distance the entry's finite `max_distance` is what
    // rejects. Against a triangle the BARYCENTRIC bound rejects it first: to travel far
    // enough along the near-parallel direction to reach the plane, the ray leaves the
    // triangle's footprint, so the answer is an ordinary miss and no bound is needed.
    // Measured on this very case — the same direction, an origin half a unit below the
    // plane instead of an ULP.
    try testing.expect(narrowphase.triangle.rayTriangle(T, tri, vr(-1, 0.25, -0.5), near_parallel) == null);
}

test "an oblique far-field configuration keeps a unit normal" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);

    // §1.11.17: the ratio that governs a triangle's orientation error is its EDGE LENGTH
    // against its own offset from the SHAPE'S LOCAL ORIGIN — not against the world origin,
    // which the body pose absorbs. So the case is a small triangle authored FAR OUT IN
    // LOCAL COORDINATES, and the degradation is a quantisation of the DESCRIPTOR: at
    // `L = 2¹⁸ = 262144` the `f32` grid spacing is `2¹⁸⁻²³ = 0.03125`, so an intended edge
    // of length 1 lands on that grid and its direction is perturbed by up to
    // `floatEps(f32) · L / 1 = 0.03125`.
    //
    // Intended: `v₀ = (L, 0, 0)`, `v₁ = v₀ + (0.6, 0.8, 0)`, `v₂ = v₀ + (0, 0, 1)`, whose
    // cross product `(0.6,0.8,0) × (0,0,1) = (0.8·1 − 0, 0 − 0.6·1, 0) = (0.8, −0.6, 0)` is
    // EXACTLY unit. That is the normal the stored triangle approximates.
    const l: f32 = 262144;
    const far_vertices = [_]ApiVec3{ av3(l, 0, 0), av3(l + 0.6, 0.8, 0), av3(l, 0, 1) };
    const far = try store.createShape(gpa, .{ .triangle_mesh = .{
        .vertices = &far_vertices,
        .indices = &one_triangle_indices,
    } });
    const far_normal = store.get(far).?.mesh.?.faceNormal(0);

    // THE NORM IS ASSERTED TIGHT, AND EVERYWHERE. It is a structural invariant — the
    // kernel normalises — so a short or degenerate normal is always a defect and never an
    // effect of distance (§1.11.4 bis). No distance-dependent slack here.
    try testing.expect(@abs(far_normal.lengthSq() - 1) <= 8 * std.math.floatEps(Real));

    // Only the ORIENTATION carries the residue, and its bound is the ratio above. Both
    // bounds below are expressed in the DESCRIPTOR's precision, `floatEps(f32)`, and not in
    // `Real`'s — the quantisation happens where the vertices are authored, so these numbers
    // are the SAME in an `f32` and an `f64` build, which is also why one bound serves both.
    const intended = vr(0.8, -0.6, 0);
    const far_error = far_normal.sub(intended).length();
    const bound: Real = 4 * std.math.floatEps(f32) * l;
    try testing.expect(far_error <= bound);

    // DISCRIMINATION GUARD: the same intended triangle authored AT the local origin has an
    // orientation error some five orders smaller. Without this the bound above would pass
    // just as well on an implementation whose normals were exact, and the test would be
    // measuring nothing about the far field.
    const near_vertices = [_]ApiVec3{ av3(0, 0, 0), av3(0.6, 0.8, 0), av3(0, 0, 1) };
    const near = try store.createShape(gpa, .{ .triangle_mesh = .{
        .vertices = &near_vertices,
        .indices = &one_triangle_indices,
    } });
    const near_normal = store.get(near).?.mesh.?.faceNormal(0);
    try testing.expect(@abs(near_normal.lengthSq() - 1) <= 8 * std.math.floatEps(Real));
    const near_envelope: Real = 8 * std.math.floatEps(f32);
    const near_error = near_normal.sub(intended).length();
    try testing.expect(near_error <= near_envelope);
    // The far error is REAL: two orders of magnitude past the whole near-field ENVELOPE,
    // so the bound above is not slack absorbing nothing. Compared against the envelope
    // rather than against `near_error` itself, which is exactly zero at `f32` — where the
    // quantised `(0.8, −0.6)` and the literal one are the same `f32` value — and would make
    // a ratio test degenerate.
    try testing.expect(far_error > 100 * near_envelope);
    try testing.expect(far_error > near_error);

    // A ray fired OBLIQUELY at the far triangle still hits it, and its normal is unit and
    // opposes the ray — the far field degrades the orientation, never the norm and never
    // the hit itself (§1.11.4 bis: a sweep that skips the non-hits lets the false negatives
    // it is meant to find go by).
    // OBLIQUE TO THIS TRIANGLE'S PLANE, which is not the same thing as oblique to the
    // axes. This triangle's normal is `≈ (0.803, −0.596, 0)` — it has no Z component at all,
    // `v₀` and `v₂` differing only in Z — so a direction dominated by `−Z` would be nearly
    // PARALLEL to the plane and the test would measure the grazing regime instead of the
    // far field. Measured on the first attempt, `(−0.4, −0.5, −0.7)` gave a determinant of
    // `0.025`, a 40× amplification of the centroid's own quantisation, and an ordinary miss.
    // `(−0.7, 0.5, −0.5)` has `n · d ≈ −0.84`: oblique on all three axes AND well
    // conditioned against the plane.
    const target = store.get(far).?.mesh.?.triangleCentroid(0);
    const oblique = vr(-0.7, 0.5, -0.5).normalize();
    const ray_hit = narrowphase.triangle.rayTriangle(
        Real,
        store.get(far).?.mesh.?.triangle(0),
        target.sub(oblique.scale(50)),
        oblique,
    );
    try testing.expect(ray_hit != null);
    try testing.expect(@abs(ray_hit.?.normal.lengthSq() - 1) <= 8 * std.math.floatEps(Real));
    const oriented = narrowphase.triangle.localHit(Real, ray_hit.?, 0);
    try testing.expect(oriented.normal.dot(oblique) <= 0);
}

test "the ray family agrees exactly with brute force over the mesh" {
    const gpa = testing.allocator;

    // The QUERY-level answer against a brute force over every triangle, on several seeds
    // and in BOTH back-face modes. The oracle runs the same kernel the traversal runs, in
    // the body's local frame, over all triangles with no tree at all — so what is being
    // compared is the TRAVERSAL and the nearest-triangle selection, not the kernel against
    // itself.
    for ([_]u64{ 11, 22, 33, 44, 55 }) |seed| {
        var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
        defer world.deinit(gpa);
        const shape = try randomMesh(gpa, &world.store, seed, 120);
        const body = try world.addBody(gpa, .{
            .shape = shape,
            .body_type = .static,
            .entity = entityOf(0),
        });
        const data = world.store.get(shape).?.mesh.?;
        const n = data.triangleCount();

        var prng = std.Random.DefaultPrng.init(seed ^ 0xA5A5);
        const rand = prng.random();
        var answered: u32 = 0;

        for (0..60) |_| {
            const target = data.triangleCentroid(rand.intRangeLessThan(u32, 0, n));
            const away = vr(
                rand.float(Real) * 2 - 1,
                rand.float(Real) * 2 - 1,
                rand.float(Real) * 2 - 1,
            );
            if (@reduce(.Max, @abs(away.data)) == 0) continue;
            const offset = away.scale(1 / away.length());
            const origin = target.add(offset.scale(30));
            // The direction the ENTRY will use, and the query is given the RAW one so the
            // entry normalises exactly ONCE. Two traps here, both measured rather than
            // reasoned about: `prepare` re-normalises whatever it is handed, and
            // `unitDirection(unitDirection(x))` is not `unitDirection(x)` — feeding an
            // already-normalised direction makes the oracle and the entry work on values one
            // ULP apart, which showed up as `29.999998` against `29.999996` on the SAME
            // triangle. So the oracle applies the entry's own normalisation, once, to the
            // same raw input the entry receives.
            const raw_direction = offset.neg();
            const direction = query.unitDirection(raw_direction).?;
            const max_distance: Real = 60;

            inline for (.{ api.BackFaceMode.ignore, api.BackFaceMode.collide }) |mode| {
                // BRUTE FORCE: every triangle, the same kernel, the same accept rule, and
                // the same `(distance, triangle index)` tie-break the collector uses.
                //
                // The ray is transported into the body's LOCAL frame exactly as the adapter
                // transports it — the same conjugate rotation, the same subtraction. Not a
                // detail: a conjugate rotation by the identity quaternion is not bit-neutral,
                // so transporting differently makes the two distances disagree in the last
                // bits and turns an exact comparison into noise. With the transport shared,
                // what remains under test is precisely the TRAVERSAL and the
                // nearest-triangle selection — which is what this oracle is for.
                const inv_rot = world.bm.rotation(body).?.conjugate();
                const local_origin = inv_rot.rotateVec3(origin.sub(world.bm.position(body).?));
                const local_direction = inv_rot.rotateVec3(direction);
                var brute_best: ?u32 = null;
                var brute_distance: Real = 0;
                var t: u32 = 0;
                while (t < n) : (t += 1) {
                    const hit = narrowphase.triangle.rayTriangle(
                        Real,
                        data.triangle(t),
                        local_origin,
                        local_direction,
                    ) orelse continue;
                    if (hit.back_face and mode == .ignore) continue;
                    if (hit.distance > max_distance) continue;
                    if (brute_best == null or hit.distance < brute_distance or
                        (hit.distance == brute_distance and t < brute_best.?))
                    {
                        brute_best = t;
                        brute_distance = hit.distance;
                    }
                }

                const q = query.RayQuery{
                    .origin = origin,
                    .direction = raw_direction,
                    .max_distance = max_distance,
                    .back_face_mode = mode,
                };
                const got = query.raycast(&world.bp, &world.bm, &world.store, q);
                if (brute_best) |expected| {
                    try testing.expect(got != null);
                    try testing.expectEqual(body, got.?.body);
                    try testing.expectEqual(expected, got.?.subshape_id);
                    try testing.expectEqual(brute_distance, got.?.distance);
                    // `any` must agree on EXISTENCE, and `all` on the nearest entry — one
                    // per body — so a traversal that lost the nearest triangle could not
                    // pass all three.
                    try testing.expect(query.raycastAny(&world.bp, &world.bm, &world.store, q));
                    var buf: [4]query.RayHit = undefined;
                    try testing.expectEqual(@as(u32, 1), query.raycastAll(&world.bp, &world.bm, &world.store, q, &buf));
                    try testing.expectEqual(expected, buf[0].subshape_id);
                    if (mode == .ignore) answered += 1;
                } else {
                    try testing.expect(got == null);
                    try testing.expect(!query.raycastAny(&world.bp, &world.bm, &world.store, q));
                }
            }
        }
        // Non-vacuous: the rays are aimed at triangle centroids, so `.ignore` — the
        // stricter mode — still answers most of them. A suite of misses would agree with
        // brute force on the empty set and prove nothing.
        try testing.expect(answered > 20);
    }
}

test "the frozen query surface carries the back-face mode and a filled subshape id" {
    // Field NAMES, TYPES and defaults are the contract, and this pin EXTENDS the M1.1.9 /
    // M1.1.10 one field by field rather than replacing any part of it.
    const ray = api.RaycastQuery{ .origin = ApiVec3.zero, .direction = ApiVec3.unit_x, .max_distance = 10 };
    try testing.expectEqual(api.BackFaceMode.ignore, ray.back_face_mode);
    try testing.expectEqual(api.BackFaceMode, @TypeOf(ray.back_face_mode));
    // `u8`-backed with `ignore` first, so the DEFAULT is the zero value — the same
    // discipline `BodyType` and `ShapeType` follow.
    try testing.expectEqual(@as(u8, 0), @intFromEnum(api.BackFaceMode.ignore));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(api.BackFaceMode.collide));
    try testing.expectEqual(u8, @typeInfo(api.BackFaceMode).@"enum".tag_type);
    // Exactly TWO states. A third would be a silent widening of a frozen surface.
    try testing.expectEqual(@as(usize, 2), @typeInfo(api.BackFaceMode).@"enum".fields.len);

    // The two entries that do NOT carry it yet are named here so their absence is a
    // DECISION and not an omission: `overlapAabb` sees no triangle, `pointQuery` never
    // returns a mesh, and `closestPoint`'s distance to a surface is not signed (§1.11.17).
    // `ShapeCastQuery` and `OverlapQuery` DO carry it in the spec and gain it with the
    // entries that read it.
    try testing.expect(!@hasField(api.ClosestPointResult, "back_face_mode"));

    // `subshape_id` still DEFAULTS to 0 — the public default is unchanged — and the solver
    // mirror carries it at the same name. What changed is that something finally writes it.
    const hit = api.RaycastHit{
        .entity = entityOf(0),
        .body = 0,
        .position = ApiVec3.zero,
        .normal = ApiVec3.unit_y,
        .distance = 1,
    };
    try testing.expectEqual(@as(u32, 0), hit.subshape_id);
    try testing.expectEqual(u32, @TypeOf(hit.subshape_id));
    const solver_hit = query.RayHit{
        .body = 0,
        .entity = entityOf(0),
        .position = Vec3r.zero,
        .normal = Vec3r.unit_y,
        .distance = 1,
    };
    try testing.expectEqual(@as(u32, 0), solver_hit.subshape_id);
    // And the kernel-level `LocalHit` gained it too, which is where the value comes from.
    const local: narrowphase.LocalHit(Real) = .{ .distance = 0, .normal = Vec3r.unit_y };
    try testing.expectEqual(@as(u32, 0), local.subshape_id);
}

// ---------------------------------------------------------------------------
// The five remaining entries
// ---------------------------------------------------------------------------

/// The unit cube `[−1, 1]³` as twelve triangles, every one wound counter-clockwise seen
/// from OUTSIDE so its outward normal points away from the centre. A CLOSED surface — which
/// is what makes it the witness for the categorical rules: it encloses a volume, and the
/// engine still refuses to call any point of that volume "inside".
///
/// Face by face, with the cross product `(v₁−v₀) × (v₂−v₀)` checked on the first triangle
/// of each: `−Z` gives `(0,2,0) × (2,2,0) = (0,0,−4)`; `+Z` gives `(2,0,0) × (2,2,0) =
/// `(0,0,4)`; `−X` gives `(0,0,2) × (0,2,2) = (−4,0,0)`; `+X` gives `(0,2,0) × (0,2,2) =
/// `(4,0,0)`; `−Y` gives `(2,0,0) × (2,0,2) = (0,−4,0)`; `+Y` gives `(0,0,2) × (2,0,2) =
/// `(0,4,0)`.
const cube_vertices = [_]ApiVec3{
    av3(-1, -1, -1), av3(1, -1, -1), av3(1, 1, -1), av3(-1, 1, -1),
    av3(-1, -1, 1),  av3(1, -1, 1),  av3(1, 1, 1),  av3(-1, 1, 1),
};
const cube_indices = [_]u32{
    0, 3, 2, 0, 2, 1, // −Z
    4, 5, 6, 4, 6, 7, // +Z
    0, 4, 7, 0, 7, 3, // −X
    1, 2, 6, 1, 6, 5, // +X
    0, 1, 5, 0, 5, 4, // −Y
    3, 7, 6, 3, 6, 2, // +Y
};

/// A static body carrying the closed cube mesh, at the world origin.
fn addCubeMesh(gpa: std.mem.Allocator, world: *harness.World, layer: u8, entity: u32) !api.BodyId {
    const shape = try world.store.createShape(gpa, .{ .triangle_mesh = .{
        .vertices = &cube_vertices,
        .indices = &cube_indices,
    } });
    return world.addBody(gpa, .{
        .shape = shape,
        .body_type = .static,
        .collision_layer = layer,
        .entity = entityOf(entity),
    });
}

test "shapeCast against a mesh gives the closed-form time of impact" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    const body = try addCubeMesh(gpa, &world, 0, 0);

    // Each probe is swept along `+X` from `x = −10` through the origin. The cube's `−X` face
    // is at `x = −1`, so contact happens when the probe's own extent along `−X` reaches it:
    //   sphere `r = 0.5`   → centre at `−1.5` → distance `−1.5 − (−10) = 8.5`
    //   box `he = 0.5`     → face at `−1.5`   → distance `8.5`
    //   capsule `r = 0.3`  → radial extent 0.3, so centre at `−1.3` → distance `8.7`
    // The expected value is `9 − extent` where `extent` is the probe's reach along `−X`, and
    // it is taken from the DESCRIPTOR's own `f32` field rather than written as a decimal.
    // Measured at f64: `0.3` is not binary-exact, so `f32(0.3) = 0.30000001192092896` and the
    // true answer is `8.699999988079071` — a decimal `8.7` fails by `1.2e-8`, which is the
    // descriptor's quantisation and not the kernel's error. Same class as the far-field bound:
    // a closed form over `f32` inputs must be computed from the `f32` values.
    const probes = [_]struct { desc: api.ShapeDescriptor, x_extent: f32 }{
        .{ .desc = .{ .sphere = .{ .radius = 0.5 } }, .x_extent = 0.5 },
        .{ .desc = .{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } }, .x_extent = 0.5 },
        // A capsule's `half_height` is along `+Y` and contributes nothing along `+X`, which is
        // why its answer differs from the sphere's: reading the extent off the wrong axis
        // would give `0.5` here too.
        .{ .desc = .{ .capsule = .{ .radius = 0.3, .half_height = 0.5 } }, .x_extent = 0.3 },
    };
    // The cast kernel is an iterative march, so the time of impact converges rather than
    // landing bit-exact: the tolerance is the kernel's own convergence budget at unit scale,
    // not a geometric slack.
    const cast_tol: Real = if (Real == f32) 1e-4 else 1e-9;
    for (probes) |probe| {
        const shape = try world.store.createShape(gpa, probe.desc);
        const hit = (try query.shapeCast(&world.bp, &world.bm, &world.store, .{
            .shape = shape,
            .origin = vr(-10, 0, 0),
            .direction = Vec3r.unit_x,
            .max_distance = 100,
        })).?;
        try testing.expectEqual(body, hit.body);
        try testing.expectApproxEqAbs(9 - @as(Real, probe.x_extent), hit.distance, cast_tol);
        // The normal FACES the sweep on every hit (§1.11.4), and the `−X` face's outward
        // normal is `(−1, 0, 0)`, which already does.
        try testing.expect(hit.normal.dot(Vec3r.unit_x) <= 0);
        // The sub-shape is a real triangle index, in range and NOT the default. The index
        // array lists the faces in order `−Z, +Z, −X, +X, −Y, +Y`, two triangles each, so the
        // `−X` face is triangles 4 and 5.
        try testing.expect(hit.subshape_id == 4 or hit.subshape_id == 5);

        // RECEDING: the same probe cast the other way never reaches the cube.
        try testing.expect((try query.shapeCast(&world.bp, &world.bm, &world.store, .{
            .shape = shape,
            .origin = vr(-10, 0, 0),
            .direction = vr(-1, 0, 0),
            .max_distance = 100,
        })) == null);

        // A ZERO DIRECTION is degenerate, not malformed: the guard is at TRUE ZERO and the
        // answer is an empty result rather than an error (§1.11.11's domain table).
        try testing.expect((try query.shapeCast(&world.bp, &world.bm, &world.store, .{
            .shape = shape,
            .origin = vr(-10, 0, 0),
            .direction = Vec3r.zero,
            .max_distance = 100,
        })) == null);
    }

    // GRAZING, as a pair either side of the tangency so the verdict is a GEOMETRIC one and
    // not a threshold's. A sphere of radius 0.5 swept along `+X` clears the cube exactly when
    // its lowest point stays above the `+Y` face at `y = 1`, i.e. when its centre is above
    // `1.5`:
    //   centre `y = 1.55` → lowest point `1.05 > 1` → MISS
    //   centre `y = 1.45` → lowest point `0.95 < 1` → HIT
    // The two are 0.1 apart, five orders past any float noise at this scale, so neither
    // verdict is a coin toss. The exact tangency at `1.5` is a measure-zero configuration the
    // M1.1.2 classification notes already document and is deliberately not asserted.
    const grazer = try world.store.createShape(gpa, .{ .sphere = .{ .radius = 0.5 } });
    try testing.expect((try query.shapeCast(&world.bp, &world.bm, &world.store, .{
        .shape = grazer,
        .origin = vr(-10, 1.55, 0),
        .direction = Vec3r.unit_x,
        .max_distance = 100,
    })) == null);
    const striker = (try query.shapeCast(&world.bp, &world.bm, &world.store, .{
        .shape = grazer,
        .origin = vr(-10, 1.45, 0),
        .direction = Vec3r.unit_x,
        .max_distance = 100,
    })).?;
    try testing.expect(striker.normal.dot(Vec3r.unit_x) <= 0);
}

test "a cast and an overlap from behind honour the mode, and the cast normal is flipped" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    _ = try addWallMesh(gpa, &world, 0, 0);
    const probe = try world.store.createShape(gpa, .{ .sphere = .{ .radius = 0.25 } });
    const cast_tol: Real = if (Real == f32) 1e-4 else 1e-9;

    // The three walls face `−X`. A probe swept along `−X` from `x = 10` meets them from
    // BEHIND. Under the DEFAULT `.ignore` nothing answers; under `.collide` the nearest wall
    // at `x = 6` answers, at `10 − 6 − 0.25 = 3.75`.
    try testing.expect((try query.shapeCast(&world.bp, &world.bm, &world.store, .{
        .shape = probe,
        .origin = vr(10, 0, 0),
        .direction = vr(-1, 0, 0),
        .max_distance = 100,
    })) == null);
    const behind = (try query.shapeCast(&world.bp, &world.bm, &world.store, .{
        .shape = probe,
        .origin = vr(10, 0, 0),
        .direction = vr(-1, 0, 0),
        .max_distance = 100,
        .back_face_mode = .collide,
    })).?;
    try testing.expectApproxEqAbs(@as(Real, 3.75), behind.distance, cast_tol);
    try testing.expectEqual(@as(u32, 2), behind.subshape_id);
    // THE FLIP, asserted: the wall's outward normal is `(−1, 0, 0)` and the sweep runs along
    // `(−1, 0, 0)`, so an unflipped normal would give `+1` here. The kernel's axis is the one
    // facing the probe, so the returned normal is `(+1, 0, 0)` — the negation of the
    // triangle's own — and the `normal · direction <= 0` invariant holds.
    try testing.expect(behind.normal.approxEql(vr(1, 0, 0), 1e-3));
    try testing.expectApproxEqAbs(@as(Real, -1), behind.normal.dot(vr(-1, 0, 0)), 1e-3);

    // The SAME geometry approached from the FRONT answers in both modes, and there the normal
    // is the triangle's own — which is what shows the flip is conditional on the facing.
    inline for (.{ api.BackFaceMode.ignore, api.BackFaceMode.collide }) |mode| {
        const front = (try query.shapeCast(&world.bp, &world.bm, &world.store, .{
            .shape = probe,
            .origin = vr(-10, 0, 0),
            .direction = Vec3r.unit_x,
            .max_distance = 100,
            .back_face_mode = mode,
        })).?;
        // The nearest wall from the front is the one at `x = 2`, reached when the probe's
        // surface touches it, i.e. its centre at `1.75`: `1.75 − (−10) = 11.75`.
        try testing.expectApproxEqAbs(@as(Real, 11.75), front.distance, cast_tol);
        try testing.expect(front.normal.approxEql(vr(-1, 0, 0), 1e-3));
    }

    // OVERLAP from behind — and the finding this measures is that the mode changes NOTHING
    // observable here. A probe ENTIRELY behind a triangle's plane cannot intersect the
    // triangle, which lies IN that plane, so every triangle the predicate discards is one GJK
    // rejects anyway; and a probe that does overlap a triangle necessarily crosses its plane,
    // so it STRADDLES and counts in both modes. Measured on both cases:
    var buf: [4]api.BodyId = undefined;
    inline for (.{ api.BackFaceMode.ignore, api.BackFaceMode.collide }) |mode| {
        // Entirely behind the wall at `x = 6`, and 0.25 clear of it: nothing, either mode.
        try testing.expectEqual(@as(u32, 0), try query.overlapShape(&world.bp, &world.bm, &world.store, .{
            .shape = probe,
            .position = vr(6.5, 0, 0),
            .back_face_mode = mode,
        }, &buf));
        // Straddling that same wall: the body, either mode.
        try testing.expectEqual(@as(u32, 1), try query.overlapShape(&world.bp, &world.bm, &world.store, .{
            .shape = probe,
            .position = vr(6.1, 0, 0),
            .back_face_mode = mode,
        }, &buf));
    }
}

test "an overlap probe entirely behind is discarded, straddling is not" {
    // **At the PREDICATE grain, which is the only grain where the two modes differ.**
    //
    // The finding, stated first because it governs what this test can assert: for
    // `overlapShape` the back-face mode has NO observable effect outside GJK's own contact
    // margin. A probe entirely in the rear half-space of a triangle's plane cannot intersect
    // the triangle — the triangle lies in that plane — so every triangle the predicate
    // discards is one GJK classifies `separated` regardless; and any probe that does overlap
    // a triangle crosses its plane, hence STRADDLES, hence counts in both modes. What remains
    // is a band a few ULPs wide: a probe whose core sits just behind the plane can be
    // `.shallow` to GJK, and there `.ignore` drops it where `.collide` keeps it. The entry
    // test above measures the two ends; this one measures the predicate itself, where the
    // sign of the radius term is decidable.
    //
    // `n = +Z`, `v₀` on the plane `z = 0`, and a POINT core whose support IS its centre —
    // chosen deliberately, because then the whole verdict rests on the radius term.
    const n = vr(0, 0, 1);
    const v0 = Vec3r.zero;

    // ENTIRELY BEHIND: centre `z = −2`, `r = 1` → the probe reaches `z = −1`, short of the
    // plane. Behind.
    try testing.expect(narrowphase.triangle.probeIsBehind(Real, n, v0, vr(0, 0, -2), 1));

    // STRADDLING: centre EXACTLY on the plane, `r = 1` → reach `+1`. NOT behind, and this is
    // the assertion that decides the SIGN of the radius term. §1.11.17 and the brief write the
    // predicate as `n · support_core − r < n · v₀`; with that form a point core on the plane
    // gives `n·v₀ − 1 < n·v₀`, TRUE, so this probe would be classified BEHIND — which the same
    // paragraph forbids one line later ("a probe straddling the plane touches from the front
    // and counts in both modes"). With `+ r` it gives `n·v₀ + 1 < n·v₀`, FALSE. See the
    // recorded deviation at `triangle.probeIsBehind`.
    try testing.expect(!narrowphase.triangle.probeIsBehind(Real, n, v0, Vec3r.zero, 1));

    // The BOUNDARY is on the front side: a probe reaching EXACTLY the plane is not behind,
    // `< n·v₀` being strict.
    try testing.expect(!narrowphase.triangle.probeIsBehind(Real, n, v0, vr(0, 0, -1), 1));

    // And with a NON-POINT core the support point moves and the radius is zero — the other
    // half of the term's job. A box core reaching `z = −0.5` is behind; reaching `z = +0.5` is
    // not; reaching exactly `0` is not.
    try testing.expect(narrowphase.triangle.probeIsBehind(Real, n, v0, vr(0, 0, -0.5), 0));
    try testing.expect(!narrowphase.triangle.probeIsBehind(Real, n, v0, vr(0, 0, 0.5), 0));
    try testing.expect(!narrowphase.triangle.probeIsBehind(Real, n, v0, Vec3r.zero, 0));

    // WITHOUT the radius term the point-core cases collapse: a sphere would be judged by its
    // CENTRE, so a probe straddling by up to its radius would read as behind. Restated here as
    // the counter-factual the brief's Notes name — right for a box, wrong for a sphere and a
    // capsule by exactly the radius.
    try testing.expect(narrowphase.triangle.probeIsBehind(Real, n, v0, vr(0, 0, -0.5), 0));
    try testing.expect(!narrowphase.triangle.probeIsBehind(Real, n, v0, vr(0, 0, -0.5), 1));
}

test "pointQuery never returns a mesh body" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    _ = try addCubeMesh(gpa, &world, 0, 0);
    // A convex body beside it, so the entry is demonstrably working and the empty answer for
    // the mesh is a decision rather than a broken query.
    const sphere = try world.store.createShape(gpa, .{ .sphere = .{ .radius = 1 } });
    const sphere_body = try world.addBody(gpa, .{
        .shape = sphere,
        .body_type = .static,
        .position = harness.av3(10, 0, 0),
        .entity = entityOf(1),
    });

    var buf: [8]api.BodyId = undefined;
    // THE CATEGORICAL RULE. The cube is CLOSED and encloses `[−1, 1]³`, so the origin is
    // inside the volume it bounds — and the mesh is still not returned, because a mesh is a
    // SURFACE and membership is false everywhere (§1.11.17). This is the test that fails if
    // someone adds solidity later, which is exactly what it is for.
    try testing.expectEqual(@as(u32, 0), query.pointQuery(&world.bp, &world.bm, &world.store, Vec3r.zero, .{}, &buf));
    // Not just at the centre: on a face, on an edge, on a vertex, and just inside each.
    for ([_]Vec3r{
        vr(0, 0, 0),       vr(0.999, 0, 0), vr(1, 0, 0),
        vr(1, 1, 0),       vr(1, 1, 1),     vr(-1, -1, -1),
        vr(0.5, 0.5, 0.5),
    }) |point| {
        try testing.expectEqual(@as(u32, 0), query.pointQuery(&world.bp, &world.bm, &world.store, point, .{}, &buf));
    }
    // The convex body DOES answer for a point inside it, so the entry itself works.
    try testing.expectEqual(@as(u32, 1), query.pointQuery(&world.bp, &world.bm, &world.store, vr(10, 0, 0), .{}, &buf));
    try testing.expectEqual(sphere_body, buf[0]);
}

test "closestPoint measures to the surface, outside and inside" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    const body = try addCubeMesh(gpa, &world, 0, 0);
    const surface_tol: Real = if (Real == f32) 1e-5 else 1e-12;

    // OUTSIDE, on the `+X` axis at `x = 4`: the nearest surface is the `+X` face at `x = 1`,
    // so the distance is exactly 3 and the closest point is `(1, 0, 0)`.
    const outside = query.closestPoint(&world.bp, &world.bm, &world.store, vr(4, 0, 0), 100, .{}).?;
    try testing.expectEqual(body, outside.body);
    try testing.expectApproxEqAbs(@as(Real, 3), outside.distance, surface_tol);
    try testing.expect(outside.position.approxEql(vr(1, 0, 0), surface_tol));

    // INSIDE the volume the closed cube encloses, at `(0.5, 0, 0)`: the nearest surface is
    // still the `+X` face, at distance `1 − 0.5 = 0.5`. NOT zero — a mesh has no interior, so
    // there is no interiority for the distance to collapse through (§1.11.17). This is the
    // assertion that separates a surface from a solid.
    const inside = query.closestPoint(&world.bp, &world.bm, &world.store, vr(0.5, 0, 0), 100, .{}).?;
    try testing.expectApproxEqAbs(@as(Real, 0.5), inside.distance, surface_tol);
    try testing.expect(inside.position.approxEql(vr(1, 0, 0), surface_tol));

    // At the CENTRE the six faces are equidistant at 1, so the distance is 1 whichever face
    // wins — and it is still not zero.
    const centre = query.closestPoint(&world.bp, &world.bm, &world.store, Vec3r.zero, 100, .{}).?;
    try testing.expectApproxEqAbs(@as(Real, 1), centre.distance, surface_tol);

    // ON the surface the distance IS zero, and that is a surface answer rather than an
    // interior one — which is what makes the two previous assertions meaningful.
    const on_face = query.closestPoint(&world.bp, &world.bm, &world.store, vr(1, 0, 0), 100, .{}).?;
    try testing.expectApproxEqAbs(@as(Real, 0), on_face.distance, surface_tol);

    // The bound is CLOSED and it prunes: nothing within 2 of a point 4 m from the surface.
    try testing.expect(query.closestPoint(&world.bp, &world.bm, &world.store, vr(5, 0, 0), 2, .{}) == null);
    try testing.expect(query.closestPoint(&world.bp, &world.bm, &world.store, vr(5, 0, 0), 4, .{}) != null);
}

test "overlapAabb stops at AABB granularity" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    const body = try addCubeMesh(gpa, &world, 0, 0);
    var buf: [8]api.BodyId = undefined;

    // A box hugging the cube's `+X+Y+Z` CORNER from outside, `[1.5, 2]³`, does not meet the
    // mesh's own box `[−1, 1]³` — so nothing is returned, and the entry is not simply
    // answering "yes" to everything.
    try testing.expectEqual(@as(u32, 0), query.overlapAabb(
        &world.bp,
        &world.bm,
        &world.store,
        vr(1.5, 1.5, 1.5),
        vr(2, 2, 2),
        .{},
        &buf,
    ));

    // **THE DOCUMENTED APPROXIMATION, PINNED.** The cube is HOLLOW — twelve triangles, no
    // interior geometry — so a small box strictly inside it, `[−0.2, 0.2]³`, touches NO
    // triangle at all. It does meet the mesh's world AABB, and this entry stops at AABB
    // GRANULARITY without descending into the mesh (§1.11.17), so the body IS returned.
    //
    // Pinned rather than tightened by accident: someone descending into the tree here would
    // "fix" this to zero and silently change the entry's cost class and its contract.
    try testing.expectEqual(@as(u32, 1), query.overlapAabb(
        &world.bp,
        &world.bm,
        &world.store,
        vr(-0.2, -0.2, -0.2),
        vr(0.2, 0.2, 0.2),
        .{},
        &buf,
    ));
    try testing.expectEqual(body, buf[0]);
    // And `overlapShape` on the same region does NOT return it, which is what proves the
    // difference is the granularity and not the geometry: a small sphere at the centre of the
    // hollow cube touches nothing.
    const small = try world.store.createShape(gpa, .{ .sphere = .{ .radius = 0.2 } });
    try testing.expectEqual(@as(u32, 0), try query.overlapShape(&world.bp, &world.bm, &world.store, .{
        .shape = small,
        .position = Vec3r.zero,
    }, &buf));
}

test "the cached world box answers as the pass does, and a teleport poisons it" {
    const gpa = testing.allocator;
    var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
    defer world.deinit(gpa);
    // Built here rather than through `addCubeMesh` because the test needs the SHAPE handle to
    // recompute the reference pass.
    const shape = try world.store.createShape(gpa, .{ .triangle_mesh = .{
        .vertices = &cube_vertices,
        .indices = &cube_indices,
    } });
    const body = try world.addBody(gpa, .{
        .shape = shape,
        .body_type = .static,
        .entity = entityOf(0),
    });

    // The cache is filled at `addBody`, and it must answer EXACTLY as the O(V) pass does —
    // it IS that value, computed once. Measured at 72.8 µs against 11.5 ns on a
    // 16 000-triangle mesh (`bench/forge_3d_mesh.zig`), which is why it exists at all.
    // The cube spans `[−1, 1]³` and the body sits at the origin unrotated, so the pass is that
    // box exactly.
    const pass = bm_mod.worldAabb(world.store.get(shape).?, world.bm.position(body).?, world.bm.rotation(body).?);
    try testing.expect(pass.min.eql(vr(-1, -1, -1)));
    try testing.expect(pass.max.eql(vr(1, 1, 1)));

    // The two answers agree on both sides of that bound, which is the equivalence the cache
    // owes: a box meeting `[−1, 1]³` is accepted, one clear of it is not.
    try testing.expect(world.bm.aabbOverlapsBody(&world.store, body, Aabbr.fromMinMax(vr(0.5, 0.5, 0.5), vr(3, 3, 3))).?);
    try testing.expect(!world.bm.aabbOverlapsBody(&world.store, body, Aabbr.fromMinMax(vr(2, 2, 2), vr(3, 3, 3))).?);

    // A TELEPORT of the static body POISONS the cache — `setPosition` cannot recompute it,
    // holding no store — and the mesh arm falls back to the pass. So the answer stays CORRECT
    // at the new pose, which is the whole point of poisoning rather than trusting: the cache's
    // correctness rests on no promise about a milestone that does not exist yet.
    world.bm.setPosition(body, vr(10, 0, 0));
    try testing.expect(world.bm.aabbOverlapsBody(&world.store, body, Aabbr.fromMinMax(vr(9, -1, -1), vr(11, 1, 1))).?);
    try testing.expect(!world.bm.aabbOverlapsBody(&world.store, body, Aabbr.fromMinMax(vr(-1, -1, -1), vr(1, 1, 1))).?);

    // A DYNAMIC body's cache is NaN from creation and is never read, so the poisoning branch
    // must leave it alone — which is what keeps the pose setters free on the solver's hot
    // path. Observed through the answer, which stays correct as the sphere moves.
    const sphere = try world.store.createShape(gpa, .{ .sphere = .{ .radius = 1 } });
    const mover = try world.addBody(gpa, .{
        .shape = sphere,
        .body_type = .dynamic,
        .entity = entityOf(1),
    });
    try testing.expect(world.bm.aabbOverlapsBody(&world.store, mover, Aabbr.fromMinMax(vr(-1, -1, -1), vr(1, 1, 1))).?);
    world.bm.setPosition(mover, vr(50, 0, 0));
    try testing.expect(!world.bm.aabbOverlapsBody(&world.store, mover, Aabbr.fromMinMax(vr(-1, -1, -1), vr(1, 1, 1))).?);
    try testing.expect(world.bm.aabbOverlapsBody(&world.store, mover, Aabbr.fromMinMax(vr(49, -1, -1), vr(51, 1, 1))).?);
}

test "the five remaining entries agree exactly with brute force over the mesh" {
    const gpa = testing.allocator;

    for ([_]u64{ 101, 202, 303, 404 }) |seed| {
        var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
        defer world.deinit(gpa);
        const shape = try randomMesh(gpa, &world.store, seed, 90);
        const body = try world.addBody(gpa, .{
            .shape = shape,
            .body_type = .static,
            .entity = entityOf(0),
        });
        const data = world.store.get(shape).?.mesh.?;
        const n = data.triangleCount();
        const probe_shape = try world.store.createShape(gpa, .{ .sphere = .{ .radius = 0.6 } });
        const probe = shape_mod.supportShape(world.store.get(probe_shape).?);

        var prng = std.Random.DefaultPrng.init(seed ^ 0xD00D);
        const rand = prng.random();
        var buf: [8]api.BodyId = undefined;
        var cast_answers: u32 = 0;
        var overlap_answers: u32 = 0;
        var aabb_answers: u32 = 0;
        var closest_answers: u32 = 0;

        for (0..40) |_| {
            const target = data.triangleCentroid(rand.intRangeLessThan(u32, 0, n));
            const away = vr(
                rand.float(Real) * 2 - 1,
                rand.float(Real) * 2 - 1,
                rand.float(Real) * 2 - 1,
            );
            if (@reduce(.Max, @abs(away.data)) == 0) continue;
            const offset = away.scale(1 / away.length());
            const origin = target.add(offset.scale(25));
            const raw_direction = offset.neg();
            const direction = query.unitDirection(raw_direction).?;
            const max_distance: Real = 60;

            // --- shapeCast. The oracle is the SAME kernel over every triangle, in the same
            // frames the adapter builds — `relpose` maps the body into the probe's frame and
            // the direction is the probe-frame one — with the same `(distance, index)`
            // tie-break the collector uses.
            {
                const relpose = narrowphase.RelativePose(Real).init(
                    origin,
                    Quatr.identity,
                    world.bm.position(body).?,
                    world.bm.rotation(body).?,
                );
                const dir_in_a = direction; // the probe's rotation is the identity here
                var brute_best: ?Real = null;
                var brute_index: u32 = 0;
                var t: u32 = 0;
                while (t < n) : (t += 1) {
                    const hit = narrowphase.castShape(
                        Real,
                        probe,
                        relpose,
                        shape_mod.triangleSupportShape(data, t),
                        dir_in_a,
                        max_distance,
                    ) orelse continue;
                    if (brute_best == null or hit.distance < brute_best.? or
                        (hit.distance == brute_best.? and t < brute_index))
                    {
                        brute_best = hit.distance;
                        brute_index = t;
                    }
                }
                const got = try query.shapeCast(&world.bp, &world.bm, &world.store, .{
                    .shape = probe_shape,
                    .origin = origin,
                    .direction = raw_direction,
                    .max_distance = max_distance,
                    .back_face_mode = .collide,
                });
                if (brute_best) |expected| {
                    try testing.expect(got != null);
                    try testing.expectEqual(expected, got.?.distance);
                    try testing.expectEqual(brute_index, got.?.subshape_id);
                    cast_answers += 1;
                } else {
                    try testing.expect(got == null);
                }
            }

            // --- overlapShape, at the probe's own pose: the body is returned exactly when SOME
            // triangle is not `separated` from the probe.
            {
                var brute_any = false;
                var t: u32 = 0;
                while (t < n) : (t += 1) {
                    const result = narrowphase.gjk(
                        Real,
                        probe,
                        target,
                        Quatr.identity,
                        shape_mod.triangleSupportShape(data, t),
                        world.bm.position(body).?,
                        world.bm.rotation(body).?,
                    );
                    if (result.status != .separated) {
                        brute_any = true;
                        break;
                    }
                }
                const count = try query.overlapShape(&world.bp, &world.bm, &world.store, .{
                    .shape = probe_shape,
                    .position = target,
                    .back_face_mode = .collide,
                }, &buf);
                try testing.expectEqual(@as(u32, if (brute_any) 1 else 0), count);
                if (brute_any) overlap_answers += 1;
            }

            // --- overlapAabb. The oracle is the mesh's own world box, WITHOUT descending —
            // which is the documented granularity of this entry (§1.11.17), so the oracle is
            // the contract rather than a tighter computation.
            {
                const half: Real = 3;
                const query_min = target.sub(Vec3r.splat(half));
                const query_max = target.add(Vec3r.splat(half));
                const brute = bm_mod.worldAabb(
                    world.store.get(shape).?,
                    world.bm.position(body).?,
                    world.bm.rotation(body).?,
                ).overlaps(Aabbr.fromMinMax(query_min, query_max));
                const count = query.overlapAabb(&world.bp, &world.bm, &world.store, query_min, query_max, .{}, &buf);
                try testing.expectEqual(@as(u32, if (brute) 1 else 0), count);
                if (brute) aabb_answers += 1;
            }

            // --- pointQuery. The oracle is the CATEGORICAL rule: never, for any point.
            {
                try testing.expectEqual(@as(u32, 0), query.pointQuery(&world.bp, &world.bm, &world.store, target, .{}, &buf));
                try testing.expectEqual(@as(u32, 0), query.pointQuery(&world.bp, &world.bm, &world.store, origin, .{}, &buf));
            }

            // --- closestPoint. The oracle is the shared per-triangle kernel over every
            // triangle, with the same tie-break.
            {
                var brute_best: ?Real = null;
                var brute_index: u32 = 0;
                var t: u32 = 0;
                while (t < n) : (t += 1) {
                    const candidate = bm_mod.closestPointOnCore(
                        origin,
                        shape_mod.triangleSupportShape(data, t),
                        world.bm.position(body).?,
                        world.bm.rotation(body).?,
                    );
                    if (brute_best == null or candidate.distance < brute_best.? or
                        (candidate.distance == brute_best.? and t < brute_index))
                    {
                        brute_best = candidate.distance;
                        brute_index = t;
                    }
                }
                const got = query.closestPoint(&world.bp, &world.bm, &world.store, origin, 1000, .{});
                try testing.expect(got != null);
                try testing.expectEqual(brute_best.?, got.?.distance);
                try testing.expectEqual(brute_index, got.?.subshape_id);
                closest_answers += 1;
            }
        }

        // Non-vacuous on every family that CAN answer: agreeing on the empty set proves
        // nothing, and `pointQuery`'s answer is empty by design so it is excluded from this
        // guard rather than silently counted.
        try testing.expect(cast_answers > 20);
        try testing.expect(overlap_answers > 20);
        try testing.expect(aabb_answers > 20);
        try testing.expect(closest_answers > 20);
    }
}

test "the shared query invariants hold with a mesh in the scene" {
    const gpa = testing.allocator;
    var buf: [8]api.BodyId = undefined;
    var hits: [8]query.RayHit = undefined;

    // --- OBJECT MASK and EXCLUSIONS, on the mesh itself.
    {
        var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
        defer world.deinit(gpa);
        const body = try addWallMesh(gpa, &world, 3, 0);
        const q = query.RayQuery{ .origin = Vec3r.zero, .direction = Vec3r.unit_x, .max_distance = 100 };

        // Layer 3 is in the mask, so the mesh answers; take it out and it does not. The mask
        // is on the SUB-SHAPE's layer, which for one shape per body is the body's.
        try testing.expect(query.raycast(&world.bp, &world.bm, &world.store, q) != null);
        var masked = q;
        masked.filter.layer_mask = ~(@as(u32, 1) << 3);
        try testing.expect(query.raycast(&world.bp, &world.bm, &world.store, masked) == null);
        try testing.expect(!query.raycastAny(&world.bp, &world.bm, &world.store, masked));
        try testing.expectEqual(@as(u32, 0), query.raycastAll(&world.bp, &world.bm, &world.store, masked, &hits));

        // EXCLUSIONS, tested on the body upstream of the kernel — the dominant case being
        // "myself".
        var excluded = q;
        const exclude_list = [_]api.BodyId{body};
        excluded.filter.exclude = &exclude_list;
        try testing.expect(query.raycast(&world.bp, &world.bm, &world.store, excluded) == null);
        // And the other entries honour both, so the filter is shared rather than reimplemented.
        try testing.expectEqual(@as(u32, 0), query.pointQuery(&world.bp, &world.bm, &world.store, vr(2, 0, 0), .{ .layer_mask = 0 }, &buf));
        try testing.expectEqual(@as(u32, 0), query.overlapAabb(&world.bp, &world.bm, &world.store, vr(-1, -1, -1), vr(7, 1, 1), .{ .exclude = &exclude_list }, &buf));
        try testing.expect(query.closestPoint(&world.bp, &world.bm, &world.store, vr(0, 0, 0), 100, .{ .exclude = &exclude_list }) == null);
    }

    // --- A SLEEPING BODY ANSWERS AND STAYS ASLEEP, with a mesh in the scene.
    {
        var world = harness.World.init(vr(0, -9.81, 0), 1.0 / 60.0);
        defer world.deinit(gpa);
        // The mesh is IN THE SCENE but OUT OF CONTACT, at `x = 1000`, and that isolation is
        // deliberate: the property under test is that a query reaches a SLEEPING body and
        // leaves it asleep, so the mesh must not also be feeding the contact path. Far enough
        // that no fat AABB ever overlaps, so `computePairs` never emits the pair at all, and a
        // future change to mesh contact generation cannot move this test's result. The dynamic
        // body rests on a static box pad instead, exercising the convex contact path.
        const mesh_vertices = [_]ApiVec3{
            av3(-4, 0, -4), av3(-4, 0, 4), av3(4, 0, -4), av3(4, 0, 4),
        };
        const mesh_indices = [_]u32{ 0, 1, 2, 2, 1, 3 };
        const mesh_shape = try world.store.createShape(gpa, .{ .triangle_mesh = .{
            .vertices = &mesh_vertices,
            .indices = &mesh_indices,
        } });
        const mesh_body = try world.addBody(gpa, .{
            .shape = mesh_shape,
            .body_type = .static,
            .position = harness.av3(1000, 0, 0),
            .entity = entityOf(0),
        });
        // A static box pad the dynamic body actually rests on, so the contact path is the
        // convex one.
        const pad_shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av3(4, 0.5, 4) } });
        _ = try world.addBody(gpa, .{
            .shape = pad_shape,
            .body_type = .static,
            .position = harness.av3(0, -0.5, 0),
            .restitution = 0,
            .entity = entityOf(1),
        });
        const box_shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });
        const box = try world.addBody(gpa, .{
            .shape = box_shape,
            .position = harness.av3(0, 0.6, 0),
            .body_type = .dynamic,
            .mass = 1,
            .restitution = 0,
            .entity = entityOf(2),
        });

        var t: u32 = 0;
        const asleep = while (t < 600) : (t += 1) {
            try world.step(gpa);
            if (world.bm.isSleeping(box).?) break true;
        } else false;
        try testing.expect(asleep);

        // The sleeper ANSWERS — its proxy is still in the tree, step 10 skips its update and
        // not its presence — and being read is not a solicitation (§1.8.4), so it stays asleep.
        // Structural, not merely observed: every entry takes `*const BodyManager` and could
        // not wake anything if it tried.
        const down = query.RayQuery{ .origin = vr(0, 5, 0), .direction = vr(0, -1, 0), .max_distance = 100 };
        try testing.expect(query.raycast(&world.bp, &world.bm, &world.store, down) != null);
        try testing.expect(world.bm.isSleeping(box).?);
        // The MESH answers too, from its own place, and the sleeper is still asleep after.
        const at_mesh = query.RayQuery{ .origin = vr(1000, 5, 0), .direction = vr(0, -1, 0), .max_distance = 100 };
        const mesh_hit = query.raycast(&world.bp, &world.bm, &world.store, at_mesh).?;
        try testing.expectEqual(mesh_body, mesh_hit.body);
        try testing.expectEqual(@as(Real, 5), mesh_hit.distance);
        try testing.expect(world.bm.isSleeping(box).?);
        _ = query.raycastAll(&world.bp, &world.bm, &world.store, down, &hits);
        _ = query.pointQuery(&world.bp, &world.bm, &world.store, vr(0, 0.5, 0), .{}, &buf);
        _ = query.overlapAabb(&world.bp, &world.bm, &world.store, vr(-1, 0, -1), vr(1, 1, 1), .{}, &buf);
        _ = query.closestPoint(&world.bp, &world.bm, &world.store, vr(0, 3, 0), 100, .{});
        try testing.expect(world.bm.isSleeping(box).?);
    }

    // --- INVARIANCE UNDER CREATION-ORDER PERMUTATION, and two BIT-IDENTICAL runs.
    {
        // Two mesh bodies on distinct ENTITIES, built in both orders. The answer is keyed on
        // `(distance, entity, BodyId)` (§1.11.14), so it must not follow the order the scene
        // was assembled in — `BodyId` being a slot index, it encodes exactly that order.
        const Answer = struct { entity: api.EntityId, distance: Real, subshape: u32 };
        var answers: [2]Answer = undefined;
        for (0..2) |order| {
            var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
            defer world.deinit(gpa);
            // The NEAR mesh is at the origin (walls at 2, 4, 6) and the FAR one is 20 m out.
            const near_first = order == 0;
            const first_entity: u32 = if (near_first) 0 else 1;
            const second_entity: u32 = if (near_first) 1 else 0;
            const first_x: f32 = if (near_first) 0 else 20;
            const second_x: f32 = if (near_first) 20 else 0;
            inline for (.{ 0, 1 }) |slot| {
                const shape = try world.store.createShape(gpa, .{ .triangle_mesh = .{
                    .vertices = &wall_vertices,
                    .indices = &wall_indices,
                } });
                _ = try world.addBody(gpa, .{
                    .shape = shape,
                    .body_type = .static,
                    .position = harness.av3(if (slot == 0) first_x else second_x, 0, 0),
                    .entity = entityOf(if (slot == 0) first_entity else second_entity),
                });
            }
            const q = query.RayQuery{ .origin = Vec3r.zero, .direction = Vec3r.unit_x, .max_distance = 100 };
            const hit = query.raycast(&world.bp, &world.bm, &world.store, q).?;
            answers[order] = .{ .entity = world.bm.entity(hit.body).?, .distance = hit.distance, .subshape = hit.subshape_id };

            // TWO IDENTICAL RUNS on the same world are bit-identical, on every field.
            const again = query.raycast(&world.bp, &world.bm, &world.store, q).?;
            try testing.expectEqual(hit.distance, again.distance);
            try testing.expectEqual(hit.subshape_id, again.subshape_id);
            try testing.expectEqual(hit.body, again.body);
            try testing.expect(hit.position.eql(again.position));
            try testing.expect(hit.normal.eql(again.normal));
        }
        // The nearest mesh is the one at the origin, entity 0 in both orders — the ENTITY, not
        // the `BodyId`, which differs between the two runs by construction.
        try testing.expectEqual(answers[0].entity.index, answers[1].entity.index);
        try testing.expectEqual(answers[0].distance, answers[1].distance);
        try testing.expectEqual(answers[0].subshape, answers[1].subshape);
        try testing.expectEqual(@as(u32, 0), answers[0].entity.index);
    }
}

test "the frozen surface carries the back-face mode on the two probe entries" {
    // EXTENDED field by field on top of the gate C pin, which stays as it is.
    const cast = api.ShapeCastQuery{ .shape = 0, .origin = ApiVec3.zero, .direction = ApiVec3.unit_x, .max_distance = 1 };
    try testing.expectEqual(api.BackFaceMode.ignore, cast.back_face_mode);
    try testing.expectEqual(api.BackFaceMode, @TypeOf(cast.back_face_mode));

    const overlap = api.OverlapQuery{ .shape = 0, .position = ApiVec3.zero };
    try testing.expectEqual(api.BackFaceMode.ignore, overlap.back_face_mode);
    try testing.expectEqual(api.BackFaceMode, @TypeOf(overlap.back_face_mode));

    // THE THREE ENTRIES THAT DO NOT CARRY IT, asserted as an ABSENCE so the omission is a
    // decision on the record rather than something a later reader might "complete for
    // symmetry" (§1.11.17): `overlapAabb` sees no triangle, `pointQuery` never returns a mesh,
    // and `closestPoint`'s distance to a surface is not signed. The first two take loose
    // arguments rather than a query struct, so the assertion is on the one that has a struct.
    try testing.expect(!@hasField(api.ClosestPointResult, "back_face_mode"));

    // The solver-side mirrors carry it at the same name and default, and the hit types carry
    // `subshape_id` — which the mesh is the first shape to FILL, on all three families.
    const solver_cast = query.CastQuery{ .shape = 0, .origin = Vec3r.zero, .direction = Vec3r.unit_x, .max_distance = 1 };
    try testing.expectEqual(api.BackFaceMode.ignore, solver_cast.back_face_mode);
    const solver_overlap = query.OverlapRequest{ .shape = 0, .position = Vec3r.zero };
    try testing.expectEqual(api.BackFaceMode.ignore, solver_overlap.back_face_mode);

    const cast_hit = api.ShapeCastHit{
        .entity = entityOf(0),
        .body = 0,
        .position = ApiVec3.zero,
        .normal = ApiVec3.unit_y,
        .distance = 1,
    };
    try testing.expectEqual(@as(u32, 0), cast_hit.subshape_id);
    try testing.expectEqual(@as(u32, 0), cast_hit.cast_subshape_id);
    const closest = api.ClosestPointResult{ .entity = entityOf(0), .body = 0, .position = ApiVec3.zero, .distance = 1 };
    try testing.expectEqual(@as(u32, 0), closest.subshape_id);
    // And the body-grained adapters gained it too, which is where the value comes from.
    const body_cast: bm_mod.BodyCastHit = .{ .distance = 0, .position = Vec3r.zero, .normal = Vec3r.unit_y };
    try testing.expectEqual(@as(u32, 0), body_cast.subshape_id);
    const body_closest: bm_mod.BodyClosestPoint = .{ .distance = 0, .position = Vec3r.zero };
    try testing.expectEqual(@as(u32, 0), body_closest.subshape_id);
}

// ---------------------------------------------------------------------------
// Contacts
// ---------------------------------------------------------------------------

const rigid = @import("../rigid/root.zig");

/// A flat mesh floor at `y = 0`: a 2 × 2 grid of quads over `[−2, 2]²`, so EIGHT triangles,
/// every one wound with its outward normal `+Y` (up).
///
/// The winding is `(v₀, v₁, v₂)` with `(v₁−v₀) × (v₂−v₀)` pointing up. For the quad whose
/// corners are `(x, z)`, `(x+2, z)`, `(x, z+2)`, `(x+2, z+2)`, the first triangle is
/// `(x,z), (x,z+2), (x+2,z)` and `(0,0,2) × (2,0,0) = (0·0 − 2·0, 2·2 − 0·0, 0) = (0, 4, 0)`.
/// Four quads, two triangles each, so a box resting on the seam of the middle four touches
/// several of them at once — which is what makes it a multi-manifold witness.
fn floorMesh(gpa: std.mem.Allocator) !struct { vertices: []ApiVec3, indices: []u32 } {
    var vertices: std.ArrayListUnmanaged(ApiVec3) = .empty;
    var indices: std.ArrayListUnmanaged(u32) = .empty;
    var qx: i32 = -2;
    while (qx < 2) : (qx += 2) {
        var qz: i32 = -2;
        while (qz < 2) : (qz += 2) {
            const x: f32 = @floatFromInt(qx);
            const z: f32 = @floatFromInt(qz);
            const base: u32 = @intCast(vertices.items.len);
            try vertices.append(gpa, av3(x, 0, z));
            try vertices.append(gpa, av3(x, 0, z + 2));
            try vertices.append(gpa, av3(x + 2, 0, z));
            try vertices.append(gpa, av3(x + 2, 0, z + 2));
            try indices.appendSlice(gpa, &.{ base, base + 1, base + 2 });
            try indices.appendSlice(gpa, &.{ base + 2, base + 1, base + 3 });
        }
    }
    return .{
        .vertices = try vertices.toOwnedSlice(gpa),
        .indices = try indices.toOwnedSlice(gpa),
    };
}

/// A world whose ground is the eight-triangle mesh floor, plus a dynamic box above it.
const FloorScene = struct {
    world: harness.World,
    ground: api.BodyId,
    box: api.BodyId,
    vertices: []ApiVec3,
    indices: []u32,

    fn init(gpa: std.mem.Allocator, box_position: ApiVec3, sleeping: bool) !FloorScene {
        const arrays = try floorMesh(gpa);
        var world = if (sleeping)
            harness.World.init(vr(0, -9.81, 0), 1.0 / 60.0)
        else
            harness.World.initNoSleep(vr(0, -9.81, 0), 1.0 / 60.0);
        const ground_shape = try world.store.createShape(gpa, .{ .triangle_mesh = .{
            .vertices = arrays.vertices,
            .indices = arrays.indices,
        } });
        const ground = try world.addBody(gpa, .{
            .shape = ground_shape,
            .body_type = .static,
            .restitution = 0,
            .entity = entityOf(0),
        });
        const box_shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });
        const box = try world.addBody(gpa, .{
            .shape = box_shape,
            .position = box_position,
            .body_type = .dynamic,
            .mass = 1,
            .restitution = 0,
            .entity = entityOf(1),
        });
        return .{ .world = world, .ground = ground, .box = box, .vertices = arrays.vertices, .indices = arrays.indices };
    }

    fn deinit(self: *FloorScene, gpa: std.mem.Allocator) void {
        self.world.deinit(gpa);
        gpa.free(self.vertices);
        gpa.free(self.indices);
    }
};

/// Every manifold `collidePairEach` offers for one pair, tagged with its sub-shape.
const ManifoldTally = struct {
    ids: [32]u32 = @splat(0),
    normals: [32]Vec3r = @splat(Vec3r.zero),
    count: u32 = 0,

    pub fn add(self: *ManifoldTally, subshape_id: u32, manifold: narrowphase.ContactManifold(Real)) void {
        self.ids[self.count] = subshape_id;
        self.normals[self.count] = manifold.normal;
        self.count += 1;
    }

    fn has(self: *const ManifoldTally, subshape_id: u32) bool {
        for (self.ids[0..self.count]) |id| {
            if (id == subshape_id) return true;
        }
        return false;
    }
};

test "a mesh and a convex produce one manifold per contacting triangle" {
    const gpa = testing.allocator;

    // The box is 1 m on a side and sits centred on the mesh floor's ORIGIN, which is the corner
    // shared by all four quads. Its footprint `[−0.5, 0.5]²` therefore overlaps ALL FOUR quads,
    // and within each quad only the triangle containing that quad's inner corner — the eight
    // triangles are laid out two per quad, and the box's footprint reaches `0.5` into each.
    //
    // Closed form on the count: four quads touched, and in each the box's footprint covers the
    // quad's inner corner, which both of that quad's triangles share along their common
    // diagonal — so BOTH triangles of each quad are reachable and the manifold count is between
    // four and eight. What is asserted exactly is stronger than a count: EVERY manifold's
    // sub-shape is a distinct triangle index in `[0, 8)`, no index repeats, and every normal is
    // `+Y` — the floor's outward direction, since the box is above it and the mesh is A.
    var scene = try FloorScene.init(gpa, av3(0, 0.5, 0), false);
    defer scene.deinit(gpa);

    var tally = ManifoldTally{};
    scene.world.bm.collidePairEach(&scene.world.store, scene.ground, scene.box, &tally);

    // SEVERAL manifolds, which is the shape change the mesh imposes — a convex pair yields one.
    try testing.expect(tally.count >= 4);
    try testing.expect(tally.count <= 8);
    // Each from a DISTINCT triangle, and each index in range: `subshape_id` is the triangle
    // index (§1.11.16), so a duplicate would mean two manifolds claiming one triangle and a
    // warm-start cache key collision.
    var seen: [8]bool = @splat(false);
    for (tally.ids[0..tally.count]) |id| {
        try testing.expect(id < 8);
        try testing.expect(!seen[id]);
        seen[id] = true;
    }
    // The ground is A (its `BodyId` is the smaller — it was created first), so every normal is
    // A→B, i.e. from the floor up toward the box: `+Y`, to the rounding of a normalised cross
    // product on exact integer coordinates.
    for (tally.normals[0..tally.count]) |n| {
        try testing.expect(n.approxEql(vr(0, 1, 0), 1e-5));
    }

    // A CONVEX pair still yields exactly one manifold, so the multi-manifold shape is the mesh's
    // and not a change to the convex path.
    const pad = try scene.world.store.createShape(gpa, .{ .box = .{ .half_extents = av3(2, 0.5, 2) } });
    const pad_body = try scene.world.addBody(gpa, .{
        .shape = pad,
        .body_type = .static,
        .position = harness.av3(0, -0.5, 0),
        .entity = entityOf(2),
    });
    var convex_tally = ManifoldTally{};
    scene.world.bm.collidePairEach(&scene.world.store, pad_body, scene.box, &convex_tally);
    try testing.expectEqual(@as(u32, 1), convex_tally.count);
    try testing.expectEqual(@as(u32, 0), convex_tally.ids[0]);
    // And `collidePair`, the single-manifold wrapper, answers that pair — its precondition being
    // that neither body carries sub-shapes.
    try testing.expect(scene.world.bm.collidePair(&scene.world.store, pad_body, scene.box) != null);

    // ORDER-INDEPENDENCE, at the multi-manifold grain: asking with the arguments swapped gives
    // the same triangles and the NEGATED normals.
    var swapped = ManifoldTally{};
    scene.world.bm.collidePairEach(&scene.world.store, scene.box, scene.ground, &swapped);
    try testing.expectEqual(tally.count, swapped.count);
    for (tally.ids[0..tally.count]) |id| try testing.expect(swapped.has(id));
    for (swapped.normals[0..swapped.count]) |n| {
        try testing.expect(n.approxEql(vr(0, -1, 0), 1e-5));
    }
}

test "the constraint build emits one constraint per contacting triangle" {
    const gpa = testing.allocator;
    var scene = try FloorScene.init(gpa, av3(0, 0.5, 0), false);
    defer scene.deinit(gpa);

    // The build loop consumes the collection: one `ContactConstraint` per manifold, each
    // carrying its own `subshape_id`. Every constraint of this pair shares the pair key and
    // differs in the sub-shape, which is precisely what the warm-start cache needs.
    var tally = ManifoldTally{};
    scene.world.bm.collidePairEach(&scene.world.store, scene.ground, scene.box, &tally);

    var constraints: std.ArrayListUnmanaged(rigid.ContactConstraint) = .empty;
    defer constraints.deinit(gpa);
    const key = (@as(u64, @min(scene.ground, scene.box)) << 32) | @max(scene.ground, scene.box);
    try rigid.build(gpa, &constraints, &scene.world.bm, &scene.world.store, &.{key});

    try testing.expectEqual(tally.count, @as(u32, @intCast(constraints.items.len)));
    var constraint_ids: [8]bool = @splat(false);
    for (constraints.items) |c| {
        try testing.expectEqual(key, c.pair_key);
        try testing.expect(c.subshape_id < 8);
        try testing.expect(!constraint_ids[c.subshape_id]);
        constraint_ids[c.subshape_id] = true;
        try testing.expect(tally.has(c.subshape_id));
    }
}

test "warm starting is per triangle and survives a reordered re-traversal" {
    const gpa = testing.allocator;
    var scene = try FloorScene.init(gpa, av3(0, 0.5, 0), false);
    defer scene.deinit(gpa);
    const key = (@as(u64, @min(scene.ground, scene.box)) << 32) | @max(scene.ground, scene.box);

    var constraints: std.ArrayListUnmanaged(rigid.ContactConstraint) = .empty;
    defer constraints.deinit(gpa);
    var cache = rigid.ContactCache{};
    defer cache.deinit(gpa);

    // ONE tick of the solve, so the cache holds a per-triangle history.
    cache.beginTick();
    try rigid.build(gpa, &constraints, &scene.world.bm, &scene.world.store, &.{key});
    try testing.expect(constraints.items.len >= 4);
    rigid.warmStart(&scene.world.bm, &cache, constraints.items);
    rigid.solveRange(&scene.world.bm, constraints.items, 0, constraints.items.len, .{});
    try rigid.storeContacts(gpa, &cache, constraints.items);
    cache.endTick();

    // Every stored key carries its own triangle index — the cache is keyed per triangle, not per
    // pair. Without the sub-shape term the entries of different triangles would collide on
    // `(pair, feature_id)`, `feature_id` being unique only WITHIN a manifold.
    var stored_ids: [8]bool = @splat(false);
    var stored: u32 = 0;
    for (constraints.items) |c| {
        for (c.points[0..c.count]) |pt| {
            const found = cache.lookup(.{
                .pair_key = c.pair_key,
                .subshape_id = c.subshape_id,
                .feature_id = pt.feature_id,
            });
            try testing.expect(found != null);
            stored_ids[c.subshape_id] = true;
            stored += 1;
        }
    }
    try testing.expect(stored >= 4);

    // **THE DECISIVE PROPERTY: no two triangles share a cache key.** `feature_id` is a LOCAL
    // identity — unique inside a manifold, not across them — and the floor's triangles are
    // geometrically similar, so the SAME feature_id really does recur on several of them. With
    // the sub-shape term every stored key is distinct; WITHOUT it, those recurrences would
    // become duplicate identical keys and a binary search would reheat one triangle from
    // another's history. Both halves are asserted: all keys pairwise distinct, AND at least one
    // feature_id present under two different sub-shapes, so the case is live and not
    // hypothetical.
    var recurring = false;
    for (cache.prev.items, 0..) |x, xi| {
        for (cache.prev.items[xi + 1 ..]) |y| {
            const same_key = x.key.pair_key == y.key.pair_key and
                x.key.subshape_id == y.key.subshape_id and
                x.key.feature_id == y.key.feature_id;
            try testing.expect(!same_key);
            if (x.key.feature_id == y.key.feature_id and x.key.subshape_id != y.key.subshape_id) {
                recurring = true;
            }
        }
    }
    try testing.expect(recurring);

    // **THE RE-TRAVERSAL, REORDERED.** The second tick's constraints are handed to the warm start
    // in REVERSE order — which is what a different SAH cut, or a different candidate order, would
    // produce. Each contact must still reheat from ITS OWN history: the lookup is keyed on
    // `(pair, subshape_id, feature_id)`, so the answer cannot depend on a position in the array.
    var reordered: std.ArrayListUnmanaged(rigid.ContactConstraint) = .empty;
    defer reordered.deinit(gpa);
    cache.beginTick();
    try rigid.build(gpa, &reordered, &scene.world.bm, &scene.world.store, &.{key});
    try testing.expectEqual(constraints.items.len, reordered.items.len);
    std.mem.reverse(rigid.ContactConstraint, reordered.items);

    // Every point of the reversed pass finds the entry of its OWN triangle, and the value it
    // reads is the one stored for that triangle — read back by key, so a lookup that ignored the
    // sub-shape would have to return some other triangle's impulse.
    var matched: u32 = 0;
    for (reordered.items) |c| {
        for (c.points[0..c.count]) |pt| {
            const own = cache.lookup(.{
                .pair_key = c.pair_key,
                .subshape_id = c.subshape_id,
                .feature_id = pt.feature_id,
            }) orelse continue;
            // The stored entry for that exact key, found independently by a linear scan rather
            // than by the binary search under test.
            var expected: ?rigid.CacheValue = null;
            for (cache.prev.items) |entry| {
                if (entry.key.pair_key == c.pair_key and
                    entry.key.subshape_id == c.subshape_id and
                    entry.key.feature_id == pt.feature_id)
                {
                    expected = entry.value;
                }
            }
            try testing.expect(expected != null);
            try testing.expectEqual(expected.?.lambda_n, own.lambda_n);
            try testing.expect(expected.?.tangent_impulse.eql(own.tangent_impulse));
            matched += 1;
        }
    }
    try testing.expect(matched >= 4);
    // The cache reports HITS, not cold starts: reheating actually happened on the reordered pass.
    const before = cache.hits;
    rigid.warmStart(&scene.world.bm, &cache, reordered.items);
    try testing.expect(cache.hits > before);
    try testing.expectEqual(@as(u32, 0), cache.misses);
}

test "mesh versus mesh and mesh versus half-space are unreachable" {
    // Both pairs are ASSERTED preconditions of the pair adapter, not answers. Exercised at the
    // grain a Zig test can reach: the assert itself cannot be caught, so what is checked is the
    // PREDICATE the assert rests on — that the two classes really are what the arms expect —
    // together with the fact that such a pair is never created by anything in the repo.
    //
    // The motive, restated because it is easy to state wrongly: the adapter presumes its pair
    // came from `computePairs` under a correct layer assignment, and a static↔static pair is a
    // programming error at its call site. It is NOT that `BodyType` determines the broad layer —
    // no such wiring exists, the layer being an insertion argument, and it arrives with
    // `PhysicsWorld` at M1.1.15.
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);

    const mesh = try store.createShape(gpa, .{ .triangle_mesh = .{
        .vertices = &cube_vertices,
        .indices = &cube_indices,
    } });
    const plane = try store.createShape(gpa, .{ .plane = .{} });
    const sphere = try store.createShape(gpa, .{ .sphere = .{ .radius = 1 } });

    try testing.expectEqual(ShapeClass.triangle_soup, store.get(mesh).?.class());
    try testing.expectEqual(ShapeClass.half_space, store.get(plane).?.class());
    try testing.expectEqual(ShapeClass.convex, store.get(sphere).?.class());

    // Both static-only shapes really are static-only, which is what makes a pair of them a
    // static↔static pair — the configuration the assertion calls a programming error.
    const mesh_body = try bm.addBody(gpa, &store, .{ .entity = entityOf(0), .body_type = .static, .shape = mesh });
    const plane_body = try bm.addBody(gpa, &store, .{ .entity = entityOf(1), .body_type = .static, .shape = plane });
    try testing.expectError(error.ShapeMustBeStatic, bm.addBody(gpa, &store, .{
        .entity = entityOf(2),
        .body_type = .dynamic,
        .shape = mesh,
    }));
    try testing.expectError(error.ShapeMustBeStatic, bm.addBody(gpa, &store, .{
        .entity = entityOf(3),
        .body_type = .dynamic,
        .shape = plane,
    }));

    // And the ADMITTED pairs are reachable and answered, so the unreachable arms are the only
    // ones left: a convex against either static-only shape produces contacts.
    //
    // The sphere is placed OUTSIDE the cube, penetrating its `+Y` face from above — a FRONT
    // contact. Its centre at `y = 1.5` with radius 1 puts its lowest point at `0.5`, half a metre
    // inside the face at `y = 1`.
    const dynamic_sphere = try bm.addBody(gpa, &store, .{
        .entity = entityOf(4),
        .body_type = .dynamic,
        .shape = sphere,
        .position = harness.av3(0, 1.5, 0),
    });
    var mesh_tally = ManifoldTally{};
    bm.collidePairEach(&store, mesh_body, dynamic_sphere, &mesh_tally);
    try testing.expect(mesh_tally.count >= 1);
    // The plane gets its OWN probe, placed to straddle it: the half-space is `{y <= 0}` by
    // default, and a unit sphere centred at `y = 0.5` reaches `−0.5`. The sphere above is 1.5 m
    // up and touches nothing of it — which is why one probe cannot serve both.
    const plane_sphere = try bm.addBody(gpa, &store, .{
        .entity = entityOf(5),
        .body_type = .dynamic,
        .shape = sphere,
        .position = harness.av3(10, 0.5, 0),
    });
    var plane_tally = ManifoldTally{};
    bm.collidePairEach(&store, plane_body, plane_sphere, &plane_tally);
    try testing.expectEqual(@as(u32, 1), plane_tally.count);

    // **THE BACK-FACE CULL, observed at the contact grain.** The same sphere moved to the
    // CENTRE of the closed cube produces NO manifold at all: it pokes out through several faces,
    // but always from BEHIND, and a contact generated on the back of a surface would resolve by
    // pushing the body further through it. The mode is `ignore`, fixed and internal to the
    // solver — contact generation takes no query as a parameter (§1.11.17).
    const inside_sphere = try bm.addBody(gpa, &store, .{
        .entity = entityOf(6),
        .body_type = .dynamic,
        .shape = sphere,
        .position = harness.av3(0, 0, 0),
    });
    var inside_tally = ManifoldTally{};
    bm.collidePairEach(&store, mesh_body, inside_sphere, &inside_tally);
    try testing.expectEqual(@as(u32, 0), inside_tally.count);
}

test "a box rests on a mesh floor, sleeps, and its aabb stops moving" {
    const gpa = testing.allocator;
    // Dropped from `y = 1.2`, so it falls a little and settles on the floor at `y ≈ 0.5` — the
    // box's half-extent — less the resting penetration the NGS pass leaves at the slop.
    var scene = try FloorScene.init(gpa, av3(0, 1.2, 0), true);
    defer scene.deinit(gpa);

    var had_contact = false;
    var t: u32 = 0;
    const asleep = while (t < 900) : (t += 1) {
        try scene.world.step(gpa);
        if (scene.world.constraints.items.len > 0) had_contact = true;
        if (scene.world.bm.isSleeping(scene.box).?) break true;
    } else false;
    // The box really did make contact with the mesh — otherwise it fell through and "asleep"
    // would mean nothing.
    try testing.expect(had_contact);
    try testing.expect(asleep);

    // It came to rest ON the floor, at the box's half-extent above it, within the resting
    // penetration the position solver leaves — `penetration_slop = 0.005 m` approached from
    // above (§1.7.2's fixed point).
    const resting_y = scene.world.bm.position(scene.box).?.toArray()[1];
    try testing.expect(resting_y < 0.5);
    try testing.expect(resting_y > 0.5 - 0.02);

    // ASLEEP means BIT-FROZEN: the body AABB does not move any more (§1.8.6's normative
    // observable), and neither does the pose. Checked over enough ticks that a slow drift would
    // show.
    const frozen_box = scene.world.bm.bodyAabb(&scene.world.store, scene.box).?;
    const frozen_pose = scene.world.bm.position(scene.box).?;
    for (0..120) |_| try scene.world.step(gpa);
    const later_box = scene.world.bm.bodyAabb(&scene.world.store, scene.box).?;
    try testing.expect(later_box.min.eql(frozen_box.min));
    try testing.expect(later_box.max.eql(frozen_box.max));
    try testing.expect(scene.world.bm.position(scene.box).?.eql(frozen_pose));
    try testing.expect(scene.world.bm.isSleeping(scene.box).?);
}

test "two runs with a mesh in the scene are bit-identical over many steps" {
    const gpa = testing.allocator;
    const steps = 300;

    // Two independent worlds, the same construction, the same number of ticks. Every pose bit
    // for bit — no hashed container on the contact path, and the per-triangle constraint order
    // is carried by the `(pair_key, subshape_id)` sort rather than by the traversal.
    var poses: [2][3]Real = undefined;
    for (0..2) |run| {
        var scene = try FloorScene.init(gpa, av3(0.25, 1.2, -0.3), false);
        defer scene.deinit(gpa);
        for (0..steps) |_| try scene.world.step(gpa);
        poses[run] = scene.world.bm.position(scene.box).?.toArray();
    }
    try testing.expectEqual(poses[0][0], poses[1][0]);
    try testing.expectEqual(poses[0][1], poses[1][1]);
    try testing.expectEqual(poses[0][2], poses[1][2]);
    // Non-vacuous: the box actually moved and settled rather than staying where it was put.
    try testing.expect(poses[0][1] < 1.2);
}

test "the contact answer is invariant under creation-order permutation" {
    const gpa = testing.allocator;

    // The SAME pair, built in both creation orders, so the mesh is body A in one and body B in
    // the other. The manifold set must be the same triangles with negated normals — which is
    // what `collidePairEach`'s canonicalisation is for — and the simulated trajectory must be
    // identical, since the solver iterates on the canonical `(pair_key, subshape_id)` order and
    // not on the order the scene was assembled in.
    var trajectories: [2][3]Real = undefined;
    for (0..2) |order| {
        const arrays = try floorMesh(gpa);
        defer gpa.free(arrays.vertices);
        defer gpa.free(arrays.indices);
        var world = harness.World.initNoSleep(vr(0, -9.81, 0), 1.0 / 60.0);
        defer world.deinit(gpa);

        const ground_shape = try world.store.createShape(gpa, .{ .triangle_mesh = .{
            .vertices = arrays.vertices,
            .indices = arrays.indices,
        } });
        const box_shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av3(0.5, 0.5, 0.5) } });

        // The ENTITY of each body is fixed to its role, so only the `BodyId` — the slot index,
        // hence the creation order — differs between the two runs.
        var box: api.BodyId = undefined;
        if (order == 0) {
            _ = try world.addBody(gpa, .{ .shape = ground_shape, .body_type = .static, .restitution = 0, .entity = entityOf(0) });
            box = try world.addBody(gpa, .{ .shape = box_shape, .position = harness.av3(0, 1.2, 0), .body_type = .dynamic, .mass = 1, .restitution = 0, .entity = entityOf(1) });
        } else {
            box = try world.addBody(gpa, .{ .shape = box_shape, .position = harness.av3(0, 1.2, 0), .body_type = .dynamic, .mass = 1, .restitution = 0, .entity = entityOf(1) });
            _ = try world.addBody(gpa, .{ .shape = ground_shape, .body_type = .static, .restitution = 0, .entity = entityOf(0) });
        }
        for (0..300) |_| try world.step(gpa);
        trajectories[order] = world.bm.position(box).?.toArray();
    }
    // **A PHYSICAL bound, and deliberately not a bit-exact one.** Swapping the creation order
    // swaps which body is A, so `collideOrdered` runs with its arguments the other way round —
    // and §3 guarantees only GEOMETRIC EQUIVALENCE between the two orders, never bit-exactness:
    // the two compute in different frames, and the manifold's point count may differ at a
    // topological contact boundary. C1.1 says the rest: a contact stack is chaotic, so two runs
    // an ULP apart decorrelate, and a bound on continuous deviation after hundreds of frames is
    // ill-posed.
    //
    // MEASURED over 300 steps: `Δy = 1.34e-4` m — and IDENTICALLY at f32 and f64, which is what
    // shows it is the geometric difference and not float noise. The bound below is 1 mm, some
    // seven times that, stated as a physical claim about where a box comes to rest.
    const settle_tol: Real = 1e-3;
    try testing.expectApproxEqAbs(trajectories[0][1], trajectories[1][1], settle_tol);
    try testing.expectApproxEqAbs(trajectories[0][0], trajectories[1][0], settle_tol);
    try testing.expectApproxEqAbs(trajectories[0][2], trajectories[1][2], settle_tol);
    // Non-vacuous: both runs fell and settled ON the floor rather than staying put or falling
    // through, so the agreement above is between two real simulations.
    try testing.expect(trajectories[0][1] < 1.2);
    try testing.expect(trajectories[0][1] > 0.4);
    try testing.expect(trajectories[1][1] > 0.4);
}

// ---------------------------------------------------------------------------
// Internal edges
// ---------------------------------------------------------------------------

/// A strip of `quads` quads along `+X`, spanning `z ∈ [−1, 1]`, every triangle wound with its
/// outward normal up.
///
/// `share` decides the TOPOLOGY and nothing else. With it, adjacent triangles reference the same
/// corner vertices, so every interior edge PAIRS and a flat seam comes out INACTIVE. Without it
/// each triangle carries its own three vertices, so every edge is the BOUNDARY of an open mesh
/// and therefore ACTIVE (§1.11.17). **The vertex COORDINATES are identical either way** — the
/// same numbers, to the bit — which is what makes the pair a counter-factual on the MECHANISM
/// and not on the shape.
///
/// `fold_sin` tilts every second quad by that sine, turning each seam into a fold of that angle;
/// zero leaves the strip flat.
fn slideStrip(gpa: std.mem.Allocator, quads: u32, share: bool, fold_sin: f32) !struct { vertices: []ApiVec3, indices: []u32 } {
    var vertices: std.ArrayListUnmanaged(ApiVec3) = .empty;
    var indices: std.ArrayListUnmanaged(u32) = .empty;
    const fold_cos: f32 = @sqrt(1 - fold_sin * fold_sin);

    const heights = try gpa.alloc(f32, quads + 1);
    defer gpa.free(heights);
    const xs = try gpa.alloc(f32, quads + 1);
    defer gpa.free(xs);
    heights[0] = 0;
    xs[0] = 0;
    for (1..quads + 1) |i| {
        heights[i] = heights[i - 1] + (if ((i % 2) == 1) fold_sin else -fold_sin);
        xs[i] = xs[i - 1] + (if (fold_sin == 0) 1 else fold_cos);
    }

    if (share) {
        for (0..quads + 1) |i| {
            try vertices.append(gpa, av3(xs[i], heights[i], -1));
            try vertices.append(gpa, av3(xs[i], heights[i], 1));
        }
        for (0..quads) |q| {
            const a: u32 = @intCast(q * 2);
            try indices.appendSlice(gpa, &.{ a, a + 1, a + 2 });
            try indices.appendSlice(gpa, &.{ a + 2, a + 1, a + 3 });
        }
    } else {
        for (0..quads) |q| {
            const p0 = av3(xs[q], heights[q], -1);
            const p1 = av3(xs[q], heights[q], 1);
            const p2 = av3(xs[q + 1], heights[q + 1], -1);
            const p3 = av3(xs[q + 1], heights[q + 1], 1);
            const base: u32 = @intCast(vertices.items.len);
            try vertices.appendSlice(gpa, &.{ p0, p1, p2, p2, p1, p3 });
            try indices.appendSlice(gpa, &.{ base, base + 1, base + 2, base + 3, base + 4, base + 5 });
        }
    }
    return .{
        .vertices = try vertices.toOwnedSlice(gpa),
        .indices = try indices.toOwnedSlice(gpa),
    };
}

/// Drive a FRICTIONLESS, UNDAMPED sphere across the strip and report the `+X` velocity it
/// retains after `steps` ticks.
///
/// Every source of lateral loss other than the internal-edge catch is removed, so the retained
/// velocity IS the measurement: friction is zero on both bodies (the combine rule `√μ_a · √μ_b`
/// makes the pair frictionless), and `linear_damping` is zeroed — measured, the default 0.05 alone
/// costs `5 · (1 − 0.05/60)⁶⁰ = 4.756049` m/s over sixty ticks, which would swamp the effect
/// under test and did on the first attempt.
///
/// A SPHERE and not a box, and that is where the artefact lives. A box resting flat contacts a
/// triangle FACE against FACE, so its normal is the face normal and there is nothing to correct
/// — measured, zero edge contacts over the whole run. A sphere whose centre has passed a seam
/// projects OUTSIDE the triangle behind it, so the closest feature of that triangle is the seam
/// EDGE and the normal it yields is TILTED. That is the internal-edge artefact, and `y0` is the
/// penetration: at 5 cm it appears reliably, and flush against the surface it does not appear at
/// all.
fn slideSphere(
    gpa: std.mem.Allocator,
    share: bool,
    fold_sin: f32,
    threshold: f32,
    y0: f32,
    steps: u32,
) !Real {
    const arrays = try slideStrip(gpa, 12, share, fold_sin);
    defer gpa.free(arrays.vertices);
    defer gpa.free(arrays.indices);

    var world = harness.World.initNoSleep(vr(0, -9.81, 0), 1.0 / 60.0);
    defer world.deinit(gpa);
    const ground = try world.store.createShape(gpa, .{ .triangle_mesh = .{
        .vertices = arrays.vertices,
        .indices = arrays.indices,
        .active_edge_cos_threshold = threshold,
    } });
    _ = try world.addBody(gpa, .{
        .shape = ground,
        .body_type = .static,
        .friction = 0,
        .restitution = 0,
        .entity = entityOf(0),
    });
    const sphere = try world.store.createShape(gpa, .{ .sphere = .{ .radius = 0.5 } });
    const slider = try world.addBody(gpa, .{
        .shape = sphere,
        .position = harness.av3(1, y0, 0),
        .body_type = .dynamic,
        .mass = 1,
        .friction = 0,
        .restitution = 0,
        .linear_damping = 0,
        .angular_damping = 0,
        .entity = entityOf(1),
    });
    world.bm.setLinearVelocity(slider, vr(5, 0, 0));
    var n: u32 = 0;
    while (n < steps) : (n += 1) {
        try world.step(gpa);
        if (world.bm.position(slider).?.toArray()[0] >= 9) break;
    }
    return world.bm.linearVelocity(slider).?.toArray()[0];
}

/// `cos(5°)`, the descriptor default — spelled out so a test that overrides it reads against a
/// named baseline.
const cos_5_deg: f32 = 0.99619472;
/// `cos(0.5°)` — a threshold TIGHTER than the default, under which a 2° fold counts as sharp.
const cos_half_deg: f32 = 0.9999619230641713;

test "a slider does not catch on a flat seam, and catches when that seam is active" {
    const gpa = testing.allocator;

    // A frictionless, undamped sphere launched at 5 m/s across a FLAT tessellated strip, 5 cm
    // into it so the trailing triangle's seam edge is reliably in contact.
    //
    // WITH the seams PAIRED they are flat, hence INACTIVE, hence the edge-derived normals are
    // snapped to the face normal — and the slider keeps its speed exactly. MEASURED: 5.000001
    // m/s, i.e. the loss is below a millionth of the speed, which on a frictionless flat plane is
    // the physically correct answer.
    const corrected = try slideSphere(gpa, true, 0, cos_5_deg, 0.45, 60);
    // A PHYSICAL bound, not an ULP one — the same class as RD-5's: 1% of the launch speed, forty
    // thousand times the measured loss.
    try testing.expect(corrected >= 4.95);

    // **THE COUNTER-FACTUAL, and it is an assertion in the same test rather than a manual
    // experiment.** The SAME geometry, vertex for vertex, with each triangle carrying its own
    // copies so no edge pairs: every seam is then a BOUNDARY edge of an open mesh and therefore
    // ACTIVE, the correction never fires, and the tilted normals decelerate the slider.
    // MEASURED: 4.647478 m/s, a 7% loss — and it FAILS the bound above, which is what makes the
    // first assertion a test of the MECHANISM and not of the geometry.
    const uncorrected = try slideSphere(gpa, false, 0, cos_5_deg, 0.45, 60);
    try testing.expect(uncorrected < 4.95);
    // Stated as a gap as well, so a future change that merely narrowed the difference could not
    // pass by drifting both numbers together.
    try testing.expect(corrected - uncorrected > 0.2);

    // **AND THE COUNTER-FACTUAL ON THE CODE, run and recorded.** Making `internalEdgeNormal`
    // return `null` unconditionally — the correction disabled, everything else untouched — takes
    // down FOUR tests of this suite: this one, the sharp-edge complement, the manifold-grain snap
    // test, and the bit-identity pair. So the bound above is load-bearing on the MECHANISM and
    // not only on the topology the second run varies.
    try testing.expect(corrected > uncorrected);
}

test "a sharp edge still catches, and the descriptor threshold is what decides" {
    const gpa = testing.allocator;

    // **THE COMPLEMENT, and the reason it is required.** The slider test above, with its
    // counter-factual, proves the mechanism FIRES. It does NOT refuse an implementation that
    // snapped EVERY normal to the face normal — that one would glide across the flat seam and
    // fail no counter-factual. What refuses it is this: an edge that is genuinely SHARP must
    // still catch.
    //
    // A 30° fold at the default `cos(5°)`: convex and far past the threshold, so ACTIVE, so no
    // correction. MEASURED: 0.769745 m/s retained of 5 — it catches hard, as a 30° ridge should.
    const fold_30 = @sin(std.math.degreesToRadians(@as(f32, 30)));
    const sharp = try slideSphere(gpa, true, fold_30, cos_5_deg, 0.5, 60);
    try testing.expect(sharp < 1.5);

    // **THE THRESHOLD MOVES THE BEHAVIOUR, IN BOTH DIRECTIONS, ON ONE GEOMETRY.** This is what
    // ties the configurability the descriptor gained to an OBSERVABLE: without it the field is
    // proved only by its type.
    //
    // A 2° fold, `cos 2° = 0.99939`:
    //   against the default `cos 5° = 0.99619` → `cos α < threshold` is FALSE → INACTIVE →
    //   corrected → MEASURED 4.969233 m/s;
    //   against `cos 0.5° = 0.99996` → TRUE → ACTIVE → not corrected → MEASURED 4.833944 m/s.
    // Same vertices, same slider, same ticks; only the threshold on the descriptor differs.
    const fold_2 = @sin(std.math.degreesToRadians(@as(f32, 2)));
    const smooth = try slideSphere(gpa, true, fold_2, cos_5_deg, 0.5, 60);
    const treated_as_sharp = try slideSphere(gpa, true, fold_2, cos_half_deg, 0.5, 60);
    try testing.expect(smooth > treated_as_sharp);
    try testing.expect(smooth - treated_as_sharp > 0.05);
    // And the smoothed run really is close to gliding, while the sharp-treated one is not — so
    // the ordering above is not two nearly-equal numbers happening to sort.
    try testing.expect(smooth > 4.9);
    try testing.expect(treated_as_sharp < 4.9);
}

/// Two quads meeting along the seam `x = 0`, `z ∈ [−1, 1]`, as four triangles.
///
/// Vertices `0..5` are `(−1,·,−1)`, `(−1,·,1)`, `(0,0,−1)`, `(0,0,1)`, `(1,0,−1)`, `(1,0,1)`, and
/// the LEFT quad's far edge is raised by `left_lift` so the seam becomes a fold. Triangles, in
/// order: `(0,1,2)`, `(2,1,3)`, `(2,3,4)`, `(4,3,5)` — each with `(v₁−v₀) × (v₂−v₀)` pointing up
/// on the flat variant. **Triangle 1 and triangle 2 share the seam `(2,3)`**, so with shared
/// indices that edge PAIRS; with a per-triangle copy it does not.
fn seamMesh(gpa: std.mem.Allocator, share: bool, left_lift: f32) !struct { vertices: []ApiVec3, indices: []u32 } {
    const p = [_]ApiVec3{
        av3(-1, left_lift, -1), av3(-1, left_lift, 1), av3(0, 0, -1),
        av3(0, 0, 1),           av3(1, 0, -1),         av3(1, 0, 1),
    };
    const tris = [_][3]u32{ .{ 0, 1, 2 }, .{ 2, 1, 3 }, .{ 2, 3, 4 }, .{ 4, 3, 5 } };
    var vertices: std.ArrayListUnmanaged(ApiVec3) = .empty;
    var indices: std.ArrayListUnmanaged(u32) = .empty;
    if (share) {
        try vertices.appendSlice(gpa, &p);
        for (tris) |t| try indices.appendSlice(gpa, &t);
    } else {
        for (tris) |t| {
            const base: u32 = @intCast(vertices.items.len);
            for (t) |v| try vertices.append(gpa, p[v]);
            try indices.appendSlice(gpa, &.{ base, base + 1, base + 2 });
        }
    }
    return .{
        .vertices = try vertices.toOwnedSlice(gpa),
        .indices = try indices.toOwnedSlice(gpa),
    };
}

test "the correction snaps an edge normal to the face normal, and only for an inactive edge" {
    const gpa = testing.allocator;

    // **THE MECHANISM AT THE MANIFOLD GRAIN, in closed form.** A unit-diameter sphere centred at
    // `(0.2, 0.45, −0.5)` sits 5 cm into a flat two-quad surface. Its centre projects at
    // `(x, z) = (0.2, −0.5)`:
    //   - INSIDE triangle 2, whose `(x, z)` corners are `(0,−1)`, `(0,1)`, `(1,−1)` — the
    //     hypotenuse being `2x + z = 1` and `2(0.2) + (−0.5) = −0.1 < 1`. So that contact is a
    //     FACE contact and its normal is `+Y` with nothing to correct.
    //   - OUTSIDE triangle 1, whose corners are `(0,−1)`, `(−1,1)`, `(0,1)`, all at `x <= 0`. The
    //     closest feature of triangle 1 is therefore the SEAM EDGE, at `(0, 0, −0.5)`, and the
    //     vector from it to the sphere centre is `(0.2, 0.45, 0)`, of length
    //     `√(0.04 + 0.2025) = 0.4924 < 0.5` — so it really is in contact, and the normal it
    //     yields is TILTED: `(0.2, 0.45, 0) / 0.4924 = (0.40614, 0.91382, 0)`.
    //
    // Triangles 0 and 3 are out of reach — 0.702 m and 0.667 m from the centre against a 0.5 m
    // radius — so exactly two triangles answer, which the count below pins.
    const tilted = vr(0.40614, 0.91382, 0);
    const face = vr(0, 1, 0);
    const tol: Real = 1e-4;

    for ([_]bool{ true, false }) |share| {
        const arrays = try seamMesh(gpa, share, 0);
        defer gpa.free(arrays.vertices);
        defer gpa.free(arrays.indices);
        var store = ShapeStore{};
        defer store.deinit(gpa);
        var bm = BodyManager{};
        defer bm.deinit(gpa);

        const ground_shape = try store.createShape(gpa, .{ .triangle_mesh = .{
            .vertices = arrays.vertices,
            .indices = arrays.indices,
        } });
        const ground = try bm.addBody(gpa, &store, .{ .entity = entityOf(0), .body_type = .static, .shape = ground_shape });
        const sphere_shape = try store.createShape(gpa, .{ .sphere = .{ .radius = 0.5 } });
        const sphere = try bm.addBody(gpa, &store, .{
            .entity = entityOf(1),
            .body_type = .dynamic,
            .shape = sphere_shape,
            .position = harness.av3(0.2, 0.45, -0.5),
        });

        var tally = ManifoldTally{};
        bm.collidePairEach(&store, ground, sphere, &tally);
        try testing.expectEqual(@as(u32, 2), tally.count);

        // The seam-edge contact is triangle 1's; the face contact is triangle 2's.
        var seam_normal: ?Vec3r = null;
        var face_normal: ?Vec3r = null;
        for (tally.ids[0..tally.count], tally.normals[0..tally.count]) |id, n| {
            if (id == 1) seam_normal = n;
            if (id == 2) face_normal = n;
        }
        try testing.expect(seam_normal != null);
        try testing.expect(face_normal != null);
        // The FACE contact is `+Y` whatever the topology — it was never a candidate for
        // correction, which is what shows the correction is targeted and not blanket.
        try testing.expect(face_normal.?.approxEql(face, tol));

        if (share) {
            // The seam PAIRS, both triangles are coplanar, so the edge is INACTIVE and the
            // tilted normal is snapped to the face normal.
            try testing.expect(seam_normal.?.approxEql(face, tol));
        } else {
            // Nothing pairs, so the seam is a BOUNDARY edge — ACTIVE — and the tilted normal
            // stands, at the closed-form value derived above.
            try testing.expect(seam_normal.?.approxEql(tilted, tol));
        }
    }
}

test "a concave seam is never active, whatever the threshold" {
    const gpa = testing.allocator;

    // A CONCAVE edge is inactive ALWAYS — the rule carries no threshold at all (§1.11.17) — so
    // the discriminating test pins it against a threshold TIGHT enough to activate a convex fold
    // of the same angle. Without that the answer could be explained by the angle alone.
    //
    // The left quad is lifted by `sin 10°` at its far edge, and then dropped by the same amount,
    // giving one convex seam and one concave seam of the same 10° from the same numbers. At
    // `cos(0.5°)` a 10° convex fold is far past the threshold and ACTIVE; the concave one is
    // inactive regardless.
    const lift = @sin(std.math.degreesToRadians(@as(f32, 10)));
    for ([_]struct { lift: f32, expect_active: bool }{
        .{ .lift = -lift, .expect_active = true }, // left quad DOWN → convex ridge at the seam
        .{ .lift = lift, .expect_active = false }, // left quad UP → concave valley at the seam
    }) |c| {
        const arrays = try seamMesh(gpa, true, c.lift);
        defer gpa.free(arrays.vertices);
        defer gpa.free(arrays.indices);
        var store = ShapeStore{};
        defer store.deinit(gpa);
        const id = try store.createShape(gpa, .{ .triangle_mesh = .{
            .vertices = arrays.vertices,
            .indices = arrays.indices,
            .active_edge_cos_threshold = cos_half_deg,
        } });
        const data = store.get(id).?.mesh.?;
        // The seam is triangle 1's edge 2 — `(v₂, v₀)` = indices `(3, 2)` — and triangle 2's
        // edge 0 — `(v₀, v₁)` = indices `(2, 3)`. Both must report the same verdict, the flag
        // being set on both members of a pair or on neither.
        try testing.expectEqual(c.expect_active, data.edgeIsActiveAt(1, 2));
        try testing.expectEqual(c.expect_active, data.edgeIsActiveAt(2, 0));
    }
}

test "two runs of the slider are bit-identical" {
    const gpa = testing.allocator;
    // The slider scene has a mesh in it, per-triangle contacts, per-triangle warm starting AND
    // the internal-edge correction on the path — every mechanism this milestone added. Two
    // independent runs must agree bit for bit: no hashed container anywhere, and the constraint
    // order carried by `(pair_key, subshape_id)` rather than by the traversal.
    const first = try slideSphere(gpa, true, 0, cos_5_deg, 0.45, 60);
    const second = try slideSphere(gpa, true, 0, cos_5_deg, 0.45, 60);
    try testing.expectEqual(first, second);
    // Non-vacuous: the slider actually ran and kept its speed rather than never starting.
    try testing.expect(first > 4.95);

    // And with the seams ACTIVE, where the trajectory is genuinely perturbed, the two runs still
    // agree bit for bit — which is the harder half, the perturbation being what a
    // non-deterministic order would show up in.
    const rough_first = try slideSphere(gpa, false, 0, cos_5_deg, 0.45, 60);
    const rough_second = try slideSphere(gpa, false, 0, cos_5_deg, 0.45, 60);
    try testing.expectEqual(rough_first, rough_second);
    try testing.expect(rough_first < 4.95);
}

// ---------------------------------------------------------------------------
// Closing-review findings
// ---------------------------------------------------------------------------

/// One triangle spanning `[−1, 1]²` in the plane `y = 0`, outward normal `+Y`:
/// `(v₁−v₀) × (v₂−v₀) = (0,0,2) × (2,0,0) = (0, 4, 0)`.
const wide_triangle_vertices = [_]ApiVec3{ av3(-1, 0, -1), av3(-1, 0, 1), av3(1, 0, -1) };

/// The GJK contact margin for a box probe of half-extent `he` hovering `gap` above that
/// triangle, computed through the SAME public helpers the filter and the classification both use
/// — so the test states the band rather than hardcoding a number that would be wrong at the other
/// precision.
fn wideTriangleMargin(data: *const MeshData, he: Real, gap: Real) Real {
    const probe: narrowphase.SupportShape(Real) = .{ .core = .{ .box = Vec3r.splat(he) }, .radius = 0 };
    const scale = narrowphase.coordScale(Real, he + gap, probe, .{ .core = .point, .radius = 0 }) +
        data.maxVertexMagnitude();
    return narrowphase.contactMargin(Real, scale);
}

test "F1 the mesh candidate filter is conservative with respect to the GJK margin" {
    const gpa = testing.allocator;
    // The descriptor's precision, and the solver's widening of it — the half-extent crosses the
    // `f32` boundary, so it is declared there and widened once (the class of finding the closed
    // forms of gates C and D kept turning up).
    const he_f32: f32 = 0.2;
    const he: Real = he_f32;

    // A box probe hovering a HAIR above one triangle. Two gaps, both derived from the normative
    // margin rather than written as literals:
    //   * HALF the margin — GJK classifies the pair as not `separated`, so §1.11.12's predicate
    //     says the body overlaps. The two boxes do NOT touch (the gap is strictly positive), so an
    //     unhardened filter drops the triangle before the kernel ever sees it.
    //   * TEN TIMES the margin — genuinely `separated`, so the answer is false. This is what makes
    //     the inflation bounded rather than a blanket widening.
    for ([_]bool{ true, false }) |inside_band| {
        var world = harness.World.initNoSleep(Vec3r.zero, 1.0 / 60.0);
        defer world.deinit(gpa);
        const shape = try world.store.createShape(gpa, .{ .triangle_mesh = .{
            .vertices = &wide_triangle_vertices,
            .indices = &one_triangle_indices,
        } });
        const body = try world.addBody(gpa, .{
            .shape = shape,
            .body_type = .static,
            .entity = entityOf(0),
        });
        const data = world.store.get(shape).?.mesh.?;
        // The margin depends on the probe's height, which depends on the gap; one iteration of the
        // fixed point is ample, the gap being some seven orders below the geometry.
        const seed_margin = wideTriangleMargin(data, he, 0);
        const gap: Real = if (inside_band) seed_margin / 2 else seed_margin * 10;
        try testing.expect(gap > 0);

        const probe_shape = try world.store.createShape(gpa, .{ .box = .{ .half_extents = av3(he_f32, he_f32, he_f32) } });
        const probe = shape_mod.supportShape(world.store.get(probe_shape).?);
        const probe_position = vr(0, he + gap, 0);

        // The KERNEL's own verdict, taken directly, so the entry is compared against the
        // predicate §1.11.12 states and not against a second opinion.
        const regime = narrowphase.gjk(
            Real,
            probe,
            probe_position,
            Quatr.identity,
            shape_mod.triangleSupportShape(data, 0),
            world.bm.position(body).?,
            world.bm.rotation(body).?,
        ).status;
        try testing.expectEqual(inside_band, regime != .separated);

        // --- PATH 1: the shape overlap. The entry must agree with the kernel.
        var buf: [4]api.BodyId = undefined;
        const overlaps = try query.overlapShape(&world.bp, &world.bm, &world.store, .{
            .shape = probe_shape,
            .position = probe_position,
            .back_face_mode = .collide,
        }, &buf);
        try testing.expectEqual(@as(u32, if (inside_band) 1 else 0), overlaps);

        // --- PATH 2: contact generation. Its predicate is `collideOrdered` returning non-null,
        // which it does for a `shallow` pair, so the same band applies and the same filter feeds it.
        // The pose is set at SOLVER precision, not carried in the descriptor. The descriptor's
        // position is `f32` by design (§1.11.8), and at `f64` this gap is `3.5e-15` — six orders
        // below `f32`'s resolution at 0.2 — so it would narrow away to zero and the probe would
        // land exactly touching, making the out-of-band branch report a contact. Measured; the
        // same class as the eighth-turn rotation at gate A and the `f32(0.3)` extent at gate D.
        const dynamic_probe = try world.addBody(gpa, .{
            .shape = probe_shape,
            .body_type = .dynamic,
            .entity = entityOf(1),
        });
        world.bm.setPosition(dynamic_probe, probe_position);
        var tally = ManifoldTally{};
        world.bm.collidePairEach(&world.store, body, dynamic_probe, &tally);
        try testing.expectEqual(@as(u32, if (inside_band) 1 else 0), tally.count);

        // The BOXES do not overlap in either case — which is the whole point: without the
        // inflation the traversal offers nothing and both paths answer false, band or no band.
        const probe_box = bm_mod.supportShapeAabb(probe, probe_position, Quatr.identity);
        const triangle_box = data.triangleAabb(0);
        try testing.expect(!probe_box.overlaps(triangle_box));
    }
}

test "F2 a face normal stays unit for legal vertices whose cross product overflows" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);

    // **THE DOMAIN IS LEGAL AND THE OLD FORM RETURNED A ZERO-LENGTH NORMAL.** Vertices at `1e10`
    // are finite, so `MeshData.init` admits them; the cross product `(v₁−v₀) × (v₂−v₀)` of
    // `(1e10,0,0)` and `(0,1e10,0)` is `(0, 0, 1e20)`, whose squared length is `1e40` — INFINITY at
    // `f32`. A plain `normalize` then computes `1 / inf = 0` and scales the vector to `(0, 0, 0)`:
    // a normal of length zero, and §1.11.17's unit-length invariant punctured.
    //
    // Note what does NOT cover this: the true-zero degeneracy refusal at creation. That one rules
    // out a cross product of exactly zero, hence a NaN; this is an OVERFLOW at the other end of the
    // range, and the guard has nothing to say about it.
    const huge = [_]ApiVec3{ av3(0, 0, 0), av3(1e10, 0, 0), av3(0, 1e10, 0) };
    const big = try store.createShape(gpa, .{ .triangle_mesh = .{
        .vertices = &huge,
        .indices = &one_triangle_indices,
    } });
    const big_normal = store.get(big).?.mesh.?.faceNormal(0);
    // Exactly `+Z`, and its length asserted TIGHT: the reduction by the largest absolute component
    // makes the arithmetic scale-free, so this is not a tolerance being met but an exact answer.
    try testing.expect(big_normal.eql(vr(0, 0, 1)));
    try testing.expectEqual(@as(Real, 1), big_normal.lengthSq());

    // THE OTHER END: vertices so small that the cross product's square UNDERFLOWS. `2⁻⁷⁰` cubed
    // territory — the cross product is `(0, 0, 2⁻¹⁴⁰)`, whose square is `2⁻²⁸⁰`, zero at `f32`. A
    // plain `normalize` divides by zero and answers infinities; the scaled form is exact.
    const tiny_side: f32 = std.math.pow(f32, 2, -70);
    const tiny = [_]ApiVec3{ av3(0, 0, 0), av3(tiny_side, 0, 0), av3(0, tiny_side, 0) };
    const small = try store.createShape(gpa, .{ .triangle_mesh = .{
        .vertices = &tiny,
        .indices = &one_triangle_indices,
    } });
    const small_normal = store.get(small).?.mesh.?.faceNormal(0);
    try testing.expect(small_normal.eql(vr(0, 0, 1)));
    try testing.expectEqual(@as(Real, 1), small_normal.lengthSq());

    // And the RAY kernel, which normalises the same cross product, answers a unit normal on the
    // same geometry — the second consumer the shared helper exists for.
    const hit = narrowphase.triangle.rayTriangle(
        Real,
        store.get(big).?.mesh.?.triangle(0),
        vr(1e9, 1e9, 5),
        vr(0, 0, -1),
    ).?;
    try testing.expectEqual(@as(Real, 1), hit.normal.lengthSq());
    try testing.expect(hit.normal.eql(vr(0, 0, 1)));

    // The COUNTER-FACTUAL, stated as arithmetic rather than by editing the code: the squared
    // length the old form fed to `sqrt` really is infinite at `f32`, so its `1 / length` really is
    // zero. `normalizeScaled` never forms that quantity.
    if (Real == f32) {
        const overflowing: Real = @as(Real, 1e20) * @as(Real, 1e20);
        try testing.expect(!std.math.isFinite(overflowing));
        try testing.expectEqual(@as(Real, 0), 1 / @sqrt(overflowing));
    }
}

test "F5 the normal and the ray parameter survive both ends of the vertex domain" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);

    // **F2 CLOSED ONLY THE SQUARE OF THE NORM. The cross product overflows one step EARLIER, and
    // the edge one step before that.** Three failures on the same path, measured on this branch
    // before the fix:
    //
    //   legs `1e20`   → cross `(0,0,1e40)` = `(0,0,inf)` at `f32`; `normalizeScaled` divides
    //                   `inf` by its own largest component `inf` and answers `(NaN,NaN,NaN)`.
    //                   Worse than F2's zero vector, a NaN propagating instead of sitting still.
    //   legs `3e38`   → the same.
    //   `±0.9·max`    → the SUBTRACTION overflows: `e0 = (inf,0,0)`, cross `(0,NaN,inf)`. This one
    //                   is precision-INDEPENDENT and reproduced at `f64` as well.
    //
    // The fix reduces the three vertices by one common power of two BEFORE subtracting, so every
    // component lands below 1, every difference below 2, every cross component below 4. Each case
    // below asserts the EXACT normal and a length of exactly 1 — not a tolerance met, an exact
    // answer, because a power-of-two factor cancels bit-for-bit inside `normalizeScaled`.
    const legs = [_]f32{ 1e20, 3e38 };
    for (legs) |leg| {
        const verts = [_]ApiVec3{ av3(0, 0, 0), av3(leg, 0, 0), av3(0, leg, 0) };
        const id = try store.createShape(gpa, .{ .triangle_mesh = .{
            .vertices = &verts,
            .indices = &one_triangle_indices,
        } });
        const data = store.get(id).?.mesh.?;
        // Counter-clockwise seen from +Z: `(leg,0,0) × (0,leg,0) = (0,0,leg²)`, so `+Z`.
        const n = data.faceNormal(0);
        try testing.expect(n.eql(vr(0, 0, 1)));
        try testing.expectEqual(@as(Real, 1), n.lengthSq());

        // THE RAY KERNEL, which is the second finding: its own Möller–Trumbore arithmetic
        // returned `t = NaN` here, and a NaN distance passes every bound the kernel tests. The
        // ray drops from `+Z` straight through the point `(leg/4, leg/4, 0)`, which is inside the
        // triangle since `1/4 + 1/4 < 1`, so the closed-form distance is the drop height itself.
        const drop: Real = 8;
        const hit = narrowphase.triangle.rayTriangle(
            Real,
            data.triangle(0),
            vr(@as(Real, leg) / 4, @as(Real, leg) / 4, drop),
            vr(0, 0, -1),
        ).?;
        try testing.expect(std.math.isFinite(hit.distance));
        try testing.expectEqual(drop, hit.distance);
        try testing.expect(hit.normal.eql(vr(0, 0, 1)));
        try testing.expectEqual(@as(Real, 1), hit.normal.lengthSq());
        try testing.expect(!hit.back_face);
    }

    // THE SUBTRACTION END, the one that fails at BOTH precisions. Two finite vertices whose
    // difference is not finite: `0.9·floatMax − (−0.9·floatMax) = 1.8·floatMax`, i.e. infinity.
    // Reducing first makes the same difference `1.8·m` with `m < 1`, hence under 2.
    {
        const big: f32 = std.math.floatMax(f32) * 0.9;
        const verts = [_]ApiVec3{ av3(-big, 0, 0), av3(big, 0, 0), av3(-big, big, 0) };
        const id = try store.createShape(gpa, .{ .triangle_mesh = .{
            .vertices = &verts,
            .indices = &one_triangle_indices,
        } });
        const data = store.get(id).?.mesh.?;
        // `(v₁−v₀) × (v₂−v₀) = (2·big,0,0) × (0,big,0) = (0, 0, 2·big²)`, so `+Z` again.
        const n = data.faceNormal(0);
        try testing.expect(n.eql(vr(0, 0, 1)));
        try testing.expectEqual(@as(Real, 1), n.lengthSq());

        // Inside the triangle: the legs run `+X` by `2·big` and `+Y` by `big` from `(−big, 0)`,
        // so `(−big + big/2, big/4)` has barycentrics `1/4` and `1/4`.
        const drop: Real = 4;
        const hit = narrowphase.triangle.rayTriangle(
            Real,
            data.triangle(0),
            vr(-@as(Real, big) / 2, @as(Real, big) / 4, drop),
            vr(0, 0, -1),
        ).?;
        try testing.expect(std.math.isFinite(hit.distance));
        try testing.expectEqual(drop, hit.distance);
        try testing.expectEqual(@as(Real, 1), hit.normal.lengthSq());
    }

    // THE DENORMAL END. Legs of `4 · floatTrueMin` cross to `16 · floatTrueMin²`, which underflows
    // to EXACTLY ZERO in the vertices' own units — so before the fix `MeshData.init` refused this
    // descriptor as degenerate, contradicting `isDegenerate`'s own claim that a sliver of
    // minuscule non-zero area must be served. After the reduction the same triangle is an ordinary
    // right triangle with legs of `0.5` and normalises exactly. Note the reduction LIFTS here
    // rather than shrinking, which is why the scale factor is applied in two halves: the exponent
    // needed is around `2^148`, itself unrepresentable at `f32`.
    {
        const tiny: f32 = std.math.floatTrueMin(f32) * 4;
        const verts = [_]ApiVec3{ av3(0, 0, 0), av3(tiny, 0, 0), av3(0, tiny, 0) };
        const id = try store.createShape(gpa, .{ .triangle_mesh = .{
            .vertices = &verts,
            .indices = &one_triangle_indices,
        } });
        const data = store.get(id).?.mesh.?;
        const n = data.faceNormal(0);
        try testing.expect(n.eql(vr(0, 0, 1)));
        try testing.expectEqual(@as(Real, 1), n.lengthSq());

        // The kernel too, on a COMMENSURATE ray: the drop is twice the leg, so the whole
        // configuration lives at one scale and the reduction lifts all of it together. This case
        // is a GAIN — the unreduced form missed it, its cross product having underflowed.
        const drop: Real = @as(Real, tiny) * 2;
        const hit = narrowphase.triangle.rayTriangle(
            Real,
            data.triangle(0),
            vr(@as(Real, tiny) / 4, @as(Real, tiny) / 4, drop),
            vr(0, 0, -1),
        ).?;
        try testing.expect(std.math.isFinite(hit.distance));
        try testing.expectEqual(drop, hit.distance);
        try testing.expectEqual(@as(Real, 1), hit.normal.lengthSq());

        // **THE MEASURED LIMIT, and it is a PRECISION limit rather than a design one — which is
        // why the two precisions are asserted to differ here instead of one of them being
        // skipped.** An ORDINARY-magnitude origin against this same triangle spans some forty
        // orders of magnitude. `det` is the leg squared, and at `f32` `(4·floatTrueMin)²` is zero
        // at the input's own scale while at the reduced scale the offset no longer fits, so every
        // form measured — unreduced, reduced, and the composition — answers a MISS. The
        // information is not in the inputs, exactly as §1.11.4 bis records for the convex
        // kernels, and what matters is the DIRECTION of the failure: a miss, never a NaN and
        // never a false hit. At `f64` the same descriptor is unremarkable — the legs are an `f32`
        // value widened, so `leg²` is about `3.1e-89` and perfectly normal — and the kernel
        // answers the exact distance. That contrast is the evidence that nothing here is
        // structural.
        const ordinary = narrowphase.triangle.rayTriangle(
            Real,
            data.triangle(0),
            vr(@as(Real, tiny) / 4, @as(Real, tiny) / 4, 2),
            vr(0, 0, -1),
        );
        if (Real == f32) {
            try testing.expect(ordinary == null);
        } else {
            try testing.expectEqual(@as(Real, 2), ordinary.?.distance);
            try testing.expectEqual(@as(Real, 1), ordinary.?.normal.lengthSq());
        }
    }

    // THE COUNTER-FACTUAL, as arithmetic rather than by editing the code: the two overflows the
    // unscaled form really does produce, and what each one becomes downstream. `inf / inf` is the
    // NaN, and the reduced forms of the same quantities are ordinary small numbers.
    if (Real == f32) {
        const cross_overflow: Real = @as(Real, 1e20) * @as(Real, 1e20);
        try testing.expect(std.math.isInf(cross_overflow));
        try testing.expect(std.math.isNan(cross_overflow / cross_overflow));

        const big: Real = std.math.floatMax(Real) * 0.9;
        try testing.expect(std.math.isInf(big - (-big)));
    }
    // The subtraction end is NOT precision-dependent, so it is asserted at both.
    {
        const big: Real = std.math.floatMax(Real) * 0.9;
        try testing.expect(std.math.isInf(big - (-big)));
        // Reduced by the power of two `frexp` picks, the same difference is finite and under 2.
        const exp = -std.math.frexp(big).exponent;
        const reduced = vr(big, 0, 0).scalePow2(exp);
        const rx = reduced.toArray()[0];
        try testing.expect(@abs(rx - (-rx)) < 2);
    }
}

test "F5 the power-of-two reduction is exact, so no verdict and no normal moves" {
    // The reduction's whole licence is that it changes NOTHING for inputs that already worked.
    // Two properties carry that, and both are asserted rather than argued.

    // (1) EXACTNESS. Scaling by a power of two rewrites the exponent field and leaves the
    // mantissa alone, so a value scaled down and back up is bit-identical — including for a
    // denormal, where the intermediate would be unrepresentable if the factor were materialised
    // once instead of in halves.
    {
        const cases = [_]Real{ 1, 0.1, 3, std.math.floatMax(Real) * 0.9, std.math.floatTrueMin(Real) * 4 };
        for (cases) |c| {
            const v = vr(c, -c * 0.5, c * 0.25);
            const exp = -std.math.frexp(c).exponent;
            const round_trip = v.scalePow2(exp).scalePow2(-exp);
            try testing.expect(round_trip.eql(v));
        }
    }

    // (2) COLLINEARITY. This is the property the true-zero degeneracy guard rests on, and the
    // one an arbitrary scale factor would break by rounding each division: three exactly
    // collinear points must still give an exactly zero cross product after reduction, at any
    // magnitude. A non-power-of-two factor is shown failing the same case just below.
    {
        // Every magnitude's TRIPLE must stay finite, the third point being exactly `3 ×` the
        // second — `floatMax * 0.9` would make `v2` an infinity and the assert inside
        // `pow2ReductionExponent` would fire on a malformed input rather than on a defect.
        const magnitudes = [_]Real{ 1, 1e20, std.math.floatMax(Real) / 4, std.math.floatTrueMin(Real) * 8 };
        for (magnitudes) |m| {
            // Collinear by construction: `v₂ − v₀` is exactly three times `v₁ − v₀`.
            const v0 = vr(0, 0, 0);
            const v1 = vr(m, m, m);
            const v2 = vr(m * 3, m * 3, m * 3);
            try testing.expect(shippedZero(v0, v1, v2));
        }
    }

    // (3) The NORMAL is invariant under the choice of exponent — which is what makes "the shared
    // form" a real claim and not a hope, the mesh reducing by its vertices while the ray kernel
    // reduces by its vertices AND its origin, hence in general by a different power of two.
    //
    // Since F6 the reduction is PER EDGE, so there are TWO exponents and they are swept
    // INDEPENDENTLY — 49 combinations, not 7. That is the stronger claim and the one the per-edge
    // form actually needs: the two factors compose into a single common factor on the cross, which
    // `normalizeScaled` cancels, so the unit normal cannot depend on either exponent.
    {
        const v0 = vr(0.25, -3, 7);
        const v1 = vr(11, 2, -0.5);
        const v2 = vr(-4, 9, 3);
        const reference = shippedDirection(v0, v1, v2).?.normalizeScaled().?;
        const exps = [_]i32{ -37, -8, -1, 0, 1, 8, 37 };
        for (exps) |k1| {
            for (exps) |k2| {
                // `v0` is shared by both edges, so scaling it alone would change the geometry.
                // What the two edges' factors are free to differ in is reached by moving the two
                // FAR vertices independently and by putting the shared vertex at the origin.
                const scaled = shippedDirection(
                    Vec3r.zero,
                    v1.scalePow2(k1),
                    v2.scalePow2(k2),
                ).?.normalizeScaled().?;
                const plain = shippedDirection(Vec3r.zero, v1, v2).?.normalizeScaled().?;
                try testing.expect(scaled.eql(plain));
            }
        }
        // And the common-factor sweep still holds on the full triangle.
        for (exps) |k| {
            const scaled = shippedDirection(
                v0.scalePow2(k),
                v1.scalePow2(k),
                v2.scalePow2(k),
            ).?.normalizeScaled().?;
            try testing.expect(scaled.eql(reference));
        }
    }

    // (4) The COUNTER-FACTUAL for the power-of-two requirement itself. Reducing by the largest
    // absolute component — the obvious choice, and the one `normalizeScaled` makes for a purpose
    // where it is harmless — rounds each division, and the collinear triple above then has a
    // NON-zero cross product: the degeneracy guard's verdict moves, which is exactly what the
    // power of two buys and what a comment alone would not have caught.
    {
        const m: Real = 1;
        const v0 = vr(0, 0, 0);
        const v1 = vr(m, m, m);
        const v2 = vr(m * 3, m * 3, m * 3);
        // The scale that a plain reduction would use, deliberately not a power of two.
        const s: Real = 3 * m;
        const a = v0.scale(1 / s);
        const b = v1.scale(1 / s);
        const c = v2.scale(1 / s);
        const rounded = b.sub(a).cross(c.sub(a));
        // Still zero for this particular triple — `1/3` rounds the SAME way in all three
        // components, so proportionality survives. The failure needs components that round
        // differently from one another, which is the point: the property holds by luck, not by
        // construction, and only the power of two makes it structural.
        try testing.expectEqual(@as(Real, 0), rounded.maxAbsComponent());

        const q0 = vr(0, 0, 0);
        const q1 = vr(1, 3, 7);
        const q2 = vr(3, 9, 21); // exactly 3 × q1, hence exactly collinear
        try testing.expect(shippedZero(q0, q1, q2));

        // A non-power-of-two divisor rounds each component independently, and a triple where the
        // three roundings do not stay proportional loses the collinearity. WHICH divisor does
        // that depends on the precision, so it is SEARCHED rather than hard-coded — a hard-coded
        // 7 breaks the property at `f32` and preserves it at `f64`, which would have made this
        // counter-factual silently vacuous at one of the two precisions. The assertion is that
        // such a divisor exists, which is the actual claim being made about power-of-two scaling.
        var broken = false;
        var d: Real = 3;
        while (d < 200) : (d += 1) {
            const w0 = q0.scale(1 / d);
            const w1 = q1.scale(1 / d);
            const w2 = q2.scale(1 / d);
            if (w1.sub(w0).cross(w2.sub(w0)).maxAbsComponent() > 0) {
                broken = true;
                break;
            }
        }
        try testing.expect(broken);
        // And the power-of-two form never loses it, at the same magnitudes.
        for ([_]i32{ -60, -3, 0, 3, 60 }) |k| {
            try testing.expect(shippedZero(q0.scalePow2(k), q1.scalePow2(k), q2.scalePow2(k)));
        }
    }
}

// ---------------------------------------------------------------------------------------------
// F6 — the exact degeneracy oracle, and the property that closes the CLASS rather than a repro.
// ---------------------------------------------------------------------------------------------

/// `x == m · 2^e` with `m` an exact integer. Zero maps to `(0, 0)`.
fn decomposeExact(comptime T: type, x: T) struct { m: i128, e: i32 } {
    if (x == 0) return .{ .m = 0, .e = 0 };
    const bits = std.math.floatMantissaBits(T) + 1;
    const f = std.math.frexp(x);
    return .{ .m = @intFromFloat(std.math.ldexp(f.significand, bits)), .e = f.exponent - bits };
}

/// The exact verdict, and the binary exponent of the exact cross's largest component.
const ExactCross = struct { zero: bool, top_exp: i32 };

/// EXACT `(v₁−v₀) × (v₂−v₀)` in integer arithmetic, so the zero test carries no tolerance and
/// needs no wider float — `f128` is deliberately not used, being software-emulated on most
/// targets and unnecessary here. Every component is written as an integer times ONE common
/// `2^emin`, after which the differences and the whole cross are exact integer operations and the
/// common factor is irrelevant to the verdict. The integers reach about `2^300` at `f32` and
/// `2^2150` at `f64`, hence big integers.
fn exactTriangleCross(gpa: std.mem.Allocator, v: [3][3]Real) !ExactCross {
    const Big = std.math.big.int.Managed;
    var emin: i32 = std.math.maxInt(i32);
    var any = false;
    for (v) |vertex| {
        for (vertex) |component| {
            const d = decomposeExact(Real, component);
            if (d.m != 0) {
                any = true;
                if (d.e < emin) emin = d.e;
            }
        }
    }
    if (!any) return .{ .zero = true, .top_exp = 0 };

    var x: [3][3]Big = undefined;
    for (0..3) |i| {
        for (0..3) |k| {
            x[i][k] = try Big.init(gpa);
            const d = decomposeExact(Real, v[i][k]);
            try x[i][k].set(d.m);
            if (d.m != 0) try x[i][k].shiftLeft(&x[i][k], @intCast(d.e - emin));
        }
    }
    defer for (0..3) |i| {
        for (0..3) |k| x[i][k].deinit();
    };

    var e0: [3]Big = undefined;
    var e1: [3]Big = undefined;
    for (0..3) |k| {
        e0[k] = try Big.init(gpa);
        e1[k] = try Big.init(gpa);
        try e0[k].sub(&x[1][k], &x[0][k]);
        try e1[k].sub(&x[2][k], &x[0][k]);
    }
    defer for (0..3) |k| {
        e0[k].deinit();
        e1[k].deinit();
    };

    var lhs = try Big.init(gpa);
    defer lhs.deinit();
    var rhs = try Big.init(gpa);
    defer rhs.deinit();
    var comp = try Big.init(gpa);
    defer comp.deinit();

    var zero = true;
    var top: i32 = std.math.minInt(i32);
    for ([3][2]usize{ .{ 1, 2 }, .{ 2, 0 }, .{ 0, 1 } }) |ij| {
        try lhs.mul(&e0[ij[0]], &e1[ij[1]]);
        try rhs.mul(&e0[ij[1]], &e1[ij[0]]);
        try comp.sub(&lhs, &rhs);
        if (!comp.eqlZero()) {
            zero = false;
            // The true value is `comp · 2^(2·emin)`.
            const e: i32 = @as(i32, @intCast(comp.bitCountAbs())) - 1 + 2 * emin;
            if (e > top) top = e;
        }
    }
    return .{ .zero = zero, .top_exp = top };
}

/// The SINGLE-FACTOR form, kept here as the reference the fix is differentially measured against
/// — this is what `math.triangleCross` did between F5 and F6.
fn singleFactorCross(v0: Vec3r, v1: Vec3r, v2: Vec3r) Vec3r {
    const largest = @max(v0.maxAbsComponent(), @max(v1.maxAbsComponent(), v2.maxAbsComponent()));
    if (largest == 0) return Vec3r.zero;
    const exp = -std.math.frexp(largest).exponent;
    const a = v0.scalePow2(exp);
    const b = v1.scalePow2(exp);
    const c = v2.scalePow2(exp);
    return b.sub(a).cross(c.sub(a));
}

/// The PER-EDGE form, kept here as the second reference in the differential ladder — this is what
/// `math.triangleCross` did between F6 and its arbitration. One power of two per edge, taken from
/// the largest of that pair's six components and applied before the subtraction.
fn perEdgeCross(v0: Vec3r, v1: Vec3r, v2: Vec3r) Vec3r {
    const edge = struct {
        fn f(from: Vec3r, to: Vec3r) Vec3r {
            const largest = @max(from.maxAbsComponent(), to.maxAbsComponent());
            if (largest == 0) return Vec3r.zero;
            const exp = -std.math.frexp(largest).exponent;
            return to.scalePow2(exp).sub(from.scalePow2(exp));
        }
    }.f;
    return edge(v0, v1).cross(edge(v0, v2));
}

/// The shipped form's verdict as a plain bool, and its direction when it has one. Written once so
/// the property test and the pins read the three-outcome result the same way.
fn shippedZero(v0: Vec3r, v1: Vec3r, v2: Vec3r) bool {
    // The VERDICT source, which is the exact integer path and NOT the tiered `triangleCross` —
    // exactly what `MeshData.init` consults. Measuring the tiered form here was itself the mistake
    // that hid three false accepts: it answers from a float tier when that tier produces any
    // non-zero, and a rounding residue on proportional points is such a non-zero.
    return math.triangleIsFlat(Real, v0, v1, v2);
}
fn shippedDirection(v0: Vec3r, v1: Vec3r, v2: Vec3r) ?Vec3r {
    return switch (math.triangleCross(Real, v0, v1, v2)) {
        .direction => |d| d,
        .degenerate => null,
    };
}

fn asArrays(v0: Vec3r, v1: Vec3r, v2: Vec3r) [3][3]Real {
    return .{ v0.toArray(), v1.toArray(), v2.toArray() };
}

test "F6 a triangle spanning the exponent range is not a false degenerate" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);

    // **THE REGRESSION F5 INTRODUCED, and the worst symptom of the three rounds: a typed refusal
    // ACCUSING valid caller data.** One factor over the three vertices cannot serve a triangle
    // whose components span more than the format's exponent range. This right triangle in the XY
    // plane is entirely ordinary — every vertex finite, the area strictly positive — yet the
    // single factor `2⁻¹²⁸` sends the second leg to `2⁻¹⁸⁸`, below the subnormal floor, so that
    // edge becomes exactly zero and the cross with it, and `MeshData.init` answers
    // `error.MeshTriangleDegenerate`. Silent, and dressed as a diagnostic.
    const leg_hi: f32 = 2e38;
    const leg_lo: f32 = std.math.ldexp(@as(f32, 1), -60);
    const verts = [_]ApiVec3{ av3(0, 0, 0), av3(leg_hi, 0, 0), av3(0, leg_lo, 0) };
    const id = try store.createShape(gpa, .{ .triangle_mesh = .{
        .vertices = &verts,
        .indices = &one_triangle_indices,
    } });
    const data = store.get(id).?.mesh.?;
    // Counter-clockwise seen from `+Z`, so the normal is exactly `+Z` and its length exactly 1.
    const n = data.faceNormal(0);
    try testing.expect(n.eql(vr(0, 0, 1)));
    try testing.expectEqual(@as(Real, 1), n.lengthSq());

    // THE COUNTER-FACTUAL, on this very geometry: the single factor really does answer zero.
    // Kept as arithmetic rather than by editing production, and it is what makes the pin a pin.
    const single = singleFactorCross(
        vr(0, 0, 0),
        vr(@as(Real, leg_hi), 0, 0),
        vr(0, @as(Real, leg_lo), 0),
    );
    if (Real == f32) try testing.expectEqual(@as(Real, 0), single.maxAbsComponent());
    // Neither the per-edge form nor the SHIPPED conditional one does, and the exact oracle agrees
    // with both. The shipped form needs no scaling at all here: the unscaled difference of these
    // vertices is finite and their cross is finite and non-zero, which is precisely why the
    // conditional design answers this case without touching an exponent.
    const per_edge = perEdgeCross(vr(0, 0, 0), vr(@as(Real, leg_hi), 0, 0), vr(0, @as(Real, leg_lo), 0));
    try testing.expect(per_edge.maxAbsComponent() > 0);
    const shipped = shippedDirection(vr(0, 0, 0), vr(@as(Real, leg_hi), 0, 0), vr(0, @as(Real, leg_lo), 0)).?;
    try testing.expect(shipped.maxAbsComponent() > 0);
    try testing.expect(shipped.normalizeScaled().?.eql(vr(0, 0, 1)));
    const truth = try exactTriangleCross(gpa, asArrays(vr(0, 0, 0), vr(@as(Real, leg_hi), 0, 0), vr(0, @as(Real, leg_lo), 0)));
    try testing.expect(!truth.zero);

    // **THE CLASS IS NOT `f32`-ONLY**, so a second repro is scaled to whatever `Real` is: a span
    // of nine tenths of the format's exponent range each way. At `f32` that is `2^114` against
    // `2^-113`, at `f64` `2^920` against `2^-919`, and the single factor answers zero at BOTH.
    {
        const hi_exp: i32 = @intFromFloat(@as(f64, @floatFromInt(std.math.floatExponentMax(Real))) * 0.9);
        const lo_exp: i32 = @intFromFloat(@as(f64, @floatFromInt(std.math.floatExponentMin(Real))) * 0.9);
        const wide0 = Vec3r.zero;
        const wide1 = vr(std.math.ldexp(@as(Real, 1), hi_exp), 0, 0);
        const wide2 = vr(0, std.math.ldexp(@as(Real, 1), lo_exp), 0);
        try testing.expectEqual(@as(Real, 0), singleFactorCross(wide0, wide1, wide2).maxAbsComponent());
        try testing.expect(perEdgeCross(wide0, wide1, wide2).maxAbsComponent() > 0);
        const wide_cross = shippedDirection(wide0, wide1, wide2).?;
        try testing.expect(wide_cross.maxAbsComponent() > 0);
        try testing.expect(wide_cross.normalizeScaled().?.eql(vr(0, 0, 1)));
        try testing.expect(!(try exactTriangleCross(gpa, asArrays(wide0, wide1, wide2))).zero);
    }
}

test "F6 property: the exact oracle over the whole exponent range, on fixed seeds" {
    const gpa = testing.allocator;

    // **This is the property that closes the CLASS, and it is stated as what is TRUE rather than
    // as what would be pleasant.** Three rounds on float extremes have shown that a named repro
    // only closes itself, so the verdict is compared against an EXACT integer oracle over
    // triangles whose component exponents are drawn across the entire representable range, on
    // fixed seeds. Two families, because they fail for different reasons and only one of them is
    // reachable by any rescaling:
    //
    //   A — one exponent PER VERTEX, so each vertex is internally commensurate while the three
    //       magnitudes differ by up to the whole range. This is the family the per-edge factor
    //       targets.
    //   C — EXACTLY collinear by construction (`v₂ − v₀` an exact small-integer multiple of
    //       `v₁ − v₀`), so the degenerate side is populated and the property is not vacuous there.
    //
    // What is asserted, and what is only measured, is decided by what a float implementation CAN
    // guarantee — established by measurement, not assumed:
    //
    //   (i)  NO FALSE ACCEPT, ever. An exactly-degenerate triangle must be reported degenerate.
    //        This is the safety-critical direction, since accepting one puts a zero-area triangle
    //        in the store where `faceNormal`'s `orelse unreachable` would fire. Measured at zero
    //        errors for both forms over every seed, and asserted exactly.
    //   (ii) DOMINANCE. On identical inputs the per-edge form must produce no more false
    //        degenerates than the single factor, and strictly fewer in aggregate. This is the
    //        property that pins the fix, and reverting to the single factor breaks it.
    //   (iii) A tight unit normal on every triangle either form calls non-degenerate.
    //
    // What is NOT asserted, because it is FALSE for any implementation working in `Real`: exact
    // agreement on family A. The residual is reported in the milestone brief with its measured
    // rate; the reason is that the intermediate needs an exponent range wider than the format
    // holds, and no arrangement of power-of-two factors supplies one.
    const units = [_][3]Real{
        .{ 1, 0, 0 },  .{ 0, 1, 0 },   .{ 0, 0, 1 },
        .{ 1, 2, 0 },  .{ 3, 0, 5 },   .{ 1, 1, 1 },
        .{ 7, -3, 2 }, .{ -5, 1, 11 },
    };
    const lo = std.math.floatExponentMin(Real) + 8;
    const hi = std.math.floatExponentMax(Real) - 8;

    var total_single: usize = 0;
    var total_per_edge: usize = 0;
    var total_cases: usize = 0;
    var degenerate_cases: usize = 0;
    var strictly_better_seeds: usize = 0;
    var legacy_false_accepts: usize = 0;
    var shipped_false_accepts: usize = 0;

    for ([_]u64{ 0x5EED_0001, 0x5EED_0002, 0x5EED_0003 }) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const rnd = prng.random();
        var seed_single: usize = 0;
        var seed_per_edge: usize = 0;

        var i: usize = 0;
        while (i < 600) : (i += 1) {
            var v: [3]Vec3r = undefined;
            switch (i % 3) {
                0 => {
                    // Family C. `3 × u` is exact for these small integer triples, so the triple is
                    // EXACTLY collinear and the oracle must say so. Note what this family CANNOT
                    // do: `d × 3d` has every component of the form `a·b − b·a`, which is exactly
                    // zero in float too, so no form can ever false-accept here. On its own it would
                    // be a vacuous proof of (i) — which is why family D exists.
                    const u = units[rnd.uintLessThan(usize, units.len)];
                    const e = rnd.intRangeAtMost(i32, lo, hi);
                    const d = vr(
                        std.math.ldexp(u[0], e),
                        std.math.ldexp(u[1], e),
                        std.math.ldexp(u[2], e),
                    );
                    v = .{ Vec3r.zero, d, d.scale(3) };
                },
                1 => {
                    // Family D — EXACTLY collinear at MIXED magnitudes: the same direction scaled
                    // by three INDEPENDENT powers of two, so all three points sit on one line
                    // through the origin and the exact cross is zero, while the float products no
                    // longer cancel bit for bit. This is the family that can produce a false
                    // ACCEPT, and it does.
                    const u = units[rnd.uintLessThan(usize, units.len)];
                    for (&v) |*vertex| {
                        const e = rnd.intRangeAtMost(i32, lo, hi);
                        vertex.* = vr(
                            std.math.ldexp(u[0], e),
                            std.math.ldexp(u[1], e),
                            std.math.ldexp(u[2], e),
                        );
                    }
                },
                else => {
                    // Family A — one exponent per vertex, each internally commensurate.
                    for (&v) |*vertex| {
                        const u = units[rnd.uintLessThan(usize, units.len)];
                        const e = rnd.intRangeAtMost(i32, lo, hi);
                        vertex.* = vr(
                            std.math.ldexp(u[0], e),
                            std.math.ldexp(u[1], e),
                            std.math.ldexp(u[2], e),
                        );
                    }
                },
            }
            if (!std.math.isFinite(v[0].maxAbsComponent()) or
                !std.math.isFinite(v[1].maxAbsComponent()) or
                !std.math.isFinite(v[2].maxAbsComponent())) continue;

            const truth = try exactTriangleCross(gpa, asArrays(v[0], v[1], v[2]));
            const single_zero = singleFactorCross(v[0], v[1], v[2]).maxAbsComponent() == 0;
            const per_edge_zero = perEdgeCross(v[0], v[1], v[2]).maxAbsComponent() == 0;
            // The VERDICT comes from the classifier `MeshData.init` actually consults, and NOT from
            // the tiered direction. Deriving it from `shippedDirection` was the very dispatch defect
            // already corrected in production, left standing in the test: the tiered form answers
            // from whichever float tier first produces a non-zero, and on exactly proportional points
            // that is a rounding residue. `shipped_opt` is now used for the DIRECTION only.
            const shipped_zero = shippedZero(v[0], v[1], v[2]);
            const shipped_opt = shippedDirection(v[0], v[1], v[2]);
            const no_direction = shipped_opt == null;
            const shipped = shipped_opt orelse Vec3r.zero;

            total_cases += 1;

            // **THE VERDICT AGREES WITH THE ORACLE IN BOTH DIRECTIONS, PER CASE.** Two exact
            // integer arithmetics computing the same determinant must give the same answer, so this
            // is an equality and not a one-sided bound. The FALSE REFUSAL half — oracle non-zero and
            // the classifier calling it flat — is the direction §1.11.17 declares structurally
            // impossible, and it had only ever been COUNTED, never asserted. A normative guarantee
            // with no assertion behind it is what this milestone spent nine rounds removing.
            try testing.expectEqual(truth.zero, shipped_zero);
            if (truth.zero) {
                degenerate_cases += 1;
                // (i) **NO FALSE ACCEPT, EVER — asserted absolutely, and the absolute form is
                // finally true.** For five rounds it was not, and the reason turned out to be the
                // test rather than the engine: the verdict was being derived from the TIERED
                // direction, which answers from whichever float tier first produces a non-zero, and
                // on three exactly proportional points that is a rounding residue. Measured that
                // way, three `f32` draws in 932 looked like false accepts. Read from the classifier
                // `MeshData.init` actually consults — `math.triangleIsFlat`, exact integer
                // arithmetic throughout — the count is ZERO at both precisions, which is what exact
                // against exact must give. The two float forms still accept 8 between them at `f32`,
                // so the family is not vacuous and the assertion has something to bite on.
                // Accepting a degenerate would put a zero-area triangle in the store, where
                // `faceNormal`'s `orelse unreachable` fires.
                if (!shipped_zero) shipped_false_accepts += 1;
                if (!single_zero) legacy_false_accepts += 1;
                if (!per_edge_zero) legacy_false_accepts += 1;
            } else {
                if (single_zero) seed_single += 1;
                if (per_edge_zero) seed_per_edge += 1;
                // **THE SHIPPED FORM MUST PRODUCE A DIRECTION HERE, and that is a guarantee rather
                // than a metric.** `.degenerate` is reached only after the exact integer tier answers
                // zero, so a triangle the oracle calls non-flat cannot come back without one — and
                // this is not a nicety: it is the precondition of `MeshData.faceNormal`'s
                // `orelse unreachable`, which fires on a stored triangle if it ever fails. Counting
                // it was the same mistake as counting the false refusal.
                try testing.expect(!no_direction);
                // (iii) A tight unit normal wherever a non-degenerate verdict is given. TIGHT is
                // a machine-epsilon budget and not a geometric tolerance: 16 ULP, the same
                // `unit_k` the ray kernel asserts its incoming direction against. An EXACT 1 is
                // reachable only for an axis-aligned cross, which the named pins assert and an
                // arbitrary triangle cannot — measured here at `0.99999994`, one ULP below.
                {
                    const n = shipped.normalizeScaled().?;
                    try testing.expect(@abs(n.lengthSq() - 1) <= 16 * std.math.floatEps(Real));
                }
            }
        }

        // (ii) DOMINANCE along the LADDER — and the two rungs do NOT get the same operator, because
        // measurement says they are not the same shape. Rung one, per-edge against one common
        // factor, is STRICT on every seed at both precisions: 47→38, 44→34, 40→32 at `f32` and
        // 60→47, 50→37, 56→37 at `f64`, over 200 non-collinear draws per seed. Rung two, the
        // SHIPPED conditional form against per-edge, is strict on three of three seeds at `f32`
        // (38→36, 34→31, 32→30) but on only TWO of three at `f64` (47→43, 37→35, then 37→37 — a
        // TIE on seed `0x5EED_0003`, not a regression). So that rung asserts `<=`, which still
        // fails on any regression whatsoever, and the improvement is carried by the aggregate and
        // by the majority check below. Writing `<` there would be asserting something false.
        // The LADDER is between the two FLOAT forms, and only them. They are the historical
        // metrics: allowed to fail, kept for the non-vacuity of the assertions above and for the
        // dominance narrative. The shipped form has no rung here at all — a comparison would be
        // meaningless now that it is asserted to produce a direction on EVERY non-flat draw, and
        // pretending otherwise is what let a guarantee sit in a counter for a whole round.
        try testing.expect(seed_per_edge < seed_single);
        if (seed_per_edge < seed_single) strictly_better_seeds += 1;
        total_single += seed_single;
        total_per_edge += seed_per_edge;
    }

    // The degenerate side must be genuinely populated, or (i) proves nothing.
    try testing.expect(degenerate_cases * 3 > total_cases);
    // **ZERO false accepts from the shipped verdict, at BOTH precisions, with no tolerance of any
    // kind.** This is the invariant the exact integer classifier buys, and for five rounds it was
    // believed unreachable — measured against the TIERED direction instead of the classifier, which
    // is the same dispatch defect already corrected in production, left standing in the test.
    try testing.expectEqual(@as(usize, 0), shipped_false_accepts);
    // And the family is NOT vacuous: the two float forms accept 8 between them at `f32`, so the
    // assertion above has something to bite on. At `f64` all three are zero, the format being wide
    // enough for these draws, so the non-vacuity check is `f32`-only rather than absolute.
    if (Real == f32) try testing.expect(legacy_false_accepts > 0);

    // (ii) DOMINANCE in aggregate, STRICT on both rungs. This is what the counter-factual breaks:
    // putting `math.triangleCross` back on the single factor makes the two counts equal and takes
    // this down. Measured false-degenerate counts over the NON-DEGENERATE draws, FLOAT forms only —
    // `f32` 131 then 104 of 597, i.e. 21.9 % then 17.4 %; `f64` 166 then 121 of 596, i.e. 27.9 %
    // then 20.3 %. The SHIPPED form has no entry in this table and cannot have one: it is asserted
    // per case to produce a direction on every non-flat draw, so its count is zero by assertion
    // rather than by measurement, and listing it beside two forms that are allowed to fail would
    // read as a comparison where there is none.
    //
    // **THOSE PERCENTAGES ARE A STRESS METRIC, NOT A FIELD EXPECTATION, and the caveat has to
    // travel with the number.** The sampling is ADVERSARIAL by construction — one exponent drawn
    // UNIFORMLY over the format's entire range per vertex — so the draw is dominated by triangles
    // whose vertices differ in magnitude by dozens or hundreds of binades. A real mesh lives inside
    // a few orders of magnitude, where every one of these forms is exact. Read out of context the
    // figure invites the conclusion that one mesh triangle in six is misjudged, which is false.
    try testing.expect(total_per_edge < total_single);
    // And the float ladder's improvement is not carried by one lucky seed: strict on a MAJORITY.
    try testing.expect(strictly_better_seeds * 2 > 3);
}

test "F3 gjkPair states its convex precondition at its own site" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    var bm = BodyManager{};
    defer bm.deinit(gpa);

    // The assert cannot be caught in a Zig test, so what is checked is the PREDICATE it rests on —
    // that the two refused categories really are what the assert names — together with the
    // admitted pair still answering. The hole was real and pre-dated this milestone: a half-space
    // reached `supportShape` through this entry from M1.1.11 onward, panicking in a safe build and
    // undefined in ReleaseFast.
    const sphere = try store.createShape(gpa, .{ .sphere = .{ .radius = 1 } });
    const plane = try store.createShape(gpa, .{ .plane = .{} });
    const mesh = try store.createShape(gpa, .{ .triangle_mesh = .{
        .vertices = &cube_vertices,
        .indices = &cube_indices,
    } });
    try testing.expect(store.get(sphere).?.class() == .convex);
    try testing.expect(store.get(plane).?.class() != .convex);
    try testing.expect(store.get(mesh).?.class() != .convex);

    // The ADMITTED pair answers, so the precondition is a restriction and not a refusal of
    // everything.
    const a = try bm.addBody(gpa, &store, .{ .entity = entityOf(0), .body_type = .dynamic, .shape = sphere });
    const b = try bm.addBody(gpa, &store, .{
        .entity = entityOf(1),
        .body_type = .dynamic,
        .shape = sphere,
        .position = harness.av3(1.5, 0, 0),
    });
    const result = bm.gjkPair(&store, a, b);
    try testing.expect(result != null);
    try testing.expect(result.?.status != .separated); // two unit spheres 1.5 apart overlap

    // A stale handle still short-circuits BEFORE the precondition, which is what keeps the assert
    // from firing on a caller whose only mistake was holding a dead id.
    bm.removeBody(b);
    try testing.expect(bm.gjkPair(&store, a, b) == null);
}

test "F4 the constraint order is a total key, not the sort's tie-handling" {
    const gpa = testing.allocator;
    var scene = try FloorScene.init(gpa, av3(0, 0.5, 0), false);
    defer scene.deinit(gpa);
    const key = (@as(u64, @min(scene.ground, scene.box)) << 32) | @max(scene.ground, scene.box);

    var constraints: std.ArrayListUnmanaged(rigid.ContactConstraint) = .empty;
    defer constraints.deinit(gpa);
    try rigid.build(gpa, &constraints, &scene.world.bm, &scene.world.store, &.{key});
    // Several constraints on ONE pair — the configuration that made `pair_key` alone a
    // non-total key, and `std.mem.sort` being `std.sort.block` it is UNSTABLE, so their relative
    // order was the algorithm's internal behaviour rather than a contract.
    try testing.expect(constraints.items.len >= 4);
    for (constraints.items) |c| try testing.expectEqual(key, c.pair_key);

    // **TOTALITY, ASSERTED ON THE COMPARATOR ITSELF — not on a restatement of it, and not on the
    // output being sorted.** Measured: with the sub-shape term removed, an output-order assertion
    // still passes, because `std.sort.block` happens to leave equal keys where it found them on
    // this input. Order preserved by luck is not order preserved by contract, so what the test
    // calls is the comparator the sort calls.
    //
    // For any two distinct constraints, EXACTLY ONE of `less(x, y)` and `less(y, x)` holds:
    // antisymmetric, and never equal. On `pair_key` alone both are false for two constraints of
    // one pair, and this fails at the first such couple.
    for (constraints.items, 0..) |x, i| {
        for (constraints.items[i + 1 ..]) |y| {
            const x_first = rigid.lessByPairKey({}, x, y);
            const y_first = rigid.lessByPairKey({}, y, x);
            try testing.expect(x_first != y_first);
        }
    }

    // The ISLAND comparator carries the same third term, and the same totality claim: two
    // constraints of one pair share `rank` AND `pair_key`, so without the sub-shape they compare
    // equal and the permutation becomes the sort's business. The keys are built the way
    // `orderConstraints` builds them, with one rank since there is one island here.
    {
        var keys: [8]rigid.ConstraintKey = undefined;
        var count: usize = 0;
        for (constraints.items) |c| {
            if (count == keys.len) break;
            keys[count] = .{
                .rank = 0,
                .pair_key = c.pair_key,
                .subshape_id = c.subshape_id,
                .source_index = @intCast(count),
            };
            count += 1;
        }
        try testing.expect(count >= 4);
        for (keys[0..count], 0..) |x, i| {
            for (keys[i + 1 .. count]) |y| {
                const x_first = rigid.lessByCompositeKey({}, x, y);
                const y_first = rigid.lessByCompositeKey({}, y, x);
                try testing.expect(x_first != y_first);
            }
        }
    }
    // And the array really is in that order, ascending on the sub-shape within the shared pair.
    for (constraints.items[1..], 0..) |c, i| {
        const prev = constraints.items[i];
        try testing.expect(prev.pair_key < c.pair_key or
            (prev.pair_key == c.pair_key and prev.subshape_id < c.subshape_id));
    }

    // The ISLAND ordering carries the same third term. Driving a full tick exercises it, and the
    // per-island ranges must still be contiguous over an array whose order no longer depends on
    // the sort's tie-handling.
    for (0..30) |_| try scene.world.step(gpa);
    try testing.expect(scene.world.constraints.items.len >= 4);
    for (scene.world.constraints.items[1..], 0..) |c, i| {
        const prev = scene.world.constraints.items[i];
        if (prev.pair_key != c.pair_key) continue;
        try testing.expect(prev.subshape_id < c.subshape_id);
    }
}
