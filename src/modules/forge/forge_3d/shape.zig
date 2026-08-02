//! `forge_3d/shape.zig` — the `ShapeStore` and its analytic shape data.
//!
//! `createShape` builds a `Shape` (geometry at solver precision + precomputed
//! local AABB + unit-mass local inertia diagonal) and stores it in a
//! generational slot pool. M1.1.0 constructs sphere/box/capsule, M1.1.11 adds
//! the infinite plane and M1.1.11.1 the static triangle mesh; every other
//! `ShapeType` is rejected with `error.UnsupportedShape`. Inertia is the unit-mass
//! diagonal; `BodyManager` scales it by the body's mass at `addBody`.
//!
//! **The store holds three CATEGORIES, not one** (M1.1.11 / M1.1.11.1,
//! `engine-physics-forge.md` §1.11.15, §1.11.17). Sphere, box and capsule are
//! bounded convexes described by a support map; a half-space is not — its support
//! map diverges in every direction but `−n`; a triangle SOUP has none at all,
//! though each triangle taken alone is a bounded convex and enters the narrowphase
//! as a `Core` variant of its own. `ShapeClass` names that distinction and
//! `Shape.class()` answers it, so a consumer chooses the category BEFORE
//! converting a shape into a `SupportShape`. `supportShape` is therefore no longer
//! a total function of the store: it is the convex arm, and it asserts its
//! precondition. Putting a half-space into `SupportShape.Core` instead would make
//! `support()` return an infinity, and GJK's termination, EPA's expansion and the
//! cast kernel's ray march all assume a finite point — the failure would be a NaN
//! surfacing several modules away from its cause.
//!
//! **The store OWNS memory since M1.1.11.1**, and it is the mesh that changed that:
//! a mesh owns its vertices and its indices. Two consequences, neither of which
//! touches the frozen interface signatures (`engine-tier-interfaces.md` §1):
//! `createShape` is TRANSACTIONAL — every allocation is reserved before any slot is
//! mutated, so a failure never leaves a half-built shape in a live slot — and
//! `destroyShape` releases while `deinit` walks the live slots. Both gained a `gpa`
//! parameter; the interface's `destroyShape: fn (*Impl, ShapeId) void` is unchanged,
//! the interface tier holding the allocator and supplying it.

const std = @import("std");
const api = @import("weld_forge");
const config = @import("config.zig");
const narrowphase = @import("pipeline/narrowphase/root.zig");
const mesh_mod = @import("mesh.zig");
const IdAllocator = @import("slot_alloc.zig").IdAllocator;

/// The owned triangle-mesh payload of a `.triangle_mesh` shape (M1.1.11.1).
const MeshData = mesh_mod.MeshData;

const Real = config.Real;
const Vec3r = config.Vec3r;
const Aabbr = config.Aabbr;
const ShapeId = api.ShapeId;
const ShapeType = api.ShapeType;
const ShapeDescriptor = api.ShapeDescriptor;
/// The descriptor's `f32` `Vec3` — the precision the plane normal arrives in
/// (`engine-physics-forge.md` §1.11.8: the public surface stays `f32`).
const ApiVec3 = @import("foundation").math.Vec3;

