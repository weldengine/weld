//! The Tier 1 physics service, callable from Etch (M1.1.15.2 G6,
//! `etch-abi-zig.md` §8, calling surface `engine-physics-forge.md` §13).
//!
//! **THE SIGNATURES ARE COMPONENTWISE, and it is a measurement that forced it,
//! not a preference.** §13 writes `physics_raycast(origin, direction, ...)` with
//! `Vec3` arguments and a struct result. Measured in the tree: `Vec3` is a type
//! the CHECKER knows (`types.BuiltinType.vec3`) and there is NO `vec3` variant in
//! `etch/value.zig` and ZERO `.vec3` handling in `etch/interp.zig` — a `Vec3`
//! value is not executable in the Phase 1 tree-walker at all, independently of
//! anything this service does. So §13's shape is unreachable from a rule today,
//! and the expressible form is scalar. Recorded as a deviation with that
//! measurement; the aggregate form returns when the tree-walker carries an
//! aggregate value.
//!
//! **PRECISION.** Every declared type here is `f64`, `i64`, `bool` or `u64` —
//! never `Real`, never `WorldReal`. That is what makes the emitted `.d.etch`
//! INVARIANT under `-Dphysics_f64`, and it is asserted below rather than left to
//! a reader to notice: the `bindgen-check` premise recorded in the milestone
//! brief expires at this gate, and this is the half of the answer that lives in
//! code. The other half is the measurement — the committed artifact, emitted at
//! f32, checked again under f64.

const std = @import("std");
const services = @import("weld_etch").services;
const api = @import("weld_forge");
const forge_3d = @import("forge_3d");
const module = @import("forge_module");
const core = @import("weld_core");
const sync = @import("forge_sync");
const sync_in = sync.in;

const Forge3DModule = module.Forge3DModule;
const Vec3 = api.precision.WorldVec3;
const Quat = api.precision.WorldQuat;
const WorldReal = api.precision.WorldReal;
const World = core.ecs.World;
const EntityId = core.ecs.EntityId;
const Transform = core.ecs.components.Transform;
const Velocity = api.Velocity;
const RigidBody = api.RigidBody;

/// The service's context: the module the calls reach, plus what a MUTATION needs
/// and a query does not (M1.1.15.2 G11).
///
/// **The ECS and the journal are here because the mutation half of this service
/// is a Tier 1 operation and not an interface entry.** `PhysicsModule` is frozen
/// at thirty-two entries and carries no entity-to-handle resolution, no ECS
/// mirror and no journal — nor should it: an entity is an ECS notion the solver
/// does not have, and a Tier 3 backend replacing `forge_3d` would inherit this
/// service unchanged. So the resolution, the mirror and the journal mark live
/// exactly one layer up, which is this file.
pub const Ctx = struct {
    m: *Forge3DModule,
    ecs: *World,
    /// The SAME journal `syncIn` consults. A wrapper that marked a journal the
    /// seam does not read would be a control with no controlled path — the class
    /// this milestone spent itself closing.
    journal: *sync_in.Journal,
};

// **NO DECLARED TYPE OF THIS SERVICE FOLLOWS `Real`.**
//
// Asserted positively and not left to `typeRefOf`'s refusal list to imply. A
// `Real` parameter would compile at f64 and FAIL at f32, which is loud but
// backwards — this states the property the artifact depends on, in the
// direction it is depended upon.
//
// What the artifact actually depends on is the RENDERED NAME, since the artifact
// is text: every float this service declares renders `float` at both settings, so
// the emitted `.d.etch` cannot move. The measurement that closes it is the
// committed artifact, emitted at f32, checked again under `-Dphysics_f64=true`.
comptime {
    std.debug.assert(std.mem.eql(u8, (services.TypeRef{ .float_ = {} }).etchName(), "float"));
    for (spec.methods) |m| {
        for (m.params) |p| std.debug.assert(p.type.isConvertible());
        std.debug.assert(m.returns.isConvertible());
    }
}

fn vec(x: f64, y: f64, z: f64) Vec3 {
    return api.precision.etchVec3ToWorld(x, y, z);
}

