//! Public surface of the `weld_core` Zig module — Tier 0 internals exposed
//! to the runtime executable, tests, and the S1 bench harness. Everything
//! Phase −1 needs lives under `core/ecs/`, `core/jobs/`, and `core/testing/`
//! for now; Phase 0 will expand the surface (resources, events, RTTI,
//! plugin loader, IPC, platform layer) as those land.

/// ECS namespace — comptime SoA archetype + runtime registry surface.
pub const ecs = struct {
    // M0.1 / E1 — generational identity store. Sits below components.zig
    // because the canonical `EntityId` lives here and components.zig
    // re-exports it.
    pub const entity = @import("ecs/entity.zig");
    pub const components = @import("ecs/components.zig");
    // M0.1 / E4 — world tick + change-detection sidecars.
    pub const tick = @import("ecs/tick.zig");
    pub const change_detection = @import("ecs/change_detection.zig");
    pub const chunk = @import("ecs/chunk.zig");
    pub const archetype = @import("ecs/archetype.zig");
    pub const query = @import("ecs/query.zig");
    pub const world = @import("ecs/world.zig");
    // M0.1 / E5a — system scheduler (phase pipeline, mono-job).
    pub const scheduler = @import("ecs/scheduler.zig");
    // M0.1 / E6 — per-system command buffer + observer registry.
    pub const command_buffer = @import("ecs/command_buffer.zig");
    pub const observers = @import("ecs/observers.zig");
    // S4 — runtime side: registry, dynamic archetype, resources, runtime query.
    pub const registry = @import("ecs/registry.zig");
    pub const archetype_dynamic = @import("ecs/archetype_dynamic.zig");
    pub const resources = @import("ecs/resources.zig");
    pub const query_runtime = @import("ecs/query_runtime.zig");
    // S5 — comptime-typed query consumed by the Etch → Zig codegen.
    pub const comptime_query = @import("ecs/comptime_query.zig");
};

/// Jobs namespace — Chase-Lev deque + work-stealing scheduler.
pub const jobs = struct {
    pub const deque = @import("jobs/deque.zig");
    pub const worker = @import("jobs/worker.zig");
    pub const scheduler = @import("jobs/scheduler.zig");
};

/// Testing helpers namespace — counting allocator wrapper, etc.
pub const testing = struct {
    pub const alloc_counting = @import("testing/alloc_counting.zig");
};

/// Platform namespace — window, Vulkan, process control.
pub const platform = struct {
    pub const window = @import("platform/window.zig");
    pub const vk = @import("platform/vk.zig");
    // S6 — minimum process control surface used by the editor stub
    // to spawn / monitor / kill the runtime stub. Wider API lands in
    // Phase 0.3 (cf. `engine-platform.md` §4).
    pub const process = @import("platform/process.zig");
};

// S6 — editor↔runtime IPC. Tier 0 endpoint per `engine-ipc.md` and the
// S6 brief. Public surface declared inline, same pattern as `ecs` and
// `jobs` above.
/// IPC namespace — editor↔runtime transport, framing, shm, viewport.
pub const ipc = struct {
    pub const protocol = @import("ipc/protocol.zig");
    pub const messages = @import("ipc/messages.zig");
    pub const framing = @import("ipc/framing.zig");
    pub const transport = @import("ipc/transport.zig");
    pub const shm = @import("ipc/shm.zig");
    pub const viewport = @import("ipc/viewport.zig");
    pub const connection = @import("ipc/connection.zig");
    pub const server = @import("ipc/server.zig");
    pub const client = @import("ipc/client.zig");
};

comptime {
    // Force eager analysis of every IPC sub-file so inline tests are
    // picked up by `zig build test`. Zig 0.16's lazy semantic analysis
    // would otherwise skip files whose declarations are not
    // transitively referenced from the test binary's root — and
    // `test` blocks are not "references" in that sense.
    _ = ipc.protocol;
    _ = ipc.messages;
    _ = ipc.framing;
    _ = ipc.transport;
    _ = ipc.shm;
    _ = ipc.viewport;
    _ = ipc.connection;
    _ = ipc.server;
    _ = ipc.client;
    // Same guard for the M0.1 identity module — `entity.zig`'s inline
    // tests must be reachable from the core test target's root.
    _ = ecs.entity;
    // M0.1 / E4 — pin the change-detection helpers + the tick module
    // so their inline tests are picked up by `zig build test`.
    _ = ecs.tick;
    _ = ecs.change_detection;
    // M0.1 / E5a — pin the system scheduler.
    _ = ecs.scheduler;
    // M0.1 / E5b — pin archetype + world so their inline tests run.
    // The pre-E5b `core_tests` build target silently skipped them
    // because no consumer in the analysis frontier referenced the
    // pub aliases (lazy analysis guard, `engine-zig-conventions.md`
    // §13). Latent regression caught when the E5b SystemScheduler
    // added a new reference path; pinning closes the test coverage
    // gap going forward.
    _ = ecs.archetype;
    _ = ecs.world;
    // M0.1 / E6 — pin the command buffer + observer modules so their
    // inline tests run alongside the rest of the ECS surface.
    _ = ecs.command_buffer;
    _ = ecs.observers;
}
