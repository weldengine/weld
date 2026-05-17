//! Public surface of the `weld_core` Zig module — Tier 0 internals exposed
//! to the runtime executable, tests, and the S1 bench harness. Everything
//! Phase −1 needs lives under `core/ecs/`, `core/jobs/`, and `core/testing/`
//! for now; Phase 0 will expand the surface (resources, events, RTTI,
//! plugin loader, IPC, platform layer) as those land.

pub const ecs = struct {
    pub const components = @import("ecs/components.zig");
    pub const chunk = @import("ecs/chunk.zig");
    pub const archetype = @import("ecs/archetype.zig");
    pub const query = @import("ecs/query.zig");
    pub const world = @import("ecs/world.zig");
    // S4 — runtime side: registry, dynamic archetype, resources, runtime query.
    pub const registry = @import("ecs/registry.zig");
    pub const archetype_dynamic = @import("ecs/archetype_dynamic.zig");
    pub const resources = @import("ecs/resources.zig");
    pub const query_runtime = @import("ecs/query_runtime.zig");
    // S5 — comptime-typed query consumed by the Etch → Zig codegen.
    pub const comptime_query = @import("ecs/comptime_query.zig");
};

pub const jobs = struct {
    pub const deque = @import("jobs/deque.zig");
    pub const worker = @import("jobs/worker.zig");
    pub const scheduler = @import("jobs/scheduler.zig");
};

pub const testing = struct {
    pub const alloc_counting = @import("testing/alloc_counting.zig");
};

pub const platform = struct {
    pub const window = @import("platform/window.zig");
    pub const vk = @import("platform/vk.zig");
};

// S6 — editor↔runtime IPC. Tier 0 endpoint per `engine-ipc.md` and the
// S6 brief. The sub-module's public exports live in `ipc/mod.zig`.
pub const ipc = @import("ipc/mod.zig");

comptime {
    // Force eager analysis of the ipc namespace's protocol constants
    // — Zig 0.16's lazy analysis would otherwise skip the file.
    _ = ipc.protocol.MAGIC;
}