fn rayQuery(ox: f64, oy: f64, oz: f64, dx: f64, dy: f64, dz: f64, max_distance: f64, mask: i64) api.RaycastQuery {
    return .{
        .origin = vec(ox, oy, oz),
        .direction = vec(dx, dy, dz),
        .max_distance = api.precision.etchToWorld(max_distance),
        .filter = .{ .layer_mask = @truncate(@as(u64, @bitCast(mask))) },
    };
}

/// Is anything on the ray? Line of sight, and the entry that reads only WHETHER
/// something blocked — it stops at the first candidate instead of looking for
/// the nearest (§1.11.6).
pub fn raycastAny(
    ctx: *Ctx,
    origin_x: f64,
    origin_y: f64,
    origin_z: f64,
    dir_x: f64,
    dir_y: f64,
    dir_z: f64,
    max_distance: f64,
    layer_mask: i64,
) bool {
    return ctx.m.raycastAny(rayQuery(origin_x, origin_y, origin_z, dir_x, dir_y, dir_z, max_distance, layer_mask));
}

/// The entity the nearest hit belongs to, or `EntityId.dead` on a miss.
///
/// **`dead` and not a sentinel of this service's invention**: the pattern is
/// already reserved as "no handle" across the whole surface, and `0` is a LIVE
/// handle to slot 0 generation 0 — the mistake `CharacterMoveResult.ground_body`
/// made before M1.1.12.
pub fn raycastEntity(
    ctx: *Ctx,
    origin_x: f64,
    origin_y: f64,
    origin_z: f64,
    dir_x: f64,
    dir_y: f64,
    dir_z: f64,
    max_distance: f64,
    layer_mask: i64,
) u64 {
    const hit = ctx.m.raycast(rayQuery(origin_x, origin_y, origin_z, dir_x, dir_y, dir_z, max_distance, layer_mask)) orelse
        return @bitCast(api.EntityId.dead);
    return @bitCast(hit.entity);
}

/// The distance to the nearest hit. **Fallible rather than sentinelled**: a miss
/// has no distance, and returning `-1` or `max_distance` would be a value a
/// caller cannot tell from a real one — the truncated-prefix class this
/// milestone has closed twice.
pub fn raycastDistance(
    ctx: *Ctx,
    origin_x: f64,
    origin_y: f64,
    origin_z: f64,
    dir_x: f64,
    dir_y: f64,
    dir_z: f64,
    max_distance: f64,
    layer_mask: i64,
) !f64 {
    const hit = ctx.m.raycast(rayQuery(origin_x, origin_y, origin_z, dir_x, dir_y, dir_z, max_distance, layer_mask)) orelse
        return error.NoHit;
    return api.precision.worldToEtch(hit.distance);
}

/// The service's fixed staging for the count entry. Named rather than inlined so
/// the bound the caller meets and the bound the code enforces are one thing.
pub const point_query_capacity: usize = 64;

/// How many entities the point lies inside. Distinct entities, the adapter having
/// already deduplicated bodies onto entities (§1.11.14).
///
/// **SIGNALS its truncation instead of returning `min(total, capacity)` under a
/// doc comment that says "total".** The service surface carries no slice, so this
/// entry stages into a fixed buffer; a count equal to the capacity CANNOT be told
/// from a larger one, so both are refused. Refusing a legitimate exactly-`capacity`
/// answer is the safe direction: a caller that receives an error learns there is a
/// bound, where one that receives `64` for a set of two hundred learns nothing and
/// acts on it.
pub fn pointQueryCount(
    ctx: *Ctx,
    x: f64,
    y: f64,
    z: f64,
    layer_mask: i64,
) !i64 {
    var buf: [point_query_capacity]api.EntityId = undefined;
    const n = try ctx.m.pointQuery(vec(x, y, z), .{ .layer_mask = @truncate(@as(u64, @bitCast(layer_mask))) }, &buf);
    if (n >= point_query_capacity) return error.TooManyResults;
    return @intCast(n);
}

