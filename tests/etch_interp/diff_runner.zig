//! Generic differential driver for the S4 Etch interpreter test corpus.
//!
//! Parameterised by a `Runner` type that exposes `setup`, `step`, and
//! `finalize`. S4 wires the tree-walking interpreter (`runner_interp.zig`);
//! S5 will plug a codegen runner without modifying this file.
//!
//! For each program:
//! 1. `Runner.setup(gpa, world, source)` parses + type-checks + compiles
//!    the .etch program, registering components and resources with the
//!    world.
//! 2. The driver spawns the entities described by `sidecar.initial` and
//!    overrides the resource values (and dirty flags) listed there.
//! 3. The driver runs `sidecar.config.ticks` ticks via `Runner.step`.
//! 4. The driver compares the final world state against `sidecar.expected`,
//!    component by component, resource by resource.

const std = @import("std");
const weld_core = @import("weld_core");
const Registry = weld_core.ecs.registry.Registry;
const ComponentId = weld_core.ecs.registry.ComponentId;
const FieldKind = weld_core.ecs.registry.FieldKind;
const World = weld_core.ecs.world.World;
const DynamicArchetype = weld_core.ecs.archetype_dynamic.DynamicArchetype;
const Chunk = weld_core.ecs.archetype_dynamic.Chunk;

pub const FieldValue = union(enum) {
    int_: i64,
    float_: f64,
    bool_: bool,

    pub fn eql(a: FieldValue, b: FieldValue) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .int_ => |x| x == b.int_,
            .float_ => |x| approxEqAbs(x, b.float_, 1e-6),
            .bool_ => |x| x == b.bool_,
        };
    }
};

fn approxEqAbs(a: f64, b: f64, eps: f64) bool {
    return @abs(a - b) <= eps;
}

pub const FieldSpec = struct {
    name: []const u8,
    value: FieldValue,
};

pub const ComponentSpec = struct {
    name: []const u8,
    fields: []const FieldSpec = &.{},
};

pub const EntitySpec = struct {
    /// Components present on this entity. Default values fill any field
    /// not explicitly listed. The set of component names also determines
    /// the archetype.
    components: []const ComponentSpec,
};

pub const ResourceInit = struct {
    name: []const u8,
    fields: []const FieldSpec = &.{},
    /// When true, mark the resource as dirty before tick 1. The interpreter
    /// clears the flag at the end of each tick (`tickBoundary`), so this is
    /// the only way to test `when resource T changed` rules.
    dirty: bool = false,
};

pub const Config = struct {
    ticks: u32,
};

pub const WorldSpec = struct {
    entities: []const EntitySpec = &.{},
    resources: []const ResourceInit = &.{},
};

pub const ExpectedWorld = struct {
    entities: []const EntitySpec = &.{},
    /// Resource state to verify after the run.
    resources: []const ResourceCheck = &.{},
};

pub const ResourceCheck = struct {
    name: []const u8,
    fields: []const FieldSpec = &.{},
};

/// Runner interface — `Runner` must declare:
///   pub fn setup(gpa: std.mem.Allocator, world: *World, name: []const u8, source: []const u8) !Runner;
///   pub fn step(self: *Runner, world: *World) !void;
///   pub fn finalize(self: *Runner, gpa: std.mem.Allocator, world: *World) void;
///
/// The S5 codegen runner uses `name` to dispatch into the pre-compiled
/// `corpus_codegen` consolidated module; the S4 interpreter runner ignores
/// it (just compiles from `source`). Passing both keeps the contract
/// uniform across backends without forcing one to parse the other's
/// preferred input.
pub fn runProgram(
    gpa: std.mem.Allocator,
    comptime Runner: type,
    name: []const u8,
    source: []const u8,
    config: Config,
    initial: WorldSpec,
    expected: ExpectedWorld,
) !void {
    var world = World.init();
    defer world.deinit(gpa);

    var runner = try Runner.setup(gpa, &world, name, source);
    defer runner.finalize(gpa, &world);

    try spawnEntities(gpa, &world, initial.entities);
    try setResources(gpa, &world, initial.resources);

    var t: u32 = 0;
    while (t < config.ticks) : (t += 1) {
        try runner.step(&world);
    }

    try verifyEntities(name, &world, expected.entities);
    try verifyResources(name, &world, expected.resources);
}

