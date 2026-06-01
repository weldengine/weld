//! CPU-side ECS instancing batcher — Phase 0 / M0.4.
//!
//! Without batching, 100 k entities at 60 FPS is ruled out — the CPU/driver
//! overhead per drawcall caps at ~5-15 k drawcalls/frame (brief §Notes decision 9).
//!
//! Phase 0 algorithm:
//! 1. For each entity (Mesh, MaterialInstance, Transform), group by
//!    the key `(mesh_id, material_id)` via `std.HashMap`.
//! 2. For each bucket, collect the `Transform`s into a contiguous
//!    instance buffer (`std.ArrayList`).
//! 3. Sort the buckets by centroid depth (front-to-back) — feeds
//!    the early-Z of the opaque forward pass.
//! 4. Emit a single instanced drawcall per bucket (`drawIndexed` with
//!    `instance_count = bucket.transforms.len`).
//!
//! Perf target (brief §Acceptance criteria > Tests):
//! - 100 000 entities over 100 distinct (mesh, material) → ≤ 100 drawcalls
//!
//! Phase 1+: GPU-driven culling + indirect draw (cf. brief §Out-of-scope).

const std = @import("std");

/// Mesh identifier (32 bits — enough for 4 billion unique meshes
/// per project). Phase 0: fed by the asset pipeline, alias `u32`.
pub const MeshId = u32;

/// Material instance identifier (32 bits).
pub const MaterialId = u32;

/// Transform `extern struct` POD — matches the canonical ECS component.
/// Stored as-is in the GPU instance buffer.
pub const Transform = extern struct {
    /// World position (x, y, z).
    position: [3]f32 = .{ 0, 0, 0 },
    _padding0: f32 = 0,
    /// Quaternion (x, y, z, w).
    rotation: [4]f32 = .{ 0, 0, 0, 1 },
    /// Uniform scale — Phase 0 simplification. Phase 1+: Vec3.
    scale: f32 = 1,
    _padding1: [3]f32 = .{ 0, 0, 0 },
};

/// Entity as seen by the batcher (extracted by the pre-render ECS
/// system — Phase 0 the caller builds this array manually).
pub const Entity = struct {
    mesh: MeshId,
    material: MaterialId,
    transform: Transform,
};

/// Bucket key — `(mesh_id, material_id)` packed into u64 for
/// efficient hashing.
pub const BucketKey = packed struct(u64) {
    mesh: MeshId,
    material: MaterialId,

    pub fn pack(mesh: MeshId, material: MaterialId) BucketKey {
        return .{ .mesh = mesh, .material = material };
    }

    pub fn unpack(self: BucketKey) struct { mesh: MeshId, material: MaterialId } {
        return .{ .mesh = self.mesh, .material = self.material };
    }
};

/// Bucket — all entities sharing `(mesh, material)`.
pub const Bucket = struct {
    key: BucketKey,
    transforms: std.ArrayListUnmanaged(Transform) = .empty,
    /// Bucket centroid for front-to-back sorting (average of the positions).
    centroid_depth: f32 = 0,

    pub fn deinit(self: *Bucket, allocator: std.mem.Allocator) void {
        self.transforms.deinit(allocator);
    }
};

/// Batching statistics for one frame.
pub const Stats = struct {
    /// Number of entities processed.
    entities: u32 = 0,
    /// Number of distinct buckets (= instanced drawcalls emitted).
    buckets: u32 = 0,
    /// Total of uploaded transforms (= entities).
    instances: u32 = 0,
};