// ---------------------------------------------------------------------------
// THE MUTATION HALF (M1.1.15.2 G11)
//
// `engine-movement.md` §9, §10 and §11 spell these `physics_move_character`,
// `physics_resize_character` and `physics_set_character_position`, and marks the
// three PROVISIONAL, deferring the definitive names to this milestone;
// `engine-physics-forge.md` § *Autorite d'ecriture* names `physics_move_kinematic`
// the explicit kinematic displacement. The prefix is dropped because the SERVICE
// carries it: the tree-walker dispatches by RECEIVER, so `physics.move_character`
// is what a rule writes and `physics_move_character` has no implementation to bind
// to — the same mapping G6 already applied to `physics_raycast_any`.
//
// **RESOLUTION IS THIS LAYER'S, and it is not an interface entry.** An entity is
// an ECS notion; `PhysicsModule` is frozen at thirty-two entries, takes handles,
// and would need a thirty-third to answer "which body is this entity". The seam's
// own election answers it, shared rather than restated (`sync.electedBodyOf`).
//
// **A STALE OR ABSENT SUBJECT IS A TYPED ERROR, never a silent no-op.** A rule
// that moves a body its entity no longer owns has a defect, and returning `void`
// with nothing done is the truncated-success class this milestone closed twice at
// the interface. `E0903` makes a rule non-`throws`, so the call site wraps in a
// local `try` / `catch` — the cost `engine-phase-1-plan.md` accepted for exactly
// this reason.

fn bodyOf(ctx: *Ctx, entity: u64) !api.BodyId {
    const e: EntityId = @bitCast(entity);
    return sync.electedBodyOf(&ctx.m.world, e) orelse error.NoPhysicsBody;
}

fn charOf(ctx: *Ctx, entity: u64) !api.CharacterId {
    const e: EntityId = @bitCast(entity);
    return sync.characterOf(&ctx.m.world, e) orelse error.NoCharacter;
}

/// Move a KINEMATIC body to a target pose over `dt`, deriving both velocities and
/// mirroring `Transform` AND `Velocity` into the ECS in the same call.
///
/// **This is the one operation where the derivation is EXPLICIT**, and the
/// contrast is the contract (`engine-physics-forge.md` § *Autorite d'ecriture*): a
/// direct ECS mutation of `Transform` stays a TELEPORTATION — exact application,
/// no derived velocity — because a mutated `Transform` does not say WHICH
/// operation to perform, and `setBodyTransform` / `moveKinematic` share that
/// distinction contractually (`engine-physics-queries.md` §1.12.5). A caller that
/// wants the support velocity a platform must report calls this; a caller that
/// wants a jump cut writes `Transform`.
///
/// **The mirror is ATOMIC with the move**, not a courtesy: without it a rule
/// reading `Transform` later in the same tick sees the pose of the previous tick,
/// and `Velocity` — which nothing else writes for a kinematic body until
/// `syncOut` — would carry the previous tick's derivation while the body already
/// occupies the new pose.
///
/// **And it MARKS THE JOURNAL**, which is what stops `syncIn` from applying a
/// second, derivation-free version of the same tick's intent. Without the mark,
/// a `Transform` written directly in the same tick is replayed by the seam as a
/// teleportation that overrides this call's atomic result, leaving the body at the
/// raw pose while its velocity still describes the motion toward the target — two
/// sources on one fact, inside one tick.
pub fn moveKinematic(
    ctx: *Ctx,
    entity: u64,
    x: f64,
    y: f64,
    z: f64,
    rot_x: f64,
    rot_y: f64,
    rot_z: f64,
    rot_w: f64,
    dt: f64,
) !void {
    const body = try bodyOf(ctx, entity);
    const rot = Quat.fromArray(.{
        api.precision.etchToWorld(rot_x),
        api.precision.etchToWorld(rot_y),
        api.precision.etchToWorld(rot_z),
        api.precision.etchToWorld(rot_w),
    });
    // The rotation is used by CONJUGATION to derive the angular velocity, and a
    // conjugate inverts a unit quaternion alone — the domain assert class
    // M1.1.10 established on every rotation reaching a kernel. Refused rather
    // than normalised: normalising would serve an intent the caller did not
    // express, and `(0,0,0,0)` has no direction to recover.
    const q = rot.toArray();
    const n = q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3];
    if (!std.math.isFinite(n) or @abs(n - 1) > 1e-3) return error.RotationNotUnit;
    if (!(dt > 0) or !std.math.isFinite(dt)) return error.NonPositiveDt;

    ctx.m.moveKinematic(body, vec(x, y, z), rot, api.precision.etchToWorld(dt));
    const owner: EntityId = @bitCast(entity);
    // The SAME read-first mirror `syncIn` publishes with, so the wrapper's mirror and
    // the seam's cannot disagree about the state they describe or about when they mark.
    _ = sync.mirrorSolverState(ctx.ecs, owner, &ctx.m.world, body, true);
    try ctx.journal.markApplied(ctx.m.gpa, body, ctx.ecs.current_tick);
}

