//! `.scene.bin` runtime loader — Tier 0 (`engine-scene-serialization.md` §4,
//! "Chargement (loader runtime — M1.0.5)").
//!
//! Reads a cooked `.scene.bin` back into a live ECS `World`. It **reuses
//! `accessor.zig` verbatim** (the zero-copy read half of the M1.0.4 codec) and
//! layers the runtime-only steps on top: on-disk-identity → runtime remap,
//! per-entity instantiation, the UUID→handle map, and the `on_spawned`
//! lifecycle. No new ECS storage primitive — the loader assembles existing
//! bricks (`world.spawnDynamicWithValues`, `Registry.idOf`, `ObserverRegistry`,
//! `world.addResource`).
//!
//! Tier discipline: imports `weld_core` internals only — never `weld_etch`
//! (`engine-spec.md` §3.5). The cook driver's Etch coupling lives in
//! `src/etch/scene_cook.zig`; the loader consumes only the neutral byte image.
//!
//! ## Stages (gate-split, see `briefs/M1.0.5-scene-load.md`)
//! * **E1 (here)** — open + integrity check + schema-identity remap. The two
//!   units below (`openVerified`, `buildSchemaRemap`) are the front of the load
//!   pipeline; both operate on a borrowed byte image so they are unit-testable
//!   without touching the filesystem. They form the clean internal boundary the
//!   E2 instantiation step builds on (and a future bulk path would swap behind).
//! * **E2** — `loadScene(world, gpa, path)`: the `fs.mmapFile` wrapper, the
//!   per-entity instantiation loop, the UUID map, two-phase `on_spawned`, and
//!   the `LoadResult` that owns the mmap.
//! * **E3** — resource loading (POD bytes + interned `string` fields).

const std = @import("std");

const format = @import("format.zig");
const accessor_mod = @import("accessor.zig");
const registry_mod = @import("../ecs/registry.zig");
const world_mod = @import("../ecs/world.zig");

const Accessor = accessor_mod.Accessor;
const ComponentId = registry_mod.ComponentId;
const World = world_mod.World;

/// Errors from opening + integrity-checking a `.scene.bin` byte image.
/// `format.ReadError` covers a truncated / wrong-magic / wrong-version file;
/// `CorruptScene` is a content-hash mismatch (the bytes were altered after the
/// cook recorded their `XxHash64`).
pub const OpenError = format.ReadError || error{CorruptScene};

/// Errors from mapping on-disk schema identity to the runtime registry.
/// `UnknownComponent`: a scene type the running program never registered
/// (Phase 1 has no auto-registration from the on-disk `SchemaEntry` —
/// `engine-scene-serialization.md` §4). `SchemaMismatch`: the type is
/// registered but its size/alignment diverge from the cooked layout, so
/// byte-copying its columns into storage would corrupt it.
pub const RemapError = error{ UnknownComponent, SchemaMismatch } || std.mem.Allocator.Error;

/// Open a `.scene.bin` byte image: validate magic + version (via the accessor,
/// read little-endian field-by-field — never a raw `@ptrCast` off an unaligned
/// buffer), then verify the content hash. Returns a zero-copy `Accessor`
/// borrowing `bytes` for its whole lifetime.
///
/// Errors:
///   - `error.TooShort` / `error.BadMagic` / `error.BadVersion` — invalid header
///   - `error.CorruptScene` — content hash does not match the header's
pub fn openVerified(bytes: []const u8) OpenError!Accessor {
    const acc = try Accessor.open(bytes);
    if (!acc.verifyHash()) return error.CorruptScene;
    return acc;
}

/// Build the schema-remap table: on-disk Schema-Registry index → runtime
/// `ComponentId`. Phase-1 schema identity is the component **name**
/// (`engine-ecs-internals.md` §10): each on-disk schema's name is resolved
/// through the world's registry (`Registry.idOf`), and its cooked
/// `size`/`alignment` are validated against the runtime layout so a scene
/// cooked against a different component layout can never feed mismatched bytes
/// into storage.
///
/// The returned slice is `acc.schemaCount()` long, indexed by on-disk schema
/// index; the caller owns it (`gpa.free`).
///
/// Errors:
///   - `error.UnknownComponent` — a schema name the world never registered
///   - `error.SchemaMismatch` — registered, but size/alignment diverge
///   - `error.OutOfMemory`
pub fn buildSchemaRemap(gpa: std.mem.Allocator, world: *const World, acc: Accessor) RemapError![]ComponentId {
    const count = acc.schemaCount();
    const remap = try gpa.alloc(ComponentId, count);
    errdefer gpa.free(remap);

    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const s = acc.schema(i);
        const id = world.componentId(s.name) orelse return error.UnknownComponent;
        if (s.size != world.registry.componentSize(id) or
            s.alignment != world.registry.componentAlignment(id))
        {
            return error.SchemaMismatch;
        }
        remap[i] = id;
    }
    return remap;
}

// ─── inline tests ───────────────────────────────────────────────────────────

const testing = std.testing;
const writer = @import("writer.zig");
const Registry = registry_mod.Registry;