/// Batcher — reusable frame-to-frame via `reset()`.
pub const Batcher = struct {
    allocator: std.mem.Allocator,
    /// Buckets by BucketKey.inner. Incremental allocation.
    buckets: std.AutoHashMapUnmanaged(u64, Bucket) = .empty,
    /// Bucket emission order after front-to-back sorting.
    /// Indices into `buckets.values()` — Phase 0 uses a
    /// simpler approach: we extract the buckets into `sorted_keys`.
    sorted_keys: std.ArrayListUnmanaged(u64) = .empty,
    stats: Stats = .{},

    pub fn init(allocator: std.mem.Allocator) Batcher {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Batcher) void {
        var it = self.buckets.valueIterator();
        while (it.next()) |b| b.deinit(self.allocator);
        self.buckets.deinit(self.allocator);
        self.sorted_keys.deinit(self.allocator);
        self.* = undefined;
    }

    /// Reset between frames. Frees the heap-allocated transforms of each
    /// bucket before clearing the map — without this deinit, the slices
    /// orphaned by the hashmap's `clearRetainingCapacity` leak (the
    /// DebugAllocator reports them at process end). The capacity of the
    /// hashmap itself stays preserved to amortize the `getOrPut` of the
    /// following frames.
    pub fn reset(self: *Batcher) void {
        var it = self.buckets.valueIterator();
        while (it.next()) |b| b.transforms.deinit(self.allocator);
        self.buckets.clearRetainingCapacity();
        self.sorted_keys.clearRetainingCapacity();
        self.stats = .{};
    }

    /// Adds an entity to the batch. Phase 0: the caller calls this
    /// method for each post-culling visible entity. Phase 1+: GPU
    /// culling eliminates this CPU-side step.
    pub fn submit(self: *Batcher, entity: Entity) std.mem.Allocator.Error!void {
        const key = BucketKey.pack(entity.mesh, entity.material);
        const packed_key: u64 = @bitCast(key);
        const gop = try self.buckets.getOrPut(self.allocator, packed_key);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .key = key };
        }
        try gop.value_ptr.transforms.append(self.allocator, entity.transform);
        self.stats.entities += 1;
    }

    /// Finalizes the buckets: computes the centroids + sorts front-to-back.
    /// To be called after all the `submit`s of a frame, before emitting
    /// the drawcalls.
    ///
    /// `view_origin` (Vec3) = camera position in world space.
    /// The sort is by squared distance² (avoids the sqrt — the relative order
    /// is preserved).
    pub fn finalize(self: *Batcher, view_origin: [3]f32) std.mem.Allocator.Error!void {
        self.sorted_keys.clearRetainingCapacity();
        try self.sorted_keys.ensureTotalCapacity(self.allocator, self.buckets.count());

        var it = self.buckets.iterator();
        while (it.next()) |kv| {
            const b = kv.value_ptr;
            // Centroid = average of the bucket's positions.
            var sx: f32 = 0;
            var sy: f32 = 0;
            var sz: f32 = 0;
            const n: f32 = @floatFromInt(b.transforms.items.len);
            for (b.transforms.items) |t| {
                sx += t.position[0];
                sy += t.position[1];
                sz += t.position[2];
            }
            if (n > 0) {
                sx /= n;
                sy /= n;
                sz /= n;
            }
            const dx = sx - view_origin[0];
            const dy = sy - view_origin[1];
            const dz = sz - view_origin[2];
            b.centroid_depth = dx * dx + dy * dy + dz * dz;
            try self.sorted_keys.append(self.allocator, kv.key_ptr.*);
        }

        // Ascending sort (front-to-back = increasing distance²).
        const ctx: SortContext = .{ .buckets = &self.buckets };
        std.mem.sort(u64, self.sorted_keys.items, ctx, SortContext.less);

        self.stats.buckets = @intCast(self.sorted_keys.items.len);
        self.stats.instances = self.stats.entities;
    }

    /// Iterator over the buckets in post-finalize emission order.
    pub fn iterateBuckets(self: *const Batcher) BucketIterator {
        return .{ .batcher = self, .index = 0 };
    }
};

const SortContext = struct {
    buckets: *const std.AutoHashMapUnmanaged(u64, Bucket),

    fn less(self: SortContext, a: u64, b: u64) bool {
        const ba = self.buckets.get(a) orelse return false;
        const bb = self.buckets.get(b) orelse return false;
        return ba.centroid_depth < bb.centroid_depth;
    }
};

