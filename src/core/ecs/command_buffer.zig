//! FROZEN — see `engine-phase-0-criteria.md` C0.5.
//!
//! Per-system command buffer.
//!
//! Records deferred structural mutations (`spawn`, `despawn`,
//! `add_component`, `remove_component`) during a phase's systems and
//! applies them at the phase boundary in submission order. Until the
//! flush runs, the world's structural state stays frozen — queries
//! built before the phase continue to see the same chunks, slots,
//! and entity locations.
//!
//! Mutation rules during a phase:
//!
//! - Inside a system body, structural mutations MUST go through the
//!   command buffer (`ctx.cmd.spawn(...)` etc.). Calling
//!   `World.spawn` / `World.despawn` / `World.addComponent` /
//!   `World.removeComponent` directly during a dispatch is a
//!   programmer error and breaks query / chunk pointer stability.
//! - Outside a dispatch (init, teardown, replay, out-of-phase paths)
//!   the direct `World.*` mutation surface stays available — the
//!   command buffer is a phase-time concession, not a permanent
//!   façade.
//!
//! Application order at flush time = submission order of the systems
//! inside the phase (the order they were registered in the
//! `SystemScheduler`). Inside a single system's buffer, commands
//! apply in the order they were recorded. Both ordering guarantees
//! are deterministic and tested.
//!
//! Threading: the command buffer is single-threaded. Recording must
//! happen on the main thread inside the `SystemFn` body — the worker
//! trampolines that run chunk bodies do **not** get the cmd buffer,
//! so they cannot record. Per-worker buffers + merge-at-flush is a
//! a later refinement.
//!
//! Allocation: each `CommandBuffer` owns an arena. Payload bytes and
//! per-spawn resolver/id/payload slices are duplicated into the arena so the
//! caller's stack values can go out of scope between recording and
//! flushing. The arena is reset with `retain_capacity` between
//! frames so steady-state allocation is zero after the first flush.
//!
//! The buffer holds NO world. A recorded command carries the type it needs as a
//! resolver and the world arrives at `flush` — see `CommandBuffer.init` for why
//! that is a contract and not a refactor.

const std = @import("std");
const world_mod = @import("world.zig");
const registry_mod = @import("registry.zig");
const job_bound = @import("foundation").job_bound;

/// Refuse, at compile time, an argument tuple that carries a `CommandBuffer`
/// into a body a worker pool runs.
///
/// `engine-ecs-internals.md` §7 states it as an absolute: no job body receives
/// a command buffer. The reason travels WITH the type — see
/// `CommandBuffer.weld_no_job_body` — and this function is the ECS-side name
/// for `foundation.job_bound.refuseMarkedArgs`, kept so the call sites in this
/// tier read in this tier's vocabulary.
///
/// The SITE SET is derived and asserted, not maintained by hand:
/// `tests/ecs/hybrid_query_test.zig`'s job-bound control. Why placing the
/// marker on the type is not the same as every entry calling it is written
/// where that reasoning failed, at `src/core/jobs/scheduler.zig`'s dispatch.
pub fn refuseCommandBufferInArgs(comptime ArgsType: type) void {
    job_bound.refuseMarkedArgs(ArgsType);
}

/// Re-export of the tier-agnostic predicate — the SAME function, NOT a copy: a
/// copy passes every test until it drifts.
pub const carriesMarked = job_bound.carriesMarked;

const World = world_mod.World;
const EntityId = world_mod.EntityId;
const ComponentId = registry_mod.ComponentId;

/// Tag enum for the `Command` union.
pub const CommandKind = enum { spawn, despawn, add_component, remove_component, set_tag, clear_tag };

/// Closure that registers a component type with a world's `Registry` if needed
/// and returns its `ComponentId`.
///
/// **This is what replaces the world the buffer used to hold.** Recording a
/// deferred `add` needs the type; resolving the type needs the world; and a
/// buffer that holds a world hands a system back the unrestricted handle its
/// view exists to withhold — through a neighbouring field, with no cast and no
/// diagnostic. So the type travels as a closure and the world arrives at
/// `flush`. Same shape as `scheduler.AccessDescriptor.resolve`, for the same
/// reason: a `comptime T` that must survive into a runtime value.
pub const ComponentResolveFn = *const fn (world: *World, gpa: std.mem.Allocator) anyerror!ComponentId;

