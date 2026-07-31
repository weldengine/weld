//! Comptime-typed query over the dynamic side of the world.
//!
//! `query(world, .{T1, T2, ...})` returns an iterator that walks the
//! world's `DynamicArchetype`s, finds those whose registry-keyed
//! component set is a superset of `{@typeName(T1), @typeName(T2), ...}`,
//! and yields a comptime-typed tuple of pointers `(*T1, *T2, ...)` per
//! matching slot.
//!
//! This is the path the S5 codegen consumes — each rule emits one
//! `query(world, .{...})` invocation, and Zig's comptime monomorphises
//! one iterator type per distinct tuple of component types. The total
//! number of distinct instantiations is the figure reported by
//! `bench-etch-compile` for Gate 4.
//!
//! Coexists with the S1 single-archetype `world.query()` (which still
//! covers the comptime `(Transform, Velocity)` path). They do not share
//! storage — `query` here only sees archetypes spawned via
//! `world.spawnDynamic`, the path the codegen and the differential
//! corpus runner use.

const std = @import("std");
const registry_mod = @import("registry.zig");
const arch_dyn_mod = @import("archetype_dynamic.zig");
const world_mod = @import("world.zig");

const ComponentId = registry_mod.ComponentId;
const DynamicArchetype = arch_dyn_mod.DynamicArchetype;
const Chunk = arch_dyn_mod.Chunk;
const World = world_mod.World;

/// Generic iterator over entities whose archetype contains all of
/// `tuple`'s component types. Comptime-monomorphised per distinct
/// `tuple`. The `Row` type is a comptime tuple struct (`.@"0"`, `.@"1"`,
/// …) of `*Ti` pointers into the chunk's SoA arrays — readers and writers
/// alike go through these pointers, no `Value` tagged union on the hot
/// path.
pub fn ComptimeQuery(comptime tuple: anytype) type {
    const types_count: usize = tuple.len;
    return struct {
        const Self = @This();

        world: *World,
        comp_ids: [types_count]ComponentId,
        arch_idx: u32 = 0,
        chunk_idx: u32 = 0,
        slot: u32 = 0,
        cur_arch: ?*DynamicArchetype = null,
        cur_chunk: ?*Chunk = null,
        cur_count: u32 = 0,
        cur_offsets: [types_count]u16 = undefined,

        pub const Row = row: {
            var ptr_types: [types_count]type = undefined;
            for (0..types_count) |i| ptr_types[i] = *tuple[i];
            break :row @Tuple(&ptr_types);
        };

        pub fn init(world: *World) Self {
            var comp_ids: [types_count]ComponentId = undefined;
            inline for (0..types_count) |i| {
                const T = tuple[i];
                comp_ids[i] = world.registry.idOf(@typeName(T)) orelse 0;
            }
            return .{
                .world = world,
                .comp_ids = comp_ids,
            };
        }

        pub fn next(self: *Self) ?Row {
            while (true) {
                // If we have a chunk in progress, yield its next slot.
                if (self.cur_chunk) |chunk| {
                    if (self.slot < self.cur_count) {
                        var row: Row = undefined;
                        inline for (0..types_count) |i| {
                            const T = tuple[i];
                            const off = self.cur_offsets[i];
                            const arr: [*]T = @ptrCast(@alignCast(&chunk.bytes[off]));
                            @field(row, std.fmt.comptimePrint("{d}", .{i})) = &arr[self.slot];
                        }
                        self.slot += 1;
                        return row;
                    }
                    // Chunk exhausted — advance to next chunk in current arch.
                    self.chunk_idx += 1;
                    self.slot = 0;
                    if (self.cur_arch) |arch| {
                        if (self.chunk_idx < arch.chunks.items.len) {
                            self.cur_chunk = arch.chunks.items[self.chunk_idx];
                            self.cur_count = self.cur_chunk.?.header().entity_count;
                            continue;
                        }
                    }
                    // Archetype exhausted — fall through to find next match.
                    self.cur_chunk = null;
                    self.cur_arch = null;
                    self.arch_idx += 1;
                    self.chunk_idx = 0;
                }
                // Find the next archetype that contains every required
                // component.
                while (self.arch_idx < self.world.archetypes.items.len) : (self.arch_idx += 1) {
                    const arch = self.world.archetypes.items[self.arch_idx];
                    // M0.2 / E3 — singleton resources are invisible to
                    // user queries (cf. `ARCH-006`).
                    if (arch.is_singleton) continue;
                    var all_present = true;
                    for (self.comp_ids) |cid| {
                        if (!arch.hasComponent(cid)) {
                            all_present = false;
                            break;
                        }
                    }
                    if (!all_present) continue;
                    inline for (0..types_count) |i| {
                        const cidx = arch.componentIndex(self.comp_ids[i]).?;
                        self.cur_offsets[i] = arch.layout.component_offsets[cidx];
                    }
                    self.cur_arch = arch;
                    if (arch.chunks.items.len > 0) {
                        self.cur_chunk = arch.chunks.items[0];
                        self.cur_count = self.cur_chunk.?.header().entity_count;
                        self.chunk_idx = 0;
                        self.slot = 0;
                        break;
                    }
                }
                if (self.cur_chunk == null) return null;
            }
        }
    };
}

