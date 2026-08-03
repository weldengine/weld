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
//! **The acceleration structure is not the broadphase `Bvh`, and what is shared is
//! shared by REUSE.** A mesh carries a FIXED triangle set: no insertion, no removal,
//! no fat margin, no rotation rebalancing. It is built once, by binned SAH, into a FLAT
//! node array. What is reused is reused verbatim — `Aabb(T).rayInterval` and
//! `Aabb(T).inflate` — so the swept traversal here is additive on §1.11.10's in the
//! strict sense: same slab test, same near-first descent, same bound tightening, in a
//! local tree instead of a scene tree.
//!
//! **Traversal is by EXPLICIT fixed-depth stack, never recursion.** The `Bvh`'s
//! recursion is safe only because its rotation rebalancing bounds its height, and a
//! static build offers no such guarantee: a pathological triangle set degrades the SAH
//! cut to an arbitrary depth. The height is therefore a BUILD-TIME INVARIANT the builder
//! knows and asserts — it forces a leaf at `max_tree_depth` — and every stack is sized
//! on it.
//!
//! **Adjacency and the active-edge flags are built HERE**, in the same transaction as
//! the storage, and not where they are consumed. Building them later would reopen the
//! OOM transaction a second time and change `MeshData`'s owned set after it had been
//! tested. Pairing is by SORTING `(min_index, max_index)` keys and pairing adjacent
//! entries — no hashed container, the `computePairs` pattern verbatim and the same
//! reason (§1.5).
//!
//! **Validation runs entirely BEFORE the first allocation.** A refused descriptor
//! therefore allocates nothing, which is what lets `ShapeStore.createShape` be
//! transactional without an unwind path for the rejection case (only for a later
//! reservation failure). The checks run on the WIDENED values, which is exact — a
//! per-component `f32` → `Real` conversion — so they validate the bytes that will be
//! stored and not a different precision's view of them.

const std = @import("std");
const config = @import("config.zig");
// Only for the `Ray` type the two ray-shaped traversals take — the reciprocal form the
// slab test wants, computed once by the query entry. The broadphase itself is the
// caller's, not this shape's; same import for the same reason as `body_manager.zig`.
const broadphase_mod = @import("pipeline/broadphase.zig");

const Real = config.Real;
const Vec3r = config.Vec3r;
const Aabbr = config.Aabbr;
const RayR = broadphase_mod.Ray(Real);
/// The descriptor's `f32` `Vec3` — the precision mesh vertices arrive in
/// (`engine-physics-forge.md` §1.11.8: the public surface stays `f32`).
const math = @import("foundation").math;
const ApiVec3 = math.Vec3;

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

/// Maximum triangles a leaf of the acceleration structure holds before the builder
/// splits it. The reference's `mMaxTrianglesPerLeaf` defaults to 8 and documents
/// sensible values between 4 and 8; Weld takes 8 and offers no build-quality option —
/// one quality, favouring traversal performance (§1.11.17).
///
/// A DISCRETISATION parameter, not a threshold: it selects how much work a leaf does
/// versus how deep the tree goes, and no answer depends on it.
pub const max_triangles_per_leaf: u32 = 8;

/// Number of uniform bins the SAH sweep evaluates per axis. Also a discretisation
/// parameter and not a threshold — a coarser or finer binning builds a different tree,
/// never a different answer, every traversal being exact against the node boxes it
/// actually holds.
pub const sah_bin_count: u32 = 12;

/// Hard ceiling on the tree's height, and the size every traversal stack is derived
/// from. The builder FORCES A LEAF at this depth, so the bound holds by construction
/// rather than by hope, and it asserts the achieved height against it.
///
/// A balanced build over the largest expressible triangle count — the index array is
/// `u32`-indexed, so at most `2³²` triangles — needs 32 levels. The other 32 are slack
/// for an unbalanced SAH cut, which a pathological triangle set really can produce: the
/// binned sweep is free to peel one triangle off at a time, and nothing in a static
/// build rebalances it. Past the ceiling a leaf simply holds more triangles, which costs
/// traversal time and changes no answer.
pub const max_tree_depth: u32 = 64;

/// Depth of every traversal stack, and of the builder's.
///
/// A depth-first walk of a binary tree of height `h` holds at most `h + 1` pending
/// entries: one deferred sibling per ancestor level, plus the node being descended into.
/// One more than that, and every push is asserted against it.
const stack_capacity: usize = max_tree_depth + 2;

