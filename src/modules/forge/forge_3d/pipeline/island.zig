//! `forge_3d/pipeline/island.zig` — the branch-neutral island partition core.
//!
//! Island partitioning cuts the simulated scene into groups of bodies coupled by
//! constraints (`engine-physics-forge.md` §1.8.1). The core of that partitioning
//! lives in the SHARED pipeline, not in a resolution branch: it is a union-find
//! over OPAQUE element indices and knows nothing of bodies, constraints, or the
//! solver scalar — the same discipline `broadphase.zig` and the narrowphase follow
//! with their opaque `user_data`. This file imports `std` and nothing else.
//!
//! The rigid branch's adapter (`rigid/island_manager.zig`) is what maps its awake
//! dynamic bodies onto `0..count` here, links the pairs its contact constraints
//! couple, and turns the resulting groups into contiguous constraint ranges. Two
//! properties this core owes it:
//!
//!   - **Seeded per element.** `seed(n)` makes every index its own group, so an
//!     element that is never linked stays a SINGLETON group — that is what makes a
//!     constraint-less body a first-class island (§1.8.1) rather than an absence.
//!   - **Purity.** The partition is a function of the SET of links alone, never of
//!     the order they arrive in — union by size with a fixed tie-break, path
//!     compression, no hash container, no address-dependent enumeration
//!     (determinism by construction, M1.1.14).
//!
//! Path compression means `find` mutates: it re-points the nodes it walks straight
//! at their root. That changes the tree SHAPE, never the partition, and the shape
//! itself stays a pure function of the operation sequence.

const std = @import("std");

/// Union-find over opaque element indices — the island partition core.
///
/// Unmanaged (`engine-zig-conventions.md` §3): the allocator is passed to `seed`,
/// the only operation that allocates. Typical use is one instance reused across
/// ticks, re-`seed`ed each tick to the current element count.
pub const UnionFind = struct {
    /// Parent index per element; a root is its own parent.
    parent: std.ArrayListUnmanaged(u32) = .empty,
    /// Element count of the group rooted at this index. Meaningful at a root only.
    size: std.ArrayListUnmanaged(u32) = .empty,

    /// Release both index arrays.
    pub fn deinit(self: *UnionFind, gpa: std.mem.Allocator) void {
        self.parent.deinit(gpa);
        self.size.deinit(gpa);
        self.* = undefined;
    }

    /// Reset to exactly `n` singleton elements `0..n`, dropping every previous
    /// link and retaining the backing capacity. This is the per-tick entry: the
    /// partition is rebuilt from scratch every tick, because island identity is
    /// deliberately NOT persistent (§1.8.3).
    pub fn seed(self: *UnionFind, gpa: std.mem.Allocator, n: u32) !void {
        self.parent.clearRetainingCapacity();
        self.size.clearRetainingCapacity();
        try self.parent.ensureTotalCapacity(gpa, n);
        try self.size.ensureTotalCapacity(gpa, n);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            self.parent.appendAssumeCapacity(i);
            self.size.appendAssumeCapacity(1);
        }
    }

    /// Number of seeded elements.
    pub fn count(self: *const UnionFind) u32 {
        return @intCast(self.parent.items.len);
    }

    /// The representative index of `x`'s group. Two elements are in the same group
    /// iff their representatives are equal. Mutates: the walk is path-compressed,
    /// which changes the tree shape but never the partition.
    pub fn find(self: *UnionFind, x: u32) u32 {
        std.debug.assert(x < self.parent.items.len);
        var root = x;
        while (self.parent.items[root] != root) root = self.parent.items[root];
        var node = x;
        while (self.parent.items[node] != root) {
            const next = self.parent.items[node];
            self.parent.items[node] = root;
            node = next;
        }
        return root;
    }

    /// Merge the groups of `a` and `b`. Idempotent (re-linking an already-merged
    /// pair is a no-op) and symmetric (`link(a, b)` and `link(b, a)` produce the
    /// same partition AND the same tree shape).
    ///
    /// Union by size, so the shallower tree hangs under the deeper one; on equal
    /// sizes the smaller root index wins, a fixed tie-break that keeps the shape a
    /// pure function of the link sequence rather than of a comparison accident.
    pub fn link(self: *UnionFind, a: u32, b: u32) void {
        std.debug.assert(a < self.parent.items.len);
        std.debug.assert(b < self.parent.items.len);
        // Merge ROOT to ROOT. Attaching `b` itself to `a` would strand whichever
        // group `b` already belonged to — and strand a different one depending on
        // the order the links arrive in, which is exactly the purity the partition
        // owes its consumers (it can also close a parent cycle and hang `find`).
        var keep = self.find(a);
        var absorb = self.find(b);
        if (keep == absorb) return;

        const size_keep = self.size.items[keep];
        const size_absorb = self.size.items[absorb];
        // Union by size; on a tie the smaller root index is kept, so the resulting
        // tree shape is a function of the link sequence and not of a comparison
        // accident.
        if (size_keep < size_absorb or (size_keep == size_absorb and absorb < keep)) {
            const swap = keep;
            keep = absorb;
            absorb = swap;
        }
        self.parent.items[absorb] = keep;
        self.size.items[keep] = size_keep + size_absorb;
    }
};