/// Build the resolver for `T`.
fn resolverFor(comptime T: type) ComponentResolveFn {
    const Wrapper = struct {
        fn resolve(world: *World, gpa: std.mem.Allocator) anyerror!ComponentId {
            return try world.ensureComponentRegistered(gpa, T);
        }
    };
    return &Wrapper.resolve;
}

/// Deferred spawn: arrays of component ids + payload bytes. Both
/// arrays live in the buffer's arena. `payloads[i]` is paired with
/// `component_ids[i]` (same ordering, before any sort the world does
/// internally).
pub const SpawnCommand = struct {
    /// EMPTY when the recorder already held the ids — see the note on
    /// `AddComponentCommand.resolve` for the two recorders this serves.
    /// Otherwise parallel to `component_ids` and the same length.
    resolvers: []const ComponentResolveFn = &.{},
    /// The ids the spawn applies with. Already meaningful when `resolvers` is
    /// empty; otherwise written at flush, in the buffer's own arena.
    component_ids: []ComponentId,
    payloads: []const []const u8,
};

/// Deferred despawn — entity handle captured at record time.
pub const DespawnCommand = struct {
    entity: EntityId,
};

/// Deferred component add — bytes live in the buffer's arena.
pub const AddComponentCommand = struct {
    entity: EntityId,
    /// Non-null when the recorder held a TYPE and no world — the typed
    /// `addComponent(T)` path, whose id can only be resolved at flush. Null
    /// when the recorder already held the id, which is the Etch interpreter,
    /// the observer flush, and every caller that resolved before recording.
    ///
    /// Two recorders, both real. `component_id` has no default precisely so a
    /// literal that says neither does not compile.
    resolve: ?ComponentResolveFn = null,
    component_id: ComponentId,
    bytes: []const u8,
};

/// Deferred component remove — only needs the component id.
pub const RemoveComponentCommand = struct {
    entity: EntityId,
    /// Same two recorders as `AddComponentCommand.resolve`.
    resolve: ?ComponentResolveFn = null,
    component_id: ComponentId,
};