/// Default cosine below which a CONVEX edge is treated as ACTIVE — `cos(5°)`, the
/// reference's `mActiveEdgeCosThresholdAngle` default.
///
/// **This is a named PHYSICAL parameter, of the same class as `restitution_threshold`
/// and `penetration_slop`, and not a numerical tolerance.** It selects a MODELLING
/// BEHAVIOUR: below it a fold is sharp enough that a slider should catch on it, above it
/// the surface is smooth enough that catching would be an artefact. The
/// `k · floatEps(T) · coordScale` discipline of §1.11.2 governs guards that absorb float
/// noise, and it does NOT apply here — a reviewer applying it to this constant will call
/// it a violation and will be wrong. Every genuinely numerical guard on this shape stays
/// at TRUE ZERO: the degenerate-triangle test, the parallel-normals test below, the
/// ray's parallel test.
///
/// It is declared HERE, and not beside those two in `rigid/solver_config.zig`, for a
/// reason that is structural rather than stylistic: the flags are BAKED AT CREATION, so
/// a solver-side field would be read long after the decision it governs had been taken,
/// and changing it at runtime would silently not rebuild anything. What makes it
/// CONFIGURABLE is `ShapeDescriptor.triangle_mesh.active_edge_cos_threshold`, whose
/// default this is: `createShape` passes the descriptor's field and never this constant,
/// so a caller of the public surface can override it per mesh. Without that field there
/// would be no path to it at all, and after the M1.1.15 freeze there could be none.
///
/// **`f32`, and NOT `Real` — the descriptor's precision is what fixes the value.** Typed
/// `Real` it renders as `0.9961947202682495` in an `f32` build and `0.9961946980917455` in
/// an `f64` one, so the same authored mesh would be classified against two different
/// thresholds depending on the build. That is not a type detail: it makes a build
/// configuration an input to the geometry, which is exactly what `-Dphysics_f64` parity
/// exists to keep from happening. Widened once at `MeshData.init`, exactly.
///
/// What this does NOT achieve, MEASURED rather than assumed: it does not make a given
/// descriptor's flags bit-identical across the two builds. The compared cosine is
/// `normalize((v₁−v₀) × (v₂−v₀)) · n_neighbour`, whose own value is build-dependent —
/// measured on a 5° fold, `0.9961947202682495` at `f32` against `0.9961946974669479` at
/// `f64`, a gap of `2.3e-8` of the same order as the `2.2e-8` between the two renderings
/// of the constant. Removing one of the two divergent terms is right, and it is the term
/// that had no business being there; the other is inherent to computing a normal at two
/// precisions and no threshold typing touches it.
///
/// The literal is written out rather than computed from `@cos`, so the value is a
/// constant of the source and not of the host's compile-time trigonometry
/// (`cos(5°) = 0.99619469809174553229…`, whose nearest `f32` is `0.9961947202682495`).
pub const default_active_edge_cos_threshold: f32 = 0.99619472;

/// One node of the flat acceleration structure.
///
/// The two children of an internal node are appended TOGETHER, so the right one is
/// always `first + 1` and one index suffices. That is what frees the builder from having
/// to emit in strict depth-first order, and therefore what lets it use an explicit stack
/// in any pop order.
pub const Node = struct {
    /// Tight bound over this node's triangles. NO fat margin: a mesh is static and
    /// nothing re-inserts into this tree, so the hysteresis a dynamic tree needs has
    /// nothing to buy here.
    aabb: Aabbr,
    /// Leaf: offset into `tri_order`. Internal: index of the LEFT child, the right one
    /// being `first + 1`.
    first: u32,
    /// Leaf: number of triangles, always `> 0`. Internal: `0`.
    count: u32,

    /// Whether this node is a leaf.
    pub fn isLeaf(self: Node) bool {
        return self.count != 0;
    }
};