/// The narrowphase CATEGORY of a shape (`engine-physics-forge.md` §1.11.15,
/// §1.11.17). The dispatch on it happens UPSTREAM of any conversion to a
/// `SupportShape`, never inside one.
///
/// **The three categories §1.11.15 names are all here** — bounded convex,
/// half-space, triangle soup — and every dispatch on this enum is a `switch`,
/// EXHAUSTIVE and with no `else` arm anywhere, so a fourth category would be a
/// compile error at each site that owes it a decision. An `else` arm converts that
/// compile error into a silent wrong answer, which is exactly the failure mode the
/// taxonomy exists to prevent.
///
/// M1.1.11 advertised that net while leaving FOUR HOLES in it, and M1.1.11.1 closed
/// them: `addBody`'s static-only refusal, `bodyAabb`, `closestPointBody` and
/// `worldAabb` each decided by an `if` on one variant or by a class ASSERT, neither
/// of which a new variant breaks. `closestPointBody` was the dangerous one — a
/// third-category shape fell through its `if` into the convex path, which panics in a
/// safe build and is undefined behaviour in ReleaseFast. The two class asserts of
/// `body.zig` became exhaustive switches for the same reason. This paragraph is the
/// docstring saying what the code DOES, which is what an advertised safety net has
/// to be checkable against.
pub const ShapeClass = enum {
    /// A bounded convex, described by a support map: sphere, box, capsule (and
    /// later cylinder, tapered cylinder, convex hull). GJK, EPA, the cast kernel
    /// and the ray kernels all serve this category and only this one.
    convex,
    /// A solid half-space `{x : n·x <= d}`. Unbounded, so it has no support map, no
    /// world AABB and no place in the broadphase trees; its kernels are analytic
    /// and closed-form, and its broadphase role is a PREDICATE ("do you overlap
    /// this box") rather than a box of its own.
    half_space,
    /// A static triangle SOUP: a surface, bounded, with no support map of its own —
    /// though each triangle taken alone IS a bounded convex, which is what lets GJK,
    /// EPA, the manifold generator and the cast kernel serve a mesh with no extra
    /// kernel (§1.11.17). It has a valid local AABB, hence a place in the broadphase
    /// trees and a defined sleep radius; what it lacks is a VOLUME, so it is
    /// static-only and it is never solid.
    ///
    /// `HeightField` joins this same category at its own sub-milestone, with an
    /// IMPLICIT acceleration structure instead of a built tree — hence no arm of its
    /// own here.
    triangle_soup,
};

