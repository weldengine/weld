//! Public surface of the `weld_core` Zig module; each namespace is documented at its
//! own declaration below.

const builtin = @import("builtin");

/// ECS: entities, archetypes, queries, scheduler, observers.
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

/// Platform: window, Vulkan loader, process control, filesystem, threading.
pub const platform = struct {
    /// FROZEN — see engine-phase-0-criteria.md C0.5
    /// Bumped on any breaking change to the frozen platform surface.
    pub const WELD_PLATFORM_PROTOCOL_VERSION: u32 = 1;

    pub const window = @import("platform/window.zig");
    pub const vk = @import("platform/vk.zig");
    pub const process = @import("platform/process.zig");
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

/// Editor-runtime IPC endpoint.
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
    pub const cleanup = @import("ipc/cleanup.zig");
    pub const command_log = @import("ipc/command_log.zig");
    pub const snapshot = @import("ipc/snapshot.zig");
};

/// RTTI: the Tier 0 reflection runtime.
pub const rtti = @import("rtti/root.zig");

/// Resources: the singleton-entity resource subsystem.
pub const resources = @import("resources/root.zig");

/// Events: the heterogeneous MPMC event bus.
pub const events = @import("events/root.zig");

/// Plugin loader: the Tier 3 boundary.
pub const plugin_loader = @import("plugin_loader/root.zig");

/// Scene: the `.scene.bin` format, codec and loader.
pub const scene = @import("scene/root.zig");

/// Memory: the refcounted persistent heap.
pub const memory = @import("memory/root.zig");

/// The Tier 0 context handed to every Tier 1 module at `init`.
pub const ModuleContext = @import("module_context.zig").ModuleContext;

comptime {
    // EVERY REFERENCE BELOW IS LOAD-BEARING, NOT DECORATION. Zig 0.16 analyses
    // lazily and a `test` block is not a reference, so a sub-file nothing names
    // here has its inline tests silently uncollected — and the suite's own total
    // does not reveal it, it simply does not grow.
    _ = ipc.protocol;
    _ = ipc.messages;
    _ = ipc.framing;
    _ = ipc.transport;
    _ = ipc.shm;
    // This guard MIRRORS `shm.zig`'s own comptime dispatch: that file opens with a
    // `@compileError` on any other OS, so an unconditional pin breaks every Windows
    // build — and a POSIX host cannot show it, because the step that cross-compiles
    // to Windows is not part of `zig build test`.
    if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        _ = @import("ipc/shm_posix.zig");
    }
    _ = ipc.viewport;
    _ = ipc.connection;
    _ = ipc.server;
    _ = ipc.client;
    _ = ipc.cleanup;
    _ = ipc.command_log;
    _ = ipc.snapshot;
    _ = ecs.entity;
    _ = ecs.tick;
    _ = ecs.change_detection;
    // M0.1 / E5a — pin the system scheduler.
    _ = ecs.scheduler;
    _ = ecs.archetype;
    _ = ecs.world;
    _ = ecs.command_buffer;
    _ = ecs.observers;
    _ = ecs.registry;
    _ = ecs.resources;
    _ = ecs.comptime_query;
    _ = ecs.chunk;
    _ = ecs.sparse_storage;
    _ = ecs.hybrid_query;
    // M0.2 / E1 — pin the RTTI sub-files so their inline tests run.
    _ = rtti.type_info;
    _ = rtti.hash;
    _ = rtti.comptime_builder;
    _ = rtti.registry;
    // M0.2 / E3 — pin the resources sub-files.
    _ = resources.registry;
    _ = resources.api;
    _ = events.lifetime;
    _ = events.cursor;
    _ = events.queue;
    _ = events.bus;
    // M0.2 / E6 — pin the plugin loader sub-files.
    _ = plugin_loader.desc;
    _ = plugin_loader.api;
    _ = plugin_loader.loader;
    // M1.0.4 — pin the scene sub-files so their inline tests run.
    _ = scene.format;
    _ = scene.writer;
    _ = scene.accessor;
    _ = scene.loader;
    // M1.0.5 — pin the Tier-0 persistent heap (moved from src/etch).
    _ = memory.persistent;
    _ = ModuleContext;
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

test "runtime-query abstraction stays dropped (D-S4-runtime-query)" {
    // Guards a DROPPED surface so it cannot silently return: the dynamic query
    // abstraction had zero consumers and could not express the real query surface.
    const std = @import("std");
    comptime std.debug.assert(!@hasDecl(ecs, "query_runtime"));
    comptime std.debug.assert(!@hasDecl(ecs.world.World, "query_dynamic"));
}
