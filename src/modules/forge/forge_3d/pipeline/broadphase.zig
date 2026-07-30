//! `forge_3d/pipeline/broadphase.zig` — the shared broadphase: a dynamic
//! multi-layer AABB tree (BVH) producing the candidate pairs the narrowphase
//! (M1.1.2–4) will consume.
//!
//! `Bvh(T)` is an incremental dynamic AABB tree in the Box2D `b2DynamicTree`
//! tradition — SAH best-cost-child descent on insertion, rotation-based
//! balancing, and fat AABBs so small motions don't re-insert — reimplemented
//! against Weld conventions, not ported. It is the proven shape for the plan's
//! acceptance (incremental insert/remove/update with O(log n) queries); Jolt's
//! 4-wide batch-rebuilt tree targets massive parallel rebuilds and is a poor
//! fit here (brief Notes).
//!
//! **Dependency discipline (brief Notes).** This file imports `foundation`
//! (math) only — never `weld_forge`, never `body*.zig`, never `config.zig`.
//! The scalar arrives as the comptime parameter `T`; `forge_3d` instantiates it
//! at `config.Real` (E4). `user_data` is an opaque `u32` to the tree; only the
//! forge_3d side knows it is a packed `BodyId`.
//!
//! **Determinism by construction (anticipates M1.1.14).** No hash containers
//! anywhere: an index-based node pool with a LIFO free-list (same philosophy as
//! `slot_alloc.zig`, but internal and without generation packing), and a tree
//! shape that is a pure function of the op sequence. SAH ties resolve to the
//! second child, balance ties to the shorter-rotation branch — both fixed.
//!
//! **Two collector contracts, three entries (M1.1.9, M1.1.10).** `queryAabb` asks
//! its collector for `add(user_data)` and nothing else. `queryCast` asks for `add`
//! plus TWO more, both required of every collector: `maxDistance()`, which it
//! re-reads before every descent and prunes on — turning the traversal into
//! *branch and bound*, with a near-first descent so the bound tightens as early as
//! possible (`engine-physics-forge.md` §1.11.2) — and `shouldStop()`, which ends
//! the traversal outright. The two are not interchangeable: a zero bound is still
//! a BOUND, so every node whose interval contains the ray origin survives it, and
//! `Broadphase.queryCast` would still walk the remaining layer trees. An `any`
//! query that must "terminate at the first candidate" needs the second. Same split
//! as the reference, which exposes `GetEarlyOutFraction` alongside `ShouldEarlyOut`
//! / `ForceEarlyOut` (`CollisionCollector.h`).
//!
//! `queryRay` is the third entry and shares the second contract: a ray IS a cast of
//! a zero-extent volume, so it delegates to `queryCast` rather than duplicating the
//! descent (§1.11.10). The swept traversal differs from the ray traversal in exactly
//! one thing — each node's stored box is inflated by the cast volume's half-extents
//! before the slab test, which stays byte-for-byte the same function.
//!
//! A query mutates nothing, wakes nobody, and visits every layer tree unless the
//! collector stops it (§1.11.1) — it never touches the moved-logs nor the retained
//! pair set.

const std = @import("std");
const math = @import("foundation").math;

/// A ray in world space, carrying the reciprocal form `Aabb.rayInterval` wants.
/// Build it with `init` so the derived fields cannot disagree with `direction`.
///
/// The traversal itself reads only `origin`, `inv_dir` and `dir_is_zero`;
/// `direction` rides along because a ray without it is not a ray and every
/// caller needs it for the exact kernel. There is no `max_distance` field: the
/// bound belongs to the collector, which is what lets it tighten mid-traversal
/// (`engine-physics-forge.md` §1.11.2).
pub fn Ray(comptime T: type) type {
    return struct {
        const Self = @This();
        const Vec3T = math.Vec(3, T);

        /// Ray origin in world space.
        origin: Vec3T,
        /// Ray direction. Normalised by the query entry, not by this type.
        direction: Vec3T,
        /// Componentwise reciprocal of `direction`.
        inv_dir: Vec3T,
        /// Lanes of `direction` that are exactly zero.
        dir_is_zero: @Vector(3, bool),

        /// Ray from an origin and a direction, deriving the reciprocal form.
        ///
        /// A direction of exactly zero is representable here and yields a
        /// degenerate ray: the query ENTRY rejects it with an empty result
        /// (`engine-physics-forge.md` §1.11.4), the traversal holds no opinion
        /// on it. What is a programming error, and asserted, is a non-finite
        /// direction — `rayInterval`'s repair of `0 · inf` is exact only under
        /// that precondition.
        pub fn init(origin: Vec3T, direction: Vec3T) Self {
            const Simd = @Vector(3, T);
            std.debug.assert(@reduce(.And, @abs(direction.data) < @as(Simd, @splat(std.math.inf(T)))));
            const ones: Simd = @splat(1);
            return .{
                .origin = origin,
                .direction = direction,
                .inv_dir = .{ .data = ones / direction.data },
                .dir_is_zero = direction.data == @as(Simd, @splat(0)),
            };
        }
    };
}

/// Broadphase tuning, carried by `Bvh(T).init`.
pub fn BroadphaseConfig(comptime T: type) type {
    return struct {
        /// Fat-AABB margin in world units (meters). Each leaf's stored AABB is
        /// enlarged by this on every axis so a proxy that moves less than the
        /// margin stays inside its fat box and does not trigger a re-insert
        /// (see `Bvh.update`, E2). Velocity-based expansion is out of scope
        /// (lands with integration, M1.1.5).
        margin: T = 0.1,
    };
}

