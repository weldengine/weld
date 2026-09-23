//! FROZEN — see `engine-phase-0-criteria.md` C0.5.
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
//! Coexists with the comptime `(Transform, Velocity)` archetype defined
//! in `world.zig` — additive, never replaces it. The struct stores no
//! allocator; per `engine-zig-conventions.md` §3, the gpa is passed at
//! every mutating op.

const std = @import("std");

/// `EntityId` (`packed struct(u64)`) — the storage type of a `.entity_` field.
/// Imported only for `FieldKind.fromZigType`; `entity.zig` imports
/// nothing of `registry.zig`, so this is acyclic.
const EntityId = @import("entity.zig").EntityId;

/// Stable identifier assigned at registration. The first registered
/// component gets `ComponentId(0)`; subsequent registrations get the next
/// integer. Stability across runs is *not* guaranteed (it would require an
/// out-of-band scheme like StableId).
pub const ComponentId = u32;

/// Storage backend of a component — the closed two-variant domain owned by
/// `engine-ecs-internals.md` §2 (*Table vs SparseSet*). `table` is the default
/// and was for a time the only backend implemented; `sparse` is the explicit
/// opt-in a declaration carries through `@storage(.sparse)`.
///
/// Declared HERE and nowhere else: the Etch front-end validates through
/// `fromName` rather than re-listing the two spellings, so the domain has one
/// text form in the tree (`etch-resolver-types.md` §13.3.1).
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

/// Coarse-grained tag for primitive fields, telling the interpreter how to read
/// or write raw bytes. The Etch subset exercises only `int_`, `float_`, `bool_`.
///
/// `sizeBytes` for `.string_` must equal `@sizeOf(persistent.StringSlot)`, and
/// for the three collection kinds `@sizeOf(persistent.CollectionSlot)`; both are
/// asserted in `ecs_bridge.zig`.
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
    /// `StringSlot`). **Resource-only by construction**: the Etch
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
    /// The exact mirror of `.string_`/`.enum_` (resource-only) —
    /// `fieldKindFromTypeName` emits `.entity_` only for the `.component` origin.
    /// An unassigned / dangling slot holds `EntityId.dead` (all-ones); at scene
    /// cook the slot is written `dead` and an entity→entity reference is carried by
    /// the Cross-references Table, resolved to the target's handle at load.
    entity_,
    /// A dynamic-array field slot (`T[]`): a `CollectionSlot` (`{ ptr: u64 }`,
    /// 8 bytes, 8-aligned) holding the persistent-heap pointer of the owned
    /// container block. **Resource-only by construction** like `.string_`. Tier 0
    /// copies the 8 raw slot bytes; the Etch runtime owns the container.
    array_,
    /// A map field slot (`[K: V]`). Same 8-byte `CollectionSlot`
    /// discipline and resource-only gating as `.array_`.
    map_,
    /// A set field slot (`Set<T>`). Same 8-byte `CollectionSlot`
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
            .string_ => 16,
            .enum_ => @sizeOf(u32),
            .entity_ => @sizeOf(EntityId),
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
    /// For a `.enum_` field: the Etch-interned id of the declared enum type
    /// name, opaque to Tier 0 and never dereferenced here. An id and not a
    /// string, so it needs no allocation and cannot dangle when the AST dies
    /// before the registry. `0` and unused for every other kind.
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
    /// `@storage(.sparse)`. **Never part of on-disk identity**: a `SchemaEntry`
    /// carries name, size and alignment, and the mode comes from this runtime
    /// registry at load, so a component changing mode invalidates no cooked scene
    /// and demands no re-cook.
    storage: StorageKind = .table,
    /// DIRECT requisites, by NAME — the variadic `@requires(A, B)` list. Names
    /// and not ids because a declaration may name a component registered LATER:
    /// Etch admits forward references, so resolving at registration would make
    /// the closure depend on declaration order. The transitive closure is
    /// computed once by `finalizeRequires` and read per add, never re-walked per
    /// add (`engine-ecs-internals.md` §3).
    requires: []const []const u8 = &.{},
    /// Identity the other inputs of `schemaDigestOf` cannot express:
    /// `TagTable.contentDigest` on the builtin `TagSet`, `0` everywhere else.
    content_digest: u64 = 0,
};

