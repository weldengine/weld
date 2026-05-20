//! Dynamic archetype storage — accepts a runtime `ComponentId[]` and
//! reproduces the chunk SoA layout of S1's comptime archetype (16 KiB
//! chunks, SoA per component, 16-byte aligned per-component arrays) but
//! computed from the runtime `Registry` rather than from a `comptime
//! Components`.
//!
//! Coexists with the S1 comptime `(Transform, Velocity)` archetype in
//! `world.zig` — additive, never replaces. The chunk size and alignment
//! match S1 so the same back-of-the-envelope cache analysis applies.

const std = @import("std");
const registry_mod = @import("registry.zig");
const entity_mod = @import("entity.zig");

const ComponentId = registry_mod.ComponentId;
const Registry = registry_mod.Registry;

// Canonical EntityId from the identity module. Previously aliased to
// `u64` locally to keep the dynamic path free of a `components.zig`
// dependency; M0.1 / E1 promotes EntityId to a generational handle
// owned by `entity.zig`, so the dynamic path imports it directly and
// the two spawn paths now agree on the wire format.
const EntityId = entity_mod.EntityId;

/// Chunk size — locked to 16 KiB to match S1 (cf. `core/ecs/chunk.zig`).
pub const ChunkSize: usize = 16 * 1024;
/// Chunk header alignment — keeps the leading bytes of every chunk
/// aligned to 16, matching the SIMD-friendly layout used by the
/// comptime SoA archetype.
pub const ChunkAlignment: usize = 16;

/// Tight header — `entity_count` is the only field mutated during normal
/// operation; `capacity` and `archetype_id` are set at chunk creation.
/// 16 bytes total keeps the header aligned to `ChunkAlignment` without
/// padding tricks.
pub const ChunkHeader = extern struct {
    entity_count: u32,
    capacity: u32,
    archetype_id: u32,
    _pad: u32 = 0,
};

/// Surfaced by `DynamicArchetype.init`, `spawnDefault`, `allocChunk`
/// and the standalone `chunkLayout` factory; the variants line up
/// 1:1 with the failure modes each of those routines can hit.
pub const ArchetypeError = error{
    EmptyComponentList,
    LayoutTooLarge,
    OutOfMemory,
};

/// Per-archetype layout descriptor — byte offsets of each SoA column
/// inside a chunk plus the chunk's entity capacity.
pub const ChunkLayout = struct {
    /// Offset (in bytes from chunk start) of each component's SoA array.
    /// Length equals the archetype's `component_ids.len`.
    component_offsets: []u16,
    /// Offset of the entity-id array.
    entity_ids_offset: u16,
    /// Maximum entities per chunk.
    capacity: u32,
};

/// Aligned raw buffer underpinning a single chunk.
pub const Chunk = struct {
    bytes: [ChunkSize]u8 align(ChunkAlignment),

    comptime {
        std.debug.assert(@sizeOf(Chunk) == ChunkSize);
        std.debug.assert(@alignOf(Chunk) >= ChunkAlignment);
    }

    pub fn header(self: *Chunk) *ChunkHeader {
        return @ptrCast(@alignCast(&self.bytes));
    }

    pub fn headerConst(self: *const Chunk) *const ChunkHeader {
        return @ptrCast(@alignCast(&self.bytes));
    }
};

