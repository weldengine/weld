//! `forge/api/components.zig` — the public Forge ECS components.
//!
//! `extern struct` POD, no methods, every field defaulted — same discipline as
//! `core.ecs.components` (`engine-zig-conventions.md` §16). Definitions only:
//! no registration here (that is runtime wiring for the milestone that
//! instantiates the module). Layouts pinned by comptime size/align asserts.
//! Per `engine-physics-forge.md` §2.

const std = @import("std");
const core = @import("weld_core");
const types = @import("types.zig");

const BodyType = types.BodyType;
const ShapeType = types.ShapeType;

/// Linear + angular velocity — re-exported from `core.ecs.components` rather
/// than redefined (moving it into Forge would invert the core→Tier-1
/// dependency; Notes decision 2). All physics call sites use `api.Velocity`.
pub const Velocity = core.ecs.components.Velocity;

/// A body whose island is ASLEEP — a zero-size marker the orchestrator adds and removes
/// as islands sleep and wake (`engine-physics-solver.md` §1.8.6).
///
/// **It is the only way a rule can ask whether a body is asleep**, and it is what carries
/// the archetype-level skip `engine-physics-forge.md` §1.4 credits to native ECS
/// integration: a query that excludes it steps over a whole archetype of resting debris
/// instead of testing a flag per entity. The skip lives HERE, in the `Transform`
/// synchronisation, and not in the solver — whose body store is a SoA indexed by `BodyId`
/// and knows nothing of archetypes.
///
/// ZERO-SIZE, deliberately: a marker carries no data, and giving it a payload byte would
/// invite one. It is `extern struct {}` so it stays POD under `ARCH-004` like every other
/// component here.
pub const Sleeping = extern struct {};

/// A rigid body's material and simulation parameters
/// (`engine-physics-forge.md` §2). Position/rotation live on the ECS
/// `Transform`; velocity on `Velocity`; accumulated forces on `PhysicsForces`.
pub const RigidBody = extern struct {
    /// Simulation class.
    body_type: BodyType = .dynamic,
    /// Mass (kg).
    mass: f32 = 1.0,
    /// Linear velocity damping per second.
    linear_damping: f32 = 0.05,
    /// Angular velocity damping per second.
    angular_damping: f32 = 0.05,
    /// Coulomb friction coefficient.
    friction: f32 = 0.5,
    /// Restitution (bounciness).
    restitution: f32 = 0.3,
    /// Per-body gravity multiplier.
    gravity_scale: f32 = 1.0,
    /// Continuous collision detection for fast movers.
    continuous_collision: bool = false,
    /// Whether the body may go to sleep when at rest.
    can_sleep: bool = true,
};

/// Per-shape parameters for a `CollisionShape`, an `extern` (untagged) union
/// overlaid by `CollisionShape.shape_type` (§2 "extern union of per-shape
/// params"). M1.1.0 carries sphere/box/capsule; other shapes read no params.
pub const ShapeParams = extern union {
    /// Sphere radius (metres).
    sphere: extern struct { radius: f32 = 0.5 },
    /// Box half-extents (metres).
    box: extern struct { half_extents: [3]f32 = .{ 0.5, 0.5, 0.5 } },
    /// Capsule radius + cylinder half-height (metres), Y axis.
    capsule: extern struct { radius: f32 = 0.3, half_height: f32 = 0.5 },
};

/// A collision shape attached to an entity (`engine-physics-forge.md` §2). The
/// `shape_type` tag selects the active `params` variant.
pub const CollisionShape = extern struct {
    /// Which shape the `params` union holds.
    shape_type: ShapeType = .sphere,
    /// Per-shape parameters, overlaid by `shape_type`.
    params: ShapeParams = .{ .sphere = .{} },
    /// Local-space position offset (metres).
    offset: [3]f32 = .{ 0, 0, 0 },
    /// Local-space rotation offset (quaternion, x, y, z, w).
    rotation_offset: [4]f32 = .{ 0, 0, 0, 1 },
    /// Collision-layer index.
    collision_layer: u8 = 0,
    /// Trigger (overlap events only, no physical response).
    is_trigger: bool = false,
    /// OBJECT layers this trigger detects — the ECS authoring source of
    /// `BodyDescriptor.trigger_layer_mask` (`engine-physics-forge.md` §2). A
    /// candidate passes when `(1 << candidate_layer) & trigger_layer_mask` is
    /// non-zero, the same mechanism as `PhysicsQueryFilter.layer_mask`
    /// (`engine-physics-solver.md` §1.13.5).
    ///
    /// `is_trigger` removes the physical RESPONSE; this field governs the
    /// DETECTION. The two axes are independent and never substitute for each other
    /// (§1.13.2). INERT when `is_trigger` is false.
    trigger_layer_mask: u32 = 0xFFFFFFFF,
};