/// Declare who writes this entity's pose. Writes the field and NOTHING else.
///
/// **The transition itself belongs to `syncIn` and not here**, and that is
/// structural rather than a division of labour: `RigidBody.authority` is a PUBLIC
/// field a rule can write directly with `entity.get_mut(RigidBody).authority`, so
/// a wrapper can never be the guardian of the invariant. What this entry buys is
/// a name and a domain check, not exclusivity — and it is deliberately identical
/// in effect to the direct write, or the two paths would differ.
pub fn setAuthority(ctx: *Ctx, entity: u64, authority: i64) !void {
    if (authority < 0 or authority > 1) return error.InvalidAuthority;
    const value: api.PhysicsAuthority = @enumFromInt(@as(u8, @intCast(authority)));
    const owner: EntityId = @bitCast(entity);
    const rb = ctx.ecs.get(RigidBody, owner) orelse return error.NoRigidBody;
    // READ FIRST — same reason as the mirror above, and it also keeps a rule that
    // re-declares the authority it already has from marking the component.
    if (rb.authority == value) return;
    ctx.ecs.getMut(RigidBody, owner).?.authority = value;
}

/// Sweep a character by `displacement` metres over `dt`, and report the ground
/// verdict as its `GroundState` ordinal.
///
/// **THE RESOLVED POSE IS MIRRORED HERE, where `engine-movement.md` §10 writes it
/// in the rule.** §10 spells `entity.get_mut(Transform).position = result.position`
/// because its `result` is a record; the Phase 1 tree-walker carries no aggregate
/// value, so a componentwise entry cannot return one and the assignment has no
/// right-hand side. Moving the mirror INTO the call is the move the corpus itself
/// makes for `physics_move_kinematic`, and it is strictly safer: the pose and the
/// verdict cannot be written apart. Recorded as a deviation.
///
/// **The position written is the capsule's BASE and not its centre** (§1.12.3),
/// which is the controller's convention and differs from a body's.
///
/// The four other ground quantities — normal, entity, body, velocity — are NOT
/// exposed. Reading them back would need either an aggregate the tree-walker does
/// not carry or a remembered last result, and §1.12.8 states that the controller
/// introduces no cache. They reach Etch with the movement system that consumes
/// them, which owns `MovementState`.
pub fn moveCharacter(
    ctx: *Ctx,
    entity: u64,
    dx: f64,
    dy: f64,
    dz: f64,
    dt: f64,
) !i64 {
    const id = try charOf(ctx, entity);
    const r = try ctx.m.moveCharacter(id, vec(dx, dy, dz), api.precision.etchToWorld(dt));
    const owner: EntityId = @bitCast(entity);
    if (ctx.ecs.get(Transform, owner)) |t| {
        const p = r.position.toArray();
        if (!std.mem.eql(WorldReal, &t.pos, &p)) ctx.ecs.getMut(Transform, owner).?.pos = p;
    }
    return @intFromEnum(r.ground_state);
}