/// Immutable per-shape data: geometry (solver precision), the local-space AABB,
/// and the unit-mass local inertia diagonal (principal axes). Only the geometry
/// fields relevant to `shape_type` are meaningful.
pub const Shape = struct {
    shape_type: ShapeType,
    /// Sphere / capsule radius (metres). A half-space carries 0: it is not a core
    /// plus an inflation, it IS the solid, and the `− r_b` term of §1.11.15's
    /// separation formula belongs to the other shape.
    radius: Real = 0,
    /// Box half-extents (metres).
    half_extents: Vec3r = Vec3r.zero,
    /// Capsule cylinder half-height (metres), along +Y.
    half_height: Real = 0,
    /// Half-space outward normal in `n·x <= d`, local frame — meaningful only for
    /// `.plane`. **UNIT at solver precision, permanently**: `createShape` asserts
    /// the descriptor is unit at `f32` tolerance and normalises the widened value
    /// once, so no consumer re-normalises (the `Body.rotation` pattern, and for the
    /// same reason — an f32-unit vector widened to `f64` is off by ~6e-8 in its
    /// squared norm). It is the sole source of the plane's contact normal.
    normal: Vec3r = Vec3r.unit_y,
    /// Half-space offset `d` in `n·x <= d` (metres), local frame — meaningful only
    /// for `.plane`.
    distance: Real = 0,
    /// The mesh a `.triangle_mesh` shape OWNS — null for every other shape type.
    ///
    /// A pointer and not an inline `MeshData`: `Shape` is stored by value and
    /// `ShapeStore.get` returns a copy, so an inline mesh would add its slices to
    /// every sphere in the store. The pointee is heap-allocated by `createShape`,
    /// released by `destroyShape` and by `deinit` over the live slots, and shared by
    /// every copy of the `Shape` — which is why only this file ever writes through it.
    mesh: ?*MeshData = null,
    /// Local-space (untransformed) bounding box.
    ///
    /// **NOT VALID for a half-space**, which is unbounded: every component is NaN
    /// there, and its sole reader — `body.computeSleepRadius` — dispatches on the
    /// class first. (`body_manager.worldAabb` and `bodyAabb` dispatch on the same
    /// class for a DIFFERENT reason: for a primitive they never read this field, they
    /// compute a world box per primitive, and a half-space simply has none.)
    ///
    /// **VALID for a mesh**, and this is where the mesh and the half-space part
    /// company: a mesh is bounded, so this is the tight bound over its vertices — the
    /// same value `MeshData.local_aabb` carries. It is also the one shape whose local
    /// box is NOT centred on the origin, which is why `worldAabb`'s mesh arm transports
    /// the vertices rather than the box.
    ///
    /// An infinite box is not the alternative — its centre is `(−inf + inf)·0.5`,
    /// i.e. NaN, which is the ray origin a shape cast derives from a box; its
    /// surface area is infinite, so the SAH cost is infinite at every candidate;
    /// and the union propagates the infinity to the root, after which every query
    /// visits every node. A finite substitute box is refused too: it is a tuning
    /// constant that changes a query's answer (§1.11.15).
    local_aabb: Aabbr,
    /// Unit-mass local inertia diagonal (principal axes).
    ///
    /// **NOT VALID for a half-space NOR for a mesh**: NaN in both. Neither has a
    /// finite volume — the half-space because it is unbounded, the mesh because an open
    /// surface encloses nothing — so no inertia tensor derives from either.
    /// `body.computeMotion` reads it only on the dynamic path and dispatches on the
    /// class there; a dynamic body carrying either never gets that far, `addBody`
    /// rejecting it with `error.ShapeMustBeStatic` first.
    unit_inertia: Vec3r,

    /// The narrowphase category of this shape — the dispatch every consumer makes
    /// before touching the geometry.
    ///
    /// Exhaustive over `ShapeType` with no `else` arm, so a thirteenth shape type
    /// is a compile error HERE, where its category must be stated. The variants the
    /// store cannot hold are named individually rather than swept together: they
    /// are unreachable because `createShape` rejects them, and naming them is what
    /// makes the milestone that lands each one arrive at this line.
    pub fn class(self: Shape) ShapeClass {
        return switch (self.shape_type) {
            .sphere, .box, .capsule => .convex,
            .plane => .half_space,
            .triangle_mesh => .triangle_soup,
            // Bounded convexes, not yet constructible (M1.1.19).
            .cylinder, .tapered_cylinder, .convex_hull => unreachable,
            // The same `.triangle_soup` category as the mesh, with an IMPLICIT
            // acceleration structure instead of a built tree — not yet constructible
            // (M1.1.20).
            .height_field => unreachable,
            // Composite / degenerate, not yet constructible (M1.1.20).
            .compound, .mutable_compound, .empty => unreachable,
        };
    }
};

