//! FROZEN — see engine-phase-0-criteria.md C0.5 (M0.9)
//!
//! Tier 0 runtime component registry — assigns a stable `ComponentId` to
//! every component (or resource) type known to the engine, plus enough
//! metadata for the rest of the ECS (dynamic archetype storage, runtime
//! queries, the Etch bridge) to operate on raw bytes.
//!
//! Two registration paths share the same backing storage:
//!
//! - `registerComponent(gpa, comptime T) ComponentId` — for types known at
//!   Zig compile time. The descriptor is derived from `@typeInfo(T)`.
//! - `registerComponentRaw(gpa, desc) ComponentId` — for types discovered
//!   at runtime (the Etch bridge consumes this path from the parsed AST:
//!   component names, field names, default bytes come from the source
//!   file).
//!
//! Coexists with the S1 comptime `(Transform, Velocity)` archetype defined
//! in `world.zig` — additive, never replaces it. The struct stores no
//! allocator; per `engine-zig-conventions.md` §3, the gpa is passed at
//! every mutating op.

const std = @import("std");

/// `EntityId` (`packed struct(u64)`) — the storage type of a `.entity_` field
/// (M1.0.6 E4). Imported only for `FieldKind.fromZigType`; `entity.zig` imports
/// nothing of `registry.zig`, so this is acyclic.
const EntityId = @import("entity.zig").EntityId;

/// Stable identifier assigned at registration. The first registered
/// component gets `ComponentId(0)`; subsequent registrations get the next
/// integer. Stability across runs is *not* guaranteed (it would require an
/// out-of-band scheme like StableId — Phase 2).
pub const ComponentId = u32;

/// Storage backend of a component — the closed two-variant domain owned by
/// `engine-ecs-internals.md` §2 (*Table vs SparseSet*). `table` is the default
/// and, before M1.B.0, the only backend implemented; `sparse` is the explicit
/// opt-in a declaration carries through `@storage(.sparse)`.
///
/// Declared HERE and nowhere else, deliberately. `etch-resolver-types.md`
/// §13.3.1 states the rule that makes this the right home: an annotation
/// argument's type is either a language type or a domain defined and citable at
/// the owner of the EFFECT — never a name introduced by the schema table. The
/// Etch front-end therefore validates through `fromName` instead of re-listing
/// the two spellings, so the domain has one text form in the tree.
pub const StorageKind = enum {
    table,
    sparse,

    /// Spelling → variant, and the single place the two names exist as text.
    /// `null` for a value outside the domain, which the Etch front-end reports
    /// as `E0503 AnnotationArgMismatch`.
    pub fn fromName(name: []const u8) ?StorageKind {
        if (std.mem.eql(u8, name, "table")) return .table;
        if (std.mem.eql(u8, name, "sparse")) return .sparse;
        return null;
    }
};