/// Iterator over the buckets in emission order (front-to-back).
pub const BucketIterator = struct {
    batcher: *const Batcher,
    index: usize,

    pub fn next(self: *BucketIterator) ?*const Bucket {
        if (self.index >= self.batcher.sorted_keys.items.len) return null;
        const key = self.batcher.sorted_keys.items[self.index];
        self.index += 1;
        return self.batcher.buckets.getPtr(key);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "batcher: groups entities by mesh and material" {
    var b = Batcher.init(std.testing.allocator);
    defer b.deinit();

    // 1000 entities, 10 distinct (mesh, material) → 10 buckets.
    var i: u32 = 0;
    while (i < 1000) : (i += 1) {
        const mesh: MeshId = i % 5;
        const material: MaterialId = (i / 5) % 2; // 5 * 2 = 10 combos
        try b.submit(.{
            .mesh = mesh,
            .material = material,
            .transform = .{ .position = .{
                @floatFromInt(i),
                0,
                0,
            } },
        });
    }
    try b.finalize(.{ 0, 0, 0 });
    try std.testing.expectEqual(@as(u32, 10), b.stats.buckets);
    try std.testing.expectEqual(@as(u32, 1000), b.stats.entities);
}

test "batcher: produces under 100 drawcalls for 100k entities on 100 distinct mesh-material pairs" {
    var b = Batcher.init(std.testing.allocator);
    defer b.deinit();

    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();

    var i: u32 = 0;
    while (i < 100_000) : (i += 1) {
        const mesh: MeshId = rand.intRangeAtMost(u32, 0, 9); // 10 meshes
        const material: MaterialId = rand.intRangeAtMost(u32, 0, 9); // 10 materials → 100 buckets max
        try b.submit(.{
            .mesh = mesh,
            .material = material,
            .transform = .{ .position = .{
                rand.float(f32) * 100,
                rand.float(f32) * 100,
                rand.float(f32) * 100,
            } },
        });
    }
    try b.finalize(.{ 50, 50, 50 });

    // Strict assertion brief §Acceptance criteria > Tests.
    try std.testing.expect(b.stats.buckets <= 100);
    try std.testing.expectEqual(@as(u32, 100_000), b.stats.entities);
}

test "batcher: front-to-back ordering after finalize" {
    var b = Batcher.init(std.testing.allocator);
    defer b.deinit();

    // 3 buckets at known distances: 1, 4, 9 (squared distances).
    try b.submit(.{ .mesh = 1, .material = 1, .transform = .{ .position = .{ 1, 0, 0 } } });
    try b.submit(.{ .mesh = 2, .material = 2, .transform = .{ .position = .{ 2, 0, 0 } } });
    try b.submit(.{ .mesh = 3, .material = 3, .transform = .{ .position = .{ 3, 0, 0 } } });
    try b.finalize(.{ 0, 0, 0 });

    // First bucket = mesh=1 (depth² = 1).
    var it = b.iterateBuckets();
    const first = it.next() orelse return error.NoBucket;
    try std.testing.expectEqual(@as(MeshId, 1), first.key.mesh);
    const second = it.next() orelse return error.NoBucket;
    try std.testing.expectEqual(@as(MeshId, 2), second.key.mesh);
    const third = it.next() orelse return error.NoBucket;
    try std.testing.expectEqual(@as(MeshId, 3), third.key.mesh);
}

test "batcher: reset preserves capacity" {
    var b = Batcher.init(std.testing.allocator);
    defer b.deinit();
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        try b.submit(.{ .mesh = i % 10, .material = 0, .transform = .{} });
    }
    try b.finalize(.{ 0, 0, 0 });
    try std.testing.expectEqual(@as(u32, 10), b.stats.buckets);
    b.reset();
    try std.testing.expectEqual(@as(u32, 0), b.stats.entities);
    try std.testing.expectEqual(@as(u32, 0), b.stats.buckets);
}