/// Forces + torques accumulated during a frame, applied and reset each fixed
/// tick. Padded to 16-byte lanes like `Velocity` (§2).
pub const PhysicsForces = extern struct {
    /// Accumulated linear force (N).
    force: [3]f32 align(16) = .{ 0, 0, 0 },
    _pad0: f32 = 0,
    /// Accumulated torque (N·m).
    torque: [3]f32 align(16) = .{ 0, 0, 0 },
    _pad1: f32 = 0,
};

comptime {
    // POD layout pins — any future field change must revisit these.
    std.debug.assert(@sizeOf(RigidBody) == 32);
    std.debug.assert(@alignOf(RigidBody) == 4);
    // 48 -> 52 at M1.1.13. MEASURED, not reasoned: `collision_layer` sits at 44 and
    // `is_trigger` at 45, so the byte after them is 46; the `u32` needs 4-alignment
    // and therefore starts at 48, leaving bytes 46 and 47 as padding in BOTH layouts.
    // The struct gains four full bytes and REUSES NOTHING — an earlier version of this
    // comment claimed the trailing padding was consumed, which is false in two ways at
    // once, so the three offsets below are pinned rather than described.
    //
    // These three are what decide the 52: a different arrangement landing on the same
    // size must fail here, and size alone would not catch it. COUNTER-FACTUAL MEASURED,
    // by changing the LAYOUT and never the expected constant — an oracle that judges a
    // layout has to be confronted with a different layout. `collision_layer` and
    // `is_trigger` were SWAPPED in the declaration: both are one byte and adjacent, so
    // the size stays 52 and the alignment 4 and only the two offsets exchange. With these
    // three asserts removed the whole suite still passed 497/497 — so the size and align
    // pins really do accept the permutation — and with them present the build failed
    // here. Moving the expected value from 44 to 43 would have proven only that the line
    // executes.
    std.debug.assert(@offsetOf(CollisionShape, "collision_layer") == 44);
    std.debug.assert(@offsetOf(CollisionShape, "is_trigger") == 45);
    std.debug.assert(@offsetOf(CollisionShape, "trigger_layer_mask") == 48);
    // This assert and the test that doubles it are updated TOGETHER — a pin changed in
    // one place only is the defect the pair exists to catch.
    std.debug.assert(@sizeOf(CollisionShape) == 52);
    std.debug.assert(@alignOf(CollisionShape) == 4);
    std.debug.assert(@sizeOf(PhysicsForces) == 32);
    std.debug.assert(@alignOf(PhysicsForces) == 16);
}

const testing = std.testing;

test "component layouts are the pinned extern-POD sizes" {
    try testing.expectEqual(@as(usize, 32), @sizeOf(RigidBody));
    try testing.expectEqual(@as(usize, 4), @alignOf(RigidBody));
    try testing.expectEqual(@as(usize, 52), @sizeOf(CollisionShape));
    try testing.expectEqual(@as(usize, 4), @alignOf(CollisionShape));
    // The three offsets that decide the 52 (see the comptime block): `collision_layer`
    // at 44, `is_trigger` at 45, and the `u32` at 48 — bytes 46 and 47 are padding in
    // the 48-byte layout and stay padding in this one. Doubled here so the pin cannot be
    // moved in one place only.
    try testing.expectEqual(@as(usize, 44), @offsetOf(CollisionShape, "collision_layer"));
    try testing.expectEqual(@as(usize, 45), @offsetOf(CollisionShape, "is_trigger"));
    try testing.expectEqual(@as(usize, 48), @offsetOf(CollisionShape, "trigger_layer_mask"));
    try testing.expectEqual(@as(usize, 32), @sizeOf(PhysicsForces));
    try testing.expectEqual(@as(usize, 16), @alignOf(PhysicsForces));
}

test "Velocity is the core component (re-export identity)" {
    try testing.expect(Velocity == core.ecs.components.Velocity);
}

test "RigidBody defaults match the spec" {
    const rb = RigidBody{};
    try testing.expectEqual(BodyType.dynamic, rb.body_type);
    try testing.expectEqual(@as(f32, 1.0), rb.mass);
    try testing.expectEqual(@as(f32, 0.05), rb.linear_damping);
    try testing.expectEqual(@as(f32, 0.05), rb.angular_damping);
    try testing.expectEqual(@as(f32, 0.5), rb.friction);
    try testing.expectEqual(@as(f32, 0.3), rb.restitution);
    try testing.expectEqual(@as(f32, 1.0), rb.gravity_scale);
    try testing.expectEqual(false, rb.continuous_collision);
    try testing.expectEqual(true, rb.can_sleep);
}