/// A generational store of collision shapes with LIFO slot reuse.
pub const ShapeStore = struct {
    alloc: IdAllocator = .{},
    shapes: std.ArrayListUnmanaged(Shape) = .empty,

    /// Release all storage, including the memory the LIVE shapes own.
    ///
    /// The walk is over the allocator's slots and not over `shapes.items`: `free` does
    /// not compact, so a dead slot still holds the bytes of the `Shape` that used to
    /// live there — including a `mesh` pointer `destroyShape` has already released.
    /// Freeing by column index instead of by liveness would double-free exactly that.
    pub fn deinit(self: *ShapeStore, gpa: std.mem.Allocator) void {
        var index: u32 = 0;
        while (index < self.shapes.items.len) : (index += 1) {
            if (self.alloc.isAliveIndex(index)) releaseOwned(&self.shapes.items[index], gpa);
        }
        self.alloc.deinit(gpa);
        self.shapes.deinit(gpa);
        self.* = undefined;
    }

    /// Number of live shapes.
    pub fn count(self: *const ShapeStore) u32 {
        return self.alloc.live_count;
    }

    /// Build and store a shape, returning its handle. Sphere/box/capsule/plane and —
    /// since M1.1.11.1 — the static triangle mesh; any other variant returns
    /// `error.UnsupportedShape` (no slot allocated).
    ///
    /// **TRANSACTIONAL** (`engine-physics-forge.md` §1.11.17). The mesh made the store
    /// an owner of memory, so a failure part-way through creation could otherwise leave
    /// a half-built shape in a live slot. The order is the reserve-then-mutate invariant
    /// the slot allocator already holds, applied to the whole call:
    ///
    ///   1. build the shape, which is where every owning allocation happens and where a
    ///      malformed descriptor is refused — and `MeshData.init` validates BEFORE its
    ///      own first allocation, so a typed refusal allocates nothing;
    ///   2. reserve the slot and the column, the two remaining fallible steps, with an
    ///      `errdefer` releasing what step 1 owns if either fails;
    ///   3. commit, which is infallible from here.
    ///
    /// So on ANY failure nothing is mutated, no handle is allocated and nothing leaks.
    pub fn createShape(self: *ShapeStore, gpa: std.mem.Allocator, desc: ShapeDescriptor) !ShapeId {
        var shape = try buildShape(gpa, desc);
        errdefer releaseOwned(&shape, gpa);
        try self.alloc.ensureUnusedCapacity(gpa, 1);
        try self.shapes.ensureUnusedCapacity(gpa, 1);
        const a = self.alloc.allocateAssumeCapacity();
        if (a.is_new) {
            self.shapes.appendAssumeCapacity(shape);
        } else {
            self.shapes.items[a.index] = shape;
        }
        return a.id;
    }

    /// Free a shape, releasing any memory it owns. No-op on a stale/invalid handle —
    /// in particular it frees NOTHING there, which is what keeps a double destroy from
    /// double-freeing a mesh.
    ///
    /// The `gpa` parameter is what M1.1.11.1 added. The frozen interface signature
    /// `destroyShape: fn (*Impl, ShapeId) void` is UNCHANGED: the interface tier holds
    /// the allocator and supplies it (`engine-tier-interfaces.md` §1).
    pub fn destroyShape(self: *ShapeStore, gpa: std.mem.Allocator, id: ShapeId) void {
        const idx = self.alloc.validate(id) orelse return;
        releaseOwned(&self.shapes.items[idx], gpa);
        _ = self.alloc.free(id);
    }

    /// Safe getter — returns the shape, or null if `id` is stale/invalid.
    pub fn get(self: *const ShapeStore, id: ShapeId) ?Shape {
        const idx = self.alloc.validate(id) orelse return null;
        return self.shapes.items[idx];
    }
};

/// Convert an immutable `Shape` to the narrowphase `SupportShape` at solver
/// precision: sphere → point core + radius, capsule → Y-segment(`half_height`)
/// core + radius, box → box(`half_extents`) core + radius 0 (a box has no convex
/// radius in M1.1.2).
///
/// **This is the CONVEX ARM, and its precondition is asserted** (M1.1.11,
/// `engine-physics-forge.md` §1.11.15). It stopped being a total function of the
/// store the moment the store gained a half-space: the category is chosen upstream
/// by `Shape.class()`, and calling this with a `.half_space` — or, since M1.1.11.1,
/// with a `.triangle_soup`, whose triangles enter the narrowphase ONE AT A TIME and
/// never as a whole shape — is a programming error, not an input to handle. Making a
/// half-space a `Core` variant instead
/// would have `support()` return an infinity, and every consumer of the support map
/// — GJK's termination, EPA's expansion, the cast kernel's ray march — assumes a
/// finite point; the failure would be a NaN appearing modules away from its cause,
/// rather than a compile error or a wrong answer at one call site.
pub fn supportShape(shape: Shape) narrowphase.SupportShape(Real) {
    std.debug.assert(shape.class() == .convex);
    return switch (shape.shape_type) {
        .sphere => .{ .core = .point, .radius = shape.radius },
        .capsule => .{ .core = .{ .segment = shape.half_height }, .radius = shape.radius },
        .box => .{ .core = .{ .box = shape.half_extents }, .radius = 0 },
        else => unreachable,
    };
}

/// The poison value a shape carries in a field that has no meaning for it: both
/// `local_aabb` and `unit_inertia` for a half-space, `unit_inertia` alone for a mesh
/// (see their field docs). NaN and not a finite placeholder: it survives ReleaseFast,
/// where the class dispatches guarding those fields compile out.
const nan: Real = std.math.nan(Real);