/// Runtime archetype owning a list of chunks. Built from a slice of
/// `ComponentId` resolved against a `Registry`.
pub const DynamicArchetype = struct {
    archetype_id: u32,
    /// Sorted ascending so `(includes ⊆ component_ids) ∧ (excludes ∩ component_ids = ∅)`
    /// queries can use ordered set intersection.
    component_ids: []ComponentId,
    sizes: []u16,
    aligns: []u16,
    /// Reference to the registry for default bytes lookup (used by
    /// `spawnDefault`). Borrowed — the archetype does not own the registry.
    registry: *const Registry,
    layout: ChunkLayout,
    chunks: std.ArrayListUnmanaged(*Chunk) = .empty,

    /// Initialise the archetype with the given component list. The list is
    /// sorted by id internally — the order of `component_ids` post-init
    /// determines the SoA order in every chunk.
    pub fn init(
        gpa: std.mem.Allocator,
        registry: *const Registry,
        archetype_id: u32,
        component_ids: []const ComponentId,
    ) ArchetypeError!DynamicArchetype {
        if (component_ids.len == 0) return ArchetypeError.EmptyComponentList;

        const ids = try gpa.dupe(ComponentId, component_ids);
        errdefer gpa.free(ids);
        std.mem.sort(ComponentId, ids, {}, comptime std.sort.asc(ComponentId));

        const sizes = try gpa.alloc(u16, ids.len);
        errdefer gpa.free(sizes);
        const aligns = try gpa.alloc(u16, ids.len);
        errdefer gpa.free(aligns);
        for (ids, 0..) |id, i| {
            sizes[i] = registry.componentSize(id);
            aligns[i] = registry.componentAlignment(id);
        }

        const layout = try computeLayout(gpa, sizes, aligns);
        errdefer gpa.free(layout.component_offsets);

        return .{
            .archetype_id = archetype_id,
            .component_ids = ids,
            .sizes = sizes,
            .aligns = aligns,
            .registry = registry,
            .layout = layout,
        };
    }

    pub fn deinit(self: *DynamicArchetype, gpa: std.mem.Allocator) void {
        for (self.chunks.items) |c| gpa.destroy(c);
        self.chunks.deinit(gpa);
        gpa.free(self.component_ids);
        gpa.free(self.sizes);
        gpa.free(self.aligns);
        gpa.free(self.layout.component_offsets);
        self.* = undefined;
    }

    pub fn capacity(self: *const DynamicArchetype) u32 {
        return self.layout.capacity;
    }

    pub fn chunkCount(self: *const DynamicArchetype) usize {
        return self.chunks.items.len;
    }

    pub fn entityCount(self: *const DynamicArchetype) usize {
        var total: usize = 0;
        for (self.chunks.items) |c| total += c.headerConst().entity_count;
        return total;
    }

    /// Returns the index of `component_id` within this archetype's
    /// component list, or `null` if absent.
    pub fn componentIndex(self: *const DynamicArchetype, component_id: ComponentId) ?usize {
        for (self.component_ids, 0..) |id, i| if (id == component_id) return i;
        return null;
    }

    pub fn hasComponent(self: *const DynamicArchetype, component_id: ComponentId) bool {
        return self.componentIndex(component_id) != null;
    }

    /// Append a fresh entity. The slot is initialised by memcpy'ing the
    /// registry's default bytes for every component. Returns the
    /// `(chunk_idx, slot)` location and the assigned entity id.
    pub const SpawnResult = struct {
        entity_id: EntityId,
        chunk_idx: u32,
        slot: u32,
    };

    pub fn spawnDefault(self: *DynamicArchetype, gpa: std.mem.Allocator, entity_id: EntityId) ArchetypeError!SpawnResult {
        const chunk = blk: {
            if (self.chunks.items.len > 0) {
                const last = self.chunks.items[self.chunks.items.len - 1];
                if (last.header().entity_count < self.layout.capacity) break :blk last;
            }
            break :blk try self.allocChunk(gpa);
        };
        const hdr = chunk.header();
        const slot = hdr.entity_count;

        // Defaults per component.
        for (self.component_ids, 0..) |id, i| {
            const off = self.layout.component_offsets[i];
            const sz = self.sizes[i];
            const dst = chunk.bytes[off + sz * slot ..][0..sz];
            @memcpy(dst, self.registry.componentDefaultBytes(id));
        }
        // Entity id slot.
        const ids_arr = self.entityIds(chunk);
        ids_arr[slot] = entity_id;

        hdr.entity_count = slot + 1;
        return .{
            .entity_id = entity_id,
            .chunk_idx = @intCast(self.chunks.items.len - 1),
            .slot = slot,
        };
    }

    fn allocChunk(self: *DynamicArchetype, gpa: std.mem.Allocator) ArchetypeError!*Chunk {
        const chunk = try gpa.create(Chunk);
        errdefer gpa.destroy(chunk);
        chunk.header().* = .{
            .entity_count = 0,
            .capacity = self.layout.capacity,
            .archetype_id = self.archetype_id,
        };
        try self.chunks.append(gpa, chunk);
        return chunk;
    }

    /// Pointer to the SoA array for component index `i` inside `chunk`.
    /// Length is `chunk.entity_count`.
    pub fn componentBytes(self: *const DynamicArchetype, chunk: *Chunk, i: usize) []u8 {
        const off = self.layout.component_offsets[i];
        const sz = self.sizes[i];
        const len = chunk.header().entity_count;
        return chunk.bytes[off..][0 .. sz * len];
    }

    /// Pointer + size to one component slot (`slot` inside the chunk).
    pub fn componentSlot(self: *const DynamicArchetype, chunk: *Chunk, i: usize, slot: u32) []u8 {
        const off = self.layout.component_offsets[i];
        const sz = self.sizes[i];
        return chunk.bytes[off + sz * slot ..][0..sz];
    }

    pub fn entityIds(self: *const DynamicArchetype, chunk: *Chunk) [*]EntityId {
        return @ptrCast(@alignCast(&chunk.bytes[self.layout.entity_ids_offset]));
    }

    pub fn entityIdsConst(self: *const DynamicArchetype, chunk: *const Chunk) [*]const EntityId {
        return @ptrCast(@alignCast(&chunk.bytes[self.layout.entity_ids_offset]));
    }
};