test "CollisionShape default is a unit-ish sphere trigger-off" {
    const cs = CollisionShape{};
    try testing.expectEqual(ShapeType.sphere, cs.shape_type);
    try testing.expectEqual(@as(f32, 0.5), cs.params.sphere.radius);
    try testing.expectEqual(@as(f32, 1), cs.rotation_offset[3]);
    try testing.expectEqual(false, cs.is_trigger);
    // Detection defaults to ALL object layers, the same value and the same reason as
    // `PhysicsQueryFilter.layer_mask`: a zero default would make a declared trigger
    // detect nothing, which reads as a broken engine rather than a forgotten field.
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), cs.trigger_layer_mask);
    try testing.expectEqual(u32, @TypeOf(cs.trigger_layer_mask));
}

test "CollisionShape mirrors the two authoring fields of the body descriptor" {
    // The ECS component is the AUTHORING source and the descriptor is the interface
    // form; the pair is what `engine-physics-forge.md` §2 calls the translation
    // `CollisionShape.is_trigger` -> `BodyDescriptor.is_trigger` -> body flag. Pinning
    // the two names and the two defaults together is what makes a rename on one side a
    // failing test rather than a silently half-wired role.
    const cs = CollisionShape{};
    const bd = types.BodyDescriptor{
        .entity = .{ .index = 0, .generation = 0 },
        .body_type = .static,
        .shape = 0,
    };
    try testing.expectEqual(bd.is_trigger, cs.is_trigger);
    try testing.expectEqual(bd.trigger_layer_mask, cs.trigger_layer_mask);
    try testing.expectEqual(@TypeOf(bd.trigger_layer_mask), @TypeOf(cs.trigger_layer_mask));

    // The count is what makes an ADDITION visible; the by-name references above cannot.
    // A component is `extern struct` POD read across the C ABI, so a field appended here
    // after the M1.1.15 freeze shifts every offset behind it.
    //
    // COUNTER-FACTUAL MEASURED, and with a field chosen so that this line is the ONLY one
    // that moves: a `u8` inserted between `is_trigger` and `trigger_layer_mask` lands in
    // padding byte 46, so the size stays 52, the alignment 4 and the three pinned offsets
    // unchanged — every assert above passes and this one reports `expected 7, found 8`.
    try testing.expectEqual(@as(usize, 7), @typeInfo(CollisionShape).@"struct".fields.len);
}

test "Sleeping is a zero-size POD marker" {
    // The size is the contract: a marker with a payload byte is a different thing, and the
    // next reader would put a field in it. Pinned in both directions — the size AND the
    // field count — because a single `u8` field would keep neither.
    try testing.expectEqual(@as(usize, 0), @sizeOf(Sleeping));
    try testing.expectEqual(@as(usize, 0), @typeInfo(Sleeping).@"struct".fields.len);
    try testing.expect(@typeInfo(Sleeping).@"struct".layout == .@"extern");
}

test "Sleeping survives registration, spawn, add and remove in a real World" {
    // THE UNKNOWN THIS TEST EXISTS FOR. No zero-size component existed anywhere in the
    // repository before this one — the ECS's own `Tag` fixture is a `u32` — so "the chunk
    // layout tolerates a zero-size column" was an assumption and not a fact. The chunk's
    // per-slot cost carries `EntityId` plus two ticks per component whatever the component
    // measures, so the capacity divisor cannot reach zero; that is an argument, and this is
    // the measurement.
    const gpa = testing.allocator;
    var world = core.ecs.World.init();
    defer world.deinit(gpa);

    // The entity carries what a physics body carries — `Transform` and `Velocity` — and
    // the marker goes on top, which is exactly the shape the orchestrator drives.
    const e = try world.spawn(gpa, .{}, .{});
    try testing.expect(world.get(Sleeping, e) == null);

    try world.addComponent(gpa, e, Sleeping, .{});
    try testing.expect(world.get(Sleeping, e) != null);

    // BOTH DIRECTIONS, because the orchestrator drives both: a body that wakes loses the
    // marker and one that sleeps again regains it, each transition an archetype migration.
    try world.removeComponent(gpa, e, Sleeping);
    try testing.expect(world.get(Sleeping, e) == null);
    try world.addComponent(gpa, e, Sleeping, .{});
    try testing.expect(world.get(Sleeping, e) != null);

    // And the entity's OTHER components survived the two migrations — a zero-size column
    // must not disturb the ones beside it, which is the half of this that a size assert
    // cannot reach.
    try testing.expect(world.get(core.ecs.components.Transform, e) != null);
    try testing.expect(world.get(Velocity, e) != null);
}
