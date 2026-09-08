//! FROZEN — see engine-phase-0-criteria.md C0.5
//!
//! Loads a dynamic library, resolves `weld_plugin_entry`, reads the descriptor,
//! checks the API version, and calls `on_load` with the stub table.
//!
//! `std.DynLib` is a `@compileError` on Windows in Zig 0.16, which is why the
//! `dlopen` / `LoadLibraryA` abstraction is hand-rolled here rather than taken from
//! the stdlib.
//!
//! Capabilities are READ and LOGGED, never enforced — a `component_get` outside
//! `reads_components` is not refused here.

const std = @import("std");
const builtin = @import("builtin");
const desc = @import("desc.zig");
const api_mod = @import("api.zig");

const WeldPluginDesc = desc.WeldPluginDesc;
const WeldPluginEntryFn = desc.WeldPluginEntryFn;

const log = std.log.scoped(.plugin_loader);

// Hand-rolled because `std.DynLib` does not compile on Windows in this Zig version.
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
    /// The dynamic file could not be opened.
    LibraryLoadFailed,
    /// The `weld_plugin_entry` symbol is absent from the binary.
    MissingEntryPoint,
    /// The plugin demands a newer major API than this runtime provides.
    ApiVersionTooNew,
    /// Allocation failure while appending the handle.
    OutOfMemory,
};

/// State of a plugin in the loader's registry.
pub const PluginState = enum {
    /// Loaded and functional.
    loaded,
    /// Unloaded; the handle is kept for debug lookup.
    unloaded,
};

/// Handle to a loaded plugin, owned by the `Loader`.
pub const PluginHandle = struct {
    /// Original path of the library, duplicated and owned.
    path: []const u8,
    /// Opaque `dlopen` / `LoadLibrary` handle.
    dyn_handle: ?*anyopaque,
    /// Descriptor returned by the entry point; owned by the PLUGIN, not by us.
    desc: *const WeldPluginDesc,
    /// Current state.
    state: PluginState,
};

/// Registry of loaded plugins; owns the duplicated paths.
pub const Loader = struct {
    gpa: std.mem.Allocator,
    /// Pointer-stable storage: each handle is heap-boxed, so a pointer handed to a
    /// caller survives later insertions.
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

    /// Load `path` as a plugin.
    pub fn loadPlugin(self: *Loader, path: []const u8) LoaderError!*PluginHandle {
        // `dlopen` and `LoadLibraryA` both need a NUL-terminated path.
        const path_z = self.gpa.dupeZ(u8, path) catch return error.OutOfMemory;
        defer self.gpa.free(path_z);

        const dyn_handle = _dlOpen(path_z.ptr) orelse {
            // `warn` and not `err`: the failure is returned to the caller, who decides.
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

        const plugin_desc = entry_fn(@ptrCast(&api_mod.stub_api));

        if (plugin_desc.api_version_min > desc.WELD_API_VERSION_MAJOR) {
            log.warn(
                "plugin '{s}' requires API version {d}, runtime supports {d}",
                .{ path, plugin_desc.api_version_min, desc.WELD_API_VERSION_MAJOR },
            );
            return error.ApiVersionTooNew;
        }

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

        // Heap-boxed so the returned pointer survives later list growth.
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

    /// Unload a plugin: calls `on_shutdown`, closes the library, marks the handle.
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

    /// Debug-only lookup of an arbitrary symbol in a loaded plugin.
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