/// Test helper: serialize a 1-archetype, 1-entity `.scene.bin` over `reg` (the
/// cook registry) holding the single component `cid` with a zeroed column.
/// Returns the caller-owned byte image (`gpa.free`).
fn buildOneCompScene(gpa: std.mem.Allocator, reg: *const Registry, cid: ComponentId) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();
    const names = try a.dupe([]const u8, &.{try a.dupe(u8, "E0")});
    const uuids = try a.dupe([16]u8, &.{[_]u8{0} ** 16});
    const col = try a.alloc(u8, reg.componentSize(cid)); // 1 entity
    @memset(col, 0);
    const cols = try a.dupe([]u8, &.{col});
    const ents = try a.dupe(format.EntityEntry, &.{
        .{ .name = 0, .uuid = 0, .parent_uuid = format.no_parent },
    });
    const ids = try a.dupe(ComponentId, &.{cid});
    const blocks = try a.dupe(format.ArchetypeBlock, &.{.{
        .component_ids = ids,
        .entity_count = 1,
        .columns = cols,
        .entities = ents,
    }});
    var model: format.CookModel = .{
        .strings = names,
        .uuids = uuids,
        .resources = &.{},
        .archetypes = blocks,
        .arena = arena,
    };
    defer model.deinit();
    return try writer.write(gpa, model, reg);
}

fn registerRaw(gpa: std.mem.Allocator, reg: *Registry, name: []const u8, size: u16, alignment: u16) !ComponentId {
    const zeros = try gpa.alloc(u8, size);
    defer gpa.free(zeros);
    @memset(zeros, 0);
    return try reg.registerComponentRaw(gpa, .{
        .name = name,
        .size = size,
        .alignment = alignment,
        .default_bytes = zeros,
        .fields = &.{},
    });
}

test "buildSchemaRemap resolves on-disk schema names to runtime ids" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);
    const pos = try registerRaw(gpa, &world.registry, "Pos", 8, 4);

    const bytes = try buildOneCompScene(gpa, &world.registry, pos);
    defer gpa.free(bytes);

    const acc = try openVerified(bytes);
    const remap = try buildSchemaRemap(gpa, &world, acc);
    defer gpa.free(remap);

    try testing.expectEqual(@as(usize, 1), remap.len);
    try testing.expectEqual(pos, remap[0]);
}

test "buildSchemaRemap errors UnknownComponent for an unregistered name" {
    const gpa = testing.allocator;

    // Cook a scene referencing "Ghost" through a standalone cook registry.
    var cook_reg = Registry.init();
    defer cook_reg.deinit(gpa);
    const ghost = try registerRaw(gpa, &cook_reg, "Ghost", 4, 4);
    const bytes = try buildOneCompScene(gpa, &cook_reg, ghost);
    defer gpa.free(bytes);

    // Load into a world that never registered "Ghost".
    var world = World.init();
    defer world.deinit(gpa);
    const acc = try openVerified(bytes);
    try testing.expectError(error.UnknownComponent, buildSchemaRemap(gpa, &world, acc));
}

test "buildSchemaRemap errors SchemaMismatch on a divergent layout" {
    const gpa = testing.allocator;

    // Cooked as size 8 …
    var cook_reg = Registry.init();
    defer cook_reg.deinit(gpa);
    const pos_cook = try registerRaw(gpa, &cook_reg, "Pos", 8, 4);
    const bytes = try buildOneCompScene(gpa, &cook_reg, pos_cook);
    defer gpa.free(bytes);

    // … but registered as size 12 at load time.
    var world = World.init();
    defer world.deinit(gpa);
    _ = try registerRaw(gpa, &world.registry, "Pos", 12, 4);
    const acc = try openVerified(bytes);
    try testing.expectError(error.SchemaMismatch, buildSchemaRemap(gpa, &world, acc));
}

test "openVerified rejects a tampered scene with CorruptScene" {
    const gpa = testing.allocator;
    var cook_reg = Registry.init();
    defer cook_reg.deinit(gpa);
    const pos = try registerRaw(gpa, &cook_reg, "Pos", 8, 4);
    const bytes = try buildOneCompScene(gpa, &cook_reg, pos);
    defer gpa.free(bytes);

    // Flip a byte in the content region (after the 64-byte header) so the
    // recorded XxHash64 no longer matches, while magic/version stay valid.
    bytes[format.header_size] ^= 0xFF;
    try testing.expectError(error.CorruptScene, openVerified(bytes));
}

test "openVerified surfaces header ReadError (short / bad magic / bad version)" {
    const gpa = testing.allocator;
    var cook_reg = Registry.init();
    defer cook_reg.deinit(gpa);
    const pos = try registerRaw(gpa, &cook_reg, "Pos", 8, 4);
    const bytes = try buildOneCompScene(gpa, &cook_reg, pos);
    defer gpa.free(bytes);

    try testing.expectError(error.TooShort, openVerified(bytes[0..10]));

    const saved = bytes[0];
    bytes[0] = 'X';
    try testing.expectError(error.BadMagic, openVerified(bytes));
    bytes[0] = saved;

    std.mem.writeInt(u16, bytes[4..6], 999, .little);
    try testing.expectError(error.BadVersion, openVerified(bytes));
}