/// Comptime entry point. The `tuple` value is e.g. `.{Counter, Position}`
/// at the call site; Zig monomorphises one return type per distinct
/// `tuple`.
pub fn query(world: *World, comptime tuple: anytype) ComptimeQuery(tuple) {
    return ComptimeQuery(tuple).init(world);
}

// ─── tests ────────────────────────────────────────────────────────────────

test "query yields typed rows over a single dynamic archetype" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const A = extern struct { v: i64 = 0 };
    const B = extern struct { f: f64 = 0 };

    const id_a = try world.registry.registerComponent(gpa, A);
    try world.registry.registerAlias(gpa, "A", id_a);
    const id_b = try world.registry.registerComponent(gpa, B);
    try world.registry.registerAlias(gpa, "B", id_b);

    // Spawn 3 entities into an archetype {A, B}.
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        _ = try world.spawnDynamic(gpa, &[_]ComponentId{ id_a, id_b });
    }

    // Mutate via the query iterator.
    var it = query(&world, .{ A, B });
    while (it.next()) |row| {
        row.@"0".v += 7;
        row.@"1".f += 1.5;
    }

    // Confirm every spawned entity received the mutation.
    var checked: u32 = 0;
    var it2 = query(&world, .{ A, B });
    while (it2.next()) |row| {
        try std.testing.expectEqual(@as(i64, 7), row.@"0".v);
        try std.testing.expectEqual(@as(f64, 1.5), row.@"1".f);
        checked += 1;
    }
    try std.testing.expectEqual(@as(u32, 3), checked);
}

test "query skips archetypes missing required components" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const A = extern struct { v: i64 = 0 };
    const B = extern struct { f: f64 = 0 };

    const id_a = try world.registry.registerComponent(gpa, A);
    try world.registry.registerAlias(gpa, "A", id_a);
    const id_b = try world.registry.registerComponent(gpa, B);
    try world.registry.registerAlias(gpa, "B", id_b);

    // One entity has only A, another has only B, third has both.
    _ = try world.spawnDynamic(gpa, &[_]ComponentId{id_a}); // entity 0
    _ = try world.spawnDynamic(gpa, &[_]ComponentId{id_b}); // entity 1
    _ = try world.spawnDynamic(gpa, &[_]ComponentId{ id_a, id_b }); // entity 2

    var count_ab: u32 = 0;
    var it = query(&world, .{ A, B });
    while (it.next()) |_| count_ab += 1;
    try std.testing.expectEqual(@as(u32, 1), count_ab);

    var count_a: u32 = 0;
    var it_a = query(&world, .{A});
    while (it_a.next()) |_| count_a += 1;
    try std.testing.expectEqual(@as(u32, 2), count_a);
}

test "query yields zero rows when no archetype contains the tuple" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const A = extern struct { v: i64 = 0 };
    _ = try world.registry.registerComponent(gpa, A);
    try world.registry.registerAlias(gpa, "A", 0);

    var it = query(&world, .{A});
    try std.testing.expect(it.next() == null);
}
