//! S4 Etch ↔ ECS adapter — translates the interpreter's name-based view of
//! the world (`entity.get(Health).current`, `when resource Score changed`)
//! onto the Tier 0 byte-oriented surface (`Registry`, `DynamicArchetype`,
//! `ResourceStore`).
//!
//! The bridge owns the mapping `Etch component / resource name → ComponentId`
//! built once at program load. It does not own the registry or the world —
//! both are borrowed.

const std = @import("std");
const value_mod = @import("value.zig");

const weld_core = @import("weld_core");
// M1.0.5 — persistent heap moved to Tier 0 (`src/core/memory`); reach it via weld_core.
const persistent = weld_core.memory.persistent;
const RegistryNS = weld_core.ecs.registry;
const Registry = RegistryNS.Registry;
const ComponentId = RegistryNS.ComponentId;
const FieldKind = RegistryNS.FieldKind;
const FieldDesc = RegistryNS.FieldDesc;
const World = weld_core.ecs.world.World;
const DynamicArchetype = weld_core.ecs.archetype_dynamic.DynamicArchetype;
const Chunk = weld_core.ecs.archetype_dynamic.Chunk;
const ResourceStore = weld_core.ecs.resources.ResourceStore;
const CoreEntityId = weld_core.ecs.entity.EntityId;
const Tick = weld_core.ecs.tick.Tick;
// M1.0.9 — runtime extension resolution (name → cooked `.prefab.bin` bytes), the
// same interface the scene loader receives. Held (optional, borrowed) by the
// bridge so a name-only Etch `entity.activate_extension("X")` resolves at runtime.
const ExtensionResolver = weld_core.scene.loader.ExtensionResolver;

// Module-private aliases shadowing the value module — `EntityId`,
// `Value`, `ComponentRef` are not exported because no external caller
// drives the bridge by hand; they enter the rule body through
// `interp.zig` which already has its own re-exports. `EntityId` here
// is the u64 wire form stored in `Value.entity_id`; the bridge bitcasts
// it back to the core `(index, generation)` struct when reaching into
// the world.
const EntityId = value_mod.EntityId;
const Value = value_mod.Value;
const ComponentRef = value_mod.ComponentRef;

comptime {
    // The `.string_` slot stride the registry reports must match the canonical
    // `StringSlot` layout (`persistent.zig`) the bridge reads/writes — one
    // source of truth across the Tier-0 / Etch boundary.
    std.debug.assert(@sizeOf(persistent.StringSlot) == FieldKind.string_.sizeBytes());
    // Same one-source-of-truth guard for the collection slot stride (M1.0.17):
    // `CollectionSlot { ptr }` must match `.array_`/`.map_`/`.set_` sizeBytes.
    std.debug.assert(@sizeOf(persistent.CollectionSlot) == FieldKind.array_.sizeBytes());
    std.debug.assert(@sizeOf(persistent.CollectionSlot) == FieldKind.map_.sizeBytes());
    std.debug.assert(@sizeOf(persistent.CollectionSlot) == FieldKind.set_.sizeBytes());
}

/// Surfaced so callers of `Bridge.dispatchEntityGet` /
/// `dispatchResourceGet` can map a name-resolution failure into a
/// typed E-code without depending on `Registry`'s raw lookup return.
pub const BridgeError = error{
    UnknownEntity,
    UnknownComponent,
    UnknownResource,
    UnknownField,
    TypeMismatch,
    OutOfMemory,
};

