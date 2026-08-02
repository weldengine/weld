//! `forge_3d/mesh.zig` — the OWNED triangle-mesh data a `.triangle_mesh` shape holds.
//!
//! A `MeshShape` is a SURFACE, not a solid, and that is a CATEGORICAL rule rather than
//! a setting (`engine-physics-forge.md` §1.11.17). Everything downstream follows from
//! that one sentence: membership is false everywhere, the point query never returns a
//! body carrying a mesh, and `closestPoint` measures to the surface and is never zero
//! by interiority.
//!
//! **This file is `Real`-bound, not scalar-generic.** It sits at the `forge_3d/` level
//! beside `shape.zig` and `body.zig`, which are bound to `config.Real`; the
//! branch-neutral, comptime-`T` discipline belongs to `pipeline/`, which imports
//! `foundation` and nothing else. What lives here is the mesh's owned STORAGE, which
//! is a property of this solver's store, not a shared kernel.
//!
//! **The domain is refused by typed error and never sanitised.** Rejected at creation:
//! an index count that is not a multiple of three, a mesh with no triangle, a
//! non-finite vertex, an index outside the vertex array, and a triangle whose cross
//! product is EXACTLY zero. No area threshold appears anywhere — a sliver of tiny but
//! non-zero area normalises exactly and MUST be served, so the guard is at true zero
//! on the cross product's largest absolute component, which is §1.11.4's null-direction
//! rule applied verbatim.
//!
//! The refusal never REMOVES the offending triangle. The reference sanitises
//! (`MeshShapeSettings::Sanitize`); Weld refuses, because a removal RENUMBERS and that
//! number IS the `subshape_id` (§1.11.16) — caller and engine would then designate
//! different triangles with no diagnostic. The data comes from an asset, hence from a
//! caller, hence the refusal is the caller's.
//!
//! **Validation runs entirely BEFORE the first allocation.** A refused descriptor
//! therefore allocates nothing, which is what lets `ShapeStore.createShape` be
//! transactional without an unwind path for the rejection case (only for a later
//! reservation failure). The checks run on the WIDENED values, which is exact — a
//! per-component `f32` → `Real` conversion — so they validate the bytes that will be
//! stored and not a different precision's view of them.

const std = @import("std");
const config = @import("config.zig");

const Real = config.Real;
const Vec3r = config.Vec3r;
const Aabbr = config.Aabbr;
/// The descriptor's `f32` `Vec3` — the precision mesh vertices arrive in
/// (`engine-physics-forge.md` §1.11.8: the public surface stays `f32`).
const ApiVec3 = @import("foundation").math.Vec3;

/// The five ways a triangle-mesh descriptor can be malformed, each distinguishable
/// from the others so a caller can act on the one it caused
/// (`engine-physics-forge.md` §1.11.17).
pub const MeshError = error{
    /// `indices.len` is not a multiple of three, so the last triangle is incomplete.
    InvalidMeshIndexCount,
    /// No triangle at all. A mesh with no surface has nothing any kernel could answer
    /// about, and its local AABB would be the empty set.
    MeshEmpty,
    /// A vertex has a non-finite component. Checked over ALL vertices, including any
    /// no index references: they are copied into the owned storage either way, and one
    /// of them alone poisons the local AABB — which the broadphase and the sleep radius
    /// both read.
    MeshVertexNotFinite,
    /// An index is `>= vertices.len`.
    MeshIndexOutOfRange,
    /// A triangle's cross product `(v₁−v₀) × (v₂−v₀)` is EXACTLY zero: the three
    /// vertices are coincident or collinear, so the triangle has no normal at all.
    MeshTriangleDegenerate,
};