/// Slack allowed on the descriptor normal's unit norm, in ULPs of 1 at `f32` — the
/// precision the descriptor is expressed in. A normal built by normalising an `f32`
/// vector, or from `f32` trigonometry, lands a few ULPs off unit; anything further
/// out is a caller error, not rounding. Same constant and same role as
/// `body_manager.descriptor_rotation_unit_k`.
const descriptor_normal_unit_k: comptime_int = 16;

/// Whether a plane descriptor's `normal` is unit to `f32` tolerance — the domain
/// `createShape` asserts.
///
/// A named predicate rather than an inline expression, so the threshold and the
/// formula exist ONCE and the inline test below can exercise the guard in both
/// senses instead of restating its arithmetic. The comparison is against 1, so
/// `descriptor_normal_unit_k · floatEps(f32)` is pure float noise and not a
/// geometric tolerance.
fn descriptorNormalIsUnit(normal: ApiVec3) bool {
    const n = normal.toArray();
    const norm_sq = n[0] * n[0] + n[1] * n[1] + n[2] * n[2];
    return @abs(norm_sq - 1) <= descriptor_normal_unit_k * std.math.floatEps(f32);
}

/// Convert an immutable `Shape` to the narrowphase `HalfSpace` at solver precision,
/// in the shape's LOCAL frame — the sibling of `supportShape`, one per category.
///
/// **This is the HALF-SPACE ARM, and its precondition is asserted**, symmetric with
/// `supportShape`'s: the category is chosen upstream by `Shape.class()` and calling
/// this with a convex is a programming error. The normal needs no normalisation here
/// — `createShape` established that invariant once, which is the whole reason it is
/// established there (`engine-physics-forge.md` §1.11.15).
pub fn halfSpace(shape: Shape) narrowphase.plane.HalfSpace(Real) {
    std.debug.assert(shape.class() == .half_space);
    return .{ .normal = shape.normal, .distance = shape.distance };
}

/// Release whatever `shape` owns and leave it owning nothing.
///
/// Idempotent by nulling the pointer, which is what makes it safe to call from both
/// `destroyShape` and `deinit` without either having to know whether the other ran.
fn releaseOwned(shape: *Shape, gpa: std.mem.Allocator) void {
    if (shape.mesh) |data| {
        data.deinit(gpa);
        gpa.destroy(data);
        shape.mesh = null;
    }
}

