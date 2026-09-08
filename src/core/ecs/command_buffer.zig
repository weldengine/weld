//! FROZEN — see engine-phase-0-criteria.md C0.5
//!
//! Records deferred structural mutations during a phase and applies them at the
//! phase boundary, so a query built before the phase keeps seeing the same chunks,
//! slots and locations throughout it.
//!
//! INSIDE a system body the direct `World.spawn` / `despawn` / `addComponent` /
//! `removeComponent` surface is programmer error — it breaks exactly that pointer
//! stability. Outside a dispatch it stays available: this is a phase-time
//! concession, not a façade over the world.
//!
//! Order at flush is system registration order, then record order within one
//! buffer. Recording is SINGLE-THREADED and main-thread only: the worker
//! trampolines never receive a buffer, which is what the marker below enforces.
//!
//! The arena resets with `retain_capacity`, so steady state allocates nothing.

const std = @import("std");
const world_mod = @import("world.zig");
const registry_mod = @import("registry.zig");
const job_bound = @import("foundation").job_bound;

/// Refuse, at comptime, an argument tuple carrying a `CommandBuffer` into a body a
/// worker pool runs. The ECS-side name for `foundation.job_bound.refuseMarkedArgs`,
/// so the call sites read in this tier's vocabulary.
pub fn refuseCommandBufferInArgs(comptime ArgsType: type) void {
    job_bound.refuseMarkedArgs(ArgsType);
}

/// The SAME function, NOT a copy: a copy passes every test until it drifts.
pub const carriesMarked = job_bound.carriesMarked;

const World = world_mod.World;
const EntityId = world_mod.EntityId;
const ComponentId = registry_mod.ComponentId;

/// Tag enum for the `Command` union.
pub const CommandKind = enum { spawn, despawn, add_component, remove_component, set_tag, clear_tag };

/// `payloads[i]` pairs with `component_ids[i]`, before any sort the world does.
pub const SpawnCommand = struct {
    component_ids: []const ComponentId,
    payloads: []const []const u8,
};

/// Deferred despawn — entity handle captured at record time.
pub const DespawnCommand = struct {
    entity: EntityId,
};

/// Deferred component add — bytes live in the buffer's arena.
pub const AddComponentCommand = struct {
    entity: EntityId,
    component_id: ComponentId,
    bytes: []const u8,
};

/// Deferred component remove — only needs the component id.
pub const RemoveComponentCommand = struct {
    entity: EntityId,
    component_id: ComponentId,
};

/// `bit_index` is the leaf's GLOBAL bit. Applied through `World.applyTagMutation`,
/// which adds `TagSet` — an archetype transition — to an entity that lacks one.
pub const TagCommand = struct {
    entity: EntityId,
    tagset_id: ComponentId,
    bit_index: u32,
};

/// Tagged union of all deferrable commands.
pub const Command = union(CommandKind) {
    spawn: SpawnCommand,
    despawn: DespawnCommand,
    add_component: AddComponentCommand,
    remove_component: RemoveComponentCommand,
    set_tag: TagCommand,
    clear_tag: TagCommand,
};