/// A static triangle mesh: owned vertices at solver precision, owned indices, the tight
/// local-space bound over those vertices, the flat acceleration structure, and the
/// per-triangle active-edge flags.
///
/// Every array is OWNED — released by `deinit`, which the shape store calls from
/// `destroyShape` and from its own `deinit` over the live slots. The descriptor's arrays
/// are only borrowed for the duration of `init`.
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
    ///
    /// The ROOT node's box is the tight bound over the TRIANGLES, so it is contained in
    /// this one and equal to it whenever every stored vertex is referenced by some
    /// triangle — which is every mesh an exporter produces.
    local_aabb: Aabbr,
    /// The flat acceleration structure. `nodes[0]` is the root; a mesh always has at
    /// least one node, since it always has at least one triangle.
    nodes: []Node,
    /// Permutation of triangle indices the builder partitioned. A leaf covers
    /// `tri_order[first .. first + count]`, and it is these values — not the positions —
    /// that are the triangle indices, hence the `subshape_id`s.
    tri_order: []u32,
    /// Three active-edge bits per triangle: bit 0 for `v₀v₁`, bit 1 for `v₁v₂`, bit 2
    /// for `v₂v₀` — the reference's layout. Built at creation and consumed at contact
    /// time.
    edge_flags: []u8,
    /// Height actually achieved by the build, `0` for a single-leaf tree. Bounded by
    /// `max_tree_depth` BY CONSTRUCTION (the builder forces a leaf there) and asserted
    /// against it, which is what makes the fixed-size traversal stacks safe.
    max_depth: u32,

    /// Validate `vertices` / `indices`, take an owned copy of both at solver precision,
    /// build the acceleration structure, and build the active-edge flags. The
    /// descriptor's arrays are borrowed: the caller may release them as soon as this
    /// returns.
    ///
    /// Validation is complete before the first allocation, so a typed refusal leaves
    /// nothing allocated. Every allocation after it carries an `errdefer`, so a failure
    /// at any point unwinds in LIFO order and this returns owning nothing — which is what
    /// `ShapeStore.createShape`'s transaction rests on.
    ///
    /// `active_edge_cos_threshold` is the descriptor's own field — `f32`, widened here
    /// exactly — and `default_active_edge_cos_threshold` is only its default; see that
    /// declaration for why it is neither `Real` nor a field of the solver config.
    pub fn init(
        gpa: std.mem.Allocator,
        vertices: []const ApiVec3,
        indices: []const u32,
        active_edge_cos_threshold: f32,
    ) (std.mem.Allocator.Error || MeshError)!MeshData {
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
        errdefer gpa.free(owned_indices);

        var mesh: MeshData = .{
            .vertices = owned_vertices,
            .indices = owned_indices,
            .local_aabb = bound,
            // Filled by the two builds below; the struct exists first so they can read
            // the geometry through the ordinary accessors instead of re-deriving it.
            .nodes = &.{},
            .tri_order = &.{},
            .edge_flags = &.{},
            .max_depth = 0,
        };
        const triangle_count = mesh.triangleCount();

        mesh.tri_order = try gpa.alloc(u32, triangle_count);
        errdefer gpa.free(mesh.tri_order);
        for (mesh.tri_order, 0..) |*slot, t| slot.* = @intCast(t);

        try mesh.buildTree(gpa);
        errdefer gpa.free(mesh.nodes);

        mesh.edge_flags = try gpa.alloc(u8, triangle_count);
        errdefer gpa.free(mesh.edge_flags);
        // Widened ONCE, here, and exactly: the descriptor's `f32` is what fixes the value
        // in both builds (see `default_active_edge_cos_threshold`).
        try mesh.buildEdgeFlags(gpa, @as(Real, active_edge_cos_threshold));

        return mesh;
    }

    /// Release the owned arrays.
    pub fn deinit(self: *MeshData, gpa: std.mem.Allocator) void {
        gpa.free(self.vertices);
        gpa.free(self.indices);
        gpa.free(self.tri_order);
        gpa.free(self.nodes);
        gpa.free(self.edge_flags);
        self.* = undefined;
    }

    /// An UPPER BOUND on `coreExtent` over every triangle of this mesh: the distance from the
    /// local origin to the furthest corner of the local AABB, which is at least the magnitude of
    /// the furthest vertex.
    ///
    /// O(1), read off the cached box rather than swept over the vertices — a candidate filter
    /// that has to be conservative with respect to GJK's contact margin needs the pair's
    /// coordinate scale BEFORE the traversal, hence a bound over all candidates and not the exact
    /// value for one. Being an over-estimate is the safe direction: it widens the candidate box.
    pub fn maxVertexMagnitude(self: MeshData) Real {
        return self.local_aabb.min.abs().max(self.local_aabb.max.abs()).length();
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
    /// **Both overflows on this path are closed, and they are two and not one.** The true-zero
    /// refusal at creation rules out a cross product of exactly zero, hence a NaN from dividing
    /// by it; the failures here are at the other end of the range, and each needed its own fix.
    /// `normalizeScaled` closes the SQUARED LENGTH: a cross product of `1e20`, which `f32`
    /// vertices at `1e10` produce and the finite domain admits, squares to infinity, and a plain
    /// `normalize` then divides by infinity and answers the ZERO VECTOR. `math.triangleCross`
    /// closes the CROSS PRODUCT ITSELF and the EDGE behind it, which `normalizeScaled` never
    /// could, being handed the damage already done: vertices at `1e20` cross to `1e40`, which is
    /// infinity, and `normalizeScaled` then divides infinity by infinity and answers NaN — a
    /// worse outcome than the zero vector, since it propagates. Vertices at `±3e38` overflow one
    /// step earlier still, in the SUBTRACTION, and that one breaks at `f64` as well. Reducing the
    /// three vertices by a common power of two before subtracting is what puts every step back in
    /// range at both precisions; §1.11.17's unit-length invariant holds across the whole domain
    /// only with the two together.
    ///
    /// Total on a stored mesh: `init` refused every exactly-degenerate triangle, so the cross
    /// product is non-zero and the optional is never empty — asserted rather than unwrapped
    /// blindly, so the guarantee is stated where it is relied upon.
    pub fn faceNormal(self: MeshData, index: u32) Vec3r {
        const v = self.triangle(index);
        return switch (faceCross(v[0], v[1], v[2])) {
            // `init` refused every degenerate triangle with an EXACT predicate, so a stored triangle
            // always has a direction — asserted here rather than assumed, and the normalisation
            // cannot fail either, the direction being non-zero by construction.
            .direction => |d| d.normalizeScaled() orelse unreachable,
            .degenerate => unreachable,
        };
    }

    /// Tight local-space bound of triangle `index`.
    pub fn triangleAabb(self: MeshData, index: u32) Aabbr {
        const v = self.triangle(index);
        return Aabbr.fromMinMax(v[0], v[0]).expand(v[1]).expand(v[2]);
    }

    /// Centroid of triangle `index` — the quantity the SAH bins on. The arithmetic mean
    /// of the three vertices, in the stored order, so it is reproducible.
    pub fn triangleCentroid(self: MeshData, index: u32) Vec3r {
        const v = self.triangle(index);
        return v[0].add(v[1]).add(v[2]).scale(1.0 / 3.0);
    }

    /// The three active-edge bits of triangle `index`: bit 0 for `v₀v₁`, bit 1 for
    /// `v₁v₂`, bit 2 for `v₂v₀`.
    pub fn edgeFlags(self: MeshData, index: u32) u8 {
        std.debug.assert(index < self.triangleCount());
        return self.edge_flags[index];
    }

    /// Whether edge `edge` (`0`, `1` or `2`) of triangle `index` is ACTIVE.
    pub fn edgeIsActiveAt(self: MeshData, index: u32, edge: u2) bool {
        std.debug.assert(edge < 3);
        return (self.edgeFlags(index) >> edge) & 1 != 0;
    }

    // ----------------------------------------------------------------------
    // The static binned-SAH build
    // ----------------------------------------------------------------------

    /// Build the flat node array over `tri_order`, which `init` has already filled with
    /// the identity permutation.
    ///
    /// One allocation, reserved PRECISELY up front so no growth can fail mid-build: a
    /// binary tree with `L` leaves has `2L − 1` nodes and `L <= T`, so `2T − 1` is the
    /// exact worst case. The list is shrunk to what was actually used on the way out —
    /// with a leaf of eight triangles the real count is nearer `T / 4`.
    ///
    /// The work list is an EXPLICIT STACK, like every traversal below and for the same
    /// reason: a recursive builder would overflow on exactly the pathological input the
    /// depth ceiling exists for.
    fn buildTree(self: *MeshData, gpa: std.mem.Allocator) std.mem.Allocator.Error!void {
        const triangle_count = self.triangleCount();
        std.debug.assert(triangle_count >= 1);

        var nodes: std.ArrayListUnmanaged(Node) = .empty;
        errdefer nodes.deinit(gpa);
        try nodes.ensureTotalCapacityPrecise(gpa, 2 * @as(usize, triangle_count) - 1);

        const Work = struct { node: u32, first: u32, count: u32, depth: u32 };
        var stack: [stack_capacity]Work = undefined;
        var sp: usize = 0;

        nodes.appendAssumeCapacity(.{ .aabb = self.triangleAabb(self.tri_order[0]), .first = 0, .count = triangle_count });
        stack[sp] = .{ .node = 0, .first = 0, .count = triangle_count, .depth = 0 };
        sp += 1;

        var achieved_depth: u32 = 0;
        while (sp > 0) {
            sp -= 1;
            const work = stack[sp];
            const range = self.tri_order[work.first .. work.first + work.count];

            // The node's box is the tight bound over its own triangles — computed here,
            // once per node, so a leaf box and an internal box mean the same thing.
            var box = self.triangleAabb(range[0]);
            for (range[1..]) |t| box = box.merge(self.triangleAabb(t));
            nodes.items[work.node].aabb = box;

            // A leaf either because the range is small enough or because the CEILING was
            // reached. The second case costs traversal time and changes no answer, which
            // is what makes a hard ceiling an acceptable way to bound the height.
            if (work.count <= max_triangles_per_leaf or work.depth == max_tree_depth) {
                nodes.items[work.node] = .{ .aabb = box, .first = work.first, .count = work.count };
                achieved_depth = @max(achieved_depth, work.depth);
                continue;
            }

            const left_count = self.chooseSplit(range);
            std.debug.assert(left_count > 0 and left_count < work.count);

            const left_index: u32 = @intCast(nodes.items.len);
            // Appended TOGETHER, which is what makes the right child `left_index + 1` and
            // frees the build from any emission-order constraint.
            nodes.appendAssumeCapacity(.{ .aabb = box, .first = 0, .count = 0 });
            nodes.appendAssumeCapacity(.{ .aabb = box, .first = 0, .count = 0 });
            nodes.items[work.node] = .{ .aabb = box, .first = left_index, .count = 0 };

            std.debug.assert(sp + 2 <= stack.len);
            stack[sp] = .{
                .node = left_index + 1,
                .first = work.first + left_count,
                .count = work.count - left_count,
                .depth = work.depth + 1,
            };
            sp += 1;
            stack[sp] = .{
                .node = left_index,
                .first = work.first,
                .count = left_count,
                .depth = work.depth + 1,
            };
            sp += 1;
        }

        // The invariant the traversal stacks are sized on, asserted rather than assumed.
        std.debug.assert(achieved_depth <= max_tree_depth);
        self.max_depth = achieved_depth;
        self.nodes = try nodes.toOwnedSlice(gpa);
    }

    /// Partition `range` in place and return the size of its left part, which is always
    /// in `[1, range.len - 1]` — the split ALWAYS makes progress, which is what bounds
    /// the recursion together with the depth ceiling.
    ///
    /// Binned SAH over all three axes: for each axis whose centroid extent is non-zero,
    /// the triangles are binned uniformly by centroid and the `bin_count − 1` candidate
    /// splits are swept, scoring `area_left · count_left + area_right · count_right` —
    /// the surface-area heuristic without the parent-area division, which is constant
    /// here. The tie-break is FIXED: axes ascending, then split positions ascending,
    /// keeping only a STRICTLY better cost, so the earliest candidate wins a tie.
    ///
    /// The zero-extent guard is at TRUE ZERO: an axis on which every centroid coincides
    /// carries no information and is skipped, and if all three are skipped — every
    /// centroid identical, which a set of concentric triangles really produces — the
    /// fallback is a MEDIAN split of the range as it stands. That fallback is what
    /// guarantees progress, and with it the height of a balanced build is `log₂`.
    fn chooseSplit(self: MeshData, range: []u32) u32 {
        var centroid_bound = Aabbr.fromMinMax(self.triangleCentroid(range[0]), self.triangleCentroid(range[0]));
        for (range[1..]) |t| centroid_bound = centroid_bound.expand(self.triangleCentroid(t));
        const lo = centroid_bound.min.toArray();
        const extent = centroid_bound.max.sub(centroid_bound.min).toArray();

        var best_axis: ?u32 = null;
        var best_bin: u32 = 0;
        var best_cost: Real = std.math.inf(Real);

        for (0..3) |axis| {
            if (extent[axis] == 0) continue; // no information on this axis
            var bin_count: [sah_bin_count]u32 = @splat(0);
            var bin_box: [sah_bin_count]Aabbr = undefined;
            for (range) |t| {
                const b = self.binOf(t, @intCast(axis), lo[axis], extent[axis]);
                const tri_box = self.triangleAabb(t);
                bin_box[b] = if (bin_count[b] == 0) tri_box else bin_box[b].merge(tri_box);
                bin_count[b] += 1;
            }

            // Right-to-left prefix sweep first, so the left-to-right one below can score
            // each candidate in constant time.
            var right_box: [sah_bin_count]Aabbr = undefined;
            var right_count: [sah_bin_count]u32 = @splat(0);
            var acc_box: ?Aabbr = null;
            var acc_count: u32 = 0;
            var b: u32 = sah_bin_count;
            while (b > 0) {
                b -= 1;
                if (bin_count[b] != 0) {
                    acc_box = if (acc_box) |a| a.merge(bin_box[b]) else bin_box[b];
                    acc_count += bin_count[b];
                }
                right_box[b] = acc_box orelse Aabbr.fromMinMax(Vec3r.zero, Vec3r.zero);
                right_count[b] = acc_count;
            }

            var left_box: ?Aabbr = null;
            var left_count: u32 = 0;
            for (0..sah_bin_count - 1) |split| {
                if (bin_count[split] != 0) {
                    left_box = if (left_box) |a| a.merge(bin_box[split]) else bin_box[split];
                    left_count += bin_count[split];
                }
                // Only candidates with BOTH sides non-empty are scored, so the returned
                // split can never be degenerate.
                if (left_count == 0 or right_count[split + 1] == 0) continue;
                const cost = left_box.?.surfaceArea() * @as(Real, @floatFromInt(left_count)) +
                    right_box[split + 1].surfaceArea() * @as(Real, @floatFromInt(right_count[split + 1]));
                if (cost < best_cost) {
                    best_cost = cost;
                    best_axis = @intCast(axis);
                    best_bin = @intCast(split);
                }
            }
        }

        const axis = best_axis orelse {
            // MEDIAN fallback: every centroid coincides on every axis, so no SAH split
            // exists. Halving the range as it stands makes progress and keeps the height
            // logarithmic on such a set.
            return @intCast(range.len / 2);
        };

        // In-place two-pointer partition by bin. Deterministic — a pure function of the
        // input order — and it needs no scratch.
        var i: usize = 0;
        var j: usize = range.len;
        while (i < j) {
            if (self.binOf(range[i], axis, lo[axis], extent[axis]) <= best_bin) {
                i += 1;
            } else {
                j -= 1;
                std.mem.swap(u32, &range[i], &range[j]);
            }
        }
        std.debug.assert(i > 0 and i < range.len);
        return @intCast(i);
    }

    /// Uniform bin of triangle `t`'s centroid along `axis`, clamped into
    /// `[0, sah_bin_count)`. The clamp catches the centroid sitting exactly on the upper
    /// bound, whose quotient is exactly 1.
    fn binOf(self: MeshData, t: u32, axis: u32, lo: Real, extent: Real) u32 {
        const c = self.triangleCentroid(t).toArray()[axis];
        const scaled = @as(Real, @floatFromInt(sah_bin_count)) * (c - lo) / extent;
        if (!(scaled > 0)) return 0; // also catches a NaN, which the domain forbids anyway
        const b: u32 = @intFromFloat(@min(scaled, @as(Real, sah_bin_count - 1)));
        return @min(b, sah_bin_count - 1);
    }

    // ----------------------------------------------------------------------
    // Adjacency and the active-edge flags
    // ----------------------------------------------------------------------

    /// Build the three active-edge bits of every triangle.
    ///
    /// Pairing is by SORTING keys `(min_index, max_index)` and pairing adjacent entries —
    /// no hashed container anywhere, the `computePairs` pattern verbatim and the same
    /// reason (determinism by construction, §1.5). The sort key is a TOTAL order
    /// `(lo, hi, triangle, edge)`, so the outcome does not rest on the sort's stability.
    ///
    /// One scratch allocation of `3T` records, released on the way out whether or not the
    /// build succeeds.
    fn buildEdgeFlags(self: *MeshData, gpa: std.mem.Allocator, cos_threshold: Real) std.mem.Allocator.Error!void {
        const triangle_count = self.triangleCount();
        const records = try gpa.alloc(EdgeRecord, 3 * @as(usize, triangle_count));
        defer gpa.free(records);

        var t: u32 = 0;
        while (t < triangle_count) : (t += 1) {
            const base = @as(usize, t) * 3;
            for (0..3) |e| {
                const a = self.indices[base + e];
                const b = self.indices[base + (e + 1) % 3];
                records[base + e] = .{
                    .lo = @min(a, b),
                    .hi = @max(a, b),
                    .triangle = t,
                    .edge = @intCast(e),
                };
            }
        }

        std.mem.sort(EdgeRecord, records, {}, EdgeRecord.less);

        @memset(self.edge_flags, 0);
        var start: usize = 0;
        while (start < records.len) {
            var end = start + 1;
            while (end < records.len and records[end].sameEdgeAs(records[start])) end += 1;
            const run = records[start..end];
            if (run.len == 2) {
                const active = self.pairIsActive(run[0], run[1], cos_threshold);
                if (active) {
                    for (run) |r| self.edge_flags[r.triangle] |= @as(u8, 1) << r.edge;
                }
            } else {
                // ONE entry: a boundary edge of an open mesh, which has no neighbour to be
                // smooth with, so it is ACTIVE (§1.11.17).
                //
                // THREE OR MORE: a non-manifold edge. It has no single neighbour either,
                // so smoothing is undefined on it, and the conservative answer is the same
                // one — active means the contact is resolved in full, which is never
                // incorrect, only occasionally stiffer than a smooth surface would be.
                for (run) |r| self.edge_flags[r.triangle] |= @as(u8, 1) << r.edge;
            }
            start = end;
        }
    }

    /// Whether the edge shared by the two records is ACTIVE.
    ///
    /// The convexity test and the fold angle are both taken from the FIRST record's
    /// triangle, whose winding gives the edge its direction; the answer is symmetric in
    /// the two, since swapping them negates both the edge direction and the cross product.
    fn pairIsActive(self: MeshData, a: EdgeRecord, b: EdgeRecord, cos_threshold: Real) bool {
        const va = self.triangle(a.triangle);
        const edge_direction = va[(@as(usize, a.edge) + 1) % 3].sub(va[a.edge]);
        return edgeIsActive(
            self.faceNormal(a.triangle),
            self.faceNormal(b.triangle),
            edge_direction,
            cos_threshold,
        );
    }

    // ----------------------------------------------------------------------
    // Traversals — explicit fixed-depth stack, never recursion
    // ----------------------------------------------------------------------

    /// Swept traversal: hand `collector.add(triangle_index)` every triangle of every leaf
    /// whose node box, INFLATED BY `extent`, the ray crosses within the collector's
    /// current bound. Returns the number of nodes visited.
    ///
    /// Additive on §1.11.10's scene traversal in the strict sense — same collector
    /// contract (`add`, `maxDistance()` re-read before every descent, `shouldStop()`),
    /// same near-first descent, `Aabb.rayInterval` and `Aabb.inflate` reused verbatim —
    /// with two differences that are both consequences of the tree being local and static:
    /// the boxes carry no fat margin, and the walk is an explicit stack rather than
    /// recursion.
    ///
    /// The bound is re-read at POP rather than at push, which can only prune more: a
    /// deferred sibling is tested against a bound that has had the whole near subtree to
    /// tighten it.
    pub fn traverseCast(self: MeshData, ray: RayR, extent: Vec3r, collector: anytype) u32 {
        const Entry = struct { index: u32, enter: Real };
        var stack: [stack_capacity]Entry = undefined;
        var sp: usize = 0;
        var visited: u32 = 0;

        const root = self.castInterval(0, ray, extent) orelse return 1;
        if (!accepts(root.enter, root.exit, collector.maxDistance())) return 1;
        stack[0] = .{ .index = 0, .enter = root.enter };
        sp = 1;

        while (sp > 0) {
            if (collector.shouldStop()) break;
            sp -= 1;
            const entry = stack[sp];
            visited += 1;
            // Re-tested at pop: the bound may have tightened since this node was deferred.
            if (entry.enter > collector.maxDistance()) continue;

            const node = self.nodes[entry.index];
            if (node.isLeaf()) {
                for (self.tri_order[node.first .. node.first + node.count]) |t| {
                    if (collector.shouldStop()) break;
                    collector.add(t);
                }
                continue;
            }

            const left = node.first;
            const right = node.first + 1;
            const iv_left = self.castInterval(left, ray, extent);
            const iv_right = self.castInterval(right, ray, extent);
            const bound = collector.maxDistance();
            const ok_left = iv_left != null and accepts(iv_left.?.enter, iv_left.?.exit, bound);
            const ok_right = iv_right != null and accepts(iv_right.?.enter, iv_right.?.exit, bound);
            const enter_left = if (ok_left) iv_left.?.enter else std.math.inf(Real);
            const enter_right = if (ok_right) iv_right.?.enter else std.math.inf(Real);

            // NEAR-FIRST: the nearer child is pushed LAST so it is popped first, which is
            // what lets the bound tighten as early as possible. A fixed tie-break keeps
            // the left child first, the convention of the broadphase file.
            const near_is_left = enter_left <= enter_right;
            const first_child: u32 = if (near_is_left) left else right;
            const second_child: u32 = if (near_is_left) right else left;
            const first_enter: Real = if (near_is_left) enter_left else enter_right;
            const second_enter: Real = if (near_is_left) enter_right else enter_left;
            const first_ok = if (near_is_left) ok_left else ok_right;
            const second_ok = if (near_is_left) ok_right else ok_left;

            std.debug.assert(sp + 2 <= stack.len);
            if (second_ok) {
                stack[sp] = .{ .index = second_child, .enter = second_enter };
                sp += 1;
            }
            if (first_ok) {
                stack[sp] = .{ .index = first_child, .enter = first_enter };
                sp += 1;
            }
        }
        return visited;
    }

    /// Ray traversal — `traverseCast` at a ZERO extent, one traversal and not two. The
    /// re-expression is behaviour-preserving for the reason `Bvh.queryRay` records: a
    /// zero added to a float changes at most the sign of a zero bound, and nothing
    /// downstream distinguishes the two zeros.
    pub fn traverseRay(self: MeshData, ray: RayR, collector: anytype) u32 {
        return self.traverseCast(ray, Vec3r.zero, collector);
    }

    /// Overlap traversal: hand `collector.add(triangle_index)` every triangle of every
    /// leaf whose node box meets `query`, faces included. Returns the number of nodes
    /// visited. There is no bound to tighten, so the collector needs only `add`
    /// (§1.11.12).
    pub fn traverseAabb(self: MeshData, query: Aabbr, collector: anytype) u32 {
        var stack: [stack_capacity]u32 = undefined;
        var sp: usize = 0;
        var visited: u32 = 0;

        if (!self.nodes[0].aabb.overlaps(query)) return 1;
        stack[0] = 0;
        sp = 1;

        while (sp > 0) {
            sp -= 1;
            const index = stack[sp];
            visited += 1;
            const node = self.nodes[index];
            if (node.isLeaf()) {
                for (self.tri_order[node.first .. node.first + node.count]) |t| collector.add(t);
                continue;
            }
            std.debug.assert(sp + 2 <= stack.len);
            // Right pushed first so the left is popped first — a fixed order, so the
            // sequence of `add` calls is a pure function of the tree and the query.
            if (self.nodes[node.first + 1].aabb.overlaps(query)) {
                stack[sp] = node.first + 1;
                sp += 1;
            }
            if (self.nodes[node.first].aabb.overlaps(query)) {
                stack[sp] = node.first;
                sp += 1;
            }
        }
        return visited;
    }

    /// Bounded-distance traversal: hand `collector.add(triangle_index)` every triangle of
    /// every leaf whose node box lies within the collector's current bound of `point`.
    /// Returns the number of nodes visited.
    ///
    /// The distance analogue of the ray's branch and bound: the nearer child is descended
    /// first and `maxDistance()` is re-read before every descent, so a collector that
    /// tightens on each accepted candidate prunes the rest (§1.11.13).
    ///
    /// The comparison is on SQUARED distances, so a bound whose square overflows to
    /// infinity prunes nothing — conservative in the safe direction, and reachable only
    /// for a bound no query entry accepts, `max_distance` being required finite.
    pub fn traverseDistance(self: MeshData, point: Vec3r, collector: anytype) u32 {
        const Entry = struct { index: u32, dist_sq: Real };
        var stack: [stack_capacity]Entry = undefined;
        var sp: usize = 0;
        var visited: u32 = 0;

        const root_dist_sq = aabbDistanceSq(self.nodes[0].aabb, point);
        var limit = collector.maxDistance();
        if (root_dist_sq > limit * limit) return 1;
        stack[0] = .{ .index = 0, .dist_sq = root_dist_sq };
        sp = 1;

        while (sp > 0) {
            sp -= 1;
            const entry = stack[sp];
            visited += 1;
            limit = collector.maxDistance();
            if (entry.dist_sq > limit * limit) continue;

            const node = self.nodes[entry.index];
            if (node.isLeaf()) {
                for (self.tri_order[node.first .. node.first + node.count]) |t| collector.add(t);
                continue;
            }

            const left = node.first;
            const right = node.first + 1;
            const d_left = aabbDistanceSq(self.nodes[left].aabb, point);
            const d_right = aabbDistanceSq(self.nodes[right].aabb, point);
            limit = collector.maxDistance();
            const limit_sq = limit * limit;
            const ok_left = d_left <= limit_sq;
            const ok_right = d_right <= limit_sq;

            const near_is_left = d_left <= d_right;
            std.debug.assert(sp + 2 <= stack.len);
            if (near_is_left) {
                if (ok_right) {
                    stack[sp] = .{ .index = right, .dist_sq = d_right };
                    sp += 1;
                }
                if (ok_left) {
                    stack[sp] = .{ .index = left, .dist_sq = d_left };
                    sp += 1;
                }
            } else {
                if (ok_left) {
                    stack[sp] = .{ .index = left, .dist_sq = d_left };
                    sp += 1;
                }
                if (ok_right) {
                    stack[sp] = .{ .index = right, .dist_sq = d_right };
                    sp += 1;
                }
            }
        }
        return visited;
    }

    /// Slab interval of `ray` against node `index`'s box inflated by `extent` —
    /// `Aabb.inflate` then `Aabb.rayInterval`, both reused verbatim (§1.11.10).
    fn castInterval(self: MeshData, index: u32, ray: RayR, extent: Vec3r) ?Aabbr.RayInterval {
        return self.nodes[index].aabb.inflate(extent)
            .rayInterval(ray.origin, ray.inv_dir, ray.dir_is_zero);
    }
};