/// Coarse-grained tag for primitive fields. The interpreter uses this to
/// decide how to read or write raw bytes. The S3 subset only exercises
/// `int_`, `float_`, `bool_`; the integer-family variants are reserved
/// for future extension.
pub const FieldKind = enum {
    int_, // i64
    float_, // f64
    bool_, // u8 wide (single byte)
    i32_,
    u32_,
    f32_,
    f64_,
    /// A `string` field slot: `{ ptr: u64, len: u32 }` (16 bytes, 8-aligned)
    /// pointing into the Tier-0 persistent heap (`src/core/memory/persistent.zig`,
    /// `StringSlot`). **Resource-only by construction** (M1.0.3): the Etch
    /// validator rejects `string` on `component` and `fieldKindFromTypeName`
    /// only emits this kind for the `.resource` origin, so no component can ever
    /// carry it — the component SoA/POD invariant (`ARCH-004`) is
    /// untouched. Tier-0 stays string-agnostic: it stores/copies the 16 raw
    /// slot bytes; the Etch runtime owns the pointed-to bytes' lifetime.
    string_,
    /// An enum field slot: the variant's declaration-order index as a `u32`
    /// discriminant (4 bytes, 4-aligned). POD — no persistent heap, no decref,
    /// no teardown. **Resource-only** like `.string_` (validator-gated out of
    /// components). The declared enum type's interned name id rides on
    /// `FieldDesc.enum_type_name_id` so the Etch bridge can rebuild a typed
    /// `enum_value{ type_name, variant }` on read.
    enum_,
    /// An `Entity` field slot: an `EntityId` (`packed struct(u64)`, 8 bytes,
    /// 8-aligned). POD — no heap, no teardown — so the component SoA/POD invariant
    /// (`ARCH-004`) is untouched. **Component-only by construction**
    /// (M1.0.6 D-A): the exact mirror of `.string_`/`.enum_` (resource-only) —
    /// `fieldKindFromTypeName` emits `.entity_` only for the `.component` origin.
    /// An unassigned / dangling slot holds `EntityId.dead` (all-ones); at scene
    /// cook the slot is written `dead` and an entity→entity reference is carried by
    /// the Cross-references Table, resolved to the target's handle at load.
    entity_,
    /// A dynamic-array field slot (`T[]`, M1.0.17): a `CollectionSlot`
    /// (`{ ptr: u64 }`, 8 bytes, 8-aligned, `src/core/memory/persistent.zig`)
    /// holding the persistent-heap pointer of the owned container block. Like
    /// `.string_`, **resource-only by construction** — the Etch validator gates
    /// collection fields to resources, so no component SoA slot ever carries one
    /// (the POD invariant, `ARCH-004`, is untouched). Tier 0 stores/
    /// copies the 8 raw slot bytes; the Etch runtime owns the container's lifetime.
    array_,
    /// A map field slot (`[K: V]`, M1.0.17). Same 8-byte `CollectionSlot`
    /// discipline and resource-only gating as `.array_`.
    map_,
    /// A set field slot (`Set<T>`, M1.0.17). Same 8-byte `CollectionSlot`
    /// discipline and resource-only gating as `.array_`.
    set_,

    pub fn sizeBytes(self: FieldKind) usize {
        return switch (self) {
            .int_ => @sizeOf(i64),
            .float_ => @sizeOf(f64),
            .bool_ => 1,
            .i32_ => @sizeOf(i32),
            .u32_ => @sizeOf(u32),
            .f32_ => @sizeOf(f32),
            .f64_ => @sizeOf(f64),
            // `{ ptr: u64, len: u32 }` padded to 8-alignment — must equal
            // `@sizeOf(persistent.StringSlot)` (asserted in `ecs_bridge.zig`).
            .string_ => 16,
            .enum_ => @sizeOf(u32), // declaration-order discriminant
            .entity_ => @sizeOf(EntityId), // 8 (packed u64)
            // `CollectionSlot { ptr: u64 }` — 8 bytes; must equal
            // `@sizeOf(persistent.CollectionSlot)` (asserted in `ecs_bridge.zig`).
            .array_, .map_, .set_ => 8,
        };
    }

    pub fn alignBytes(self: FieldKind) usize {
        return switch (self) {
            .int_ => @alignOf(i64),
            .float_ => @alignOf(f64),
            .bool_ => 1,
            .i32_ => @alignOf(i32),
            .u32_ => @alignOf(u32),
            .f32_ => @alignOf(f32),
            .f64_ => @alignOf(f64),
            .string_ => 8,
            .enum_ => @alignOf(u32),
            .entity_ => @alignOf(EntityId), // 8
            .array_, .map_, .set_ => 8, // CollectionSlot pointer
        };
    }

    pub fn fromZigType(comptime T: type) FieldKind {
        return switch (T) {
            i64 => .int_,
            f64 => .float_,
            bool => .bool_,
            i32 => .i32_,
            u32 => .u32_,
            f32 => .f32_,
            EntityId => .entity_,
            else => @compileError("unsupported Zig type for FieldKind: " ++ @typeName(T)),
        };
    }
};

