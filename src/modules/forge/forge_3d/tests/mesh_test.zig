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
