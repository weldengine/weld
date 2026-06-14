//! M0.2 / E6 — Tier 0 plugin loader skeleton.
//!
//! Loads a `.so` / `.dll` / `.dylib`, resolves the
//! `weld_plugin_entry` symbol, reads the `WeldPluginDesc` produced
//! by the plugin, checks the API version, and (optionally) calls
//! the `on_load` callback with the stub `WeldAPI` table.
//!
//! `std.DynLib` is `@compileError("unsupported platform")` on
//! Windows in Zig 0.16's stdlib (cf. `lib/std/dynamic_library.zig`
//! line 21). The E6 skeleton therefore hand-rolls a thin
//! `dlopen` / `LoadLibraryA` (POSIX / Windows) abstraction directly,
//! exactly the pattern used by `src/core/platform/vk.zig`. The E6
//! brief mentions `platform.dynamic_loader` as a hypothetical M0.3
//! dependency; that file does not exist yet. When the wrapper is
//! introduced in M0.3 (platform layer extension), it will replace
//! this local block without changing the loader's public surface.
//!
//! NO real wiring of the 7 sub-APIs — the loader passes the
//! `api.stub_api` instance to plugins. All callbacks return
//! `WELD_ERR_NOT_IMPLEMENTED` (cf. `api.zig`).
//!
//! Runtime capability enforcement (refusing a `component_get` if
//! not declared in `reads_components`) is Phase 3 (brief
//! § Out-of-scope). M0.2 READS the capabilities and logs them,
//! without inline checks.

const std = @import("std");
const builtin = @import("builtin");
const desc = @import("desc.zig");
const api_mod = @import("api.zig");

const WeldPluginDesc = desc.WeldPluginDesc;
const WeldPluginEntryFn = desc.WeldPluginEntryFn;

const log = std.log.scoped(.plugin_loader);

// `std.DynLib` is `@compileError("unsupported platform")` on Windows
// in Zig 0.16's stdlib (cf. `lib/std/dynamic_library.zig` line 21).
// We hand-roll a tiny dlopen/LoadLibrary abstraction here, mirroring
// the pattern used by `src/core/platform/vk.zig`. The wrapper around
// `platform.dynamic_loader` arrives in M0.3 — drop-in substitution
// without any change to the loader's public surface.
const _dl = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn LoadLibraryA(name: [*:0]const u8) callconv(.c) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.c) ?*anyopaque;
    extern "kernel32" fn FreeLibrary(module: *anyopaque) callconv(.c) c_int;
} else struct {
    extern "c" fn dlopen(path: ?[*:0]const u8, mode: c_int) ?*anyopaque;
    extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;
    extern "c" fn dlclose(handle: ?*anyopaque) c_int;
};

fn _dlOpen(path_z: [*:0]const u8) ?*anyopaque {
    return if (comptime builtin.os.tag == .windows)
        _dl.LoadLibraryA(path_z)
    else
        _dl.dlopen(path_z, 2); // RTLD_NOW
}

fn _dlLookup(handle: *anyopaque, name_z: [*:0]const u8) ?*anyopaque {
    return if (comptime builtin.os.tag == .windows)
        _dl.GetProcAddress(handle, name_z)
    else
        _dl.dlsym(handle, name_z);
}

fn _dlClose(handle: *anyopaque) void {
    if (comptime builtin.os.tag == .windows) {
        _ = _dl.FreeLibrary(handle);
    } else {
        _ = _dl.dlclose(handle);
    }
}

/// Errors surfaced by `loadPlugin`.
pub const LoaderError = error{
    /// The dynamic file could not be opened (nonexistent path,
    /// permissions, invalid format).
    LibraryLoadFailed,
    /// The `weld_plugin_entry` symbol is absent from the binary.
    /// Strict check — its absence signals either a badly
    /// compiled plugin or a non-plugin binary loaded by
    /// mistake.
    MissingEntryPoint,
    /// `desc.api_version_min > WELD_API_VERSION_MAJOR` of the
    /// current runtime. The plugin requests a more recent API
    /// version than the one compiled into Weld.
    ApiVersionTooNew,
    /// Allocation failure while appending the handle.
    OutOfMemory,
};

