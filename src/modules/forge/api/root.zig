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

/// Opaque physics-body handle (`u32`, `index:24 | generation:8`).
pub const BodyId = types.BodyId;
/// Opaque collision-shape handle (`u32`, same packing as `BodyId`).
pub const ShapeId = types.ShapeId;
/// The `index:24 | generation:8` packing shared by `BodyId`/`ShapeId`.
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

// Pins so the inline tests in the sub-files are analysed when this module is
// built as a test target (engine-zig-conventions.md §13).
comptime {
    _ = components;
    _ = types;
}