/// Per-system command buffer.
pub const CommandBuffer = struct {
    /// THE TYPE DECLARES ITS OWN REFUSAL and its value is the reason, read at
    /// comptime by `foundation.job_bound`: importing this file from `src/core/jobs/`
    /// would drag `world.zig` into the job tier's graph.
    pub const weld_no_job_body: []const u8 =
        "a worker owns its range's storage and nothing else, so two workers " ++
        "recording structural changes would need a deterministic merge, which " ++
        "has no producer anywhere in the repository. Record the change outside " ++
        "the dispatch, or dispatch a body that does not record.";

    /// Owns the payload copies; reset with `retain_capacity` on every flush.
    arena: std.heap.ArenaAllocator,
    /// Recorded commands, in submission order inside this system.
    commands: std.ArrayListUnmanaged(Command) = .empty,
    /// BORROWED — used for type resolution at record time and mutation at flush.
    world: *World,
    /// Backs the `commands` list; the arena is initialised from it too.
    gpa: std.mem.Allocator,

    /// `world` is borrowed and MUST outlive the buffer.
    pub fn init(gpa: std.mem.Allocator, world: *World) CommandBuffer {
        return .{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .world = world,
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *CommandBuffer) void {
        self.commands.deinit(self.gpa);
        self.arena.deinit();
        self.* = undefined;
    }

    /// Drop every command and reset the arena; steady-state alloc-free.
    pub fn reset(self: *CommandBuffer) void {
        self.commands.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
    }

    /// For tests and zero-alloc assertions.
    pub fn commandCount(self: *const CommandBuffer) usize {
        return self.commands.items.len;
    }

    /// `values` is a tuple of component values; each type is resolved through
    /// `world.ensureComponentRegistered` and its bytes COPIED into the arena.
    pub fn spawn(self: *CommandBuffer, values: anytype) !void {
        const Args = @TypeOf(values);
        const info = @typeInfo(Args).@"struct";
        const n = info.fields.len;
        if (n == 0) @compileError("CommandBuffer.spawn requires at least one component");

        const arena_alloc = self.arena.allocator();
        const ids = try arena_alloc.alloc(ComponentId, n);
        const payloads = try arena_alloc.alloc([]const u8, n);

        inline for (info.fields, 0..) |field, i| {
            const T = field.type;
            ids[i] = try self.world.ensureComponentRegistered(self.gpa, T);
            // A local first, so `std.mem.asBytes` has a stable address to dupe.
            const v: T = @field(values, field.name);
            payloads[i] = try arena_alloc.dupe(u8, std.mem.asBytes(&v));
        }

        try self.commands.append(self.gpa, .{ .spawn = .{
            .component_ids = ids,
            .payloads = payloads,
        } });
    }

    /// The handle is captured BY VALUE: if it is stale at flush time the flush
    /// stops this buffer with `StaleEntityHandle` and the next system's still runs.
    pub fn despawn(self: *CommandBuffer, entity: EntityId) !void {
        try self.commands.append(self.gpa, .{ .despawn = .{ .entity = entity } });
    }

    /// `T`'s bytes are COPIED into the arena.
    pub fn addComponent(
        self: *CommandBuffer,
        entity: EntityId,
        comptime T: type,
        value: T,
    ) !void {
        const cid = try self.world.ensureComponentRegistered(self.gpa, T);
        const arena_alloc = self.arena.allocator();
        const bytes = try arena_alloc.dupe(u8, std.mem.asBytes(&value));
        try self.commands.append(self.gpa, .{ .add_component = .{
            .entity = entity,
            .component_id = cid,
            .bytes = bytes,
        } });
    }

    /// An unregistered type fails at FLUSH time, as `StaleEntityHandle`.
    pub fn removeComponent(
        self: *CommandBuffer,
        entity: EntityId,
        comptime T: type,
    ) !void {
        const cid = try self.world.ensureComponentRegistered(self.gpa, T);
        try self.commands.append(self.gpa, .{ .remove_component = .{
            .entity = entity,
            .component_id = cid,
        } });
    }

    /// Sets `bit_index` of `entity`'s `TagSet` at flush time.
    pub fn setTag(self: *CommandBuffer, entity: EntityId, tagset_id: ComponentId, bit_index: u32) !void {
        try self.commands.append(self.gpa, .{ .set_tag = .{
            .entity = entity,
            .tagset_id = tagset_id,
            .bit_index = bit_index,
        } });
    }

    /// Clears `bit_index` of `entity`'s `TagSet` at flush time.
    pub fn clearTag(self: *CommandBuffer, entity: EntityId, tagset_id: ComponentId, bit_index: u32) !void {
        try self.commands.append(self.gpa, .{ .clear_tag = .{
            .entity = entity,
            .tagset_id = tagset_id,
            .bit_index = bit_index,
        } });
    }

    /// Apply in submission order and reset. The RAW flush: observer dispatch is
    /// `flushWithObservers` in `observers.zig`, and this one fires nothing.
    pub fn flush(self: *CommandBuffer) !void {
        for (self.commands.items) |cmd| {
            try self.applyOne(cmd);
        }
        self.reset();
    }

    /// Module-scope so the observer-aware flush can interleave dispatch.
    pub fn applyOne(self: *CommandBuffer, cmd: Command) !void {
        switch (cmd) {
            .spawn => |s| {
                _ = try self.world.spawnDynamicWithValues(
                    self.gpa,
                    s.component_ids,
                    s.payloads,
                );
            },
            .despawn => |d| {
                try self.world.despawn(self.gpa, d.entity);
            },
            .add_component => |a| {
                try self.world.addComponentDynamic(
                    self.gpa,
                    a.entity,
                    a.component_id,
                    a.bytes,
                );
            },
            .remove_component => |r| {
                try self.world.removeComponentDynamic(
                    self.gpa,
                    r.entity,
                    r.component_id,
                );
            },
            .set_tag => |t| {
                try self.world.applyTagMutation(self.gpa, t.entity, t.tagset_id, t.bit_index, true);
            },
            .clear_tag => |t| {
                try self.world.applyTagMutation(self.gpa, t.entity, t.tagset_id, t.bit_index, false);
            },
        }
    }
};

const testing = std.testing;

test "CommandBuffer init/deinit round-trip is leak-free" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    var cmd = CommandBuffer.init(gpa, &world);
    defer cmd.deinit();
    try testing.expectEqual(@as(usize, 0), cmd.commandCount());
}