/// Build the `Shape` for a descriptor (sphere/box/capsule/plane/triangle_mesh),
/// computing its local AABB, and its unit-mass inertia for the bounded convexes.
/// Other shapes → `error.UnsupportedShape`.
///
/// **The mesh arm is the only one that allocates**, and it allocates in the order that
/// keeps a REFUSAL free of any allocation at all: `MeshData.init` validates before its
/// own first allocation, and the box that carries it is created afterwards, with an
/// `errdefer` releasing the arrays if that last step fails.
fn buildShape(
    gpa: std.mem.Allocator,
    desc: ShapeDescriptor,
) (std.mem.Allocator.Error || mesh_mod.MeshError || error{UnsupportedShape})!Shape {
    switch (desc) {
        .sphere => |s| {
            const r: Real = s.radius;
            return .{
                .shape_type = .sphere,
                .radius = r,
                .local_aabb = Aabbr.fromCenterHalfExtents(Vec3r.zero, Vec3r.splat(r)),
                // I = 2/5 m r² (all axes), unit mass.
                .unit_inertia = Vec3r.splat(0.4 * r * r),
            };
        },
        .box => |b| {
            const he_arr = b.half_extents.toArray(); // [3]f32
            const hx: Real = he_arr[0];
            const hy: Real = he_arr[1];
            const hz: Real = he_arr[2];
            const he = Vec3r.fromArray(.{ hx, hy, hz });
            return .{
                .shape_type = .box,
                .half_extents = he,
                .local_aabb = Aabbr.fromCenterHalfExtents(Vec3r.zero, he),
                // Ix = m/3 (hy² + hz²), cyclic; unit mass.
                .unit_inertia = Vec3r.fromArray(.{
                    (hy * hy + hz * hz) / 3.0,
                    (hx * hx + hz * hz) / 3.0,
                    (hx * hx + hy * hy) / 3.0,
                }),
            };
        },
        .capsule => |c| {
            const r: Real = c.radius;
            const h: Real = c.half_height;
            return .{
                .shape_type = .capsule,
                .radius = r,
                .half_height = h,
                // Extends ±r in X/Z, ±(h+r) in Y.
                .local_aabb = Aabbr.fromCenterHalfExtents(Vec3r.zero, Vec3r.fromArray(.{ r, h + r, r })),
                .unit_inertia = capsuleUnitInertia(r, h),
            };
        },
        .plane => |p| {
            // The descriptor normal must ALREADY be unit, to `f32` tolerance — it IS
            // `f32`. Without this guard the normalisation below would silently repair
            // any input, turning a zero normal into NaN; with it, the normalisation is
            // total in what it does: it corrects the widening, it does not rescue an
            // invalid input. The `Body.rotation` pattern verbatim.
            std.debug.assert(descriptorNormalIsUnit(p.normal));
            // And the offset is FINITE, for the same reason in the same place: it is the
            // other half of the caller-supplied domain, and a non-finite one is not a
            // plane with an unusual position, it is two silent and MUTUALLY CONTRADICTORY
            // behaviours — the narrowphase reporting contact with everything (`sep > 0` is
            // false against a NaN) while the broadphase reports contact with nothing
            // (every comparison against a NaN bound is false). Measured both ways; see
            // `plane.HalfSpace.assertDomain`.
            std.debug.assert(std.math.isFinite(p.distance));
            const n = p.normal.toArray();
            return .{
                .shape_type = .plane,
                // Normalised ONCE, here, so no consumer ever re-normalises: an
                // `f32`-unit vector widened to `f64` is off by up to ~6e-8 in its
                // squared norm, and this normal is the SOLE source of the plane's
                // contact normal.
                .normal = Vec3r.fromArray(.{ n[0], n[1], n[2] }).normalize(),
                .distance = p.distance,
                // NOT VALID for a half-space (see the field docs): unbounded, so no
                // local AABB, and no finite volume, so no inertia.
                //
                // **POISONED WITH NaN, not left `undefined`**, and the two mechanisms
                // guarding these fields are COMPLEMENTARY rather than redundant. The
                // class assert on each reader is a `std.debug.assert`, so it is
                // compiled OUT of ReleaseFast — which is the mode the benches run in,
                // with a plane in the scene. `undefined` there is whatever the memory
                // held; in Debug it is the 0xAA fill, which reads as a perfectly
                // ordinary small number: MEASURED on the E1 commit, a plane's sleep
                // radius came out 5.2510e-13 at f32 and 6.4444e-104 at f64 — finite,
                // small and plausible, so nobody would ever see it go past. A NaN
                // survives ReleaseFast and propagates loudly through every arithmetic
                // path instead. The assert is the primary guard in a safe build; the
                // NaN is the one that outlives it.
                //
                // Safe because NOTHING compares or hashes a `Shape` by value — the
                // 34 `store.get` sites all read individual fields, and `shapes.items`
                // is touched only inside this file. A future `expectEqual` on a whole
                // `Shape`, or a `Shape`-keyed map, would break on `NaN != NaN`; that
                // is the one thing this choice forbids.
                .local_aabb = Aabbr.fromMinMax(Vec3r.splat(nan), Vec3r.splat(nan)),
                .unit_inertia = Vec3r.splat(nan),
            };
        },
        .triangle_mesh => |m| {
            // Validation and the owned copy, in that order and both inside `init`. The
            // descriptor's arrays are BORROWED for the duration of the call: the caller
            // may release them the moment this returns.
            var data = try MeshData.init(gpa, m.vertices, m.indices);
            errdefer data.deinit(gpa);
            const owned = try gpa.create(MeshData);
            owned.* = data;
            return .{
                .shape_type = .triangle_mesh,
                .mesh = owned,
                // VALID, unlike the half-space's: a mesh is bounded, and this is the
                // tight bound over its vertices. Held here as well as on the `MeshData`
                // so every consumer of a shape's local box needs no mesh indirection —
                // one value, two readers, not two sources of truth.
                .local_aabb = owned.local_aabb,
                // NaN, like the half-space's, but for the other half of the reason: a
                // mesh is bounded, so it HAS a local box; what it lacks is a VOLUME, an
                // open surface enclosing nothing, so no inertia tensor derives from it.
                // NaN rather than a plausible zero, because the class dispatches that
                // guard this field compile out of ReleaseFast (see `nan` above).
                .unit_inertia = Vec3r.splat(nan),
            };
        },
        else => return error.UnsupportedShape,
    }
}

