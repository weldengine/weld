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
        const arch = world.dynamicArchetype(loc.archetype_idx);
        if (arch.componentIndex(component_id) == null) return BridgeError.UnknownComponent;
        const chunk = arch.chunks.items[loc.chunk_idx];
        return .{
            .component_id = component_id,
            .chunk_ptr = chunk,
            .slot = loc.slot,
            .mutable = mutable,
        };
    }

    /// Read a field from a component slot as a `Value` (auto-tagged from
    /// the field's `FieldKind`).
    pub fn readComponentField(
        registry: *const Registry,
        ref: ComponentRef,
        world: *World,
        field_name: []const u8,
    ) BridgeError!Value {
        const field = registry.findField(ref.component_id, field_name) orelse return BridgeError.UnknownField;
        const loc_arch = blk: {
            // The chunk's archetype id is in its header.
            const chunk: *Chunk = @ptrCast(@alignCast(ref.chunk_ptr));
            const archetype_id = chunk.header().archetype_id;
            break :blk world.dynamicArchetype(archetype_id);
        };
        const idx = loc_arch.componentIndex(ref.component_id) orelse return BridgeError.UnknownComponent;
        const chunk: *Chunk = @ptrCast(@alignCast(ref.chunk_ptr));
        const slot_bytes = loc_arch.componentSlot(chunk, idx, ref.slot);
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
        const chunk: *Chunk = @ptrCast(@alignCast(ref.chunk_ptr));
        const arch = world.dynamicArchetype(chunk.header().archetype_id);
        const idx = arch.componentIndex(ref.component_id) orelse return BridgeError.UnknownComponent;
        const slot_bytes = arch.componentSlot(chunk, idx, ref.slot);
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
        const chunk: *Chunk = @ptrCast(@alignCast(ref.chunk_ptr));
        const arch = world.dynamicArchetype(chunk.header().archetype_id);
        const idx = arch.componentIndex(ref.component_id) orelse return;
        arch.markChanged(chunk, idx, ref.slot, tick);
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
    var buf: [8]u8 = undefined;
    try std.testing.expectError(error.TypeMismatch, writeValueAsBytes(.int_, &buf, .{ .bool_ = true }));
    try std.testing.expectError(error.TypeMismatch, writeValueAsBytes(.bool_, &buf, .{ .int_ = 1 }));
    try std.testing.expectError(error.TypeMismatch, writeValueAsBytes(.f32_, &buf, .{ .bool_ = false }));
}