/// One bridge instance per Etch program run. Lives for the same
/// duration as the `Interpreter` that owns it; the registry it
/// targets is borrowed (not owned) — the bridge never frees it.
pub const Bridge = struct {
    /// Etch component name → registry id (for components). Owns the keys
    /// (strings dup'd at registration time so the lifetime survives the
    /// AST's StringPool).
    components: std.StringHashMapUnmanaged(ComponentId) = .empty,
    /// Etch resource name → registry id.
    resources: std.StringHashMapUnmanaged(ComponentId) = .empty,

    /// M1.0.9 — optional runtime extension resolver (name → cooked `.prefab.bin`
    /// bytes). Borrowed, not owned — set when the interpreter is bound, used by
    /// `entity.activate_extension` / `deactivate_extension`. Absent → those
    /// methods fail with `error.MissingExtensionResolver`.
    ext_resolver: ?ExtensionResolver = null,

    pub fn init() Bridge {
        return .{};
    }

    pub fn deinit(self: *Bridge, gpa: std.mem.Allocator) void {
        var c_it = self.components.keyIterator();
        while (c_it.next()) |k| gpa.free(k.*);
        self.components.deinit(gpa);
        var r_it = self.resources.keyIterator();
        while (r_it.next()) |k| gpa.free(k.*);
        self.resources.deinit(gpa);
        self.* = undefined;
    }

    pub fn mapComponent(self: *Bridge, gpa: std.mem.Allocator, name: []const u8, id: ComponentId) !void {
        const owned = try gpa.dupe(u8, name);
        errdefer gpa.free(owned);
        try self.components.put(gpa, owned, id);
    }

    pub fn mapResource(self: *Bridge, gpa: std.mem.Allocator, name: []const u8, id: ComponentId) !void {
        const owned = try gpa.dupe(u8, name);
        errdefer gpa.free(owned);
        try self.resources.put(gpa, owned, id);
    }

    pub fn componentIdOf(self: *const Bridge, name: []const u8) ?ComponentId {
        return self.components.get(name);
    }

    pub fn resourceIdOf(self: *const Bridge, name: []const u8) ?ComponentId {
        return self.resources.get(name);
    }

    // ─── Component access ────────────────────────────────────────────────

    /// Resolve `entity.get(T)` (or `get_mut`). Returns a `ComponentRef`
    /// pointing at the slot in the archetype's chunk.
    pub fn componentRefOf(
        world: *World,
        entity: EntityId,
        component_id: ComponentId,
        mutable: bool,
    ) BridgeError!ComponentRef {
        const core_id: CoreEntityId = @bitCast(entity);
        const loc = world.dynamicLocation(core_id) orelse return BridgeError.UnknownEntity;
        // The MODE decides the arm, and the presence question is the routed one:
        // asking `arch.componentIndex` for a sparse id answers null, which is
        // what made a sparse component look ABSENT before G5 — the same error a
        // caller gets for a component the entity really does not carry.
        if (!world.hasComponentDyn(core_id, component_id)) return BridgeError.UnknownComponent;
        if (world.storageOf(component_id) == .sparse) {
            return .{
                .component_id = component_id,
                .mutable = mutable,
                .where = .{ .sparse = entity },
            };
        }
        const arch = world.dynamicArchetype(loc.archetype_idx);
        const chunk = arch.chunks.items[loc.chunk_idx];
        return .{
            .component_id = component_id,
            .mutable = mutable,
            .where = .{ .table = .{ .chunk_ptr = chunk, .slot = loc.slot } },
        };
    }

    /// Read a field from a component slot as a `Value` (auto-tagged from
    /// the field's `FieldKind`).
    /// The component's bytes for this handle, whichever backend holds them.
    ///
    /// ONE place, not four: the three accessors below each re-derived the
    /// archetype from `chunk_ptr` and asked for the column, so the bimodal
    /// decision would have had to be written three times — and a change landing
    /// in one site and not its siblings is this milestone's dominant defect
    /// shape.
    fn refBytes(world: *World, ref: ComponentRef) BridgeError![]u8 {
        switch (ref.where) {
            .table => |t| {
                const chunk: *Chunk = @ptrCast(@alignCast(t.chunk_ptr));
                const arch = world.dynamicArchetype(chunk.header().archetype_id);
                const idx = arch.componentIndex(ref.component_id) orelse return BridgeError.UnknownComponent;
                return arch.componentSlot(chunk, idx, t.slot);
            },
            .sparse => |wire| {
                const core_id: CoreEntityId = @bitCast(wire);
                // Through the World-level entry, which G3 made bimodal and which
                // deliberately does NOT stamp a change — the table arm does not
                // either, and `markComponentChanged` owns the stamp.
                return world.componentBytes(core_id, ref.component_id) orelse
                    BridgeError.UnknownComponent;
            },
        }
    }

    pub fn readComponentField(
        registry: *const Registry,
        ref: ComponentRef,
        world: *World,
        field_name: []const u8,
    ) BridgeError!Value {
        const field = registry.findField(ref.component_id, field_name) orelse return BridgeError.UnknownField;
        const slot_bytes = try refBytes(world, ref);
        const field_bytes = slot_bytes[field.offset .. field.offset + @as(u16, @intCast(field.kind.sizeBytes()))];
        return readBytesAsValue(field.kind, field_bytes);
    }

    /// Write a field of a component slot from a `Value` (auto-coerced
    /// against the field's `FieldKind`).
    pub fn writeComponentField(
        registry: *const Registry,
        ref: ComponentRef,
        world: *World,
        field_name: []const u8,
        v: Value,
    ) BridgeError!void {
        std.debug.assert(ref.mutable);
        const field = registry.findField(ref.component_id, field_name) orelse return BridgeError.UnknownField;
        const slot_bytes = try refBytes(world, ref);
        const field_bytes = slot_bytes[field.offset .. field.offset + @as(u16, @intCast(field.kind.sizeBytes()))];
        try writeValueAsBytes(field.kind, field_bytes, v);
    }

    /// Stamp `ref`'s slot as modified at `tick` — writes the `changed_tick`
    /// sidecar + sets the dirty bit (M0.8 E3 change detection,
    /// `engine-ecs-internals.md` §5). Called by the interpreter right after a
    /// `writeComponentField` when the program uses `changed` filters. This is
    /// the SAME logical point (post component write) at which the codegen emits
    /// `markChanged`, so the stamped tick is identical across backends → the
    /// `changed` differential is byte-exact by construction.
    pub fn markComponentChanged(world: *World, ref: ComponentRef, tick: Tick) void {
        // Two arms rather than `World.markComponentChangedDyn`, which would be
        // shorter and would DROP the explicit `tick`. The sparse storage's own
        // `markChanged` takes a tick too, so the parameter survives on both
        // sides and the caller's contract does not move.
        switch (ref.where) {
            .table => |t| {
                const chunk: *Chunk = @ptrCast(@alignCast(t.chunk_ptr));
                const arch = world.dynamicArchetype(chunk.header().archetype_id);
                const idx = arch.componentIndex(ref.component_id) orelse return;
                arch.markChanged(chunk, idx, t.slot, tick);
            },
            .sparse => |wire| {
                const core_id: CoreEntityId = @bitCast(wire);
                if (world.sparse_stores.get(ref.component_id)) |store| store.markChanged(core_id, tick);
            },
        }
    }

    // ─── Resource access ─────────────────────────────────────────────────

    pub fn readResourceField(
        registry: *const Registry,
        store: *const ResourceStore,
        resource_id: ComponentId,
        field_name: []const u8,
    ) BridgeError!Value {
        const bytes = store.getResource(resource_id) orelse return BridgeError.UnknownResource;
        const field = registry.findField(resource_id, field_name) orelse return BridgeError.UnknownField;
        const slice = bytes[field.offset .. field.offset + @as(u16, @intCast(field.kind.sizeBytes()))];
        // Enum read (M1.0.3 E3): rebuild a typed `enum_value` from the slot's
        // discriminant + the declared enum type's interned id on `FieldDesc`
        // (the byte-only `readBytesAsValue` has no access to the latter). The
        // `type_name` id matches the rest of the interpreter's enum machinery
        // (`enum_decls` is keyed by it), so the value compares/matches correctly.
        if (field.kind == .enum_) {
            var disc: u32 = 0;
            @memcpy(std.mem.asBytes(&disc), slice[0..@sizeOf(u32)]);
            return .{ .enum_value = .{ .type_name = field.enum_type_name_id, .variant = disc } };
        }
        return readBytesAsValue(field.kind, slice);
    }

    pub fn writeResourceField(
        registry: *const Registry,
        store: *ResourceStore,
        resource_id: ComponentId,
        field_name: []const u8,
        v: Value,
    ) BridgeError!void {
        const field = registry.findField(resource_id, field_name) orelse return BridgeError.UnknownField;
        const bytes = store.getMutResource(resource_id) orelse return BridgeError.UnknownResource;
        const slice = bytes[field.offset .. field.offset + @as(u16, @intCast(field.kind.sizeBytes()))];
        try writeValueAsBytes(field.kind, slice, v);
    }

    /// Promote `bytes` into a fresh persistent allocation and store it in a
    /// resource `.string_` slot (`etch-memory-model.md` §6.7 rule-arena →
    /// persistent promotion). The interpreter resolves the incoming string's
    /// bytes (literal / rule-arena) and hands them here with the allocator.
    ///
    /// Order is load-bearing (M1.0.3 E2 review guard, anti use-after-free): read
    /// the old slot → alloc + copy the new value → write the new slot → only then
    /// `decref` the *previous* slot value (never after overwriting it). The
    /// previous value's `decref` is a no-op when it was the immortal default. An
    /// empty write stores `{ptr=0,len=0}` and allocates nothing.
    pub fn promoteResourceString(
        gpa: std.mem.Allocator,
        registry: *const Registry,
        store: *ResourceStore,
        resource_id: ComponentId,
        field_name: []const u8,
        bytes: []const u8,
    ) BridgeError!void {
        const field = registry.findField(resource_id, field_name) orelse return BridgeError.UnknownField;
        std.debug.assert(field.kind == .string_);
        const buf = store.getMutResource(resource_id) orelse return BridgeError.UnknownResource;
        const slot = buf[field.offset .. field.offset + @sizeOf(persistent.StringSlot)];

        var old: persistent.StringSlot = undefined;
        @memcpy(std.mem.asBytes(&old), slot);

        var new_slot: persistent.StringSlot = .{};
        if (bytes.len > 0) {
            const block = persistent.alloc(gpa, persistent.type_string, bytes.len) catch return BridgeError.OutOfMemory;
            @memcpy(block[0..bytes.len], bytes);
            new_slot = .{ .ptr = @intFromPtr(block), .len = @intCast(bytes.len) };
        }
        @memcpy(slot, std.mem.asBytes(&new_slot));

        if (old.ptr != 0) persistent.decref(gpa, @ptrFromInt(old.ptr));
    }

    /// Swap a resource collection field's slot to a freshly-built persistent
    /// container block (M1.0.17 E2, whole-field reassignment `get_mut(R).xs =
    /// [...]`). The interpreter builds `new_block` (a `type_array` block whose
    /// elements are deep-copied, strings promoted — it owns the collections store
    /// + string helpers this needs); the bridge does only the slot mechanics, in
    /// the load-bearing order: read the old slot → write the new slot → decref the
    /// previous block (never before the new one is in place). The previous block's
    /// drop (registered by the interpreter) releases its string elements.
    pub fn promoteResourceCollection(
        gpa: std.mem.Allocator,
        registry: *const Registry,
        store: *ResourceStore,
        resource_id: ComponentId,
        field_name: []const u8,
        new_block: [*]u8,
    ) BridgeError!void {
        const field = registry.findField(resource_id, field_name) orelse return BridgeError.UnknownField;
        std.debug.assert(field.kind == .array_ or field.kind == .map_ or field.kind == .set_);
        const buf = store.getMutResource(resource_id) orelse return BridgeError.UnknownResource;
        const slot = buf[field.offset .. field.offset + @sizeOf(persistent.CollectionSlot)];

        var old: persistent.CollectionSlot = undefined;
        @memcpy(std.mem.asBytes(&old), slot);

        const new_slot = persistent.CollectionSlot{ .ptr = @intFromPtr(new_block) };
        @memcpy(slot, std.mem.asBytes(&new_slot));

        if (old.ptr != 0) persistent.decref(gpa, @ptrFromInt(old.ptr));
    }
};

