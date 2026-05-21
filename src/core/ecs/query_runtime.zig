//! Runtime query for the S4 ECS — accepts `includes` and `excludes` slices
//! of `ComponentId`, plus an optional per-slot filter callback used by the
//! `has T { field == value }` form.
//!
//! Walks every registered `DynamicArchetype` and yields the matching
//! chunks. Per-slot iteration is the caller's responsibility (the
//! interpreter visits each slot to evaluate the rule body); the query
//! itself only narrows the search space at archetype + chunk granularity.

const std = @import("std");
const registry_mod = @import("registry.zig");
const arch_mod = @import("archetype_dynamic.zig");
const entity_mod = @import("entity.zig");

const ComponentId = registry_mod.ComponentId;
const DynamicArchetype = arch_mod.DynamicArchetype;
const Chunk = arch_mod.Chunk;
const EntityId = entity_mod.EntityId;

/// Filter callback for the `has T { field == value }` form. Returns
/// `true` to keep a slot. Compare against `RuntimeQuery.filter` —
/// `filter.fn_ptr == null` means "no filter, keep every slot".
pub const FilterFn = *const fn (ctx: *const anyopaque, archetype: *const DynamicArchetype, chunk: *Chunk, slot: u32) bool;

/// Optional filter predicate evaluated per slot — `fn_ptr == null`
/// means "keep every slot".
pub const Filter = struct {
    fn_ptr: ?FilterFn = null,
    ctx: *const anyopaque = undefined,
};

/// Dynamic-side query: include / exclude component id lists, optional
/// per-slot filter, and the archetype bag to scan.
pub const RuntimeQuery = struct {
    includes: []const ComponentId,
    excludes: []const ComponentId,
    filter: Filter = .{},
    /// Bag of every dynamic archetype the world owns. Borrowed.
    archetypes: []const *DynamicArchetype,

    pub fn matchesArchetype(self: *const RuntimeQuery, archetype: *const DynamicArchetype) bool {
        for (self.includes) |id| {
            if (!archetype.hasComponent(id)) return false;
        }
        for (self.excludes) |id| {
            if (archetype.hasComponent(id)) return false;
        }
        return true;
    }

    /// Filter the archetypes into a borrowed buffer. Returns the slice
    /// of pointers to matching archetypes (subset of `self.archetypes`).
    pub fn matchingArchetypes(self: *const RuntimeQuery, buf: []*DynamicArchetype) []*DynamicArchetype {
        var n: usize = 0;
        for (self.archetypes) |a| {
            if (self.matchesArchetype(a)) {
                buf[n] = a;
                n += 1;
            }
        }
        return buf[0..n];
    }

    /// Chunk iterator. Walks every matching archetype's chunks in order.
    /// Per-slot filtering is the caller's job (apply `self.filter` to each
    /// slot encountered).
    pub const ChunkIter = struct {
        query: *const RuntimeQuery,
        arch_idx: usize = 0,
        chunk_idx: usize = 0,

        pub fn next(self: *ChunkIter) ?ChunkMatch {
            while (self.arch_idx < self.query.archetypes.len) {
                const a = self.query.archetypes[self.arch_idx];
                if (!self.query.matchesArchetype(a)) {
                    self.arch_idx += 1;
                    self.chunk_idx = 0;
                    continue;
                }
                if (self.chunk_idx < a.chunks.items.len) {
                    const c = a.chunks.items[self.chunk_idx];
                    self.chunk_idx += 1;
                    return .{ .archetype = a, .chunk = c };
                }
                self.arch_idx += 1;
                self.chunk_idx = 0;
            }
            return null;
        }
    };

    pub const ChunkMatch = struct {
        archetype: *DynamicArchetype,
        chunk: *Chunk,
    };

    pub fn chunkIter(self: *const RuntimeQuery) ChunkIter {
        return .{ .query = self };
    }

    /// Apply the optional filter to a slot. When no filter is set, every
    /// slot passes.
    pub fn slotPasses(self: *const RuntimeQuery, archetype: *const DynamicArchetype, chunk: *Chunk, slot: u32) bool {
        if (self.filter.fn_ptr) |f| return f(self.filter.ctx, archetype, chunk, slot);
        return true;
    }
};

// ─── tests ────────────────────────────────────────────────────────────────

const Registry = registry_mod.Registry;