test "CommandBuffer.spawn records but does not mutate world" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    var cmd = CommandBuffer.init(gpa, &world);
    defer cmd.deinit();

    try cmd.spawn(.{
        world_mod.Transform{},
        world_mod.Velocity{},
    });
    try testing.expectEqual(@as(usize, 1), cmd.commandCount());
    try testing.expectEqual(@as(usize, 0), world.entityCount());
}

test "CommandBuffer.flush applies spawn → world entity count incremented" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    var cmd = CommandBuffer.init(gpa, &world);
    defer cmd.deinit();

    try cmd.spawn(.{
        world_mod.Transform{},
        world_mod.Velocity{},
    });
    try cmd.flush();

    try testing.expectEqual(@as(usize, 1), world.entityCount());
    try testing.expectEqual(@as(usize, 0), cmd.commandCount());
}

test "CommandBuffer set_tag adds TagSet and sets the bit; clear_tag clears it" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    // A `TagSet`-shaped component: one 64-bit word, zeroed default, no fields.
    const zero = [_]u8{0} ** 8;
    const tagset_id = try world.registry.registerComponentRaw(gpa, .{
        .name = "TagSet",
        .size = 8,
        .alignment = 8,
        .default_bytes = &zero,
        .fields = &.{},
    });
    const eid = try world.spawn(gpa, world_mod.Transform{}, world_mod.Velocity{});

    var cmd = CommandBuffer.init(gpa, &world);
    defer cmd.deinit();

    // Recorded, not yet applied — the entity still lacks TagSet.
    try cmd.setTag(eid, tagset_id, 3);
    try testing.expectEqual(@as(usize, 1), cmd.commandCount());
    {
        const loc = world.dynamicLocation(eid).?;
        try testing.expect(world.dynamicArchetype(loc.archetype_idx).componentIndex(tagset_id) == null);
    }

    // Flush adds TagSet (archetype transition) with bit 3 set.
    try cmd.flush();
    try testing.expectEqual(@as(u64, 1) << 3, readTagWord(&world, tagset_id, eid));

    // clear_tag flips the bit back in place (no further transition).
    try cmd.clearTag(eid, tagset_id, 3);
    try cmd.flush();
    try testing.expectEqual(@as(u64, 0), readTagWord(&world, tagset_id, eid));
}

fn readTagWord(world: *World, tagset_id: ComponentId, eid: EntityId) u64 {
    const loc = world.dynamicLocation(eid).?;
    const arch = world.dynamicArchetype(loc.archetype_idx);
    const col = arch.componentIndex(tagset_id).?;
    const chunk = arch.chunks.items[loc.chunk_idx];
    const bytes = arch.componentSlot(chunk, col, loc.slot);
    var word: u64 = 0;
    @memcpy(std.mem.asBytes(&word), bytes[0..8]);
    return word;
}