// ─── Byte ↔ Value conversion ─────────────────────────────────────────────

/// Decode the on-storage byte representation of a field into the
/// interpreter's tagged `Value`. The width to read is dictated by
/// `kind` — the slice must already be sized to the field's column
/// stride.
pub fn readBytesAsValue(kind: FieldKind, bytes: []const u8) Value {
    return switch (kind) {
        .int_ => blk: {
            var v: i64 = 0;
            @memcpy(std.mem.asBytes(&v), bytes[0..@sizeOf(i64)]);
            break :blk .{ .int_ = v };
        },
        .float_ => blk: {
            var v: f64 = 0;
            @memcpy(std.mem.asBytes(&v), bytes[0..@sizeOf(f64)]);
            break :blk .{ .float_ = v };
        },
        .bool_ => .{ .bool_ = bytes[0] != 0 },
        .i32_ => blk: {
            var v: i32 = 0;
            @memcpy(std.mem.asBytes(&v), bytes[0..@sizeOf(i32)]);
            break :blk .{ .int_ = v };
        },
        .u32_ => blk: {
            var v: u32 = 0;
            @memcpy(std.mem.asBytes(&v), bytes[0..@sizeOf(u32)]);
            break :blk .{ .int_ = @intCast(v) };
        },
        .f32_ => blk: {
            var v: f32 = 0;
            @memcpy(std.mem.asBytes(&v), bytes[0..@sizeOf(f32)]);
            break :blk .{ .float_ = v };
        },
        .f64_ => blk: {
            var v: f64 = 0;
            @memcpy(std.mem.asBytes(&v), bytes[0..@sizeOf(f64)]);
            break :blk .{ .float_ = v };
        },
        // Borrowed read (M1.0.3 E2, resource-only): decode the `{ptr,len}` slot
        // into a `string_persistent` view without incref'ing the block. `ptr==0`
        // ⇔ empty string (the no-default / empty-write representation).
        .string_ => blk: {
            var ss: persistent.StringSlot = undefined;
            @memcpy(std.mem.asBytes(&ss), bytes[0..@sizeOf(persistent.StringSlot)]);
            break :blk .{ .string_persistent = .{ .ptr = ss.ptr, .len = ss.len } };
        },
        // Enum reads need the declared type's id (on `FieldDesc`), which this
        // byte-only decoder lacks — `readResourceField` handles `.enum_` before
        // delegating here, and components never carry `.enum_` (validator-gated).
        // Proven invariant: this arm is never reached.
        .enum_ => unreachable,
        // Collection read (M1.0.17 E2): decode the `CollectionSlot { ptr }` into a
        // borrowed `.array_persistent` view over the owned container block (no
        // incref — the resource, hence the block, outlives the rule body). `ptr`
        // is never 0 for a live field (the empty collection is a real block
        // allocated at `addResource`). Components never carry a collection kind
        // (validator-gated, resource-only), so this is reached only via
        // `readResourceField`.
        .array_ => blk: {
            var cs: persistent.CollectionSlot = undefined;
            @memcpy(std.mem.asBytes(&cs), bytes[0..@sizeOf(persistent.CollectionSlot)]);
            break :blk .{ .array_persistent = cs.ptr };
        },
        // Map read (M1.0.17 E3): same borrowed-view decode as `.array_`.
        .map_ => blk: {
            var cs: persistent.CollectionSlot = undefined;
            @memcpy(std.mem.asBytes(&cs), bytes[0..@sizeOf(persistent.CollectionSlot)]);
            break :blk .{ .map_persistent = cs.ptr };
        },
        // Set read (M1.0.17 E4): same borrowed-view decode.
        .set_ => blk: {
            var cs: persistent.CollectionSlot = undefined;
            @memcpy(std.mem.asBytes(&cs), bytes[0..@sizeOf(persistent.CollectionSlot)]);
            break :blk .{ .set_persistent = cs.ptr };
        },
        // Entity field (M1.0.6 E4): decode the 8-byte `EntityId` (`value.zig`'s
        // `EntityId` is a `u64` that shares the bit pattern of core `EntityId`,
        // packed `struct(u64)`; `invalid_entity`/`dead` == all-ones). The runtime
        // interp read path returns it as `Value.entity_id`.
        .entity_ => blk: {
            var v: value_mod.EntityId = 0;
            @memcpy(std.mem.asBytes(&v), bytes[0..@sizeOf(value_mod.EntityId)]);
            break :blk .{ .entity_id = v };
        },
    };
}

