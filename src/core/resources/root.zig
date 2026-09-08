//! FROZEN — see engine-phase-0-criteria.md C0.5
//!
//! Public surface of the resource subsystem — the single entry point; there is no
//! parallel `src/core/resources.zig`.

const registry_mod = @import("registry.zig");
const api_mod = @import("api.zig");

/// Registry storage (`(TypeId → EntityId)` map + marker component).
pub const registry = registry_mod;
/// Public API surface — set, get, getMut, has, remove, changed.
pub const api = api_mod;

/// Indexes the world's singleton-entity resources.
pub const ResourceRegistry = registry_mod.ResourceRegistry;
/// Marker component added to every singleton-resource entity.
pub const ResourceMarker = registry_mod.ResourceMarker;
/// Error set returned by the write paths.
pub const ResourceError = api_mod.ResourceError;

/// FROZEN — see engine-phase-0-criteria.md C0.5
/// Bumped on any breaking change to the frozen surface — a tracked migration,
/// never a freeze failure.
pub const WELD_RESOURCES_PROTOCOL_VERSION: u32 = 1;

/// Insert or update the singleton resource of type `T`.
pub const setResource = api_mod.setResource;
/// Read-only view of the singleton resource of type `T`.
pub const getResource = api_mod.getResource;
/// Mutable view of resource `T`; auto-marks `changed_tick`.
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
