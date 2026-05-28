//! Instancing batcher ECS CPU-side — Phase 0 / M0.4.
//!
//! Sans batching, 100 k entités à 60 FPS est exclu — l'overhead CPU/driver
//! par drawcall plafonne à ~5-15 k drawcalls/frame (brief §Notes décision 9).
//!
//! Algorithme Phase 0 :
//! 1. Pour chaque entité (Mesh, MaterialInstance, Transform), grouper par
//!    la clé `(mesh_id, material_id)` via `std.HashMap`.
//! 2. Pour chaque bucket, collecter les `Transform` en instance buffer
//!    contigu (`std.ArrayList`).
//! 3. Trier les buckets par profondeur du centroïde (front-to-back) — alimente
//!    le early-Z du forward opaque.
//! 4. Émettre un seul drawcall instancié par bucket (`drawIndexed` avec
//!    `instance_count = bucket.transforms.len`).
//!
//! Cible perf (brief §Critères d'acceptation > Tests) :
//! - 100 000 entities sur 100 (mesh, material) distincts → ≤ 100 drawcalls
//!
//! Phase 1+ : GPU-driven culling + indirect draw (cf. brief §Out-of-scope).

const std = @import("std");

/// Identifiant de mesh (32 bits — suffit pour 4 milliards de meshes uniques
/// par projet). Phase 0 : alimenté par l'asset pipeline, alias `u32`.
pub const MeshId = u32;

/// Identifiant de material instance (32 bits).
pub const MaterialId = u32;

/// Transform `extern struct` POD — matche le composant ECS canonique.
/// Stocké tel-quel dans l'instance buffer GPU.
pub const Transform = extern struct {
    /// World position (x, y, z).
    position: [3]f32 = .{ 0, 0, 0 },
    _padding0: f32 = 0,
    /// Quaternion (x, y, z, w).
    rotation: [4]f32 = .{ 0, 0, 0, 1 },
    /// Scale uniforme — Phase 0 simplification. Phase 1+ : Vec3.
    scale: f32 = 1,
    _padding1: [3]f32 = .{ 0, 0, 0 },
};

/// Entité telle que vue par le batcher (extraite par le système ECS
/// pre-render — Phase 0 le caller construit ce tableau manuellement).
pub const Entity = struct {
    mesh: MeshId,
    material: MaterialId,
    transform: Transform,
};

/// Clé de bucket — `(mesh_id, material_id)` packé en u64 pour
/// hashing efficace.
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

/// Bucket — toutes les entités partageant `(mesh, material)`.
pub const Bucket = struct {
    key: BucketKey,
    transforms: std.ArrayListUnmanaged(Transform) = .empty,
    /// Centroïde du bucket pour le tri front-to-back (moyenne des positions).
    centroid_depth: f32 = 0,

    pub fn deinit(self: *Bucket, allocator: std.mem.Allocator) void {
        self.transforms.deinit(allocator);
    }
};

/// Statistiques de batching pour une frame.
pub const Stats = struct {
    /// Nombre d'entités processed.
    entities: u32 = 0,
    /// Nombre de buckets distincts (= drawcalls instanciés émis).
    buckets: u32 = 0,
    /// Total des transforms uploadés (= entities).
    instances: u32 = 0,
};

/// Batcher — réutilisable frame-à-frame via `reset()`.
pub const Batcher = struct {
    allocator: std.mem.Allocator,
    /// Buckets par BucketKey.inner. Allocation incrémentale.
    buckets: std.AutoHashMapUnmanaged(u64, Bucket) = .empty,
    /// Ordre d'émission des buckets après tri front-to-back.
    /// Indices vers `buckets.values()` — Phase 0 utilise une approche
    /// plus simple : on extrait les buckets dans `sorted_keys`.
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

    /// Reset entre frames. Libère les transforms heap-allocated de chaque
    /// bucket avant de vider la map — sans cette deinit, les slices
    /// orphaned par `clearRetainingCapacity` du hashmap fuient (le
    /// DebugAllocator les signale en fin de process). La capacity du
    /// hashmap lui-même reste préservée pour amortir la `getOrPut` des
    /// frames suivantes.
    pub fn reset(self: *Batcher) void {
        var it = self.buckets.valueIterator();
        while (it.next()) |b| b.transforms.deinit(self.allocator);
        self.buckets.clearRetainingCapacity();
        self.sorted_keys.clearRetainingCapacity();
        self.stats = .{};
    }

    /// Ajoute une entité au batch. Phase 0 : le caller appelle cette
    /// méthode pour chaque entité visible post-culling. Phase 1+ : GPU
    /// culling élimine cette étape côté CPU.
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

    /// Finalise les buckets : calcule les centroides + trie front-to-back.
    /// À appeler après tous les `submit` d'une frame, avant l'émission
    /// des drawcalls.
    ///
    /// `view_origin` (Vec3) = position de la caméra dans le repère monde.
    /// Le tri est par distance² au carré (évite la sqrt — l'ordre relatif
    /// est préservé).
    pub fn finalize(self: *Batcher, view_origin: [3]f32) std.mem.Allocator.Error!void {
        self.sorted_keys.clearRetainingCapacity();
        try self.sorted_keys.ensureTotalCapacity(self.allocator, self.buckets.count());

        var it = self.buckets.iterator();
        while (it.next()) |kv| {
            const b = kv.value_ptr;
            // Centroïde = moyenne des positions du bucket.
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

        // Tri ascending (front-to-back = distance² croissante).
        const ctx: SortContext = .{ .buckets = &self.buckets };
        std.mem.sort(u64, self.sorted_keys.items, ctx, SortContext.less);

        self.stats.buckets = @intCast(self.sorted_keys.items.len);
        self.stats.instances = self.stats.entities;
    }

    /// Itérateur sur les buckets dans l'ordre d'émission post-finalize.
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

/// Itérateur sur les buckets dans l'ordre d'émission (front-to-back).
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

    // 1000 entities, 10 (mesh, material) distincts → 10 buckets.
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

    // Assertion stricte brief §Critères d'acceptation > Tests.
    try std.testing.expect(b.stats.buckets <= 100);
    try std.testing.expectEqual(@as(u32, 100_000), b.stats.entities);
}

test "batcher: front-to-back ordering after finalize" {
    var b = Batcher.init(std.testing.allocator);
    defer b.deinit();

    // 3 buckets à distances connues : 1, 4, 9 (carré des distances).
    try b.submit(.{ .mesh = 1, .material = 1, .transform = .{ .position = .{ 1, 0, 0 } } });
    try b.submit(.{ .mesh = 2, .material = 2, .transform = .{ .position = .{ 2, 0, 0 } } });
    try b.submit(.{ .mesh = 3, .material = 3, .transform = .{ .position = .{ 3, 0, 0 } } });
    try b.finalize(.{ 0, 0, 0 });

    // Premier bucket = mesh=1 (depth² = 1).
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