/// Encode an interpreter `Value` into the on-storage byte representation of a
/// field. `bytes` must already be sized to the field's column stride.
///
/// Returns `error.TypeMismatch` when `v`'s tag is incompatible with the
/// field's `kind` (M0.5 item 10 — resolves the S4 closing-debt
/// `D-S4-ecs-bridge-panic`: a type incoherence is now a recoverable typed
/// error propagated to the caller instead of a runtime `@panic`).
pub fn writeValueAsBytes(kind: FieldKind, bytes: []u8, v: Value) BridgeError!void {
    switch (kind) {
        .int_ => {
            const x: i64 = switch (v) {
                .int_ => |a| a,
                else => return error.TypeMismatch,
            };
            @memcpy(bytes[0..@sizeOf(i64)], std.mem.asBytes(&x));
        },
        .float_, .f64_ => {
            const x: f64 = switch (v) {
                .float_ => |a| a,
                .int_ => |a| @floatFromInt(a),
                else => return error.TypeMismatch,
            };
            @memcpy(bytes[0..@sizeOf(f64)], std.mem.asBytes(&x));
        },
        .bool_ => {
            const b: bool = switch (v) {
                .bool_ => |a| a,
                else => return error.TypeMismatch,
            };
            bytes[0] = if (b) 1 else 0;
        },
        .i32_ => {
            const x: i32 = switch (v) {
                .int_ => |a| @intCast(a),
                else => return error.TypeMismatch,
            };
            @memcpy(bytes[0..@sizeOf(i32)], std.mem.asBytes(&x));
        },
        .u32_ => {
            const x: u32 = switch (v) {
                .int_ => |a| @intCast(a),
                else => return error.TypeMismatch,
            };
            @memcpy(bytes[0..@sizeOf(u32)], std.mem.asBytes(&x));
        },
        .f32_ => {
            const x: f32 = switch (v) {
                .float_ => |a| @floatCast(a),
                .int_ => |a| @floatFromInt(a),
                else => return error.TypeMismatch,
            };
            @memcpy(bytes[0..@sizeOf(f32)], std.mem.asBytes(&x));
        },
        // A `.string_` write is a persistent promotion (alloc + copy + decref of
        // the previous slot), which needs an allocator and the old slot bytes —
        // the POD byte-encoder has neither. Resource string writes route through
        // `promoteResourceString`; components never carry `.string_` (validator-
        // gated). Reaching here is a bug, surfaced as a typed error, never a panic.
        .string_ => return error.TypeMismatch,
        // Enum write (M1.0.3 E3): store the variant's declaration-order index as
        // the `u32` discriminant. POD — self-contained in the `enum_value`, so
        // (unlike `.string_`) it goes through the generic write path.
        .enum_ => {
            const disc: u32 = switch (v) {
                .enum_value => |e| e.variant,
                else => return error.TypeMismatch,
            };
            @memcpy(bytes[0..@sizeOf(u32)], std.mem.asBytes(&disc));
        },
        // Entity field (M1.0.6 E4): store the 8-byte `EntityId` (u64 bit pattern).
        // The interp runtime write path (e.g. `entity.get_mut(Comp).ref = other`)
        // routes here; the scene cook does NOT (it writes `dead` + a cross-ref
        // side entry, never an immediate value).
        .entity_ => {
            const x: value_mod.EntityId = switch (v) {
                .entity_id => |e| e,
                else => return error.TypeMismatch,
            };
            @memcpy(bytes[0..@sizeOf(value_mod.EntityId)], std.mem.asBytes(&x));
        },
        // A collection write is a persistent promotion (alloc + deep-copy +
        // decref of the previous slot), needing an allocator and the old slot —
        // the POD byte-encoder has neither. Resource collection writes route
        // through `promoteResourceCollection` (M1.0.17 E2+); components never
        // carry a collection kind (validator-gated). Reaching here is a bug,
        // surfaced as a typed error, never a panic — the `.string_` precedent.
        .array_, .map_, .set_ => return error.TypeMismatch,
    }
}