fn spawnEntities(gpa: std.mem.Allocator, world: *World, entities: []const EntitySpec) !void {
    for (entities) |espec| {
        // Resolve component ids for this entity's archetype.
        var comp_ids = try gpa.alloc(ComponentId, espec.components.len);
        defer gpa.free(comp_ids);
        for (espec.components, 0..) |c, i| {
            comp_ids[i] = world.registry.idOf(c.name) orelse {
                std.debug.print("sidecar component name '{s}' not registered by the .etch program\n", .{c.name});
                return error.UnknownComponent;
            };
        }
        const eid = try world.spawnDynamic(gpa, comp_ids);
        const loc = world.dynamicLocation(eid).?;
        const arch = world.dynamicArchetype(loc.archetype_idx);
        const chunk = arch.chunks.items[loc.chunk_idx];
        for (espec.components) |c| {
            const cid = world.registry.idOf(c.name).?;
            const idx = arch.componentIndex(cid).?;
            const slot_bytes = arch.componentSlot(chunk, idx, loc.slot);
            for (c.fields) |f| {
                const fd = world.registry.findField(cid, f.name) orelse return error.UnknownField;
                writeFieldValue(fd.kind, slot_bytes[fd.offset .. fd.offset + @as(u16, @intCast(fd.kind.sizeBytes()))], f.value);
            }
        }
    }
}

fn setResources(gpa: std.mem.Allocator, world: *World, resources: []const ResourceInit) !void {
    _ = gpa;
    // Phase 1: write field bytes through `getMutResource` (which sets the
    // dirty bit on every touched resource).
    for (resources) |r| {
        const rid = world.registry.idOf(r.name) orelse return error.UnknownResource;
        const bytes = world.resources.getMutResource(rid) orelse return error.UnknownResource;
        for (r.fields) |f| {
            const fd = world.registry.findField(rid, f.name) orelse return error.UnknownField;
            writeFieldValue(fd.kind, bytes[fd.offset .. fd.offset + @as(u16, @intCast(fd.kind.sizeBytes()))], f.value);
        }
    }
    // Phase 2: any resource whose sidecar entry does NOT request initial
    // dirty must have its bit cleared before the first tick. Phase 1 set
    // dirty=true unconditionally via `getMutResource`. The store does not
    // expose per-id clear; instead, run `tickBoundary` once (clears all),
    // then re-set dirty for the resources that did request it.
    var any_dirty = false;
    for (resources) |r| if (r.dirty) {
        any_dirty = true;
        break;
    };
    if (!any_dirty) {
        world.resources.tickBoundary();
        return;
    }
    world.resources.tickBoundary();
    for (resources) |r| {
        if (!r.dirty) continue;
        const rid = world.registry.idOf(r.name) orelse return error.UnknownResource;
        _ = world.resources.getMutResource(rid);
    }
}