/// A single field on a component. `offset` is in bytes relative to the
/// component's storage slot (not relative to the chunk).
pub const FieldDesc = struct {
    name: []const u8,
    offset: u16,
    kind: FieldKind,
    /// For a `.enum_` field (resource-only, M1.0.3 E3): the Etch-interned id of
    /// the declared enum type name (an AST `StringId`, kept opaque by Tier-0 —
    /// a plain `u32`, never dereferenced here). Lets the Etch bridge rebuild a
    /// typed `enum_value{ type_name, variant }` on read with no string pool.
    /// Stored as the id (not a string) so it needs no allocation and cannot
    /// dangle when the AST outlives nothing while the registry persists in the
    /// world. `0` and unused for every non-`.enum_` kind.
    enum_type_name_id: u32 = 0,
};

/// Full descriptor stored by the registry. `default_bytes` is `size` bytes
/// long and gets memcpy'd into each freshly spawned slot.
pub const ComponentDesc = struct {
    name: []const u8,
    size: u16,
    alignment: u16,
    default_bytes: []const u8,
    fields: []const FieldDesc,
    /// Storage backend. `table` unless the declaration carried
    /// `@storage(.sparse)`. **Never part of on-disk identity**: a
    /// `SchemaEntry` carries name, size and alignment, and the mode comes from
    /// this runtime registry at load (`engine-scene-serialization.md` §4), so a
    /// component changing mode invalidates no cooked scene and demands no
    /// re-cook. Defaulted, so every existing initializer of this struct stays
    /// source-compatible and absence of the annotation yields `table` by
    /// construction rather than by a branch somebody has to remember.
    storage: StorageKind = .table,
    /// DIRECT requisites, by NAME — the `@requires(A, B)` list, variadic
    /// (`etch-reference-part3.md` §6). Names and not ids because a declaration
    /// may name a component registered LATER: Etch admits forward references,
    /// and resolving at registration would make the closure depend on
    /// declaration order. The transitive closure is computed once by
    /// `finalizeRequires` after every registration and read per add — never
    /// re-walked per add, which `engine-ecs-internals.md` §3 requires in those
    /// words. Defaulted, so every existing initializer stays source-compatible.
    requires: []const []const u8 = &.{},
};

/// Surfaced by `Registry.registerComponent`, `registerComponentRaw`,
/// and `registerAlias`; lookup paths never fail (return `?T`).
pub const RegistryError = error{
    DuplicateComponent,
    OutOfMemory,
};

/// One owned entry. `name`, `default_bytes`, and `fields` are duplicated
/// at registration time so the caller can free its inputs immediately.
const Entry = struct {
    desc: ComponentDesc,
    /// The TRANSITIVE closure of `desc.requires`, flattened to ids, computed
    /// once by `finalizeRequires`. Beside the descriptor and not inside it
    /// because the descriptor is what a CALLER supplies and this is what the
    /// registry DERIVES — one authority per question, the rule this milestone
    /// settled at G3. Empty until finalisation, and empty forever for a
    /// component with no requisites.
    closure: []const ComponentId = &.{},
};