// ─── tests ────────────────────────────────────────────────────────────────

test "readBytesAsValue / writeValueAsBytes roundtrip on int" {
    var buf: [8]u8 = undefined;
    try writeValueAsBytes(.int_, &buf, .{ .int_ = -42 });
    const v = readBytesAsValue(.int_, &buf);
    try std.testing.expectEqual(@as(i64, -42), v.int_);
}

test "readBytesAsValue / writeValueAsBytes roundtrip on float" {
    var buf: [8]u8 = undefined;
    try writeValueAsBytes(.float_, &buf, .{ .float_ = 3.14 });
    const v = readBytesAsValue(.float_, &buf);
    try std.testing.expectEqual(@as(f64, 3.14), v.float_);
}

test "readBytesAsValue / writeValueAsBytes roundtrip on bool" {
    var buf: [1]u8 = undefined;
    try writeValueAsBytes(.bool_, &buf, .{ .bool_ = true });
    const v = readBytesAsValue(.bool_, &buf);
    try std.testing.expect(v.bool_);
}

test "writeValueAsBytes returns TypeMismatch on an incompatible value tag" {
    // Dedicated D-S4-ecs-bridge-panic proof (closed by M0.5 item 10): a type
    // incoherence at the bridge is a recoverable typed error on EVERY kind
    // branch — never a runtime `@panic`.
    var buf: [8]u8 = undefined;
    try std.testing.expectError(error.TypeMismatch, writeValueAsBytes(.int_, &buf, .{ .bool_ = true }));
    try std.testing.expectError(error.TypeMismatch, writeValueAsBytes(.bool_, &buf, .{ .int_ = 1 }));
    try std.testing.expectError(error.TypeMismatch, writeValueAsBytes(.f32_, &buf, .{ .bool_ = false }));
    try std.testing.expectError(error.TypeMismatch, writeValueAsBytes(.float_, &buf, .{ .bool_ = true }));
    // Float kinds (.float_/.f64_/.f32_) intentionally accept an int Value via
    // `@floatFromInt` (see `writeValueAsBytes` above), so an int is NOT an
    // incompatible tag for `.f64_` — probe it with a genuinely incompatible tag
    // (`.bool_`). (M1.0.1 wire-in: this assertion previously used `.int_ = 7`,
    // which the int→float coercion accepts, so it never matched the impl.)
    try std.testing.expectError(error.TypeMismatch, writeValueAsBytes(.f64_, &buf, .{ .bool_ = true }));
    try std.testing.expectError(error.TypeMismatch, writeValueAsBytes(.i32_, &buf, .{ .float_ = 1.5 }));
    try std.testing.expectError(error.TypeMismatch, writeValueAsBytes(.u32_, &buf, .{ .bool_ = false }));
}

