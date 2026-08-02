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