/// Whether a slab interval survives the `[0, bound]` window, closed at both ends — the
/// broadphase's `accepts`, in the form this file's intervals arrive in.
fn accepts(enter: Real, exit: Real, bound: Real) bool {
    return exit >= 0 and enter <= bound;
}

/// Squared distance from `point` to the closed box, zero inside it.
///
/// Local to this file rather than in `foundation`: `surfaceArea`, `rayInterval`,
/// `inflate` and `overlapsHalfSpace` live there because two or more consumers needed
/// each, and this one has exactly one. It moves the day a second appears. `pub` only so
/// the acceptance suite can state the bounded-distance traversal's brute-force contract
/// in the same terms the traversal decides it in.
pub fn aabbDistanceSq(box: Aabbr, point: Vec3r) Real {
    const zeros: @Vector(3, Real) = @splat(0);
    const below = @max(box.min.data - point.data, zeros);
    const above = @max(point.data - box.max.data, zeros);
    const d = below + above; // at most one term is non-zero per axis
    return @reduce(.Add, d * d);
}

/// One (triangle, edge) endpoint of the adjacency sort.
const EdgeRecord = struct {
    /// Smaller vertex index of the edge.
    lo: u32,
    /// Larger vertex index of the edge.
    hi: u32,
    /// Owning triangle.
    triangle: u32,
    /// Which of the triangle's three edges: `0` for `v₀v₁`, `1` for `v₁v₂`, `2` for
    /// `v₂v₀` — the reference's bit layout, and the bit this record sets.
    edge: u2,

    /// Total order `(lo, hi, triangle, edge)`. Total and not merely a grouping key, so
    /// the pairing does not rest on the sort's stability.
    fn less(_: void, a: EdgeRecord, b: EdgeRecord) bool {
        if (a.lo != b.lo) return a.lo < b.lo;
        if (a.hi != b.hi) return a.hi < b.hi;
        if (a.triangle != b.triangle) return a.triangle < b.triangle;
        return a.edge < b.edge;
    }

    /// Whether both records name the same undirected edge.
    fn sameEdgeAs(self: EdgeRecord, other: EdgeRecord) bool {
        return self.lo == other.lo and self.hi == other.hi;
    }
};