/// Deferred tag bit set/clear (`etch-grammar.md` §4.4). `tagset_id`
/// is the registered `TagSet` component id; `bit_index` is the leaf's global
/// bit. Applied via `World.applyTagMutation`, which adds `TagSet` to the
/// entity (an archetype transition) when a `set_tag` lands on an entity that
/// lacks one. Sits beside add/remove-component as a sibling deferred
/// structural change.
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
    /// THE TYPE DECLARES ITS OWN REFUSAL, and its value is the reason.
    ///
    /// Read at comptime by `foundation.job_bound.refuseMarkedArgs`, which is how
    /// the bound reaches a tier that cannot name this type: importing this file
    /// from `src/core/jobs/` would drag `world.zig` into the job tier's graph.
    pub const weld_no_job_body: []const u8 =
        "a worker owns its range's storage and nothing else, so two workers " ++
        "recording structural changes would need a deterministic merge, which " ++
        "has no producer anywhere in the repository. Record the change outside " ++
        "the dispatch, or dispatch a body that does not record.";

    /// Arena that owns payload byte copies + per-spawn id/payload
    /// slices. Reset with `retain_capacity` on every flush so the
    /// steady-state behaviour matches the `JobBuilder` arena's
    /// pattern.
    arena: std.heap.ArenaAllocator,
    /// Recorded commands, in submission order inside this system.
    commands: std.ArrayListUnmanaged(Command) = .empty,
    /// Backing allocator for the `commands` ArrayList. The arena is
    /// initialised from this allocator too.
    gpa: std.mem.Allocator,

    /// Construct a fresh command buffer.
    ///
    /// **It holds no world, and that absence is the contract.** Zig has no
    /// private field, so a buffer carrying a `*World` would hand every system
    /// the unrestricted handle its declared-access view exists to withhold —
    /// `ctx.cmd.world.getMut(Anything, e)`, no cast, no diagnostic. The world
    /// arrives at `flush`, and the type each command needs travels with the
    /// command as a resolver. Encapsulation here is the REMOVAL of the datum,
    /// never an envelope around it.
    pub fn init(gpa: std.mem.Allocator) CommandBuffer {
        return .{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *CommandBuffer) void {
        self.commands.deinit(self.gpa);
        self.arena.deinit();
        self.* = undefined;
    }

    /// Drop every command + reset the arena to its first chunk.
    /// Steady-state alloc-free.
    pub fn reset(self: *CommandBuffer) void {
        self.commands.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
    }

    /// Number of recorded commands (across all kinds). Mostly for
    /// tests and zero-alloc assertions.
    pub fn commandCount(self: *const CommandBuffer) usize {
        return self.commands.items.len;
    }

    /// Record a deferred spawn. `values` is a tuple of component
    /// values (e.g. `.{Transform{}, Velocity{}}`); each field's type
    /// is resolved through `world.ensureComponentRegistered` and its
    /// bytes are duplicated into the buffer's arena.
    pub fn spawn(self: *CommandBuffer, values: anytype) !void {
        const Args = @TypeOf(values);
        const info = @typeInfo(Args).@"struct";
        const n = info.fields.len;
        if (n == 0) @compileError("CommandBuffer.spawn requires at least one component");

        const arena_alloc = self.arena.allocator();
        const resolvers = try arena_alloc.alloc(ComponentResolveFn, n);
        const ids = try arena_alloc.alloc(ComponentId, n);
        const payloads = try arena_alloc.alloc([]const u8, n);

        inline for (info.fields, 0..) |field, i| {
            const T = field.type;
            resolvers[i] = resolverFor(T);
            // Materialise the field as a local so `std.mem.asBytes`
            // has a stable address, then dupe into the arena.
            const v: T = @field(values, field.name);
            payloads[i] = try arena_alloc.dupe(u8, std.mem.asBytes(&v));
        }

        try self.commands.append(self.gpa, .{ .spawn = .{
            .resolvers = resolvers,
            .component_ids = ids,
            .payloads = payloads,
        } });
    }

    /// Record a deferred despawn. The entity handle is captured by
    /// value — if the entity has already been despawned by the time
    /// the flush runs, the flush surfaces a `StaleEntityHandle`
    /// error and the cmd buffer stops processing further commands
    /// from this system's buffer (the next system's buffer still
    /// flushes normally).
    pub fn despawn(self: *CommandBuffer, entity: EntityId) !void {
        try self.commands.append(self.gpa, .{ .despawn = .{ .entity = entity } });
    }

    /// Record a deferred component add. `T`'s bytes are duplicated
    /// into the arena.
    pub fn addComponent(
        self: *CommandBuffer,
        entity: EntityId,
        comptime T: type,
        value: T,
    ) !void {
        const arena_alloc = self.arena.allocator();
        const bytes = try arena_alloc.dupe(u8, std.mem.asBytes(&value));
        try self.commands.append(self.gpa, .{
            .add_component = .{
                .entity = entity,
                .resolve = resolverFor(T),
                // Meaningless until `resolveComponentIds` runs; the field carries no
                // default so that a recorder holding NEITHER a type nor an id
                // cannot be written at all.
                .component_id = undefined,
                .bytes = bytes,
            },
        });
    }

    /// Record a deferred component remove. The component must
    /// already be registered in the world (or the remove will fail
    /// at flush time with `StaleEntityHandle` if the type is
    /// unknown).
    pub fn removeComponent(
        self: *CommandBuffer,
        entity: EntityId,
        comptime T: type,
    ) !void {
        try self.commands.append(self.gpa, .{ .remove_component = .{
            .entity = entity,
            .resolve = resolverFor(T),
            .component_id = undefined,
        } });
    }

    /// Record a deferred `add_tag` — set `bit_index` of `entity`'s
    /// `TagSet` at flush time. `tagset_id` is the registered `TagSet`
    /// component id.
    pub fn setTag(self: *CommandBuffer, entity: EntityId, tagset_id: ComponentId, bit_index: u32) !void {
        try self.commands.append(self.gpa, .{ .set_tag = .{
            .entity = entity,
            .tagset_id = tagset_id,
            .bit_index = bit_index,
        } });
    }

    /// Record a deferred `remove_tag` — clear `bit_index` of
    /// `entity`'s `TagSet` at flush time.
    pub fn clearTag(self: *CommandBuffer, entity: EntityId, tagset_id: ComponentId, bit_index: u32) !void {
        try self.commands.append(self.gpa, .{ .clear_tag = .{
            .entity = entity,
            .tagset_id = tagset_id,
            .bit_index = bit_index,
        } });
    }

    /// Apply every recorded command, in submission order, against
    /// the world. Resets the buffer at the end so the system is
    /// ready for the next frame. Observer dispatch is layered on top
    /// via `flushWithObservers` (see `observers.zig`) — this raw
    /// flush is used by tests that exercise the cmd-buffer logic in
    /// isolation.
    pub fn flush(self: *CommandBuffer, world: *World) !void {
        try self.resolveComponentIds(world);
        for (self.commands.items) |cmd| {
            try self.applyOne(world, cmd);
        }
        self.reset();
    }

    /// Turn every recorded command's type into a `ComponentId` against `world`.
    ///
    /// Runs ONCE per flush, before the first mutation, and must: an observer
    /// firing mid-flush can record into another buffer, but the commands of
    /// THIS one are all resolved before any of them applies — so a resolution
    /// cannot observe a registry the flush itself has changed.
    ///
    /// Registering a type is itself a world mutation, which is why this is at
    /// flush time and not at record time: a buffer with no world cannot
    /// register, and a buffer that could would be a world handle.
    pub fn resolveComponentIds(self: *CommandBuffer, world: *World) !void {
        for (self.commands.items) |*cmd| {
            switch (cmd.*) {
                .spawn => |*sp| {
                    for (sp.resolvers, sp.component_ids[0..sp.resolvers.len]) |r, *slot| {
                        slot.* = try r(world, self.gpa);
                    }
                },
                .add_component => |*a| {
                    if (a.resolve) |r| a.component_id = try r(world, self.gpa);
                },
                .remove_component => |*r| {
                    if (r.resolve) |f| r.component_id = try f(world, self.gpa);
                },
                // The tag commands carry a `tagset_id` their caller already
                // holds: nothing to resolve, and nothing that needs a world.
                .despawn, .set_tag, .clear_tag => {},
            }
        }
    }

    /// Apply a single command. Exposed at module scope so the
    /// observer-aware flush in `observers.zig` can interleave
    /// dispatch between mutations.
    pub fn applyOne(self: *CommandBuffer, world: *World, cmd: Command) !void {
        switch (cmd) {
            .spawn => |s| {
                _ = try world.spawnDynamicWithValues(
                    self.gpa,
                    s.component_ids,
                    s.payloads,
                );
            },
            .despawn => |d| {
                try world.despawn(self.gpa, d.entity);
            },
            .add_component => |a| {
                try world.addComponentDynamic(
                    self.gpa,
                    a.entity,
                    a.component_id,
                    a.bytes,
                );
            },
            .remove_component => |r| {
                try world.removeComponentDynamic(
                    self.gpa,
                    r.entity,
                    r.component_id,
                );
            },
            .set_tag => |t| {
                try world.applyTagMutation(self.gpa, t.entity, t.tagset_id, t.bit_index, true);
            },
            .clear_tag => |t| {
                try world.applyTagMutation(self.gpa, t.entity, t.tagset_id, t.bit_index, false);
            },
        }
    }
};