/// Runtime registry of component (and resource) type descriptions.
/// Resolves Etch type names to `ComponentId`s and back, owns the
/// type metadata across the world's lifetime.
pub const Registry = struct {
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    /// Inverse map for lookup by name. Used by the Etch bridge to resolve
    /// `entity.get(T)` strings into a `ComponentId`. Each entry's primary
    /// `desc.name` slice is owned by `entries[id]`; alias slices added via
    /// `registerAlias` are owned by the `aliases` ArrayList below.
    by_name: std.StringHashMapUnmanaged(ComponentId) = .empty,
    /// Extra name slices that map to existing component ids. Lets a single
    /// component be reached by both its Etch name (via `idOf("Counter")`)
    /// and its Zig type's `@typeName(T)` (so the S5 codegen's comptime
    /// `world.query(.{T})` can resolve to the same `ComponentId` as
    /// `world.spawnDynamic(gpa, &.{idOf("Counter").?})`). Stored separately
    /// from the primary names so `deinit` can free them without
    /// double-freeing the entries' own names.
    aliases: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn init() Registry {
        return .{};
    }

    pub fn deinit(self: *Registry, gpa: std.mem.Allocator) void {
        for (self.entries.items) |*e| {
            gpa.free(e.desc.name);
            gpa.free(e.desc.default_bytes);
            // FieldDesc.name slices were each dup'd individually.
            for (e.desc.fields) |f| gpa.free(f.name);
            gpa.free(e.desc.fields);
            for (e.desc.requires) |r| gpa.free(r);
            gpa.free(e.desc.requires);
            if (e.closure.len != 0) gpa.free(e.closure);
        }
        self.entries.deinit(gpa);
        self.by_name.deinit(gpa);
        for (self.aliases.items) |a| gpa.free(a);
        self.aliases.deinit(gpa);
        self.* = undefined;
    }

    /// Register a component described at runtime. The registry duplicates
    /// `desc.name`, `desc.default_bytes`, and each `FieldDesc.name`.
    pub fn registerComponentRaw(self: *Registry, gpa: std.mem.Allocator, desc: ComponentDesc) RegistryError!ComponentId {
        if (self.by_name.contains(desc.name)) return RegistryError.DuplicateComponent;
        const id: ComponentId = @intCast(self.entries.items.len);

        const name_owned = try gpa.dupe(u8, desc.name);
        errdefer gpa.free(name_owned);

        const default_owned = try gpa.dupe(u8, desc.default_bytes);
        errdefer gpa.free(default_owned);

        // Duplicate every FieldDesc name individually; the array itself is
        // also owned.
        const fields_owned = try gpa.alloc(FieldDesc, desc.fields.len);
        errdefer gpa.free(fields_owned);
        var dup_count: usize = 0;
        errdefer for (fields_owned[0..dup_count]) |f| gpa.free(f.name);
        for (desc.fields, 0..) |f, i| {
            const fname_owned = try gpa.dupe(u8, f.name);
            fields_owned[i] = .{
                .name = fname_owned,
                .offset = f.offset,
                .kind = f.kind,
                .enum_type_name_id = f.enum_type_name_id,
            };
            dup_count += 1;
        }

        // Owned copies, freed in `deinit` — same discipline as `name` and the
        // field names. `dup_req` counts what is already duplicated so a failure
        // mid-loop frees exactly those and no more.
        const requires_owned = try gpa.alloc([]const u8, desc.requires.len);
        errdefer gpa.free(requires_owned);
        var dup_req: usize = 0;
        errdefer for (requires_owned[0..dup_req]) |r| gpa.free(r);
        for (desc.requires, 0..) |r, i| {
            requires_owned[i] = try gpa.dupe(u8, r);
            dup_req += 1;
        }

        try self.entries.append(gpa, .{ .desc = .{
            .name = name_owned,
            .size = desc.size,
            .alignment = desc.alignment,
            .default_bytes = default_owned,
            .fields = fields_owned,
            .storage = desc.storage,
            .requires = requires_owned,
        } });
        errdefer _ = self.entries.pop();

        try self.by_name.put(gpa, name_owned, id);
        return id;
    }

    /// Register a component whose layout is known at Zig compile time. The
    /// descriptor is derived from `@typeInfo(T)`; every exported field maps
    /// to a `FieldDesc`. The default value is `T{}`.
    pub fn registerComponent(self: *Registry, gpa: std.mem.Allocator, comptime T: type) RegistryError!ComponentId {
        const info = @typeInfo(T);
        const fields_info = switch (info) {
            .@"struct" => |s| s.fields,
            else => @compileError("registerComponent requires a struct type, got " ++ @typeName(T)),
        };
        var fields: [fields_info.len]FieldDesc = undefined;
        inline for (fields_info, 0..) |f, i| {
            fields[i] = .{
                .name = f.name,
                .offset = @intCast(@offsetOf(T, f.name)),
                .kind = FieldKind.fromZigType(f.type),
            };
        }
        var default: T = .{};
        const default_bytes = std.mem.asBytes(&default);
        return try self.registerComponentRaw(gpa, .{
            .name = @typeName(T),
            .size = @intCast(@sizeOf(T)),
            .alignment = @intCast(@alignOf(T)),
            .default_bytes = default_bytes,
            .fields = &fields,
        });
    }

    /// The three-colour mark of the closure walk. NAMED and declared once: the
    /// same `enum(u8) { … }` written at two sites is two distinct types, which
    /// is what the compiler said the first time.
    const Colour = enum(u8) { white, grey, black };

    /// Resolve every `@requires` name list to ids and flatten the TRANSITIVE
    /// closure, once, after all components are registered.
    ///
    /// Called by whoever finished registering — the Etch front end after its
    /// declaration pass, a host after its own. Idempotent: a second call
    /// recomputes from the same descriptors and yields the same arrays, which
    /// is what makes a hot-reload re-registration safe.
    ///
    /// **A cycle is an ERROR and not a fixpoint.** The fixpoint is computable,
    /// and `engine-ecs-internals.md` §3 refuses it with a reason worth keeping
    /// in view: it would make `add(A)` and `add(B)` indistinguishable and leave
    /// every carrier of one carrying the other, with nothing able to undo the
    /// coupling.
    ///
    /// An unknown requisite name is also an error: `@requires(Nonexistent)`
    /// silently ignored would leave the invariant unenforceable for that
    /// component while reporting nothing.
    pub fn finalizeRequires(self: *Registry, gpa: std.mem.Allocator) !void {
        // Depth-first with a THREE-COLOUR mark: white unvisited, grey on the
        // current path, black done. Grey-on-grey is the cycle — a two-colour
        // visited set cannot tell a cycle from a diamond, and a diamond
        // (`A requires B, C`; `B requires D`; `C requires D`) is legal.
        const n = self.entries.items.len;
        const colour = try gpa.alloc(Colour, n);
        defer gpa.free(colour);
        @memset(colour, .white);

        for (self.entries.items, 0..) |*e, i| {
            if (e.closure.len != 0) {
                gpa.free(e.closure);
                e.closure = &.{};
            }
            _ = i;
        }
        for (0..n) |i| {
            if (colour[i] == .black) continue;
            try self.closeOne(gpa, @intCast(i), colour);
        }
    }

    fn closeOne(self: *Registry, gpa: std.mem.Allocator, id: ComponentId, colour: []Colour) !void {
        if (colour[id] == .black) return;
        if (colour[id] == .grey) return error.RequiresCycle;
        colour[id] = .grey;

        var acc: std.ArrayListUnmanaged(ComponentId) = .empty;
        errdefer acc.deinit(gpa);
        for (self.entries.items[id].desc.requires) |req_name| {
            const req = self.by_name.get(req_name) orelse return error.UnknownRequisite;
            if (req == id) return error.RequiresCycle; // self-requirement
            try self.closeOne(gpa, req, colour);
            try appendUnique(gpa, &acc, req);
            for (self.entries.items[req].closure) |t| try appendUnique(gpa, &acc, t);
        }
        // Ascending id: the add path applies the closure in this order, so the
        // order must be a pure function of the program and not of the walk.
        const flat = try acc.toOwnedSlice(gpa);
        std.mem.sort(ComponentId, flat, {}, std.sort.asc(ComponentId));
        self.entries.items[id].closure = flat;
        colour[id] = .black;
    }

    fn appendUnique(gpa: std.mem.Allocator, list: *std.ArrayListUnmanaged(ComponentId), v: ComponentId) !void {
        for (list.items) |x| if (x == v) return;
        try list.append(gpa, v);
    }

    /// The transitive closure of `id`'s requisites, ascending by id. Empty when
    /// `id` requires nothing or before `finalizeRequires` has run.
    pub fn requiresClosure(self: *const Registry, id: ComponentId) []const ComponentId {
        if (id >= self.entries.items.len) return &.{};
        return self.entries.items[id].closure;
    }

    /// Whether any registered component names `id` among its DIRECT requisites.
    /// The removal guard's question, and it is over direct requisites and not
    /// the closure: a component is "still required" iff something that carries
    /// it names it, and the closure of a third party does not make it required
    /// by that third party's own dependents.
    pub fn isRequiredBy(self: *const Registry, id: ComponentId, by: ComponentId) bool {
        if (by >= self.entries.items.len) return false;
        for (self.entries.items[by].closure) |t| if (t == id) return true;
        return false;
    }

    pub fn componentCount(self: *const Registry) usize {
        return self.entries.items.len;
    }

    pub fn componentSize(self: *const Registry, id: ComponentId) u16 {
        return self.entries.items[id].desc.size;
    }

    pub fn componentAlignment(self: *const Registry, id: ComponentId) u16 {
        return self.entries.items[id].desc.alignment;
    }

    pub fn componentDefaultBytes(self: *const Registry, id: ComponentId) []const u8 {
        return self.entries.items[id].desc.default_bytes;
    }

    pub fn componentName(self: *const Registry, id: ComponentId) []const u8 {
        return self.entries.items[id].desc.name;
    }

    pub fn componentFields(self: *const Registry, id: ComponentId) []const FieldDesc {
        return self.entries.items[id].desc.fields;
    }

    /// Storage backend recorded for `id` at registration. `table` for every
    /// component declared without `@storage`, and for every component
    /// registered from Zig — `registerComponent(T)` reaches no annotation, so
    /// the Etch annotation is the mode's only producer (M1.B/G0 §2.1).
    pub fn componentStorage(self: *const Registry, id: ComponentId) StorageKind {
        return self.entries.items[id].desc.storage;
    }

    /// Lookup a field on a component by name. Returns `null` if the name
    /// is not declared.
    pub fn findField(self: *const Registry, id: ComponentId, field_name: []const u8) ?FieldDesc {
        const fields = self.componentFields(id);
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, field_name)) return f;
        }
        return null;
    }

    /// Resolve a component name to its id. Returns `null` if the name is
    /// not registered. Both the primary registration name and any aliases
    /// added via `registerAlias` resolve to the same id.
    pub fn idOf(self: *const Registry, name: []const u8) ?ComponentId {
        return self.by_name.get(name);
    }

    /// Add an additional name → id mapping for an already-registered
    /// component. Used by the S5 codegen's `register()` function so the
    /// component is reachable by both its Etch name (e.g. `"Counter"`)
    /// and its Zig `@typeName(T)` (e.g. `"corpus_codegen.p01_…Counter"`).
    /// The two names share one entry — no duplication of the underlying
    /// descriptor.
    ///
    /// Errors `DuplicateComponent` if `alias_name` already maps to a
    /// different id. Idempotent when the alias already maps to `id`.
    pub fn registerAlias(self: *Registry, gpa: std.mem.Allocator, alias_name: []const u8, id: ComponentId) RegistryError!void {
        std.debug.assert(id < self.entries.items.len);
        if (self.by_name.get(alias_name)) |existing| {
            if (existing == id) return;
            return RegistryError.DuplicateComponent;
        }
        const owned = try gpa.dupe(u8, alias_name);
        errdefer gpa.free(owned);
        try self.aliases.append(gpa, owned);
        errdefer _ = self.aliases.pop();
        try self.by_name.put(gpa, owned, id);
    }
};

