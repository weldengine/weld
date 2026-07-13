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

const std = @import("std");
const math = @import("foundation").math;

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

        /// Tuning config type for this scalar.
        pub const Config = BroadphaseConfig(T);

        /// A proxy handle: the owning layer plus its tree-local proxy id.
        pub const Proxy = struct {
            layer: BroadphaseLayer,
            id: u32,
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

        /// A broadphase with the given tuning and no proxies.
        pub fn init(config: Config) Self {
            var self: Self = .{ .trees = undefined, .moved = undefined };
            for (&self.trees) |*t| t.* = BvhT.init(config);
            for (&self.moved) |*m| m.* = .empty;
            return self;
        }

        /// Release every layer tree and moved-log.
        pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
            for (&self.trees) |*t| t.deinit(gpa);
            for (&self.moved) |*m| m.deinit(gpa);
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
            return .{ .layer = layer, .id = id };
        }

        /// Remove a proxy. A lingering moved-log entry for it is harmless — the
        /// freed slot fails `isLiveLeaf` and is skipped by `computePairs`.
        pub fn remove(self: *Self, proxy: Proxy) void {
            self.trees[@intFromEnum(proxy.layer)].remove(proxy.id);
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
            return visited;
        }

        /// Fill `out` with the deterministic candidate pairs among moved proxies
        /// and the layers they may pair with (`default_layer_pairs`). Consumes
        /// (clears) the moved-logs. `out` is cleared first, then sorted by the
        /// packed key `(a << 32) | b` and adjacent-deduped, so it holds each
        /// unordered pair once, in canonical `(a < b)` form.
        pub fn computePairs(self: *Self, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(Pair)) !void {
            out.clearRetainingCapacity();

            var sink = PairSink{ .out = out, .gpa = gpa };
            for (0..layer_count) |li| {
                for (self.moved[li].items) |proxy| {
                    if (!self.trees[li].isLiveLeaf(proxy)) continue; // stale id
                    sink.moved_ud = self.trees[li].userData(proxy);
                    const p_aabb = self.trees[li].proxyAabb(proxy);
                    for (0..layer_count) |lj| {
                        if (!default_layer_pairs[li][lj]) continue;
                        _ = self.trees[lj].queryAabb(p_aabb, &sink);
                    }
                }
            }
            if (sink.err) |e| return e;

            for (&self.moved) |*m| m.clearRetainingCapacity();

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