// ─── inline tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "CommandBuffer init/deinit round-trip is leak-free" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    var cmd = CommandBuffer.init(gpa);
    defer cmd.deinit();
    try testing.expectEqual(@as(usize, 0), cmd.commandCount());
}

test "CommandBuffer.spawn records but does not mutate world" {
    const gpa = testing.allocator;
    var world = World.init();
    defer world.deinit(gpa);

    var cmd = CommandBuffer.init(gpa);
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

    var cmd = CommandBuffer.init(gpa);
    defer cmd.deinit();

    try cmd.spawn(.{
        world_mod.Transform{},
        world_mod.Velocity{},
    });
    try cmd.flush(&world);

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

    var cmd = CommandBuffer.init(gpa);
    defer cmd.deinit();

    // Recorded, not yet applied — the entity still lacks TagSet.
    try cmd.setTag(eid, tagset_id, 3);
    try testing.expectEqual(@as(usize, 1), cmd.commandCount());
    {
        const loc = world.dynamicLocation(eid).?;
        try testing.expect(world.dynamicArchetype(loc.archetype_idx).componentIndex(tagset_id) == null);
    }

    // Flush adds TagSet (archetype transition) with bit 3 set.
    try cmd.flush(&world);
    try testing.expectEqual(@as(u64, 1) << 3, readTagWord(&world, tagset_id, eid));

    // clear_tag flips the bit back in place (no further transition).
    try cmd.clearTag(eid, tagset_id, 3);
    try cmd.flush(&world);
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