/// Unit-mass local inertia diagonal of a Y-axis capsule (radius `r`, cylinder
/// half-height `h`): a composite of the cylinder and two hemispheres with the
/// mass split proportional to their volumes, hemispheres carried to the capsule
/// centre by the parallel-axis theorem. Degenerates to a sphere (h→0) and a
/// rod (r→0).
fn capsuleUnitInertia(r: Real, h: Real) Vec3r {
    const pi: Real = std.math.pi;
    const v_cyl = 2.0 * pi * r * r * h; // π r² · 2h
    const v_sph = (4.0 / 3.0) * pi * r * r * r; // two hemispheres = one sphere
    const v_total = v_cyl + v_sph;
    const m_cyl = v_cyl / v_total; // unit total mass, split by volume
    const m_sph = v_sph / v_total;

    // Long axis (Y): cylinder ½mr² + hemispheres ⅖mr².
    const iyy = m_cyl * (0.5 * r * r) + m_sph * (0.4 * r * r);
    // Transverse (X = Z): cylinder m(h²/3 + r²/4) + hemispheres m(⅖r² + h² + ¾hr).
    const ixx = m_cyl * (h * h / 3.0 + r * r / 4.0) +
        m_sph * (0.4 * r * r + h * h + 0.75 * h * r);
    return Vec3r.fromArray(.{ ixx, iyy, ixx });
}

const testing = std.testing;

test "unsupported shape is rejected" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    try testing.expectError(error.UnsupportedShape, store.createShape(gpa, .{ .cylinder = {} }));
    try testing.expectError(error.UnsupportedShape, store.createShape(gpa, .{ .empty = {} }));
    try testing.expectEqual(@as(u32, 0), store.count());
}

test "sphere shape: local aabb and unit inertia" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    const id = try store.createShape(gpa, .{ .sphere = .{ .radius = 2.0 } });
    const s = store.get(id).?;
    try testing.expect(s.local_aabb.min.approxEql(Vec3r.splat(-2.0), 1e-6));
    try testing.expect(s.local_aabb.max.approxEql(Vec3r.splat(2.0), 1e-6));
    // 2/5 · 2² = 1.6 on every axis.
    try testing.expect(s.unit_inertia.approxEql(Vec3r.splat(1.6), 1e-6));
}

test "box shape: local aabb and cyclic unit inertia" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    // half_extents is the f32 descriptor Vec3 (`math.Vec3`).
    const id = try store.createShape(gpa, .{ .box = .{ .half_extents = ApiVec3.fromArray(.{ 1, 2, 3 }) } });
    const s = store.get(id).?;
    try testing.expect(s.local_aabb.max.approxEql(vec3(1, 2, 3), 1e-6));
    try testing.expect(s.local_aabb.min.approxEql(vec3(-1, -2, -3), 1e-6));
    // Ix = (2²+3²)/3 = 13/3, Iy = (1²+3²)/3 = 10/3, Iz = (1²+2²)/3 = 5/3.
    try testing.expect(s.unit_inertia.approxEql(vec3(13.0 / 3.0, 10.0 / 3.0, 5.0 / 3.0), 1e-5));
}