test "Query.new on includes only matches" {
    const gpa = std.testing.allocator;
    var reg = Registry.init();
    defer reg.deinit(gpa);

    const A = struct { v: i64 = 0 };
    const B = struct { v: f64 = 0 };
    const id_a = try reg.registerComponent(gpa, A);
    const id_b = try reg.registerComponent(gpa, B);

    var arch_ab = try DynamicArchetype.init(gpa, &reg, 0, &[_]ComponentId{ id_a, id_b });
    defer arch_ab.deinit(gpa);
    var arch_a = try DynamicArchetype.init(gpa, &reg, 1, &[_]ComponentId{id_a});
    defer arch_a.deinit(gpa);

    _ = try arch_ab.spawnDefault(gpa, EntityId{ .index = 0, .generation = 0 }, 0);
    _ = try arch_a.spawnDefault(gpa, EntityId{ .index = 1, .generation = 0 }, 0);

    const archs = [_]*DynamicArchetype{ &arch_ab, &arch_a };
    const q: RuntimeQuery = .{
        .includes = &[_]ComponentId{ id_a, id_b },
        .excludes = &[_]ComponentId{},
        .archetypes = &archs,
    };

    var it = q.chunkIter();
    var count: usize = 0;
    while (it.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "Query.new on includes + excludes matches" {
    const gpa = std.testing.allocator;
    var reg = Registry.init();
    defer reg.deinit(gpa);

    const A = struct { v: i64 = 0 };
    const B = struct { v: f64 = 0 };
    const id_a = try reg.registerComponent(gpa, A);
    const id_b = try reg.registerComponent(gpa, B);

    var arch_ab = try DynamicArchetype.init(gpa, &reg, 0, &[_]ComponentId{ id_a, id_b });
    defer arch_ab.deinit(gpa);
    var arch_a = try DynamicArchetype.init(gpa, &reg, 1, &[_]ComponentId{id_a});
    defer arch_a.deinit(gpa);

    _ = try arch_ab.spawnDefault(gpa, EntityId{ .index = 0, .generation = 0 }, 0);
    _ = try arch_a.spawnDefault(gpa, EntityId{ .index = 1, .generation = 0 }, 0);

    const archs = [_]*DynamicArchetype{ &arch_ab, &arch_a };
    const q: RuntimeQuery = .{
        .includes = &[_]ComponentId{id_a},
        .excludes = &[_]ComponentId{id_b},
        .archetypes = &archs,
    };

    var it = q.chunkIter();
    var count: usize = 0;
    while (it.next()) |m| {
        try std.testing.expectEqual(&arch_a, m.archetype);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "Query iteration yields chunks in archetype order" {
    const gpa = std.testing.allocator;
    var reg = Registry.init();
    defer reg.deinit(gpa);

    const A = struct { v: i64 = 0 };
    const id_a = try reg.registerComponent(gpa, A);
    var arch1 = try DynamicArchetype.init(gpa, &reg, 0, &[_]ComponentId{id_a});
    defer arch1.deinit(gpa);
    var arch2 = try DynamicArchetype.init(gpa, &reg, 1, &[_]ComponentId{id_a});
    defer arch2.deinit(gpa);

    _ = try arch1.spawnDefault(gpa, EntityId{ .index = 0, .generation = 0 }, 0);
    _ = try arch2.spawnDefault(gpa, EntityId{ .index = 1, .generation = 0 }, 0);

    const archs = [_]*DynamicArchetype{ &arch1, &arch2 };
    const q: RuntimeQuery = .{
        .includes = &[_]ComponentId{id_a},
        .excludes = &[_]ComponentId{},
        .archetypes = &archs,
    };

    var it = q.chunkIter();
    const m1 = it.next().?;
    try std.testing.expectEqual(&arch1, m1.archetype);
    const m2 = it.next().?;
    try std.testing.expectEqual(&arch2, m2.archetype);
    try std.testing.expect(it.next() == null);
}

test "Query over zero matching archetypes yields empty iterator" {
    const gpa = std.testing.allocator;
    var reg = Registry.init();
    defer reg.deinit(gpa);

    const A = struct { v: i64 = 0 };
    const B = struct { v: f64 = 0 };
    const id_a = try reg.registerComponent(gpa, A);
    const id_b = try reg.registerComponent(gpa, B);

    var arch_a = try DynamicArchetype.init(gpa, &reg, 0, &[_]ComponentId{id_a});
    defer arch_a.deinit(gpa);

    const archs = [_]*DynamicArchetype{&arch_a};
    const q: RuntimeQuery = .{
        .includes = &[_]ComponentId{id_b}, // arch_a lacks B
        .excludes = &[_]ComponentId{},
        .archetypes = &archs,
    };

    var it = q.chunkIter();
    try std.testing.expect(it.next() == null);
}