/// Whether an edge shared by two triangles is ACTIVE, given their outward unit normals
/// and the edge's direction in the FIRST triangle's winding.
///
/// The three rules of §1.11.17, in order:
///
///   - normals OPPOSITE → active;
///   - CONCAVE → inactive, always;
///   - CONVEX → active exactly when the fold is sharper than the threshold, i.e. when
///     `n₁·n₂` falls below it.
///
/// Convexity is `(n₁ × n₂) · edge_direction > 0`, and the sign is DERIVED rather than
/// guessed: for two triangles meeting along `+X` with `n₁ = +Z`, a convex ridge puts the
/// second triangle's far vertex at `(0, −cos α, −sin α)`, giving `n₂ = (0, −sin α, cos α)`
/// and `n₁ × n₂ = (sin α, 0, 0)`, which is POSITIVE along the edge direction `(1, 0, 0)`;
/// the valley case flips that vertex to `+sin α` and the dot product's sign with it. The
/// inline tests pin both.
///
/// The `== 0` branch is at TRUE ZERO and it is exactly the parallel case, not an
/// approximation of one: the cross product and the edge direction both lie in the line
/// orthogonal to the two normals, so they are parallel whenever the normals are
/// independent, and the dot product vanishes only when the cross product does. Parallel
/// normals then split by SIGN — the same normal twice is a flat seam and inactive, an
/// opposite pair is back-to-back and active.
///
/// RESIDUAL, named rather than papered over: within a few ULPs of exactly antiparallel
/// the cross product is not exactly zero and its direction is float noise, so such an
/// edge is classified by the convex/concave branch and may come out inactive. Closing
/// that would take an angular epsilon, which the threshold discipline forbids, and the
/// configuration is a pair of coincident back-to-back triangles, which no valid surface
/// contains.
pub fn edgeIsActive(normal_a: Vec3r, normal_b: Vec3r, edge_direction: Vec3r, cos_threshold: Real) bool {
    const orientation = normal_a.cross(normal_b).dot(edge_direction);
    const cos_angle = normal_a.dot(normal_b);
    if (orientation > 0) return cos_angle < cos_threshold; // convex
    if (orientation < 0) return false; // concave — never active
    return cos_angle < 0; // parallel: active exactly when opposite
}