/// A static triangle mesh: owned vertices at solver precision, owned indices, and the
/// tight local-space bound over those vertices.
///
/// `vertices` and `indices` are OWNED — released by `deinit`, which the shape store
/// calls from `destroyShape` and from its own `deinit` over the live slots. The
/// descriptor's arrays are only borrowed for the duration of `init`.
pub const MeshData = struct {
    /// Owned vertex positions in the shape's LOCAL frame, at solver precision.
    vertices: []Vec3r,
    /// Owned triangle indices, three per triangle, each `< vertices.len`.
    indices: []u32,
    /// Tight local-space bound over `vertices`.
    ///
    /// Computed once at `init`. `Shape.local_aabb` holds the same value, by
    /// construction and not as a second source of truth: every consumer of a shape's
    /// local AABB — the sleep radius, the world AABB — then needs no mesh indirection,
    /// and a mesh is the one shape whose local box is NOT centred on the origin, which
    /// is exactly the property those consumers must not have to rediscover.
    local_aabb: Aabbr,

    /// Validate `vertices` / `indices`, then take an owned copy of both at solver
    /// precision. The descriptor's arrays are borrowed: the caller may release them as
    /// soon as this returns.
    ///
    /// Validation is complete before the first allocation, so a typed refusal leaves
    /// nothing allocated. The two allocations that follow are unwound in LIFO order by
    /// the `errdefer` below if the second fails.
    pub fn init(gpa: std.mem.Allocator, vertices: []const ApiVec3, indices: []const u32) (std.mem.Allocator.Error || MeshError)!MeshData {
        // (1) The index count describes whole triangles. Tested first because every
        // check after it reads indices three at a time.
        if (indices.len % 3 != 0) return error.InvalidMeshIndexCount;
        // (2) At least one triangle. `0` IS a multiple of three, so an empty index array
        // reaches here rather than failing above, and the two conditions stay
        // distinguishable.
        if (indices.len == 0) return error.MeshEmpty;
        // A triangle index is the shape's `subshape_id` (§1.11.16), which is 32 bits
        // wide, so an index count past `3 · 2³²` would alias two triangles onto one id.
        // A debug assert and not a sixth typed error: the domain of §1.11.17 is closed at
        // five conditions, and the real bound here is the allocation itself — the index
        // array alone would be 51 GB, so this cannot be reached by any caller that
        // survived building its own descriptor.
        std.debug.assert(indices.len / 3 <= std.math.maxInt(u32));

        // (3) Every vertex is finite, and (4) every index is in range. Both run on the
        // descriptor's own arrays, before anything is copied.
        for (vertices) |v| {
            const c = v.toArray();
            // `@abs(NaN) < inf` is false, so this catches NaN along with the infinities.
            if (!(@abs(c[0]) < std.math.inf(f32) and @abs(c[1]) < std.math.inf(f32) and @abs(c[2]) < std.math.inf(f32))) {
                return error.MeshVertexNotFinite;
            }
        }
        for (indices) |i| {
            if (i >= vertices.len) return error.MeshIndexOutOfRange;
        }

        // (5) No triangle is exactly degenerate, checked on the WIDENED vertices because
        // those are the ones every kernel will use. The widening is exact, so this is the
        // stored geometry and not a different precision's view of it — and it matters:
        // three vertices whose `f32` cross product cancels to zero can have a non-zero
        // `f64` cross product, and vice versa.
        {
            var t: usize = 0;
            while (t < indices.len) : (t += 3) {
                const v0 = widen(vertices[indices[t]]);
                const v1 = widen(vertices[indices[t + 1]]);
                const v2 = widen(vertices[indices[t + 2]]);
                if (isDegenerate(v0, v1, v2)) return error.MeshTriangleDegenerate;
            }
        }

        const owned_vertices = try gpa.alloc(Vec3r, vertices.len);
        errdefer gpa.free(owned_vertices);
        var bound = Aabbr.fromMinMax(widen(vertices[0]), widen(vertices[0]));
        for (vertices, owned_vertices) |src, *dst| {
            dst.* = widen(src);
            bound = bound.expand(dst.*);
        }
        const owned_indices = try gpa.dupe(u32, indices);
        return .{ .vertices = owned_vertices, .indices = owned_indices, .local_aabb = bound };
    }

    /// Release the owned arrays.
    pub fn deinit(self: *MeshData, gpa: std.mem.Allocator) void {
        gpa.free(self.vertices);
        gpa.free(self.indices);
        self.* = undefined;
    }

    /// Number of triangles — and therefore the exclusive upper bound on a valid
    /// `subshape_id` for this shape (§1.11.16: a mesh is root, so its path IS its
    /// triangle index).
    pub fn triangleCount(self: MeshData) u32 {
        return @intCast(self.indices.len / 3);
    }

    /// The three vertices of triangle `index`, in stored order.
    pub fn triangle(self: MeshData, index: u32) [3]Vec3r {
        std.debug.assert(index < self.triangleCount());
        const base = @as(usize, index) * 3;
        return .{
            self.vertices[self.indices[base]],
            self.vertices[self.indices[base + 1]],
            self.vertices[self.indices[base + 2]],
        };
    }

    /// Outward unit normal of triangle `index`, in the shape's local frame.
    ///
    /// Winding is COUNTER-CLOCKWISE seen from the front face, so the normal is
    /// `normalize((v₁−v₀) × (v₂−v₀))` in that FIXED evaluation order. The order is what
    /// determinism needs (§1.5): the value is then a reproducible function of the stored
    /// vertices, which is why normals are NOT precomputed — precomputing would not
    /// improve the conditioning, the same cancellation happening at build time, it would
    /// only freeze the value and cost memory on the heaviest shape in the store.
    ///
    /// Total on a stored mesh: `init` refused every exactly-degenerate triangle, so the
    /// cross product is non-zero and `normalize` cannot answer NaN.
    pub fn faceNormal(self: MeshData, index: u32) Vec3r {
        const v = self.triangle(index);
        return faceCross(v[0], v[1], v[2]).normalize();
    }
};

/// The un-normalised face normal `(v₁−v₀) × (v₂−v₀)` — twice the triangle's area vector,
/// in the fixed evaluation order the winding convention fixes.
pub fn faceCross(v0: Vec3r, v1: Vec3r, v2: Vec3r) Vec3r {
    return v1.sub(v0).cross(v2.sub(v0));
}

/// Whether a triangle is EXACTLY degenerate — its cross product's largest absolute
/// component is zero, hence all three are.
///
/// The guard is at TRUE ZERO, and the test is on the largest absolute COMPONENT rather
/// than on the squared length, for the two reasons §1.11.4 gives for a null direction:
/// the square of a large-amplitude but finite value overflows to infinity, and the
/// square of a tiny but perfectly legitimate one underflows to zero. A sliver whose
/// area is minuscule and non-zero normalises exactly and must be SERVED — which is why
/// no area threshold appears here, and why a suite that only rejects degenerates would
/// pass just as well with one.
pub fn isDegenerate(v0: Vec3r, v1: Vec3r, v2: Vec3r) bool {
    return @reduce(.Max, @abs(faceCross(v0, v1, v2).data)) == 0;
}

/// Widen a descriptor vertex to solver precision. Exact: a per-component `f32` → `Real`
/// conversion.
fn widen(v: ApiVec3) Vec3r {
    const c = v.toArray();
    return Vec3r.fromArray(.{ c[0], c[1], c[2] });
}
