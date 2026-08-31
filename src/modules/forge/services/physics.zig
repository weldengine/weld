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

const Forge3DModule = module.Forge3DModule;
const Vec3 = api.precision.WorldVec3;

/// The service's context: the module the calls reach.
pub const Ctx = struct {
    m: *Forge3DModule,
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
    },
};

/// The emitted `physics.d.etch`. Embedded, never hand-written — G3's emitter
/// produces it and `bindgen-check` guards it.
pub const declaration_source = @embedFile("physics.d.etch");