/// Resize a character, anchored at its feet. `true` on success, `false` when the
/// target volume is OCCUPIED, and a typed error for an inadmissible request.
///
/// **The three outcomes stay three** (§1.12.7). A `bool` alone would make "I
/// cannot stand up" and "your handle is dead" indistinguishable, which is the
/// false-negative class §1.11.3 refuses; the split is `shapeCast`'s exactly —
/// error channel for the inadmissible input, absence of a value for the real
/// refusal.
pub fn resizeCharacter(ctx: *Ctx, entity: u64, radius: f64, height: f64) !bool {
    const id = try charOf(ctx, entity);
    return ctx.m.resizeCharacter(
        id,
        api.precision.etchToWorld(radius),
        api.precision.etchToWorld(height),
    );
}

/// Teleport a character. It sweeps nothing and resolves nothing, so it can leave
/// the capsule interpenetrating — that IS the contract (§1.12.8) — and it
/// INVALIDATES the reported ground verdict, which returns to `.in_air`.
///
/// No `Transform` mirror here, and the asymmetry with `move_character` is the
/// corpus's: `engine-movement.md` §11 writes `Transform.position = destination` in
/// the rule, right beside the call, because the caller already HAS the destination
/// — it just passed it. Mirroring would be this service writing a value the rule
/// can write itself, and the two could then disagree about which is authoritative.
pub fn setCharacterPosition(ctx: *Ctx, entity: u64, x: f64, y: f64, z: f64) !void {
    const id = try charOf(ctx, entity);
    ctx.m.setCharacterPosition(id, vec(x, y, z));
}

/// The service's `ServiceSpec`. Parameter NAMES are declared because Zig
/// carries none; every type and every `throws` flag is derived from the
/// implementations above, so the emitted declaration cannot drift from them.
pub const spec = services.ServiceSpec{
    .name = "physics",
    .version = 1,
    .methods = &.{
        services.method(
            "raycast_any",
            "Is anything on the ray? Stops at the first candidate.",
            *Ctx,
            &.{ "origin_x", "origin_y", "origin_z", "dir_x", "dir_y", "dir_z", "max_distance", "layer_mask" },
            raycastAny,
        ),
        services.method(
            "raycast_entity",
            "The entity of the nearest hit, or the dead handle on a miss.",
            *Ctx,
            &.{ "origin_x", "origin_y", "origin_z", "dir_x", "dir_y", "dir_z", "max_distance", "layer_mask" },
            raycastEntity,
        ),
        services.method(
            "raycast_distance",
            "Distance to the nearest hit. Throws when the ray hits nothing.",
            *Ctx,
            &.{ "origin_x", "origin_y", "origin_z", "dir_x", "dir_y", "dir_z", "max_distance", "layer_mask" },
            raycastDistance,
        ),
        services.method(
            "point_query_count",
            "How many distinct entities contain the point.",
            *Ctx,
            &.{ "x", "y", "z", "layer_mask" },
            pointQueryCount,
        ),
        services.method(
            "move_kinematic",
            "Move a kinematic body to a target pose over dt, deriving both velocities and mirroring Transform and Velocity.",
            *Ctx,
            &.{ "entity", "x", "y", "z", "rot_x", "rot_y", "rot_z", "rot_w", "dt" },
            moveKinematic,
        ),
        services.method(
            "set_authority",
            "Declare who writes this entity's pose: 0 = solver, 1 = gameplay.",
            *Ctx,
            &.{ "entity", "authority" },
            setAuthority,
        ),
        services.method(
            "move_character",
            "Sweep a character by a displacement in metres; returns the GroundState ordinal.",
            *Ctx,
            &.{ "entity", "dx", "dy", "dz", "dt" },
            moveCharacter,
        ),
        services.method(
            "resize_character",
            "Resize a character, anchored at its feet. False when the target volume is occupied.",
            *Ctx,
            &.{ "entity", "radius", "height" },
            resizeCharacter,
        ),
        services.method(
            "set_character_position",
            "Teleport a character. Sweeps nothing, resolves nothing, and invalidates the ground verdict.",
            *Ctx,
            &.{ "entity", "x", "y", "z" },
            setCharacterPosition,
        ),
    },
};

/// The emitted `physics.d.etch`. Embedded, never hand-written — G3's emitter
/// produces it and `bindgen-check` guards it.
pub const declaration_source = @embedFile("physics.d.etch");