/// Dynamic AABB tree over proxies carrying an opaque `u32` `user_data`.
/// Generic over the scalar `T` (`f32` by default, `f64` under the solver's
/// `-Dphysics_f64`); a proxy id is a node-pool index (no generation packing —
/// the caller owns staleness semantics). See the file header.
pub fn Bvh(comptime T: type) type {
    return struct {
        const Self = @This();
        const AabbT = math.Aabb(T);
        const Vec3T = math.Vec(3, T);

        /// Sentinel for "no node" (pool index that never exists).
        const null_index: u32 = std.math.maxInt(u32);

        /// One pool slot. Leaves have `child1 == null_index` and carry
        /// `user_data`; internal nodes have both children and an AABB that is
        /// the exact union of theirs. A slot on the free-list has
        /// `height == -1` and reuses `parent` as the free-list link.
        const Node = struct {
            /// Fat AABB (leaf: tight ⊕ margin; internal: union of children).
            aabb: AabbT = undefined,
            /// Parent index, or the next free slot while `height == -1`.
            parent: u32 = null_index,
            /// First child, or `null_index` for a leaf.
            child1: u32 = null_index,
            /// Second child, or `null_index` for a leaf.
            child2: u32 = null_index,
            /// Opaque payload; meaningful only for leaves.
            user_data: u32 = 0,
            /// 0 for a leaf, `1 + max(children)` for an internal node, `-1` for
            /// a free slot.
            height: i32 = -1,
        };

        /// Tuning config type for this scalar.
        pub const Config = BroadphaseConfig(T);

        nodes: std.ArrayListUnmanaged(Node) = .empty,
        root: u32 = null_index,
        free_list: u32 = null_index,
        leaf_count: u32 = 0,
        config: Config,

        /// A tree with the given tuning and no proxies.
        pub fn init(config: Config) Self {
            return .{ .config = config };
        }

        /// Release the node pool.
        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            self.nodes.deinit(gpa);
            self.* = undefined;
        }

        /// Number of live proxies (leaves).
        pub fn leafCount(self: *const Self) u32 {
            return self.leaf_count;
        }

        /// Height of the tree (`-1` when empty, `0` for a single proxy).
        pub fn height(self: *const Self) i32 {
            if (self.root == null_index) return -1;
            return self.nodes.items[self.root].height;
        }

        /// The opaque `user_data` stored for `proxy` (must be a live leaf).
        pub fn userData(self: *const Self, proxy: u32) u32 {
            std.debug.assert(self.nodes.items[proxy].height == 0);
            return self.nodes.items[proxy].user_data;
        }

        /// The stored fat AABB of `proxy` (must be a live leaf).
        pub fn proxyAabb(self: *const Self, proxy: u32) AabbT {
            std.debug.assert(self.nodes.items[proxy].height == 0);
            return self.nodes.items[proxy].aabb;
        }

        /// Whether `index` currently names a live leaf (used to skip a stale
        /// proxy id whose slot was freed and not yet reused).
        pub fn isLiveLeaf(self: *const Self, index: u32) bool {
            return index < self.nodes.items.len and self.nodes.items[index].height == 0;
        }

        /// Insert a proxy for `tight_aabb` carrying `user_data`. The stored box
        /// is `tight_aabb` fattened by `config.margin`. Returns the proxy id
        /// (a node index). Each insert adds at most two nodes (the leaf plus one
        /// internal split node); `gpa` is required because the pool grows.
        pub fn insert(self: *Self, gpa: std.mem.Allocator, tight_aabb: AabbT, user_data: u32) !u32 {
            // At most 2 fresh appends per insert (leaf + split parent); reusing
            // free-list slots consumes none. Reserve up front so the internal
            // allocation in `insertLeaf` cannot fail (slot_alloc idiom).
            try self.nodes.ensureUnusedCapacity(gpa, 2);
            const leaf = self.allocateNodeAssumeCapacity();
            self.nodes.items[leaf].aabb = self.fatten(tight_aabb);
            self.nodes.items[leaf].user_data = user_data;
            self.nodes.items[leaf].height = 0;
            self.nodes.items[leaf].child1 = null_index;
            self.nodes.items[leaf].child2 = null_index;
            self.insertLeaf(leaf);
            self.leaf_count += 1;
            return leaf;
        }

        /// Remove a proxy previously returned by `insert`. `proxy` must be a
        /// live leaf; removing frees the leaf and its parent internal node.
        pub fn remove(self: *Self, proxy: u32) void {
            std.debug.assert(proxy < self.nodes.items.len);
            std.debug.assert(self.nodes.items[proxy].height == 0); // live leaf
            self.removeLeaf(proxy);
            self.freeNode(proxy);
            self.leaf_count -= 1;
        }

        /// Move a proxy to `tight_aabb`. Hysteresis: if `tight_aabb` still lies
        /// inside the proxy's stored fat AABB, nothing changes and this returns
        /// `false`; otherwise the proxy is re-fattened around `tight_aabb`,
        /// re-inserted, and this returns `true`. Allocation-free — `removeLeaf`
        /// frees exactly the one internal node `insertLeaf` reuses (and a lone
        /// proxy re-roots without touching the pool), so no `gpa` is needed.
        pub fn update(self: *Self, proxy: u32, tight_aabb: AabbT) bool {
            std.debug.assert(proxy < self.nodes.items.len);
            std.debug.assert(self.nodes.items[proxy].height == 0); // live leaf
            if (aabbContains(self.nodes.items[proxy].aabb, tight_aabb)) {
                return false;
            }
            self.removeLeaf(proxy);
            self.nodes.items[proxy].aabb = self.fatten(tight_aabb);
            self.insertLeaf(proxy);
            return true;
        }

        /// Overlap query: call `collector.add(user_data)` for every proxy whose
        /// stored (fat) AABB overlaps `query` (face-inclusive, `Aabb.overlaps`).
        /// Returns the number of nodes visited — the metric the O(log n)
        /// complexity test asserts on. `collector` is a pointer to any value
        /// exposing `fn add(self, user_data: u32) void`.
        pub fn queryAabb(self: *const Self, query: AabbT, collector: anytype) u32 {
            if (self.root == null_index) return 0;
            return self.queryNode(self.root, query, collector);
        }

        /// Recursive half of `queryAabb`: prune on non-overlap, collect leaves,
        /// descend otherwise. Each touched node counts as one visit. Depth is
        /// the (balanced) tree height, so the call stack stays logarithmic.
        fn queryNode(self: *const Self, index: u32, query: AabbT, collector: anytype) u32 {
            const node = self.nodes.items[index];
            if (!node.aabb.overlaps(query)) return 1; // visited then pruned
            if (isLeaf(node)) {
                collector.add(node.user_data);
                return 1;
            }
            return 1 + self.queryNode(node.child1, query, collector) +
                self.queryNode(node.child2, query, collector);
        }

        /// Half-space query: `collector.add(user_data)` for every proxy whose stored (fat)
        /// AABB meets the CLOSED half-space `{ x : normal·x <= distance }`. Returns the
        /// number of nodes visited.
        ///
        /// An exact mirror of `queryAabb` with one predicate swapped — the eight-branch
        /// corner test of `Aabb.overlapsHalfSpace` instead of the box overlap. This is
        /// the broadphase role of an unbounded shape: it is never asked for a box, it is
        /// asked whether it meets one (`engine-physics-forge.md` §1.11.15).
        ///
        /// Pruning on the FAT box is conservative in the safe direction: the fat box
        /// contains the tight one, so a subtree the half-space does not meet contains no
        /// body it could touch. The surplus candidates a fat box admits are the exact
        /// kernel's to reject, exactly as for `queryAabb` (§1.11.2).
        pub fn queryHalfSpace(self: *const Self, normal: Vec3T, distance: T, collector: anytype) u32 {
            if (self.root == null_index) return 0;
            return self.queryHalfSpaceNode(self.root, normal, distance, collector);
        }

        /// Recursive half of `queryHalfSpace` — prune on non-overlap, collect leaves,
        /// descend otherwise. Each touched node counts as one visit.
        fn queryHalfSpaceNode(self: *const Self, index: u32, normal: Vec3T, distance: T, collector: anytype) u32 {
            const node = self.nodes.items[index];
            if (!node.aabb.overlapsHalfSpace(normal, distance)) return 1; // visited then pruned
            if (isLeaf(node)) {
                collector.add(node.user_data);
                return 1;
            }
            return 1 + self.queryHalfSpaceNode(node.child1, normal, distance, collector) +
                self.queryHalfSpaceNode(node.child2, normal, distance, collector);
        }

        /// Ray type for this scalar.
        pub const RayT = Ray(T);

        /// Swept-volume query, *branch and bound* (`engine-physics-forge.md`
        /// §1.11.10): `collector.add(user_data)` for every proxy whose stored (fat)
        /// AABB, **inflated by `extent`**, the ray crosses within the collector's
        /// current bound. Returns the number of nodes visited.
        ///
        /// Additive on the ray traversal in the strict sense: same collector
        /// contract, same near-first descent, same slab test unchanged, same visited
        /// accounting. The single difference is the inflation, and `queryRay` below
        /// is this function at a zero extent.
        ///
        /// **What the caller must pass.** `extent` is the half-extents of the cast
        /// shape's INITIAL world AABB, and `ray.origin` is the CENTRE `c₀` of that
        /// same AABB — not the shape's position. The AABB is a constant of the query:
        /// the sweep is a pure translation, so the shape's rotation does not change
        /// during it, and the caller computes the box once at entry. For the three
        /// shapes the store builds today the centre and the position coincide, their
        /// local AABB being centred on the origin, but that is a property of THOSE
        /// SHAPES and not of the model — a decentred volume (a compound, a mesh)
        /// breaks the equality, which is why the contract is written on `c₀`. The
        /// returned parameter is the same either way, the sweep being a translation.
        ///
        /// **Why inflating the node is exact.** The Minkowski sum of two boxes is a
        /// box, so `node.inflate(extent)` is exactly the set of centres at which the
        /// swept box overlaps the node (`Aabb.inflate`); testing the ray from `c₀`
        /// against it therefore IS the swept-box-versus-node test, not an
        /// approximation. It stays conservative with respect to the SHAPE — whose
        /// AABB is larger than it is — and never with respect to the boxes, and the
        /// surplus candidates are the exact kernel's to reject (§1.11.2). The
        /// inflation is an ADDITION, not a threshold: no constant appears.
        ///
        /// The entry parameter of an inflated node is a LOWER BOUND of the true time
        /// of impact against any leaf it contains, so branch and bound stays valid
        /// and a `closest` collector may tighten on the best accepted time of impact
        /// exactly as it does for a ray.
        ///
        /// What is deliberately NOT done: enclosing the whole sweep in a single AABB
        /// and handing it to `queryAabb`. That loses the bound entirely — a 50 m cast
        /// would visit the whole corridor — turning a sub-linear query into one linear
        /// in the proxies of the swept volume (§1.11.10).
        pub fn queryCast(self: *const Self, ray: RayT, extent: Vec3T, collector: anytype) u32 {
            if (self.root == null_index) return 0;
            // Checked before the root too, so a collector that has already stopped
            // costs nothing per remaining tree in `Broadphase.queryCast`.
            if (collector.shouldStop()) return 0;
            const iv = self.castInterval(self.root, ray, extent);
            if (!accepts(iv, collector.maxDistance())) return 1; // visited then pruned
            return self.queryCastNode(self.root, ray, extent, collector);
        }

        /// Ray query, *branch and bound*: `collector.add(user_data)` for every
        /// proxy whose stored (fat) AABB the ray crosses within the collector's
        /// current bound. Returns the number of nodes visited — the metric the
        /// logarithmic-cost test asserts on.
        ///
        /// A ray is a cast of a zero-extent volume, and this is literally that call
        /// — one traversal, not two. **Its behaviour is unchanged by the
        /// re-expression**, and the argument is worth writing down because a zero
        /// added to a float is not always a no-op:
        ///
        ///   - `min − 0` is exact and preserves the sign of a zero bound.
        ///   - `max + 0` maps a `−0.0` bound to `+0.0`. Every other value is
        ///     unchanged, and no other bound can change at all.
        ///   - Nothing downstream distinguishes the two zeros. The parallel-slab
        ///     test compares with `<` and `>`; the slab products then differ at most
        ///     in a zero's sign; `@min`/`@max` treat `±0.0` as equal; the
        ///     `enter > exit` rejection, `accepts`'s `exit >= 0` and `enter <= bound`,
        ///     and the near-first `e1 <= e2` ordering are all blind to it.
        ///   - The `0 · inf` NaN repair is untouched: both signed zeros times an
        ///     infinity are NaN, and the repair is unconditional.
        ///
        /// So the traversal's two observables — the visited count and the collected
        /// set — are identical, which the M1.1.9 traversal suite asserts against
        /// counts measured before the refactor.
        ///
        /// `collector` is a pointer to any value exposing the `queryAabb`
        /// contract plus one method:
        ///
        ///   - `fn add(self, user_data: u32) void` — a candidate. The exact
        ///     kernel is the collector's business, not the traversal's.
        ///   - `fn maxDistance(self) T` — the distance beyond which it accepts
        ///     nothing more. **Re-read before every descent**, so a collector
        ///     that tightens it inside `add` prunes the rest of the traversal
        ///     immediately: that is what makes a closest-hit sub-linear. A
        ///     `closest` collector tightens on each accepted hit, an `all`
        ///     collector never tightens.
        ///   - `fn shouldStop(self) bool` — whether to abandon the traversal
        ///     entirely. **Re-read before every descent** as well, and checked
        ///     again by `Broadphase.queryRay` between layer trees. A bound of zero
        ///     does NOT express this: it still admits every node whose interval
        ///     contains the origin, and it says nothing about the trees not yet
        ///     visited. An `any` collector returns true from its first accepted
        ///     hit; `closest` and `all` never stop early.
        ///
        /// The interval is intersected with `[0, maxDistance()]`, closed at both
        /// ends: a box behind the origin is pruned, a box entered exactly at the
        /// bound is not. The fat AABBs are traversed as stored — the surplus
        /// candidates are the exact kernel's to reject, never the box's to
        /// shrink (§1.11.2).
        pub fn queryRay(self: *const Self, ray: RayT, collector: anytype) u32 {
            return self.queryCast(ray, Vec3T.zero, collector);
        }

        /// Recursive half of `queryCast`. Precondition: `index`'s own interval has
        /// already been tested and accepted, so each node's slab test runs
        /// exactly once and each node contributes exactly one visit.
        ///
        /// The descent is **near-first**: of the two children, the one with the
        /// smaller entry parameter goes first, so the bound tightens as early as
        /// possible. That order is a pure function of the tree shape and the ray,
        /// hence deterministic — but it is NOT invariant under a different
        /// creation order, which builds a different tree. Only the RESULT is
        /// invariant (§1.11.6); the visited-node count never is.
        fn queryCastNode(self: *const Self, index: u32, ray: RayT, extent: Vec3T, collector: anytype) u32 {
            const node = self.nodes.items[index];
            if (isLeaf(node)) {
                collector.add(node.user_data);
                return 1;
            }

            const iv1 = self.castInterval(node.child1, ray, extent);
            const iv2 = self.castInterval(node.child2, ray, extent);
            // A missed child sorts last; ties keep `child1` first (fixed
            // tie-break, the SAH/balance convention of this file).
            const e1 = if (iv1) |v| v.enter else std.math.inf(T);
            const e2 = if (iv2) |v| v.enter else std.math.inf(T);
            const first_is_1 = e1 <= e2;
            const children: [2]u32 = if (first_is_1)
                .{ node.child1, node.child2 }
            else
                .{ node.child2, node.child1 };
            const intervals: [2]?AabbT.RayInterval = if (first_is_1)
                .{ iv1, iv2 }
            else
                .{ iv2, iv1 };

            var visited: u32 = 1;
            for (children, intervals) |child, iv| {
                // Both are re-read HERE, once per descent: a tightening performed
                // while the near child was being explored prunes the far one, and a
                // collector that has seen enough ends the walk instead of merely
                // narrowing it.
                if (collector.shouldStop()) break;
                if (accepts(iv, collector.maxDistance())) {
                    visited += self.queryCastNode(child, ray, extent, collector);
                } else {
                    visited += 1; // tested then pruned
                }
            }
            return visited;
        }

        /// Slab interval of `ray` against node `index`'s stored AABB inflated by
        /// `extent`. The slab test itself is `Aabb.rayInterval`, unchanged: the
        /// swept traversal differs from the ray traversal only in the box it is
        /// handed (§1.11.10).
        fn castInterval(self: *const Self, index: u32, ray: RayT, extent: Vec3T) ?AabbT.RayInterval {
            return self.nodes.items[index].aabb.inflate(extent)
                .rayInterval(ray.origin, ray.inv_dir, ray.dir_is_zero);
        }

        /// Whether an interval survives the `[0, bound]` window, closed at both
        /// ends.
        fn accepts(interval: ?AabbT.RayInterval, bound: T) bool {
            const iv = interval orelse return false;
            return iv.exit >= 0 and iv.enter <= bound;
        }

        // --- Node pool ---

        /// Grab a slot (LIFO free-list reuse, else a fresh append). Capacity for
        /// a fresh append must be reserved by the caller (`ensureUnusedCapacity`).
        fn allocateNodeAssumeCapacity(self: *Self) u32 {
            if (self.free_list != null_index) {
                const idx = self.free_list;
                self.free_list = self.nodes.items[idx].parent; // next free
                self.nodes.items[idx] = .{ .height = 0 };
                return idx;
            }
            const idx: u32 = @intCast(self.nodes.items.len);
            self.nodes.appendAssumeCapacity(.{ .height = 0 });
            return idx;
        }

        /// Return a slot to the LIFO free-list (pushed at the head, so an
        /// identical op sequence reuses indices identically — M1.1.14).
        fn freeNode(self: *Self, index: u32) void {
            self.nodes.items[index].parent = self.free_list;
            self.nodes.items[index].height = -1;
            self.free_list = index;
        }

        fn isLeaf(node: Node) bool {
            return node.child1 == null_index;
        }

        /// `tight` grown by `config.margin` on every axis.
        fn fatten(self: *const Self, tight: AabbT) AabbT {
            const m = Vec3T.splat(self.config.margin);
            return .{ .min = tight.min.sub(m), .max = tight.max.add(m) };
        }

        // --- Insertion (SAH descent + rebalance) ---

        /// SAH cost of descending into `child` for `leaf_aabb`: the surface-area
        /// contribution of merging plus the inherited cost above.
        fn descentCost(self: *const Self, child: u32, leaf_aabb: AabbT, inheritance_cost: T) T {
            const combined = leaf_aabb.merge(self.nodes.items[child].aabb);
            if (isLeaf(self.nodes.items[child])) {
                return combined.surfaceArea() + inheritance_cost;
            }
            const old_area = self.nodes.items[child].aabb.surfaceArea();
            return (combined.surfaceArea() - old_area) + inheritance_cost;
        }

        fn insertLeaf(self: *Self, leaf: u32) void {
            if (self.root == null_index) {
                self.root = leaf;
                self.nodes.items[leaf].parent = null_index;
                return;
            }

            // 1. Find the best sibling by SAH best-cost-child descent.
            const leaf_aabb = self.nodes.items[leaf].aabb;
            var index = self.root;
            while (!isLeaf(self.nodes.items[index])) {
                const child1 = self.nodes.items[index].child1;
                const child2 = self.nodes.items[index].child2;

                const area = self.nodes.items[index].aabb.surfaceArea();
                const combined = self.nodes.items[index].aabb.merge(leaf_aabb);
                const combined_area = combined.surfaceArea();

                // Cost of putting a new parent here vs. pushing further down.
                const cost = 2 * combined_area;
                const inheritance_cost = 2 * (combined_area - area);
                const cost1 = self.descentCost(child1, leaf_aabb, inheritance_cost);
                const cost2 = self.descentCost(child2, leaf_aabb, inheritance_cost);

                if (cost < cost1 and cost < cost2) break;
                index = if (cost1 < cost2) child1 else child2; // tie → child2
            }
            const sibling = index;

            // 2. Create a new parent for `sibling` and `leaf`.
            const old_parent = self.nodes.items[sibling].parent;
            const new_parent = self.allocateNodeAssumeCapacity();
            self.nodes.items[new_parent].parent = old_parent;
            self.nodes.items[new_parent].aabb = leaf_aabb.merge(self.nodes.items[sibling].aabb);
            self.nodes.items[new_parent].height = self.nodes.items[sibling].height + 1;
            self.nodes.items[new_parent].child1 = sibling;
            self.nodes.items[new_parent].child2 = leaf;
            self.nodes.items[sibling].parent = new_parent;
            self.nodes.items[leaf].parent = new_parent;
            if (old_parent != null_index) {
                if (self.nodes.items[old_parent].child1 == sibling) {
                    self.nodes.items[old_parent].child1 = new_parent;
                } else {
                    self.nodes.items[old_parent].child2 = new_parent;
                }
            } else {
                self.root = new_parent;
            }

            // 3. Walk back up refitting AABBs / heights and rebalancing.
            self.refitFrom(self.nodes.items[leaf].parent);
        }

        fn removeLeaf(self: *Self, leaf: u32) void {
            if (leaf == self.root) {
                self.root = null_index;
                return;
            }
            const parent = self.nodes.items[leaf].parent;
            const grand_parent = self.nodes.items[parent].parent;
            const sibling = if (self.nodes.items[parent].child1 == leaf)
                self.nodes.items[parent].child2
            else
                self.nodes.items[parent].child1;

            if (grand_parent != null_index) {
                // Splice `sibling` in where `parent` was, drop `parent`.
                if (self.nodes.items[grand_parent].child1 == parent) {
                    self.nodes.items[grand_parent].child1 = sibling;
                } else {
                    self.nodes.items[grand_parent].child2 = sibling;
                }
                self.nodes.items[sibling].parent = grand_parent;
                self.freeNode(parent);
                self.refitFrom(grand_parent);
            } else {
                self.root = sibling;
                self.nodes.items[sibling].parent = null_index;
                self.freeNode(parent);
            }
        }

        /// From `start` up to the root: rebalance, then refit AABB + height.
        fn refitFrom(self: *Self, start: u32) void {
            var index = start;
            while (index != null_index) {
                index = self.balance(index);
                const c1 = self.nodes.items[index].child1;
                const c2 = self.nodes.items[index].child2;
                self.nodes.items[index].aabb = self.nodes.items[c1].aabb.merge(self.nodes.items[c2].aabb);
                self.nodes.items[index].height = 1 + @max(self.nodes.items[c1].height, self.nodes.items[c2].height);
                index = self.nodes.items[index].parent;
            }
        }

        /// One rotation step at subtree root `ia` (AVL-like: rotate the taller
        /// grandchild up when the child heights differ by more than one).
        /// Returns the new subtree root. No allocation — the `items` slice is
        /// stable for the whole call.
        fn balance(self: *Self, ia: u32) u32 {
            const items = self.nodes.items;
            if (isLeaf(items[ia]) or items[ia].height < 2) return ia;

            const ib = items[ia].child1;
            const ic = items[ia].child2;
            const bal = items[ic].height - items[ib].height;

            // Rotate C up.
            if (bal > 1) {
                const if_ = items[ic].child1;
                const ig = items[ic].child2;
                // Swap A and C.
                items[ic].child1 = ia;
                items[ic].parent = items[ia].parent;
                items[ia].parent = ic;
                // A's old parent now points to C.
                const cp = items[ic].parent;
                if (cp != null_index) {
                    if (items[cp].child1 == ia) items[cp].child1 = ic else items[cp].child2 = ic;
                } else {
                    self.root = ic;
                }
                // Rotate: promote C's taller child, keep the shorter under A.
                if (items[if_].height > items[ig].height) {
                    items[ic].child2 = if_;
                    items[ia].child2 = ig;
                    items[ig].parent = ia;
                    items[ia].aabb = items[ib].aabb.merge(items[ig].aabb);
                    items[ic].aabb = items[ia].aabb.merge(items[if_].aabb);
                    items[ia].height = 1 + @max(items[ib].height, items[ig].height);
                    items[ic].height = 1 + @max(items[ia].height, items[if_].height);
                } else {
                    items[ic].child2 = ig;
                    items[ia].child2 = if_;
                    items[if_].parent = ia;
                    items[ia].aabb = items[ib].aabb.merge(items[if_].aabb);
                    items[ic].aabb = items[ia].aabb.merge(items[ig].aabb);
                    items[ia].height = 1 + @max(items[ib].height, items[if_].height);
                    items[ic].height = 1 + @max(items[ia].height, items[ig].height);
                }
                return ic;
            }

            // Rotate B up.
            if (bal < -1) {
                const id = items[ib].child1;
                const ie = items[ib].child2;
                // Swap A and B.
                items[ib].child1 = ia;
                items[ib].parent = items[ia].parent;
                items[ia].parent = ib;
                const bp = items[ib].parent;
                if (bp != null_index) {
                    if (items[bp].child1 == ia) items[bp].child1 = ib else items[bp].child2 = ib;
                } else {
                    self.root = ib;
                }
                if (items[id].height > items[ie].height) {
                    items[ib].child2 = id;
                    items[ia].child1 = ie;
                    items[ie].parent = ia;
                    items[ia].aabb = items[ic].aabb.merge(items[ie].aabb);
                    items[ib].aabb = items[ia].aabb.merge(items[id].aabb);
                    items[ia].height = 1 + @max(items[ic].height, items[ie].height);
                    items[ib].height = 1 + @max(items[ia].height, items[id].height);
                } else {
                    items[ib].child2 = ie;
                    items[ia].child1 = id;
                    items[id].parent = ia;
                    items[ia].aabb = items[ic].aabb.merge(items[id].aabb);
                    items[ib].aabb = items[ia].aabb.merge(items[ie].aabb);
                    items[ia].height = 1 + @max(items[ic].height, items[id].height);
                    items[ib].height = 1 + @max(items[ia].height, items[ie].height);
                }
                return ib;
            }

            return ia;
        }

        // --- Invariant checker (used by tests; asserts, so a no-op in
        //     ReleaseFast — the test targets run Debug + ReleaseSafe) ---

        /// Assert every structural and metric invariant of the tree: parent /
        /// child link coherence, each internal AABB contains its children,
        /// height consistency, a well-formed free-list, and a leaf census that
        /// matches `leaf_count`.
        pub fn validate(self: *const Self) void {
            if (self.root == null_index) {
                std.debug.assert(self.leaf_count == 0);
            } else {
                std.debug.assert(self.nodes.items[self.root].parent == null_index);
            }
            self.validateStructure(self.root);
            self.validateMetrics(self.root);

            // Free-list: every slot is marked free, in range, and acyclic.
            var idx = self.free_list;
            var guard: usize = 0;
            while (idx != null_index) {
                std.debug.assert(idx < self.nodes.items.len);
                std.debug.assert(self.nodes.items[idx].height == -1);
                idx = self.nodes.items[idx].parent;
                guard += 1;
                std.debug.assert(guard <= self.nodes.items.len);
            }

            std.debug.assert(self.countLeaves(self.root) == self.leaf_count);
        }

        fn validateStructure(self: *const Self, index: u32) void {
            if (index == null_index) return;
            const node = self.nodes.items[index];
            if (isLeaf(node)) {
                std.debug.assert(node.child2 == null_index);
                std.debug.assert(node.height == 0);
                return;
            }
            const c1 = node.child1;
            const c2 = node.child2;
            std.debug.assert(c1 < self.nodes.items.len);
            std.debug.assert(c2 < self.nodes.items.len);
            std.debug.assert(self.nodes.items[c1].parent == index);
            std.debug.assert(self.nodes.items[c2].parent == index);
            self.validateStructure(c1);
            self.validateStructure(c2);
        }

        fn validateMetrics(self: *const Self, index: u32) void {
            if (index == null_index) return;
            const node = self.nodes.items[index];
            if (isLeaf(node)) {
                std.debug.assert(node.height == 0);
                return;
            }
            const c1 = node.child1;
            const c2 = node.child2;
            const expected_height = 1 + @max(self.nodes.items[c1].height, self.nodes.items[c2].height);
            std.debug.assert(node.height == expected_height);
            std.debug.assert(aabbContains(node.aabb, self.nodes.items[c1].aabb));
            std.debug.assert(aabbContains(node.aabb, self.nodes.items[c2].aabb));
            self.validateMetrics(c1);
            self.validateMetrics(c2);
        }

        fn countLeaves(self: *const Self, index: u32) u32 {
            if (index == null_index) return 0;
            const node = self.nodes.items[index];
            if (isLeaf(node)) return 1;
            return self.countLeaves(node.child1) + self.countLeaves(node.child2);
        }

        /// Whether `outer` fully contains `inner` (inclusive faces).
        fn aabbContains(outer: AabbT, inner: AabbT) bool {
            return @reduce(.And, outer.min.data <= inner.min.data) and
                @reduce(.And, inner.max.data <= outer.max.data);
        }
    };
}

