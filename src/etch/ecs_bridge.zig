//! S4 Etch ↔ ECS adapter — translates the interpreter's name-based view of
//! the world (`entity.get(Health).current`, `when resource Score changed`)
//! onto the Tier 0 byte-oriented surface (`Registry`, `DynamicArchetype`,
//! `ResourceStore`, `RuntimeQuery`).
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
const RuntimeQuery = weld_core.ecs.query_runtime.RuntimeQuery;
const ResourceStore = weld_core.ecs.resources.ResourceStore;

pub const EntityId = value_mod.EntityId;
pub const Value = value_mod.Value;
pub const ComponentRef = value_mod.ComponentRef;

pub const BridgeError = error{
    UnknownEntity,
    UnknownComponent,
    UnknownResource,
    UnknownField,
    OutOfMemory,
};

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
        const loc = world.dynamicLocation(entity) orelse return BridgeError.UnknownEntity;
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
        writeValueAsBytes(field.kind, field_bytes, v);
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
        writeValueAsBytes(field.kind, slice, v);
    }
};

// ─── Byte ↔ Value conversion ─────────────────────────────────────────────

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

pub fn writeValueAsBytes(kind: FieldKind, bytes: []u8, v: Value) void {
    switch (kind) {
        .int_ => {
            const x: i64 = switch (v) {
                .int_ => |a| a,
                else => @panic("type mismatch on writeValueAsBytes (int_)"),
            };
            @memcpy(bytes[0..@sizeOf(i64)], std.mem.asBytes(&x));
        },
        .float_, .f64_ => {
            const x: f64 = switch (v) {
                .float_ => |a| a,
                .int_ => |a| @floatFromInt(a),
                else => @panic("type mismatch on writeValueAsBytes (float_)"),
            };
            @memcpy(bytes[0..@sizeOf(f64)], std.mem.asBytes(&x));
        },
        .bool_ => {
            const x: u8 = if (v.bool_) 1 else 0;
            bytes[0] = x;
        },
        .i32_ => {
            const x: i32 = switch (v) {
                .int_ => |a| @intCast(a),
                else => @panic("type mismatch on writeValueAsBytes (i32_)"),
            };
            @memcpy(bytes[0..@sizeOf(i32)], std.mem.asBytes(&x));
        },
        .u32_ => {
            const x: u32 = switch (v) {
                .int_ => |a| @intCast(a),
                else => @panic("type mismatch on writeValueAsBytes (u32_)"),
            };
            @memcpy(bytes[0..@sizeOf(u32)], std.mem.asBytes(&x));
        },
        .f32_ => {
            const x: f32 = switch (v) {
                .float_ => |a| @floatCast(a),
                .int_ => |a| @floatFromInt(a),
                else => @panic("type mismatch on writeValueAsBytes (f32_)"),
            };
            @memcpy(bytes[0..@sizeOf(f32)], std.mem.asBytes(&x));
        },
    }
}

// ─── tests ────────────────────────────────────────────────────────────────

test "readBytesAsValue / writeValueAsBytes roundtrip on int" {
    var buf: [8]u8 = undefined;
    writeValueAsBytes(.int_, &buf, .{ .int_ = -42 });
    const v = readBytesAsValue(.int_, &buf);
    try std.testing.expectEqual(@as(i64, -42), v.int_);
}

test "readBytesAsValue / writeValueAsBytes roundtrip on float" {
    var buf: [8]u8 = undefined;
    writeValueAsBytes(.float_, &buf, .{ .float_ = 3.14 });
    const v = readBytesAsValue(.float_, &buf);
    try std.testing.expectEqual(@as(f64, 3.14), v.float_);
}

test "readBytesAsValue / writeValueAsBytes roundtrip on bool" {
    var buf: [1]u8 = undefined;
    writeValueAsBytes(.bool_, &buf, .{ .bool_ = true });
    const v = readBytesAsValue(.bool_, &buf);
    try std.testing.expect(v.bool_);
}