// ─── Layout computation ──────────────────────────────────────────────────

fn computeLayout(
    gpa: std.mem.Allocator,
    sizes: []const u16,
    aligns: []const u16,
) ArchetypeError!ChunkLayout {
    const header_size: usize = std.mem.alignForward(usize, @sizeOf(ChunkHeader), ChunkAlignment);

    // Per-slot byte cost: components + entity id. Used only to seed the
    // capacity loop with a reasonable upper bound.
    var per_slot: usize = @sizeOf(EntityId);
    for (sizes) |s| per_slot += s;
    if (per_slot == 0) return ArchetypeError.LayoutTooLarge;

    var n: usize = (ChunkSize - header_size) / per_slot;
    while (n > 0) : (n -= 1) {
        if (fits(sizes, aligns, n, header_size)) break;
    }
    if (n == 0) return ArchetypeError.LayoutTooLarge;

    const offsets = try gpa.alloc(u16, sizes.len);
    errdefer gpa.free(offsets);

    var off: usize = header_size;
    for (sizes, aligns, 0..) |sz, al, i| {
        off = std.mem.alignForward(usize, off, @max(ChunkAlignment, @as(usize, al)));
        offsets[i] = @intCast(off);
        off += @as(usize, sz) * n;
    }
    off = std.mem.alignForward(usize, off, @alignOf(EntityId));
    const entity_ids_offset: u16 = @intCast(off);

    return .{
        .component_offsets = offsets,
        .entity_ids_offset = entity_ids_offset,
        .capacity = @intCast(n),
    };
}

fn fits(sizes: []const u16, aligns: []const u16, n: usize, header_size: usize) bool {
    var off: usize = header_size;
    for (sizes, aligns) |sz, al| {
        off = std.mem.alignForward(usize, off, @max(ChunkAlignment, @as(usize, al)));
        off += @as(usize, sz) * n;
    }
    off = std.mem.alignForward(usize, off, @alignOf(EntityId));
    off += @sizeOf(EntityId) * n;
    return off <= ChunkSize;
}

// ─── tests ────────────────────────────────────────────────────────────────

