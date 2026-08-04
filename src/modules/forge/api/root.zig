//! `forge/api` — the public Forge API surface (Tier 1).
//!
//! ECS component types (`engine-physics-forge.md` §2) and physics
//! descriptor/handle types (`engine-tier-interfaces.md` §1). Type definitions
//! only — no ECS registration, no `ModuleContext`, no interface instantiation
//! (deferred to the milestone that wires forge_3d as a stepping module). The
//! `forge_3d` solver (E3) and any Tier-3 backend depend on this surface;
//! `core.ecs.EntityId`/`Velocity` reach consumers through here.

const components = @import("components.zig");
const types = @import("types.zig");

// --- ECS components (extern POD) ---

/// Rigid-body material + simulation parameters.
pub const RigidBody = components.RigidBody;
/// A collision shape attached to an entity.
pub const CollisionShape = components.CollisionShape;
/// Per-shape parameter union overlaid by `CollisionShape.shape_type`.
pub const ShapeParams = components.ShapeParams;
/// Accumulated per-frame forces + torques.
pub const PhysicsForces = components.PhysicsForces;
/// Linear + angular velocity (re-export of `core.ecs.components.Velocity`).
pub const Velocity = components.Velocity;

// --- Descriptor + handle types ---

/// Generational ECS entity handle (re-export of `core.ecs.EntityId`).
pub const EntityId = types.EntityId;
/// Opaque physics-body handle (`u32`, `index:24 | generation:8`).
pub const BodyId = types.BodyId;
/// Opaque collision-shape handle (`u32`, same packing as `BodyId`).
pub const ShapeId = types.ShapeId;
/// Opaque character-controller handle (`u32`, same packing as `BodyId`).
pub const CharacterId = types.CharacterId;
/// The `index:24 | generation:8` packing shared by `BodyId`, `ShapeId` and
/// `CharacterId`.
pub const PackedId = types.PackedId;
/// Simulation class of a body (static / kinematic / dynamic).
pub const BodyType = types.BodyType;
/// Collision-shape kind (C1.1-complete set).
pub const ShapeType = types.ShapeType;
/// Shape parameters tagged by `ShapeType`.
pub const ShapeDescriptor = types.ShapeDescriptor;
/// Everything needed to create one body.
pub const BodyDescriptor = types.BodyDescriptor;
/// Physics pose (position + rotation, no scale).
pub const Transform = types.Transform;

// --- Character controller (`engine-physics-forge.md` §1.12) ---

/// Everything needed to create one character controller. A controller is VIRTUAL —
/// it takes part in no solver pass, and its pose is written by `moveCharacter` alone.
pub const CharacterDescriptor = types.CharacterDescriptor;
/// The TERNARY ground verdict. Zig mirror of the Etch enum owned by
/// `engine-movement.md` §2 — same order, same values.
pub const GroundState = types.GroundState;
/// Result of one `moveCharacter`: the resolved BASE position plus the five ground
/// quantities, of which `ground_state` is the discriminator.
pub const CharacterMoveResult = types.CharacterMoveResult;

// --- Queries (the complete frozen family, `engine-tier-interfaces.md` §1) ---

/// Number of object layers a query mask can address; `addBody` rejects a body
/// beyond this domain with `error.InvalidCollisionLayer`.
pub const collision_layer_count = types.collision_layer_count;
/// Filtering shared by the whole query family (object-layer mask + exclusions).
/// Distinct from the `QueryFilter` of §6 `AIModule`.
pub const PhysicsQueryFilter = types.PhysicsQueryFilter;
/// Which side of a mesh TRIANGLE an entry answers on. Carried only by the entries whose
/// answer differs between the two modes; vacuous on every other shape (M1.1.11.1).
pub const BackFaceMode = types.BackFaceMode;
/// A world-space ray query.
pub const RaycastQuery = types.RaycastQuery;
/// A cast of an arbitrary shape (one entry for sphere / box / capsule).
pub const ShapeCastQuery = types.ShapeCastQuery;
/// An overlap test of an arbitrary shape.
pub const OverlapQuery = types.OverlapQuery;
/// One ray hit.
pub const RaycastHit = types.RaycastHit;
/// One shape-cast hit (two sub-shapes: the cast one and the one hit).
pub const ShapeCastHit = types.ShapeCastHit;
/// Result of `closestPoint`.
pub const ClosestPointResult = types.ClosestPointResult;

// Pins so the inline tests in the sub-files are analysed when this module is
// built as a test target (engine-zig-conventions.md §13).
comptime {
    _ = components;
    _ = types;
}