// ---------------------------------------------------------------------------
// Multi-layer aggregate + candidate-pair generation
// ---------------------------------------------------------------------------

/// The collision broad layers (`engine-physics-forge.md` §1.2). Each owns its
/// own `Bvh(T)` inside `Broadphase(T)`; `default_layer_pairs` decides which
/// layer combinations may produce candidate pairs.
pub const BroadphaseLayer = enum(u8) {
    static,
    dynamic,
    debris,
    trigger,
};

/// Number of broad layers.
pub const layer_count = @typeInfo(BroadphaseLayer).@"enum".fields.len;

/// Sentinel for "no free unbounded slot" — a list index that can never exist, the same
/// role `Bvh`'s `null_index` plays for its node pool.
const null_slot: u32 = std.math.maxInt(u32);

/// Default layer-pair matrix — symmetric; `true` = the two layers produce
/// candidate pairs. Indexed by `@intFromEnum(BroadphaseLayer)`
/// (static=0, dynamic=1, debris=2, trigger=3). Allowed: dynamic×dynamic,
/// dynamic×static, dynamic×debris, dynamic×trigger, debris×static (brief Notes).
/// Overridable `CollisionConfig` wiring is a later milestone (out of scope);
/// this `const` is the Phase-1 default.
pub const default_layer_pairs: [layer_count][layer_count]bool = .{
    //         static  dynamic  debris  trigger
    .{ false, true, true, false }, // static
    .{ true, true, true, true }, // dynamic
    .{ true, true, false, false }, // debris
    .{ false, true, false, false }, // trigger
};