/// The 64-bit schema identity of `desc` (`engine-ecs-internals.md` §13), over
/// `(name, size, alignment, [(field name, kind, offset) in declaration order],
/// content_digest)`.
///
/// - **Derived at REGISTRATION, not at `comptime`.** A component declared in
///   Etch has no Zig type when the engine is compiled.
/// - **Size and alignment are IN the tuple**, not only the fields: a component
///   with no named field and a zero `content_digest` is discriminated by
///   nothing else.
/// - **Storage mode is OUT of it.** `table` or `sparse` is a property of this
///   registry and not of the layout (`ARCH-005`), so changing it provokes
///   neither refusal nor migration.
/// - **`requires` is OUT of it too**: it changes no layout, so hashing it would
///   refuse a reload as a layout change that did not happen. A reload editing
///   only `@requires` passes, and nothing re-checks live entities against a newly
///   added requisite.
///
/// Sensitive to a field added in EXISTING padding, since offsets enter the hash.
///
/// **Not the Tier 0 RTTI digest, and never compared with it**: they run over
/// different field descriptors, with different `kind` domains and offset widths.
/// A reload confrontation is always between two values of the SAME computation.
pub fn schemaDigestOf(desc: ComponentDesc) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(desc.name);
    h.update(std.mem.asBytes(&desc.size));
    h.update(std.mem.asBytes(&desc.alignment));
    for (desc.fields) |f| {
        h.update(f.name);
        const k: u16 = @intFromEnum(f.kind);
        h.update(std.mem.asBytes(&k));
        h.update(std.mem.asBytes(&f.offset));
    }
    h.update(std.mem.asBytes(&desc.content_digest));
    return h.final();
}

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
    /// once by `finalizeRequires`. Empty until finalisation, and empty forever
    /// for a component with no requisites. Beside the descriptor rather than
    /// inside it: the descriptor is what a CALLER supplies, this is what the
    /// registry DERIVES, and one question gets one authority.
    closure: []const ComponentId = &.{},
    /// Schema identity, derived at registration — beside the descriptor for the
    /// same reason `closure` is.
    schema_digest: u64 = 0,
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
    /// and its Zig type's `@typeName(T)` (so the codegen's comptime
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

        const requires_owned = try gpa.alloc([]const u8, desc.requires.len);
        errdefer gpa.free(requires_owned);
        var dup_req: usize = 0;
        errdefer for (requires_owned[0..dup_req]) |r| gpa.free(r);
        for (desc.requires, 0..) |r, i| {
            requires_owned[i] = try gpa.dupe(u8, r);
            dup_req += 1;
        }

        try self.entries.append(gpa, .{
            .desc = .{
                .name = name_owned,
                .size = desc.size,
                .alignment = desc.alignment,
                .default_bytes = default_owned,
                .fields = fields_owned,
                .storage = desc.storage,
                .requires = requires_owned,
            },
            .schema_digest = schemaDigestOf(desc),
        });
        errdefer _ = self.entries.pop();

        try self.by_name.put(gpa, name_owned, id);
        return id;
    }

    /// The schema identity recorded for `id` at registration, or `null` when `id`
    /// names no entry. A reload compares it with `schemaDigestOf` of the
    /// CANDIDATE — two values of one computation, never against the RTTI digest.
    pub fn schemaDigest(self: *const Registry, id: ComponentId) ?u64 {
        if (id >= self.entries.items.len) return null;
        return self.entries.items[id].schema_digest;
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

    /// The three-colour mark of the closure walk. Declared ONCE: the same
    /// `enum(u8) { … }` written at two sites is two distinct types.
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
    ///
    /// The walk is depth-first with a THREE-colour mark — white unvisited, grey
    /// on the current path, black done — and grey-on-grey is the cycle. Do NOT
    /// reduce it to a two-colour visited set: that cannot tell a cycle from a
    /// diamond (`A requires B, C`; `B requires D`; `C requires D`), and a
    /// diamond is legal.
    pub fn finalizeRequires(self: *Registry, gpa: std.mem.Allocator) !void {
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

    /// Sorts the closure ASCENDING by id: the add path applies it in that order, so
    /// the order must be a pure function of the program and never of the walk.
    fn closeOne(self: *Registry, gpa: std.mem.Allocator, id: ComponentId, colour: []Colour) !void {
        if (colour[id] == .black) return;
        if (colour[id] == .grey) return error.RequiresCycle;
        colour[id] = .grey;

        var acc: std.ArrayListUnmanaged(ComponentId) = .empty;
        errdefer acc.deinit(gpa);
        for (self.entries.items[id].desc.requires) |req_name| {
            const req = self.by_name.get(req_name) orelse return error.UnknownRequisite;
            if (req == id) return error.RequiresCycle;
            try self.closeOne(gpa, req, colour);
            try appendUnique(gpa, &acc, req);
            for (self.entries.items[req].closure) |t| try appendUnique(gpa, &acc, t);
        }
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

    /// Whether `by` reaches `id` through its `@requires` CLOSURE — transitive,
    /// not the direct list. That is the removal guard's question, and the direct
    /// list would answer it wrongly: with `A @requires(B)` and `B @requires(C)`,
    /// an entity carrying `A` cannot lose `C` without breaking `B` and therefore
    /// `A`. Do NOT narrow this to `desc.requires`: the guard would then pass a
    /// removal that leaves a requisite of a requisite missing.
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
    /// the Etch annotation is the mode's only producer.
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
    /// component. Used by the codegen's `register()` function so the
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

test "the digest is blind to the default bytes" {
    // A DEPENDENT RESTS ON THIS. `interp.schemaDigestFor` passes `&.{}` for
    // `default_bytes` so the hot-reload pre-validation pass can confront every
    // declared schema WITHOUT materialising a single default — materialising them
    // allocates immortal persistent blocks, which a pass that may refuse must not
    // do. That shortcut is only sound while this property holds.
    //
    // If a future change makes the digest read the defaults, this test fires and
    // names where to go: `schemaDigestFor` must then be given the real bytes, and
    // the pre-pass must materialise them and own their rollback.
    const fields = [_]FieldDesc{.{ .name = "v", .offset = 0, .kind = .int_ }};
    const a: ComponentDesc = .{
        .name = "T",
        .size = 8,
        .alignment = 8,
        .default_bytes = &[_]u8{0} ** 8,
        .fields = &fields,
    };
    var b = a;
    b.default_bytes = &[_]u8{7} ** 8;
    try std.testing.expectEqual(schemaDigestOf(a), schemaDigestOf(b));

    // NON-VACUITY: the digest is not blind to everything. A field offset moves it,
    // so the equality above is a property of `default_bytes` and not of a hash
    // that ignores its input.
    var c = a;
    const moved = [_]FieldDesc{.{ .name = "v", .offset = 4, .kind = .int_ }};
    c.fields = &moved;
    try std.testing.expect(schemaDigestOf(a) != schemaDigestOf(c));
}

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