// ─── tests ────────────────────────────────────────────────────────────────

test "registerComponent assigns stable ComponentId" {
    const gpa = std.testing.allocator;
    var reg = Registry.init();
    defer reg.deinit(gpa);

    const Health = struct {
        current: f64 = 100.0,
        max: f64 = 100.0,
    };
    const Position = struct {
        x: f64 = 0.0,
        y: f64 = 0.0,
    };
    const id_h = try reg.registerComponent(gpa, Health);
    const id_p = try reg.registerComponent(gpa, Position);
    try std.testing.expectEqual(@as(ComponentId, 0), id_h);
    try std.testing.expectEqual(@as(ComponentId, 1), id_p);
}

test "registerComponent rejects duplicate registration" {
    const gpa = std.testing.allocator;
    var reg = Registry.init();
    defer reg.deinit(gpa);

    const A = struct { x: f64 = 0.0 };
    _ = try reg.registerComponent(gpa, A);
    try std.testing.expectError(error.DuplicateComponent, reg.registerComponent(gpa, A));
}

test "componentSize matches @sizeOf" {
    const gpa = std.testing.allocator;
    var reg = Registry.init();
    defer reg.deinit(gpa);

    const Health = struct {
        current: f64 = 100.0,
        max: f64 = 100.0,
    };
    const id = try reg.registerComponent(gpa, Health);
    try std.testing.expectEqual(@as(u16, @intCast(@sizeOf(Health))), reg.componentSize(id));
}