/// The DIRECTION of the face normal `(v₁−v₀) × (v₂−v₀)`, in the fixed evaluation order the winding
/// convention fixes. **NOT a flatness classifier** — that is `isDegenerate` below.
///
/// The two outcomes are ASYMMETRIC, exactly as `math.CrossOutcome` states: `.degenerate` is only
/// reached after the exact integer tier has answered zero, so it is a reliable flatness verdict;
/// `.direction` is returned by the first FLOAT tier that forms a finite non-zero vector, so it does
/// NOT prove the triangle is non-flat — on exactly proportional points that vector can be a rounding
/// residue. On a stored mesh the distinction costs nothing, `init` having already classified every
/// triangle exactly, which is why this entry may stay on the cheap tiers.
///
/// **SCALED, and deliberately so — the magnitude is not a reliable multiple of twice the area.** The
/// shared `math.triangleCross` answers in three tiers, unscaled first and an exact integer
/// determinant last, and only the direction survives across all three unchanged. It is shared with the ray↔triangle kernel for the reason
/// stated at `isDegenerate`: the guard that refuses a triangle and the normal that describes it must
/// be computed from the same geometry.
pub fn faceCross(v0: Vec3r, v1: Vec3r, v2: Vec3r) math.CrossOutcome(Real) {
    return math.triangleCross(Real, v0, v1, v2);
}