fn verifyEntities(name: []const u8, world: *World, entities: []const EntitySpec) !void {
    // Iterate matching entities in spawn order: entity ids start at 0 and
    // increase monotonically by one per spawn, so we just walk by id.
    for (entities, 0..) |espec, i| {
        const eid: u64 = @intCast(i);
        const loc = world.dynamicLocation(eid) orelse {
            std.debug.print("[{s}] entity {d} is missing from the world\n", .{ name, eid });
            return error.EntityMissing;
        };
        const arch = world.dynamicArchetype(loc.archetype_idx);
        const chunk = arch.chunks.items[loc.chunk_idx];
        for (espec.components) |c| {
            const cid = world.registry.idOf(c.name) orelse {
                std.debug.print("[{s}] expected component '{s}' is not registered\n", .{ name, c.name });
                return error.UnknownComponent;
            };
            const idx = arch.componentIndex(cid) orelse {
                std.debug.print("[{s}] entity {d} archetype lacks component '{s}'\n", .{ name, eid, c.name });
                return error.ComponentMissing;
            };
            const slot_bytes = arch.componentSlot(chunk, idx, loc.slot);
            for (c.fields) |f| {
                const fd = world.registry.findField(cid, f.name) orelse return error.UnknownField;
                const got = readFieldValue(fd.kind, slot_bytes[fd.offset .. fd.offset + @as(u16, @intCast(fd.kind.sizeBytes()))]);
                if (!got.eql(f.value)) {
                    std.debug.print("[{s}] entity {d} {s}.{s} mismatch: got {any}, expected {any}\n", .{ name, eid, c.name, f.name, got, f.value });
                    return error.FieldMismatch;
                }
            }
        }
    }
}

fn verifyResources(name: []const u8, world: *World, resources: []const ResourceCheck) !void {
    for (resources) |r| {
        const rid = world.registry.idOf(r.name) orelse return error.UnknownResource;
        const bytes = world.resources.getResource(rid) orelse return error.UnknownResource;
        for (r.fields) |f| {
            const fd = world.registry.findField(rid, f.name) orelse return error.UnknownField;
            const got = readFieldValue(fd.kind, bytes[fd.offset .. fd.offset + @as(u16, @intCast(fd.kind.sizeBytes()))]);
            if (!got.eql(f.value)) {
                std.debug.print("[{s}] resource {s}.{s} mismatch: got {any}, expected {any}\n", .{ name, r.name, f.name, got, f.value });
                return error.FieldMismatch;
            }
        }
    }
}

fn writeFieldValue(kind: FieldKind, bytes: []u8, v: FieldValue) void {
    switch (kind) {
        .int_ => {
            const x: i64 = switch (v) {
                .int_ => |a| a,
                .float_ => |a| @intFromFloat(a),
                .bool_ => |a| @intFromBool(a),
            };
            @memcpy(bytes[0..@sizeOf(i64)], std.mem.asBytes(&x));
        },
        .float_, .f64_ => {
            const x: f64 = switch (v) {
                .float_ => |a| a,
                .int_ => |a| @floatFromInt(a),
                .bool_ => |a| if (a) @as(f64, 1.0) else @as(f64, 0.0),
            };
            @memcpy(bytes[0..@sizeOf(f64)], std.mem.asBytes(&x));
        },
        .bool_ => bytes[0] = switch (v) {
            .bool_ => |a| if (a) @as(u8, 1) else @as(u8, 0),
            .int_ => |a| if (a != 0) @as(u8, 1) else @as(u8, 0),
            .float_ => |a| if (a != 0) @as(u8, 1) else @as(u8, 0),
        },
        .i32_ => {
            const x: i32 = @intCast(v.int_);
            @memcpy(bytes[0..@sizeOf(i32)], std.mem.asBytes(&x));
        },
        .u32_ => {
            const x: u32 = @intCast(v.int_);
            @memcpy(bytes[0..@sizeOf(u32)], std.mem.asBytes(&x));
        },
        .f32_ => {
            const x: f32 = @floatCast(v.float_);
            @memcpy(bytes[0..@sizeOf(f32)], std.mem.asBytes(&x));
        },
    }
}

fn readFieldValue(kind: FieldKind, bytes: []const u8) FieldValue {
    return switch (kind) {
        .int_ => blk: {
            var v: i64 = 0;
            @memcpy(std.mem.asBytes(&v), bytes[0..@sizeOf(i64)]);
            break :blk .{ .int_ = v };
        },
        .float_, .f64_ => blk: {
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
    };
}