test "capsule unit inertia degenerates to a sphere at h=0" {
    // h→0 ⇒ capsule is a sphere of radius r ⇒ inertia 2/5 r² on every axis.
    const inertia = capsuleUnitInertia(1.5, 0.0);
    try testing.expect(inertia.approxEql(Vec3r.splat(0.4 * 1.5 * 1.5), 1e-6));
}

test "the plane descriptor normal domain accepts float noise and rejects a real error" {
    // The guard `createShape` asserts, exercised in BOTH senses. A control never seen
    // to fail is a comment with syntax, and the assert itself cannot be caught in a
    // Zig test — so the PREDICATE is what the test discriminates on, and the assert's
    // wiring to it is one line above the call.
    //
    // ACCEPTED: exactly unit, and unit to a few ULPs. `(1,1,1)/√3` at f32 has a
    // squared norm off by float noise, and `(2,−3,6)/7` is exact (4 + 9 + 36 = 49).
    try testing.expect(descriptorNormalIsUnit(ApiVec3.unit_y));
    try testing.expect(descriptorNormalIsUnit(ApiVec3.unit_x.neg()));
    try testing.expect(descriptorNormalIsUnit(ApiVec3.fromArray(.{ 1, 1, 1 }).normalize()));
    try testing.expect(descriptorNormalIsUnit(ApiVec3.fromArray(.{ 2.0 / 7.0, -3.0 / 7.0, 6.0 / 7.0 })));

    // REJECTED: the zero normal (which normalisation would turn into NaN — the exact
    // reason the guard precedes it), an unnormalised direction, and one just far
    // enough out to be a caller error rather than rounding. The last case is a
    // squared norm of `(1 + 64·eps)² ≈ 1 + 128·eps`, eight times the 16-ULP budget.
    try testing.expect(!descriptorNormalIsUnit(ApiVec3.zero));
    try testing.expect(!descriptorNormalIsUnit(ApiVec3.fromArray(.{ 0, 2, 0 })));
    try testing.expect(!descriptorNormalIsUnit(ApiVec3.fromArray(.{ 1, 1, 1 })));
    const just_out: f32 = 1 + 64 * std.math.floatEps(f32);
    try testing.expect(!descriptorNormalIsUnit(ApiVec3.fromArray(.{ 0, just_out, 0 })));

    // The boundary is where the constant says it is, not somewhere near it: a squared
    // norm exactly `1 + 16·eps` is inside the budget, `1 + 17·eps` is outside.
    const eps = std.math.floatEps(f32);
    try testing.expect(descriptorNormalIsUnit(ApiVec3.fromArray(.{ 0, 0, @sqrt(1 + 16 * eps) })));
    try testing.expect(!descriptorNormalIsUnit(ApiVec3.fromArray(.{ 0, 0, @sqrt(1 + 24 * eps) })));
}

test "shape slot reuse is LIFO and generation-checked" {
    const gpa = testing.allocator;
    var store = ShapeStore{};
    defer store.deinit(gpa);
    const a = try store.createShape(gpa, .{ .sphere = .{ .radius = 1 } });
    const b = try store.createShape(gpa, .{ .box = .{} });
    store.destroyShape(gpa, b);
    try testing.expect(store.get(b) == null); // stale ⇒ safe getter returns null
    const c = try store.createShape(gpa, .{ .capsule = .{} }); // reuses b's slot
    try testing.expect(c != b);
    try testing.expectEqual(api.PackedId.unpack(b).index, api.PackedId.unpack(c).index);
    try testing.expectEqual(api.PackedId.unpack(b).generation +% 1, api.PackedId.unpack(c).generation);
    try testing.expect(store.get(b) == null);
    try testing.expect(store.get(a) != null);
    try testing.expect(store.get(c) != null);
    try testing.expectEqual(@as(u32, 2), store.count());
}

// Test helper: build a solver-precision Vec3r from literals.
fn vec3(x: Real, y: Real, z: Real) Vec3r {
    return Vec3r.fromArray(.{ x, y, z });
}