/// Whether a triangle is degenerate — its EXACT area vector is zero, with no tolerance taking part
/// in the decision at any point.
///
/// **This is an EXACT predicate, and that is new.** For five rounds it was a float test at true
/// zero, which is unimpeachable about a zero it computes but says nothing about the zeros it fails
/// to compute: a triangle whose components span more than the format's exponent range read as flat
/// while being perfectly ordinary, and the caller received a typed refusal accusing valid data.
/// `math.triangleIsFlat` settles it in integer arithmetic with no float step anywhere, so the verdict
/// means exactly one thing — the three points really are collinear — and no triangle is ever
/// mislabelled. The agreement with an independent big-integer oracle is asserted in BOTH directions,
/// per case, over the randomized property: no false accept and no false refusal, at both precisions.
///
/// A sliver whose area is minuscule and non-zero normalises exactly and IS SERVED, which the earlier
/// comment claimed without being able to deliver it; no area threshold appears here, and a suite
/// that only rejected degenerates would pass just as well with one.
pub fn isDegenerate(v0: Vec3r, v1: Vec3r, v2: Vec3r) bool {
    // The EXACT path directly, never through the tiered `faceCross`. The reason is measured: the
    // cheap tiers answer first, and a float cross that comes out non-zero on three exactly
    // proportional points is a rounding residue rather than evidence, so routing the verdict through
    // them admitted flat triangles — three of 932 exactly-degenerate `f32` draws, with the exact
    // tier never consulted. Since the rewiring the verdict is exact and its agreement with an
    // independent big-integer oracle is asserted in BOTH directions, per case, at both precisions.
    // The direction is a separate question, asked of `faceCross` on geometry this predicate has
    // already admitted.
    return math.triangleIsFlat(Real, v0, v1, v2);
}

/// Widen a descriptor vertex to solver precision. Exact: a per-component `f32` → `Real`
/// conversion.
fn widen(v: ApiVec3) Vec3r {
    const c = v.toArray();
    return Vec3r.fromArray(.{ c[0], c[1], c[2] });
}