// ─── M1.B / G5 — the handle is bimodal ──────────────────────────────────────
//
// `ComponentRef` was chunk-anchored, and a sparse component has no chunk. These
// tests live here rather than in `tests/etch/` because the bridge is not
// exported from the Etch root, and exporting it to reach a test would widen the
// public surface for the test's convenience. They also cannot be written end to
// end yet: a rule does not SELECT an entity by a sparse component until G7's
// planner lands, so the body that would use this handle never runs — pinned in
// `tests/etch/storage_mode_test.zig` as the boundary of the day.

fn g5TestWorld(gpa: std.mem.Allocator, world: *World, mode: weld_core.ecs.StorageKind) !ComponentId {
    const zero = [_]u8{0} ** 8;
    return world.registry.registerComponentRaw(gpa, .{
        .name = "Probe",
        .size = 8,
        .alignment = 8,
        .default_bytes = &zero,
        .fields = &.{.{ .name = "v", .offset = 0, .kind = .f64_ }},
        .storage = mode,
    });
}

test "G5: componentRefOf resolves a SPARSE component, and the field round-trips" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const cid = try g5TestWorld(gpa, &world, .sparse);
    const eid = try world.spawnDynamic(gpa, &.{cid});

    // Before G5 this returned `BridgeError.UnknownComponent`: the resolution
    // asked `arch.componentIndex(cid)`, which answers null for a sparse id, so
    // `entity.get(T)` on a sparse component was indistinguishable from asking
    // for a component the entity does not carry.
    const ref = try Bridge.componentRefOf(&world, @bitCast(eid), cid, true);

    try Bridge.writeComponentField(&world.registry, ref, &world, "v", .{ .float_ = 7.5 });
    const read = try Bridge.readComponentField(&world.registry, ref, &world, "v");
    try std.testing.expectApproxEqAbs(@as(f64, 7.5), read.float_, 1e-12);

    // The write reached the STORE and not a copy: read it back through the
    // World-level entry, which knows nothing of this handle.
    const bytes = world.componentBytes(eid, cid).?;
    const v: f64 = @bitCast(std.mem.readInt(u64, bytes[0..8], .little));
    try std.testing.expectApproxEqAbs(@as(f64, 7.5), v, 1e-12);
}