test "componentDefaultBytes initializes per registered default" {
    const gpa = std.testing.allocator;
    var reg = Registry.init();
    defer reg.deinit(gpa);

    const Health = struct {
        current: f64 = 100.0,
        max: f64 = 100.0,
    };
    const id = try reg.registerComponent(gpa, Health);
    const bytes = reg.componentDefaultBytes(id);
    try std.testing.expectEqual(@as(usize, @sizeOf(Health)), bytes.len);

    // Reading the bytes back as a Health value yields the defaults.
    var buf: Health = undefined;
    @memcpy(std.mem.asBytes(&buf), bytes);
    try std.testing.expectEqual(@as(f64, 100.0), buf.current);
    try std.testing.expectEqual(@as(f64, 100.0), buf.max);
}

test "registerAlias maps additional name to same id" {
    const gpa = std.testing.allocator;
    var reg = Registry.init();
    defer reg.deinit(gpa);

    const Foo = struct { v: i64 = 0 };
    const id = try reg.registerComponent(gpa, Foo);
    try reg.registerAlias(gpa, "Foo", id);

    try std.testing.expectEqual(@as(?ComponentId, id), reg.idOf("Foo"));
    try std.testing.expectEqual(@as(?ComponentId, id), reg.idOf(@typeName(Foo)));
}

