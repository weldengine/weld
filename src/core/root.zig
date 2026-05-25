//! Public surface of the `weld_core` Zig module — Tier 0 internals exposed
//! to the runtime executable, tests, and the S1 bench harness. Everything
//! Phase −1 needs lives under `core/ecs/`, `core/jobs/`, and `core/testing/`
//! for now; Phase 0 will expand the surface (resources, events, RTTI,
//! plugin loader, IPC, platform layer) as those land.

/// ECS namespace — single canonical entry point at
/// `src/core/ecs/root.zig` (M0.1 / E7). The root provides both:
///   * Flat public types : `ecs.World`, `ecs.EntityId`, `ecs.Query`,
///     `ecs.CommandBuffer`, `ecs.SystemScheduler`, etc. — the M0.1
///     stable contract listed in the milestone brief.
///   * Sub-module aliases: `ecs.world`, `ecs.scheduler`,
///     `ecs.query`, `ecs.command_buffer`, … — kept reachable for
///     tests and the bench so they can address internal symbols
///     without going through the flat surface.
///
/// Consumers writing new code should prefer the flat surface
/// (`ecs.World` over `ecs.world.World`). The sub-module aliases are
/// stable for the lifetime of M0.1 but may be pruned at M0.2 once
/// the RTTI rework cleans up the deprecated `archetype_dynamic`
/// shim and the S4 surface.
pub const ecs = @import("ecs/root.zig");

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

/// Platform namespace — window, Vulkan, process control, plus the M0.3
/// commun layer (fs, time, threading, dynamic_lib, once).
pub const platform = struct {
    pub const window = @import("platform/window.zig");
    pub const vk = @import("platform/vk.zig");
    pub const process = @import("platform/process.zig");
    // M0.3 — once-init primitive (CAS tri-state on std.atomic.Value(u32)).
    // Used by win32 thread-safety patches and by time.sleepPrecise.
    pub const once = @import("platform/once.zig");
    // M0.3 — sleepPrecise wrapper with Win32 timeBeginPeriod(1) once-init.
    pub const time = @import("platform/time.zig");
    // M0.3 — setAffinity / setPriority OS-specific helpers.
    pub const threading = @import("platform/threading.zig");
    // M0.3 — DynamicLib { open, lookup, close } over LoadLibraryW / dlopen.
    pub const dynamic_lib = @import("platform/dynamic_lib.zig");
    // M0.3 — VFS resolver (assets:// / cache:// / user://) + mmapFile.
    pub const fs = @import("platform/fs.zig");
    // M0.3 — Input Tier 0 namespace (raw_state, keycode, OS-specific).
    pub const input = struct {
        pub const keycode = @import("platform/input/keycode.zig");
        pub const raw_state = @import("platform/input/raw_state.zig");
        pub const win32_xinput = @import("platform/input/win32_xinput.zig");
        pub const linux_evdev = @import("platform/input/linux_evdev.zig");
    };
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

/// RTTI namespace — Tier 0 reflection runtime (M0.2 / E1). Comptime
/// builder, type metadata, deterministic identity + schema hashes,
/// runtime registry. Single canonical entry point at
/// `src/core/rtti/root.zig` (cohérent avec le pattern `ecs/root.zig`).
pub const rtti = @import("rtti/root.zig");

/// Resources namespace — Tier 0 singleton-entity resource subsystem
/// (M0.2 / E3). Public API for `setResource` / `getResource` /
/// `getResourceMut` / `hasResource` / `removeResource` /
/// `resourceChanged`. Single canonical entry point at
/// `src/core/resources/root.zig`.
pub const resources = @import("resources/root.zig");

/// Events namespace — Tier 0 MPMC event bus (M0.2 / E4). `EventBus`
/// is a field on `World` (decision technique E4) and holds the
/// typed `EventQueue(T)` instances. Producers `emit(T, e)`,
/// consumers `subscribe(T)` → cursor → `poll(T, &cursor)`. The
/// scheduler drives lifetime drains at phase / tick / frame
/// boundaries.
pub const events = @import("events/root.zig");

/// Plugin loader namespace — Tier 0 squelette M0.2 / E6.
/// `Loader` charge des `.so` / `.dll` / `.dylib`, lit le
/// `WeldPluginDesc` exporté, et expose la table `WeldAPI`
/// avec 7 sous-APIs (signatures finales, implémentations stub
/// retournant `WELD_ERR_NOT_IMPLEMENTED`). Câblage runtime
/// Phase 3.
pub const plugin_loader = @import("plugin_loader/root.zig");

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
    // M0.2 / E1 — pin the RTTI sub-files so their inline tests run.
    _ = rtti.type_info;
    _ = rtti.hash;
    _ = rtti.comptime_builder;
    _ = rtti.registry;
    // M0.2 / E3 — pin the resources sub-files.
    _ = resources.registry;
    _ = resources.api;
    // M0.2 / E4 — pin the events sub-files so their inline tests
    // run alongside the rest of the surface.
    _ = events.lifetime;
    _ = events.cursor;
    _ = events.queue;
    _ = events.bus;
    // M0.2 / E6 — pin the plugin loader sub-files.
    _ = plugin_loader.desc;
    _ = plugin_loader.api;
    _ = plugin_loader.loader;
    // M0.3 — pin the new platform sub-files so their inline tests run.
    _ = platform.once;
    _ = platform.time;
    _ = platform.threading;
    _ = platform.dynamic_lib;
    _ = platform.fs;
    _ = platform.input.keycode;
    _ = platform.input.raw_state;
    _ = platform.input.win32_xinput;
    _ = platform.input.linux_evdev;
}
