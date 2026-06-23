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

/// Stable identifier assigned at registration. The first registered
/// component gets `ComponentId(0)`; subsequent registrations get the next
/// integer. Stability across runs is *not* guaranteed (it would require an
/// out-of-band scheme like StableId — Phase 2).
pub const ComponentId = u32;

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
    /// pointing into the Etch persistent heap (`src/etch/persistent.zig`,
    /// `StringSlot`). **Resource-only by construction** (M1.0.3): the Etch
    /// validator rejects `string` on `component` and `fieldKindFromTypeName`
    /// only emits this kind for the `.resource` origin, so no component can ever
    /// carry it — the component SoA/POD invariant (`engine-spec.md` §4) is
    /// untouched. Tier-0 stays string-agnostic: it stores/copies the 16 raw
    /// slot bytes; the Etch runtime owns the pointed-to bytes' lifetime.
    string_,

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
};

/// Full descriptor stored by the registry. `default_bytes` is `size` bytes
/// long and gets memcpy'd into each freshly spawned slot.
pub const ComponentDesc = struct {
    name: []const u8,
    size: u16,
    alignment: u16,
    default_bytes: []const u8,
    fields: []const FieldDesc,
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
            fields_owned[i] = .{ .name = fname_owned, .offset = f.offset, .kind = f.kind };
            dup_count += 1;
        }

        try self.entries.append(gpa, .{ .desc = .{
            .name = name_owned,
            .size = desc.size,
            .alignment = desc.alignment,
            .default_bytes = default_owned,
            .fields = fields_owned,
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