/// State of a plugin in the loader's registry.
pub const PluginState = enum {
    /// Loaded and functional.
    loaded,
    /// `unloadPlugin` was called — handle kept for debug
    /// history, but the `.so` is closed.
    unloaded,
};

/// Handle to a loaded plugin. The caller receives it from
/// `loadPlugin` and passes it to `unloadPlugin`. Stable for the
/// lifetime of the `Loader`.
pub const PluginHandle = struct {
    /// Original path of the `.so` / `.dll` (useful for logs
    /// and replay after hot-reload Phase 3+).
    path: []const u8,
    /// Opaque handle returned by `dlopen` (POSIX) or
    /// `LoadLibraryA` (Windows). Freed by `unloadPlugin`.
    /// `null` once unloaded.
    dyn_handle: ?*anyopaque,
    /// Descriptor returned by `weld_plugin_entry`. Pointer to
    /// the static data of the `.so` — valid as long as the `.so`
    /// is loaded.
    desc: *const WeldPluginDesc,
    /// Current state.
    state: PluginState,
};

/// Registry of loaded plugins. Owns the storage of the duplicated
/// `path` + the array list. Not the `.so` themselves (managed by
/// dlopen/LoadLibraryA via `_dlOpen`/`_dlClose`).
pub const Loader = struct {
    gpa: std.mem.Allocator,
    /// Pointer-stable storage: each handle is heap-boxed so the
    /// `*PluginHandle` returned by `loadPlugin` stays valid for the
    /// lifetime of the `Loader`. E7/M0.9 fix — the prior
    /// `ArrayListUnmanaged(PluginHandle)` returned an interior pointer
    /// (`&items[len-1]`) that a subsequent `loadPlugin` could dangle by
    /// reallocating the backing buffer, contradicting the
    /// `PluginHandle` "stable for the lifetime of the Loader" promise.
    plugins: std.ArrayListUnmanaged(*PluginHandle) = .empty,

    pub fn init(gpa: std.mem.Allocator) Loader {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Loader) void {
        for (self.plugins.items) |handle| {
            if (handle.state == .loaded) {
                if (handle.desc.callbacks.on_shutdown) |cb| {
                    cb(@ptrCast(&api_mod.stub_api));
                }
                if (handle.dyn_handle) |lib| {
                    _dlClose(lib);
                }
            }
            self.gpa.free(handle.path);
            self.gpa.destroy(handle);
        }
        self.plugins.deinit(self.gpa);
        self.* = undefined;
    }

    /// Loads `path` as a plugin. The path must point to a
    /// dynamic binary (`.so` / `.dll` / `.dylib`) that exports
    /// `weld_plugin_entry`. The loader logs the capabilities
    /// declared by the plugin without enforcing them (Phase 3).
    pub fn loadPlugin(self: *Loader, path: []const u8) LoaderError!*PluginHandle {
        // dlopen/LoadLibraryA need a NUL-terminated path. Allocate
        // a temporary buffer with the sentinel, then release after
        // the call.
        const path_z = self.gpa.dupeZ(u8, path) catch return error.OutOfMemory;
        defer self.gpa.free(path_z);

        const dyn_handle = _dlOpen(path_z.ptr) orelse {
            // log.warn (not .err) — the failure mode is surfaced
            // through the error union return, the log is purely
            // diagnostic. Avoids polluting the test runner's
            // "errors logged" counter for the negative-path tests.
            log.warn("plugin load failed: '{s}'", .{path});
            return error.LibraryLoadFailed;
        };
        errdefer _dlClose(dyn_handle);

        // Resolve `weld_plugin_entry`. Absent → MissingEntryPoint.
        const entry_sym = _dlLookup(dyn_handle, "weld_plugin_entry") orelse {
            log.warn("plugin missing 'weld_plugin_entry' symbol: '{s}'", .{path});
            return error.MissingEntryPoint;
        };
        const entry_fn: WeldPluginEntryFn = @ptrCast(@alignCast(entry_sym));

        // Call the entry to get the descriptor. The plugin
        // returns a pointer to static data inside its `.so`,
        // valid for the lifetime of the load.
        const plugin_desc = entry_fn(@ptrCast(&api_mod.stub_api));

        // Version check. We accept `desc.api_version_min <=
        // current MAJOR`.
        if (plugin_desc.api_version_min > desc.WELD_API_VERSION_MAJOR) {
            log.warn(
                "plugin '{s}' requires API version {d}, runtime supports {d}",
                .{ path, plugin_desc.api_version_min, desc.WELD_API_VERSION_MAJOR },
            );
            return error.ApiVersionTooNew;
        }

        // Log identity + capabilities (no enforcement). The
        // capability arrays are read-only views into the plugin's
        // static data.
        log.info(
            "loaded plugin '{s}' v'{s}' (api_version_min={d})",
            .{
                plugin_desc.name.slice(),
                plugin_desc.version.slice(),
                plugin_desc.api_version_min,
            },
        );
        if (plugin_desc.caps.needs_filesystem) {
            log.info("  caps: needs_filesystem", .{});
        }
        if (plugin_desc.caps.needs_network) {
            log.info("  caps: needs_network", .{});
        }
        if (plugin_desc.caps.needs_threading) {
            log.info("  caps: needs_threading", .{});
        }
        if (plugin_desc.caps.reads_components_count > 0) {
            log.info("  caps: reads_components_count={d}", .{plugin_desc.caps.reads_components_count});
        }
        if (plugin_desc.caps.writes_components_count > 0) {
            log.info("  caps: writes_components_count={d}", .{plugin_desc.caps.writes_components_count});
        }

        const owned_path = try self.gpa.dupe(u8, path);
        errdefer self.gpa.free(owned_path);

        // Heap-box the handle so the returned pointer survives later
        // `loadPlugin` calls (the list stores pointers, not values —
        // see the `plugins` field doc).
        const handle = try self.gpa.create(PluginHandle);
        errdefer self.gpa.destroy(handle);
        handle.* = .{
            .path = owned_path,
            .dyn_handle = dyn_handle,
            .desc = plugin_desc,
            .state = .loaded,
        };
        try self.plugins.append(self.gpa, handle);

        // Call `on_load` lifecycle if provided.
        if (plugin_desc.callbacks.on_load) |cb| {
            const res = cb(@ptrCast(&api_mod.stub_api));
            if (res != .WELD_OK) {
                log.warn(
                    "plugin '{s}' on_load returned {s}",
                    .{ plugin_desc.name.slice(), @tagName(res) },
                );
            }
        }

        return handle;
    }

    /// Unloads a previously loaded plugin. Calls `on_shutdown`,
    /// closes the `.so`, and marks the entry as `.unloaded`.
    /// The entry is kept in the registry for debug history.
    pub fn unloadPlugin(self: *Loader, handle: *PluginHandle) void {
        _ = self;
        if (handle.state != .loaded) return;
        if (handle.desc.callbacks.on_shutdown) |cb| {
            cb(@ptrCast(&api_mod.stub_api));
        }
        if (handle.dyn_handle) |lib| {
            _dlClose(lib);
            handle.dyn_handle = null;
        }
        handle.state = .unloaded;
    }

    /// Debug utility — lookup of an arbitrary symbol in the
    /// loaded `.so`. Not used by the loader itself; exposed for
    /// tests and diagnostic tools. The caller casts the returned
    /// `*anyopaque` to the target type (the type-safe lookup
    /// wrapper will arrive when `platform.dynamic_loader` is
    /// extracted in M0.3).
    pub fn lookupSymbol(handle: *PluginHandle, name: [:0]const u8) ?*anyopaque {
        if (handle.state != .loaded) return null;
        if (handle.dyn_handle) |lib| {
            return _dlLookup(lib, name);
        }
        return null;
    }

    /// Number of loaded plugins (loaded + unloaded history).
    pub fn count(self: *const Loader) u32 {
        return @intCast(self.plugins.items.len);
    }
};
