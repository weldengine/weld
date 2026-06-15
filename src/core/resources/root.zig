//! FROZEN — see engine-phase-0-criteria.md C0.5 (M0.2)
//!
//! Public surface of the M0.2 / E3 resource subsystem.
//!
//! Resources are singleton-entity components — exactly one value of
//! each resource type lives in the world (cf. `engine-spec.md`
//! §2.9). Wired into the ECS via the dynamic archetype path:
//! `setResource(world, gpa, value)` spawns a dedicated entity in a
//! singleton-flagged archetype, `getResource` / `getResourceMut`
//! route through the existing component access machinery, and
//! change detection reuses the M0.1 tick-based mechanism.
//!
//! The module convention follows `src/core/ecs/root.zig` and
//! `src/core/rtti/root.zig` — single canonical entry point. No
//! parallel `src/core/resources.zig` file.

const registry_mod = @import("registry.zig");
const api_mod = @import("api.zig");

// -- Sub-module aliases ------------------------------------------------

/// Registry storage (`(TypeId → EntityId)` map + marker component).
pub const registry = registry_mod;
/// Public API surface — set, get, getMut, has, remove, changed.
pub const api = api_mod;

// -- Flat type surface -------------------------------------------------

/// Indexes the world's singleton-entity resources.
pub const ResourceRegistry = registry_mod.ResourceRegistry;
/// Marker component added to every singleton-resource entity.
pub const ResourceMarker = registry_mod.ResourceMarker;
/// Error set returned by the write paths (`setResource`,
/// `removeResource`).
pub const ResourceError = api_mod.ResourceError;

/// FROZEN — see engine-phase-0-criteria.md C0.5 (M0.9)
/// Version of the frozen Resources (M0.2 singleton-entity) Tier-0 public
/// surface (ResourceError + the set/get/getMut/has/remove/changed fns).
/// Bumped on any breaking change — a tracked migration, not a freeze
/// failure (the `*_PROTOCOL_VERSION` rule, generalized from `WELD_IPC_PROTOCOL_VERSION`).
pub const WELD_RESOURCES_PROTOCOL_VERSION: u32 = 1;

// -- Flat function surface ---------------------------------------------

/// Insert or update the singleton resource of type `T`.
pub const setResource = api_mod.setResource;
/// Read-only view of the singleton resource of type `T`.
pub const getResource = api_mod.getResource;
/// Mutable view of the singleton resource of type `T`
/// (auto-marks `changed_tick`).
pub const getResourceMut = api_mod.getResourceMut;
/// Presence check for resource of type `T`.
pub const hasResource = api_mod.hasResource;
/// Drop the singleton resource of type `T`.
pub const removeResource = api_mod.removeResource;
/// Tick-based change detection for resource of type `T`.
pub const resourceChanged = api_mod.resourceChanged;

comptime {
    // Force eager analysis of every resource sub-file so the
    // inline tests are picked up by `zig build test` (lazy
    // analysis guard, cf. `engine-zig-conventions.md` §13).
    _ = registry_mod;
    _ = api_mod;
}
