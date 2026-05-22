//! M0.2 / E6 — squelette du plugin loader Tier 0.
//!
//! Charge un `.so` / `.dll` / `.dylib`, résout le symbole
//! `weld_plugin_entry`, lit le `WeldPluginDesc` produit par le
//! plugin, vérifie la version d'API, et appelle (optionnellement)
//! la callback `on_load` avec la table `WeldAPI` stub.
//!
//! `std.DynLib` est `@compileError("unsupported platform")` sur
//! Windows dans la stdlib Zig 0.16 (cf. `lib/std/dynamic_library.zig`
//! ligne 21). Le squelette E6 hand-roll donc directement une mince
//! abstraction `dlopen` / `LoadLibraryA` (POSIX / Windows), exactement
//! le pattern utilisé par `src/core/platform/vk.zig`. Le brief E6
//! mentionne `platform.dynamic_loader` comme dépendance hypothétique
//! M0.3 ; ce fichier n'existe pas encore. Lorsque le wrapper sera
//! introduit en M0.3 (extension platform layer), il remplacera ce
//! bloc local sans changement de la surface publique du loader.
//!
//! AUCUN câblage réel des 7 sous-APIs — le loader passe l'instance
//! `api.stub_api` aux plugins. Toutes les callbacks renvoient
//! `WELD_ERR_NOT_IMPLEMENTED` (cf. `api.zig`).
//!
//! Capability enforcement runtime (refuser un `component_get` si
//! non déclaré dans `reads_components`) est Phase 3 (brief
//! § Out-of-scope). M0.2 LIT les capabilities et les logue, sans
//! check inline.

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

/// Erreurs surfacées par `loadPlugin`.
pub const LoaderError = error{
    /// Le fichier dynamique n'a pas pu être ouvert (chemin
    /// inexistant, permissions, format invalide).
    LibraryLoadFailed,
    /// Le symbole `weld_plugin_entry` est absent du binaire.
    /// Vérification stricte — l'absence signale soit un plugin
    /// mal compilé soit un binaire non-plugin chargé par
    /// erreur.
    MissingEntryPoint,
    /// `desc.api_version_min > WELD_API_VERSION_MAJOR` du runtime
    /// courant. Le plugin demande une version d'API plus récente
    /// que celle compilée dans Weld.
    ApiVersionTooNew,
    /// Échec d'allocation lors de l'append du handle.
    OutOfMemory,
};

/// État d'un plugin dans le registry du loader.
pub const PluginState = enum {
    /// Chargé et fonctionnel.
    loaded,
    /// `unloadPlugin` a été appelé — handle conservé pour
    /// historique debug, mais le `.so` est fermé.
    unloaded,
};

/// Handle vers un plugin chargé. Le caller le reçoit de
/// `loadPlugin` et le passe à `unloadPlugin`. Stable pour la
/// durée de vie du `Loader`.
pub const PluginHandle = struct {
    /// Chemin d'origine du `.so` / `.dll` (utile pour les logs
    /// et le rejeu après hot-reload Phase 3+).
    path: []const u8,
    /// Handle opaque retourné par `dlopen` (POSIX) ou
    /// `LoadLibraryA` (Windows). Libéré par `unloadPlugin`.
    /// `null` une fois unloadé.
    dyn_handle: ?*anyopaque,
    /// Descripteur retourné par `weld_plugin_entry`. Pointeur vers
    /// les données statiques du `.so` — valide tant que le `.so`
    /// est chargé.
    desc: *const WeldPluginDesc,
    /// État courant.
    state: PluginState,
};

/// Registry des plugins chargés. Owns le storage du `path`
/// dupliqué + l'array list. Pas les `.so` eux-mêmes (gérés par
/// dlopen/LoadLibraryA via `_dlOpen`/`_dlClose`).
pub const Loader = struct {
    gpa: std.mem.Allocator,
    plugins: std.ArrayListUnmanaged(PluginHandle) = .empty,

    pub fn init(gpa: std.mem.Allocator) Loader {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Loader) void {
        for (self.plugins.items) |*handle| {
            if (handle.state == .loaded) {
                if (handle.desc.callbacks.on_shutdown) |cb| {
                    cb(@ptrCast(&api_mod.stub_api));
                }
                if (handle.dyn_handle) |lib| {
                    _dlClose(lib);
                }
            }
            self.gpa.free(handle.path);
        }
        self.plugins.deinit(self.gpa);
        self.* = undefined;
    }

    /// Charge `path` en tant que plugin. Le chemin doit pointer
    /// vers un binaire dynamique (`.so` / `.dll` / `.dylib`) qui
    /// exporte `weld_plugin_entry`. Le loader log les capabilities
    /// déclarées par le plugin sans les enforcement (Phase 3).
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
        try self.plugins.append(self.gpa, .{
            .path = owned_path,
            .dyn_handle = dyn_handle,
            .desc = plugin_desc,
            .state = .loaded,
        });

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

        return &self.plugins.items[self.plugins.items.len - 1];
    }

    /// Décharge un plugin précédemment chargé. Appelle
    /// `on_shutdown`, ferme le `.so`, et marque l'entrée comme
    /// `.unloaded`. L'entrée est conservée dans le registry pour
    /// historique debug.
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

    /// Utilitaire debug — lookup d'un symbole arbitraire dans le
    /// `.so` chargé. Non utilisé par le loader lui-même ; exposé
    /// pour les tests et les outils de diagnostic. Cast côté caller
    /// du `*anyopaque` retourné vers le type cible (le wrapper de
    /// type-safe lookup arrivera quand `platform.dynamic_loader`
    /// sera extrait en M0.3).
    pub fn lookupSymbol(handle: *PluginHandle, name: [:0]const u8) ?*anyopaque {
        if (handle.state != .loaded) return null;
        if (handle.dyn_handle) |lib| {
            return _dlLookup(lib, name);
        }
        return null;
    }

    /// Nombre de plugins chargés (loaded + unloaded historique).
    pub fn count(self: *const Loader) u32 {
        return @intCast(self.plugins.items.len);
    }
};