test "G5: the TABLE arm is unchanged — the same round-trip, same assertions" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // The counter-factual is the MODE and nothing else: same size, same field,
    // same calls. Without it, "the sparse arm works" would not establish that
    // the table arm still does.
    const cid = try g5TestWorld(gpa, &world, .table);
    const eid = try world.spawnDynamic(gpa, &.{cid});

    const ref = try Bridge.componentRefOf(&world, @bitCast(eid), cid, true);
    try Bridge.writeComponentField(&world.registry, ref, &world, "v", .{ .float_ = 7.5 });
    const read = try Bridge.readComponentField(&world.registry, ref, &world, "v");
    try std.testing.expectApproxEqAbs(@as(f64, 7.5), read.float_, 1e-12);

    const bytes = world.componentBytes(eid, cid).?;
    const v: f64 = @bitCast(std.mem.readInt(u64, bytes[0..8], .little));
    try std.testing.expectApproxEqAbs(@as(f64, 7.5), v, 1e-12);
}

test "G5: markComponentChanged stamps a SPARSE component" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    const cid = try g5TestWorld(gpa, &world, .sparse);
    const eid = try world.spawnDynamic(gpa, &.{cid});
    const at_spawn = world.sparse_stores.getConst(cid).?.changedTick(eid).?;

    world.beginFrame();
    world.beginFrame();
    const ref = try Bridge.componentRefOf(&world, @bitCast(eid), cid, true);
    Bridge.markComponentChanged(&world, ref, world.current_tick);

    const after = world.sparse_stores.getConst(cid).?.changedTick(eid).?;
    // The entry returns `void`, so a lost stamp has no diagnostic — asserted to
    // have MOVED rather than merely to exist, with two frames making the two
    // ticks distinguishable.
    try std.testing.expect(after != at_spawn);
    try std.testing.expectEqual(world.current_tick, after);
}

test "G5: componentRefOf still refuses a component the entity does NOT carry" {
    const gpa = std.testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // The refusal must survive the widening: a guard has two ways of being
    // wrong, and making the sparse arm resolve must not make every id resolve.
    const cid = try g5TestWorld(gpa, &world, .sparse);
    const eid = try world.spawnDynamic(gpa, &.{});
    try std.testing.expectError(
        BridgeError.UnknownComponent,
        Bridge.componentRefOf(&world, @bitCast(eid), cid, false),
    );
}
