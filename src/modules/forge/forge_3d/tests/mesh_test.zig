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
const ApiVec3 = foundation.math.Vec3;
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
        // The mesh is IN THE SCENE but OUT OF CONTACT, at `x = 1000`. Deliberate: mesh↔convex
        // contact generation is gate E, so a mesh in contact would reach a `@panic` in
        // `collidePair` and this test would be measuring that instead of the query. Far enough
        // that no fat AABB ever overlaps, so `computePairs` never emits the pair at all — and
        // the mesh still answers queries, which is the property under test.
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