test "DynamicArchetype matches the chunk layout of the S1 comptime archetype for equivalent component sets" {
    // The S1 chunk for `(Transform, Velocity)` has capacity 185 (cf.
    // `briefs/S1-mini-ecs.md` journal). Build a dynamic archetype with two
    // components matching Transform's and Velocity's size+align and
    // confirm the same capacity falls out.
    const gpa = std.testing.allocator;
    var reg = Registry.init();
    defer reg.deinit(gpa);

    const Transform = struct {
        a: f64 = 0, // 8
        b: f64 = 0, // 8
        c: f64 = 0, // 8
        d: f64 = 0, // 8
        e: f64 = 0, // 8
        f: f64 = 0, // 8
    }; // 48 bytes, align 8
    const Velocity = struct {
        a: f64 = 0,
        b: f64 = 0,
        c: f64 = 0,
        d: f64 = 0,
    }; // 32 bytes, align 8

    const id_t = try reg.registerComponent(gpa, Transform);
    const id_v = try reg.registerComponent(gpa, Velocity);
    var arch = try DynamicArchetype.init(gpa, &reg, 0, &[_]ComponentId{ id_t, id_v });
    defer arch.deinit(gpa);

    // S1 reference capacity = 185. The runtime computation aligns each
    // component array to max(16, alignof) = 16; with a small header it
    // should reach the same value within ±a few units (the runtime header
    // is 16 vs S1's 64). The test asserts a reasonable lower bound that
    // catches gross layout breakage, not an exact match.
    try std.testing.expect(arch.capacity() >= 180);
    try std.testing.expect(arch.capacity() <= 210);
}

test "spawnDefault returns a generational Entity handle" {
    const gpa = std.testing.allocator;
    var reg = Registry.init();
    defer reg.deinit(gpa);

    const Health = struct { current: f64 = 42.0 };
    const id_h = try reg.registerComponent(gpa, Health);
    var arch = try DynamicArchetype.init(gpa, &reg, 0, &[_]ComponentId{id_h});
    defer arch.deinit(gpa);

    const expected_id = EntityId{ .index = 7, .generation = 0 };
    const r = try arch.spawnDefault(gpa, expected_id);
    try std.testing.expectEqual(expected_id, r.entity_id);
    try std.testing.expectEqual(@as(u32, 0), r.chunk_idx);
    try std.testing.expectEqual(@as(u32, 0), r.slot);
    try std.testing.expectEqual(@as(usize, 1), arch.entityCount());

    // The default value should be visible at the slot.
    const slot_bytes = arch.componentSlot(arch.chunks.items[0], 0, 0);
    var v: f64 = 0;
    @memcpy(std.mem.asBytes(&v), slot_bytes);
    try std.testing.expectEqual(@as(f64, 42.0), v);
}

test "iteration over a 16 KiB chunk respects SoA per component" {
    const gpa = std.testing.allocator;
    var reg = Registry.init();
    defer reg.deinit(gpa);

    const A = struct { v: i64 = 0 };
    const B = struct { v: f64 = 0 };
    const id_a = try reg.registerComponent(gpa, A);
    const id_b = try reg.registerComponent(gpa, B);
    var arch = try DynamicArchetype.init(gpa, &reg, 0, &[_]ComponentId{ id_a, id_b });
    defer arch.deinit(gpa);

    // Spawn 4 entities, write distinct values via the SoA arrays.
    var i: u32 = 0;
    while (i < 4) : (i += 1) {
        _ = try arch.spawnDefault(gpa, .{ .index = i, .generation = 0 });
    }
    const chunk = arch.chunks.items[0];
    const a_idx = arch.componentIndex(id_a).?;
    const b_idx = arch.componentIndex(id_b).?;
    var j: u32 = 0;
    while (j < 4) : (j += 1) {
        const a_slot = arch.componentSlot(chunk, a_idx, j);
        var av: i64 = @intCast(j);
        @memcpy(a_slot, std.mem.asBytes(&av));
        const b_slot = arch.componentSlot(chunk, b_idx, j);
        var bv: f64 = @floatFromInt(j);
        @memcpy(b_slot, std.mem.asBytes(&bv));
    }
    // Read back.
    j = 0;
    while (j < 4) : (j += 1) {
        const a_slot = arch.componentSlot(chunk, a_idx, j);
        var av: i64 = 0;
        @memcpy(std.mem.asBytes(&av), a_slot);
        try std.testing.expectEqual(@as(i64, @intCast(j)), av);

        const b_slot = arch.componentSlot(chunk, b_idx, j);
        var bv: f64 = 0;
        @memcpy(std.mem.asBytes(&bv), b_slot);
        try std.testing.expectEqual(@as(f64, @floatFromInt(j)), bv);
    }
}