/// Multi-layer broadphase: one `Bvh(T)` per `BroadphaseLayer`, per-layer
/// moved-proxy tracking, and `computePairs` producing the deterministic,
/// deduplicated candidate-pair list the narrowphase consumes. No hash
/// containers anywhere (determinism by construction, M1.1.14).
pub fn Broadphase(comptime T: type) type {
    return struct {
        const Self = @This();
        const BvhT = Bvh(T);
        const AabbT = math.Aabb(T);
        const Vec3T = math.Vec(3, T);

        /// Tuning config type for this scalar.
        pub const Config = BroadphaseConfig(T);

        /// Which structure a `Proxy` names. An UNBOUNDED shape has no AABB, so it
        /// cannot live in a tree at all (`engine-physics-forge.md` §1.11.15): it lives in
        /// a flat per-layer list, and the handle has to say which of the two it indexes.
        pub const ProxyKind = enum {
            /// A leaf of the layer's `Bvh` — `id` is a node-pool index.
            tree,
            /// A slot of the layer's unbounded list — `id` is a list index.
            unbounded,
        };

        /// A proxy handle: the owning layer, WHICH STRUCTURE it lives in, and its
        /// structure-local id.
        pub const Proxy = struct {
            layer: BroadphaseLayer,
            /// Added at M1.1.11. Every consumer switches on it exhaustively, so the
            /// third structure a later shape category might need is a compile error at
            /// each site rather than a silent mis-index into the wrong pool.
            kind: ProxyKind = .tree,
            id: u32,
        };

        /// An unbounded shape as the broadphase sees it: NOT a box, a half-space
        /// `{ x : normal·x <= distance }` in WORLD space, carried by value.
        ///
        /// Deliberately a local type rather than a shared one with the narrowphase's
        /// `plane.HalfSpace`: this file imports `foundation` only, and what is shared is
        /// the FORMULA — `Aabb.overlapsHalfSpace`, which lives in `foundation/math`
        /// precisely so both callers use one copy of it. Two field names are not a
        /// duplicated formula.
        pub const UnboundedShape = struct {
            /// Outward unit normal; the solid is the `normal·x <= distance` side.
            normal: Vec3T,
            /// Offset along `normal` (metres).
            distance: T,
        };

        /// One slot of a layer's unbounded list.
        ///
        /// **What the in-place retirement defends is the slot's IDENTITY, not its
        /// existence.** A live `Proxy` holds a list INDEX, so no operation may move
        /// another slot: compaction would shift later entries down and silently re-point
        /// every `Proxy` past the hole. REUSE is a different matter and is fine — a LIFO
        /// free-list hands the same index back to a new shape and moves nothing — which is
        /// exactly what `Bvh` does one level up with `freeNode` / `allocateNodeAssumeCapacity`
        /// in this same file. Without the free-list the list grew monotonically with every
        /// plane ever created, and its visit cost with it (M1.1.11/E7-J3); with it, the
        /// bound becomes the live PEAK, which is stated on the `unbounded` field.
        ///
        /// A dead slot links to the next free one through `user_data`, which is meaningless
        /// while dead — the same field-reuse `Bvh` performs on a free node's `parent`.
        ///
        /// The stale-index exposure a free-list carries is BOUNDED here, and by more than
        /// precedent. A `moved_unbounded` entry naming a slot that was freed and reused
        /// before `computePairs` ran now names the NEW occupant — which was itself logged
        /// on insertion, so the effect is a duplicate entry, and `computePairs` sorts and
        /// adjacent-dedupes its output. A freed and NOT reused slot fails `live` and is
        /// skipped. Neither produces a wrong pair.
        const UnboundedSlot = struct {
            shape: UnboundedShape,
            /// The caller's opaque payload while live; the next free slot index while dead.
            user_data: u32,
            live: bool,
        };

        /// A candidate overlap between two proxies, by `user_data`, canonical
        /// (`a < b`).
        pub const Pair = struct {
            a: u32,
            b: u32,
        };

        trees: [layer_count]BvhT,
        /// Per-layer log of proxy ids touched since the last `computePairs`
        /// (inserted, or re-inserted by `update`). Consumed (cleared) by
        /// `computePairs`; may hold duplicates or stale ids — both are handled
        /// there (pair-set dedup; `isLiveLeaf` skip for a freed id).
        moved: [layer_count]std.ArrayListUnmanaged(u32),
        /// Per-layer flat list of UNBOUNDED shapes, outside the trees (§1.11.15). No hashed
        /// container, here as everywhere on this path (determinism by construction,
        /// M1.1.14).
        ///
        /// **Iteration follows the slot INDEX, which is not insertion order.** The contract
        /// §1.11.15 states is exactly three clauses: a slot's index never moves while a
        /// proxy holds it, a retired slot is recycled LIFO, and iteration follows the
        /// index. So `A, B, C`, retire `A`, insert `D` iterates `D, B, C` — `D` took `A`'s
        /// slot. That is the WANTED behaviour, not a tolerated side effect of the
        /// free-list.
        ///
        /// It suffices because what M1.1.14 requires is not insertion order but that the
        /// iteration order be a DETERMINISTIC FUNCTION OF THE OPERATION SEQUENCE — which
        /// LIFO recycling satisfies exactly, the free-list head being itself a function of
        /// that sequence. And no observable result depends on the order in the first place:
        /// the query entries sort their hits by the §1.11.14 key `(distance, entity,
        /// BodyId)`, and `computePairs` sorts by the canonical packed pair key and
        /// adjacent-dedupes. The list order reaches no answer.
        ///
        /// **The length is the PEAK of SIMULTANEOUSLY live slots in this layer, not the
        /// live count.** `items.len` never decreases: retirement recycles a slot, it does
        /// not remove it, so a layer that once held nine half-spaces at once keeps nine
        /// slots forever even when eight are dead. What the free-list removed is the
        /// growth with the TOTAL EVER CREATED, which was the pathology — an unbounded
        /// monotonic visit cost in the number of planes a session has ever built — and
        /// that is strictly better without being dense.
        ///
        /// The peak is acceptable because of what a half-space IS here: `addBody` rejects
        /// any non-static body carrying one (`error.ShapeMustBeStatic`, §1.11.15), so the
        /// population is authored level geometry rather than gameplay churn, and its peak
        /// is a quantity the scene author controls directly. MEASURED at 1 in every scene
        /// in this repo, including the two benches.
        ///
        /// A DENSE list was considered and deliberately NOT built. Making the list dense
        /// means compacting on removal, which moves a surviving slot's index — and that
        /// index is what a live `Proxy` holds, so every held proxy would have to be
        /// rewritten, or the list would need a second level of indirection to keep them
        /// valid. That is the cost, and it buys iteration in O(live) rather than O(peak).
        /// The trigger for paying it is a real scene that CHURNS half-spaces — creating and
        /// destroying them during play rather than at load — and no such scene exists yet.
        unbounded: [layer_count]std.ArrayListUnmanaged(UnboundedSlot),
        /// Per-layer LIFO free-list head over `unbounded`, or `null_slot` when empty. A
        /// dead slot's `user_data` is the link to the next (see `UnboundedSlot`).
        unbounded_free: [layer_count]u32,
        /// Per-layer log of unbounded slots inserted since the last `computePairs` —
        /// the second pairing direction's driver. Consumed (cleared) there.
        ///
        /// A separate log from `moved`, and not merely for tidiness: the two are
        /// crossed against DIFFERENT structures. A moved bounded proxy is crossed with
        /// the unbounded LISTS; a newly inserted unbounded shape is crossed with the
        /// TREES. Sharing one log would lose which of the two a given id needs.
        moved_unbounded: [layer_count]std.ArrayListUnmanaged(u32),

        /// A broadphase with the given tuning and no proxies.
        pub fn init(config: Config) Self {
            var self: Self = .{ .trees = undefined, .moved = undefined, .unbounded = undefined, .unbounded_free = undefined, .moved_unbounded = undefined };
            for (&self.trees) |*t| t.* = BvhT.init(config);
            for (&self.moved) |*m| m.* = .empty;
            for (&self.unbounded) |*u| u.* = .empty;
            for (&self.unbounded_free) |*f| f.* = null_slot;
            for (&self.moved_unbounded) |*m| m.* = .empty;
            return self;
        }

        /// Release every layer tree, moved-log and unbounded list.
        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            for (&self.trees) |*t| t.deinit(gpa);
            for (&self.moved) |*m| m.deinit(gpa);
            for (&self.unbounded) |*u| u.deinit(gpa);
            for (&self.moved_unbounded) |*m| m.deinit(gpa);
            self.* = undefined;
        }

        /// Insert a proxy into `layer` for `tight_aabb` carrying `user_data`,
        /// and mark it moved so the next `computePairs` considers it.
        ///
        /// Precondition: `user_data` must be unique across ALL proxies in every
        /// layer — `computePairs` treats it as the proxy's identity to exclude
        /// self-matches, so a collision would silently drop a legitimate pair
        /// (forge_3d passes the packed `BodyId`, which is unique by construction).
        ///
        /// Atomic: **on error (OOM), the broadphase is unchanged**. The
        /// moved-log slot is reserved before the tree is touched, so a leaf can
        /// never be inserted-but-unlogged (an orphan the caller has no `Proxy`
        /// to remove).
        pub fn insert(self: *Self, gpa: std.mem.Allocator, layer: BroadphaseLayer, tight_aabb: AabbT, user_data: u32) !Proxy {
            const li = @intFromEnum(layer);
            // Reserve the moved-log slot BEFORE mutating the tree (`Bvh.insert`
            // is itself atomic), so no allocation remains after the tree gains
            // the leaf → insert is all-or-nothing.
            try self.moved[li].ensureUnusedCapacity(gpa, 1);
            const id = try self.trees[li].insert(gpa, tight_aabb, user_data);
            self.moved[li].appendAssumeCapacity(id);
            return .{ .layer = layer, .kind = .tree, .id = id };
        }

        /// Insert an UNBOUNDED shape into `layer`'s flat list, outside the trees, and log
        /// it so the next `computePairs` crosses it with the existing leaves.
        ///
        /// Precondition: `user_data` unique across ALL proxies of every layer and every
        /// structure — the same requirement `insert` carries, and for the same reason
        /// (`computePairs` treats it as the identity that excludes a self-match).
        ///
        /// Atomic: on error (OOM) the broadphase is unchanged. Both slots are reserved
        /// before either list is appended to, so an entry can never exist unlogged — the
        /// same reserve-then-mutate ordering `insert` uses, and here it matters more: an
        /// unlogged unbounded shape would never be crossed with the existing leaves at
        /// all, and nothing would ever log it again (a half-space is static and never
        /// re-enters a moved log).
        pub fn insertUnbounded(self: *Self, gpa: std.mem.Allocator, layer: BroadphaseLayer, shape: UnboundedShape, user_data: u32) !Proxy {
            const li = @intFromEnum(layer);
            // Both fallible steps precede EVERY mutation, so an OOM leaves the broadphase
            // bit-unchanged and the call is retryable — and an entry can never exist
            // unlogged (see the doc comment).
            //
            // The two reserves are NOT symmetric, and the asymmetry is the point.
            // `moved_unbounded` always receives an entry, so its reserve is unconditional.
            // `unbounded` receives one only when the free-list is empty, and
            // `ensureUnusedCapacity(gpa, 1)` guarantees room for `len + 1` — so at
            // `len == capacity` it GROWS the list. Reserving it unconditionally would
            // therefore allocate for a slot the free-list is about to hand back, and would
            // fail an insertion that already has every byte it needs. Reading the head
            // before the reserve mutates nothing, so the ordering guarantee is intact.
            const head = self.unbounded_free[li];
            try self.moved_unbounded[li].ensureUnusedCapacity(gpa, 1);
            if (head == null_slot) try self.unbounded[li].ensureUnusedCapacity(gpa, 1);
            const id = blk: {
                // LIFO reuse first (the `Bvh.allocateNodeAssumeCapacity` shape): an
                // identical op sequence therefore reuses indices identically, which is what
                // keeps the whole path a pure function of that sequence (M1.1.14).
                if (head != null_slot) {
                    self.unbounded_free[li] = self.unbounded[li].items[head].user_data; // next free
                    self.unbounded[li].items[head] = .{ .shape = shape, .user_data = user_data, .live = true };
                    break :blk head;
                }
                const fresh: u32 = @intCast(self.unbounded[li].items.len);
                self.unbounded[li].appendAssumeCapacity(.{ .shape = shape, .user_data = user_data, .live = true });
                break :blk fresh;
            };
            self.moved_unbounded[li].appendAssumeCapacity(id);
            return .{ .layer = layer, .kind = .unbounded, .id = id };
        }

        /// Remove a proxy. A lingering moved-log entry for it is harmless — a freed tree
        /// slot fails `isLiveLeaf` and a retired unbounded slot fails its `live` flag, and
        /// `computePairs` skips both.
        ///
        /// Exhaustive on `ProxyKind`, no `else`: a third structure would be a compile
        /// error here rather than a removal that silently indexes the wrong pool.
        pub fn remove(self: *Self, proxy: Proxy) void {
            const li = @intFromEnum(proxy.layer);
            switch (proxy.kind) {
                .tree => self.trees[li].remove(proxy.id),
                // Retired IN PLACE and pushed onto the LIFO free-list: the slot's INDEX
                // must not move (a live `Proxy` holds one), but the slot itself is
                // recycled, so creating and destroying planes stops growing the list with
                // the TOTAL EVER CREATED. `items.len` does not decrease — the bound is the
                // peak of simultaneously live slots, and why that is acceptable, plus the
                // dense-list option and its trigger, are on the `unbounded` field.
                .unbounded => {
                    self.unbounded[li].items[proxy.id].live = false;
                    self.unbounded[li].items[proxy.id].user_data = self.unbounded_free[li];
                    self.unbounded_free[li] = proxy.id;
                },
            }
        }

        /// Move a proxy to `tight_aabb`. Marks it moved only when the tree
        /// actually re-inserted it (the fat AABB changed); an in-margin nudge is
        /// a no-op with no pair consequence (hysteresis).
        ///
        /// Atomic: **on error (OOM), the broadphase is unchanged**. The
        /// moved-log slot is reserved UP FRONT — before the hysteresis test and
        /// the (allocation-free) tree re-insert — so a re-inserted proxy can
        /// never go unlogged. Were it unlogged, a retry would find the box
        /// already re-fattened, pass the hysteresis test, and the move would be
        /// lost forever. The reserve is unconditional; `computePairs` retains
        /// the log's capacity, so in steady state it is a no-op.
        pub fn update(self: *Self, gpa: std.mem.Allocator, proxy: Proxy, tight_aabb: AabbT) !void {
            // An UNBOUNDED shape has no box to move to, and it cannot move at all: a
            // half-space forces a STATIC body (`addBody` rejects any other with
            // `error.ShapeMustBeStatic`, §1.11.15), so it never re-enters a moved log and
            // its pairs are established once, at insertion, and then carried by the
            // retention rule of §1.7 step 2. Asking it to move is a caller error rather
            // than a no-op to absorb.
            std.debug.assert(proxy.kind == .tree);
            const li = @intFromEnum(proxy.layer);
            try self.moved[li].ensureUnusedCapacity(gpa, 1);
            if (self.trees[li].update(proxy.id, tight_aabb)) {
                self.moved[li].appendAssumeCapacity(proxy.id);
            }
        }

        /// Overlap query across every layer: `collector.add(user_data)` for each
        /// proxy whose fat AABB overlaps `query`. Returns the total nodes
        /// visited. `collector` is a pointer with `fn add(self, u32) void`.
        pub fn queryAabb(self: *const Self, query: AabbT, collector: anytype) u32 {
            var visited: u32 = 0;
            for (&self.trees) |*t| visited += t.queryAabb(query, collector);
            self.visitUnbounded(query, collector);
            return visited;
        }

        /// Offer every live unbounded shape the `query` box MEETS to `collector`
        /// (M1.1.11, §1.11.1 point 3 as amended). Shared by the three query entries so
        /// they cannot drift in which structures they visit.
        ///
        /// The returned visited-node count is deliberately NOT incremented by these
        /// entries: that metric attests the TREES' logarithmic property, which the
        /// acceptance suite asserts on, and the unbounded lists are an explicitly LINEAR
        /// cost in a per-layer count that is one in a normal scene. Folding the two
        /// together would make a logarithmic claim unreadable.
        fn visitUnbounded(self: *const Self, query: AabbT, collector: anytype) void {
            for (&self.unbounded) |*list| {
                for (list.items) |slot| {
                    if (!slot.live) continue;
                    if (!query.overlapsHalfSpace(slot.shape.normal, slot.shape.distance)) continue;
                    collector.add(slot.user_data);
                }
            }
        }

        /// Ray type for this scalar.
        pub const RayT = Ray(T);

        /// Swept-volume query across every layer, summing the visited counts exactly
        /// as `queryAabb` does. See `Bvh.queryCast` for the `extent`/`c₀` contract
        /// and for why inflating each node is exact (`engine-physics-forge.md`
        /// §1.11.10).
        ///
        /// All four trees are visited: a query has no second body, so no row of the
        /// layer-pair matrix applies to it, and its filtering is a mask on the
        /// candidate's OBJECT layer, decided on the forge_3d side (§1.11.1). A
        /// broad-layer filter would be an additive optimisation, never a substitute
        /// for that mask.
        ///
        /// The collector's bound carries across the trees — the tightening a
        /// hit in the first tree performs prunes the next — so the sum is not a
        /// per-tree independent cost. And `shouldStop()` is honoured BETWEEN trees,
        /// which is the half a bound cannot express: without it an `any` query that
        /// found its candidate in the first tree would still walk the other three.
        pub fn queryCast(self: *const Self, ray: RayT, extent: Vec3T, collector: anytype) u32 {
            var visited: u32 = 0;
            for (&self.trees) |*t| {
                if (collector.shouldStop()) break;
                visited += t.queryCast(ray, extent, collector);
            }
            // The UNBOUNDED lists, after the trees (M1.1.11). Offered UNCONDITIONALLY —
            // there is no box to run the slab test against, which is the very reason a
            // half-space is not in a tree — so the collector's exact kernel decides, and
            // the bound cannot prune here. `shouldStop()` is still honoured, exactly as it
            // is between the four trees: an `any` query that already found its candidate
            // walks nothing further.
            for (&self.unbounded) |*list| {
                for (list.items) |slot| {
                    if (collector.shouldStop()) return visited;
                    if (!slot.live) continue;
                    collector.add(slot.user_data);
                }
            }
            return visited;
        }

        /// Ray query across every layer — `queryCast` at a zero extent, with the
        /// unchanged-behaviour argument written out on `Bvh.queryRay`.
        pub fn queryRay(self: *const Self, ray: RayT, collector: anytype) u32 {
            return self.queryCast(ray, Vec3T.zero, collector);
        }

        /// Fill `out` with the deterministic candidate pairs among moved proxies
        /// and the layers they may pair with (`default_layer_pairs`). Consumes
        /// (clears) the moved-logs. `out` is cleared first, then sorted by the
        /// packed key `(a << 32) | b` and adjacent-deduped, so it holds each
        /// unordered pair once, in canonical `(a < b)` form.
        pub fn computePairs(self: *Self, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(Pair)) !void {
            out.clearRetainingCapacity();

            var sink = PairSink{ .out = out, .gpa = gpa };

            // DIRECTION (1) — a moved BOUNDED proxy is crossed with the trees it may pair
            // with, and (M1.1.11) with their UNBOUNDED LISTS as well. Omitting the second
            // half makes a body created after a plane collide with nothing.
            for (0..layer_count) |li| {
                for (self.moved[li].items) |proxy| {
                    if (!self.trees[li].isLiveLeaf(proxy)) continue; // stale id
                    sink.moved_ud = self.trees[li].userData(proxy);
                    const p_aabb = self.trees[li].proxyAabb(proxy);
                    for (0..layer_count) |lj| {
                        if (!default_layer_pairs[li][lj]) continue;
                        _ = self.trees[lj].queryAabb(p_aabb, &sink);
                        for (self.unbounded[lj].items) |slot| {
                            if (!slot.live) continue;
                            if (!p_aabb.overlapsHalfSpace(slot.shape.normal, slot.shape.distance)) continue;
                            sink.add(slot.user_data);
                        }
                    }
                }
            }

            // DIRECTION (2) — a newly inserted UNBOUNDED shape enumerates the existing
            // leaves of the layers it may pair with. **The omission of this direction is
            // invisible in any scene that creates the plane first**, which is every
            // naively written test: pair generation is moved-driven, so the bodies' own
            // insertions would have covered it. Create the plane last and only this loop
            // can produce those pairs.
            //
            // An unbounded shape is NOT crossed with the other unbounded lists. Two
            // half-spaces have no narrowphase kernel — §1.11.15's table is a half-space
            // against a bounded convex — and the only reachable combination is forbidden
            // anyway: a half-space forces a static body, and `default_layer_pairs` has
            // static×static false. A dated unreachability, named rather than left to be
            // discovered.
            for (0..layer_count) |li| {
                for (self.moved_unbounded[li].items) |slot_id| {
                    const slot = self.unbounded[li].items[slot_id];
                    if (!slot.live) continue; // retired before the pairs were computed
                    sink.moved_ud = slot.user_data;
                    for (0..layer_count) |lj| {
                        if (!default_layer_pairs[li][lj]) continue;
                        _ = self.trees[lj].queryHalfSpace(slot.shape.normal, slot.shape.distance, &sink);
                    }
                }
            }
            if (sink.err) |e| return e;

            for (&self.moved) |*m| m.clearRetainingCapacity();
            for (&self.moved_unbounded) |*m| m.clearRetainingCapacity();

            std.mem.sort(Pair, out.items, {}, pairLess);
            dedupAdjacent(out);
        }

        /// Query sink: turns each found `user_data` into a canonical pair with
        /// the current moved proxy, skipping the self-match (a proxy's
        /// `user_data` is its unique id). OOM in the void-returning `add` is
        /// latched in `err` and surfaced by `computePairs`.
        const PairSink = struct {
            out: *std.ArrayListUnmanaged(Pair),
            gpa: std.mem.Allocator,
            moved_ud: u32 = 0,
            err: ?std.mem.Allocator.Error = null,

            fn add(self: *PairSink, found_ud: u32) void {
                if (found_ud == self.moved_ud) return; // self / same body
                self.out.append(self.gpa, .{
                    .a = @min(self.moved_ud, found_ud),
                    .b = @max(self.moved_ud, found_ud),
                }) catch |e| {
                    self.err = e;
                };
            }
        };

        fn packKey(p: Pair) u64 {
            return (@as(u64, p.a) << 32) | @as(u64, p.b);
        }

        fn pairLess(_: void, x: Pair, y: Pair) bool {
            return packKey(x) < packKey(y);
        }

        fn dedupAdjacent(out: *std.ArrayListUnmanaged(Pair)) void {
            if (out.items.len == 0) return;
            var w: usize = 1;
            var i: usize = 1;
            while (i < out.items.len) : (i += 1) {
                const prev = out.items[w - 1];
                const cur = out.items[i];
                if (cur.a != prev.a or cur.b != prev.b) {
                    out.items[w] = cur;
                    w += 1;
                }
            }
            out.shrinkRetainingCapacity(w);
        }
    };
}