test "registerAlias is idempotent on identical (name, id) pair" {
    const gpa = std.testing.allocator;
    var reg = Registry.init();
    defer reg.deinit(gpa);

    const Foo = struct { v: i64 = 0 };
    const id = try reg.registerComponent(gpa, Foo);
    try reg.registerAlias(gpa, "Foo", id);
    try reg.registerAlias(gpa, "Foo", id);
}

test "registerAlias rejects conflicting alias" {
    const gpa = std.testing.allocator;
    var reg = Registry.init();
    defer reg.deinit(gpa);

    const Foo = struct { v: i64 = 0 };
    const Bar = struct { v: i64 = 0 };
    const id_foo = try reg.registerComponent(gpa, Foo);
    const id_bar = try reg.registerComponent(gpa, Bar);
    try reg.registerAlias(gpa, "Shared", id_foo);
    try std.testing.expectError(error.DuplicateComponent, reg.registerAlias(gpa, "Shared", id_bar));
}

test "registerComponentRaw and findField roundtrip" {
    const gpa = std.testing.allocator;
    var reg = Registry.init();
    defer reg.deinit(gpa);

    var default_bytes: [16]u8 = [_]u8{0} ** 16;
    // Inject a custom default for the second field (offset 8): 42.0_f64.
    @memcpy(default_bytes[8..16], std.mem.asBytes(&@as(f64, 42.0)));
    const id = try reg.registerComponentRaw(gpa, .{
        .name = "MyComp",
        .size = 16,
        .alignment = 8,
        .default_bytes = &default_bytes,
        .fields = &[_]FieldDesc{
            .{ .name = "a", .offset = 0, .kind = .float_ },
            .{ .name = "b", .offset = 8, .kind = .float_ },
        },
    });

    try std.testing.expectEqual(@as(?ComponentId, id), reg.idOf("MyComp"));
    const f = reg.findField(id, "b").?;
    try std.testing.expectEqual(@as(u16, 8), f.offset);
    try std.testing.expectEqual(FieldKind.float_, f.kind);
    try std.testing.expect(reg.findField(id, "missing") == null);
}
