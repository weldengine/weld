//! M0.2 / E6 — squelette du plugin loader Tier 0.
//!
//! Charge un `.so` / `.dll` / `.dylib`, résout le symbole
//! `weld_plugin_entry`, lit le `WeldPluginDesc` produit par le
//! plugin, vérifie la version d'API, et appelle (optionnellement)
//! la callback `on_load` avec la table `WeldAPI` stub.
//!
//! Wraps `std.DynLib` (qui couvre dlopen/LoadLibrary cross-platform
//! sur Zig 0.16). Le brief E6 mentionne `platform.dynamic_loader`
//! comme dépendance hypothétique S2/M0.3 ; ce fichier n'existe pas
//! encore dans le repo, donc le squelette E6 consomme directement
//! `std.DynLib`. Le wrapper `platform.dynamic_loader` sera introduit
//! en M0.3 (extension platform layer) sans changement de surface
//! pour ce loader — il restera consommateur de la même API
//! cross-platform.
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
const desc = @import("desc.zig");
const api_mod = @import("api.zig");

const WeldPluginDesc = desc.WeldPluginDesc;
const WeldPluginEntryFn = desc.WeldPluginEntryFn;
const WeldAPI = api_mod.WeldAPI;

const log = std.log.scoped(.plugin_loader);

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
    /// Wrapper sur dlopen/LoadLibrary, libéré par `unloadPlugin`.
    /// `null` une fois unloadé.
    dyn_lib: ?std.DynLib,
    /// Descripteur retourné par `weld_plugin_entry`. Pointeur vers
    /// les données statiques du `.so` — valide tant que le `.so`
    /// est chargé.
    desc: *const WeldPluginDesc,
    /// État courant.
    state: PluginState,
};

/// Registry des plugins chargés. Owns le storage du `path`
/// dupliqué + l'array list. Pas les `.so` eux-mêmes (gérés par
/// `std.DynLib`).
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
                if (handle.dyn_lib) |*lib| {
                    lib.close();
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
        var dyn_lib = std.DynLib.open(path) catch |err| {
            // log.warn (not .err) — the failure mode is surfaced
            // through the error union return, the log is purely
            // diagnostic. Avoids polluting the test runner's
            // "errors logged" counter for the negative-path tests.
            log.warn("plugin load failed: '{s}' ({s})", .{ path, @errorName(err) });
            return error.LibraryLoadFailed;
        };
        errdefer dyn_lib.close();

        // Resolve `weld_plugin_entry`. Absent → MissingEntryPoint.
        const entry_fn = dyn_lib.lookup(WeldPluginEntryFn, "weld_plugin_entry") orelse {
            log.warn("plugin missing 'weld_plugin_entry' symbol: '{s}'", .{path});
            return error.MissingEntryPoint;
        };

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
            .dyn_lib = dyn_lib,
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
        if (handle.dyn_lib) |*lib| {
            lib.close();
            handle.dyn_lib = null;
        }
        handle.state = .unloaded;
    }

    /// Utilitaire debug — lookup d'un symbole arbitraire dans le
    /// `.so` chargé. Non utilisé par le loader lui-même ; exposé
    /// pour les tests et les outils de diagnostic.
    pub fn lookupSymbol(handle: *PluginHandle, comptime T: type, name: [:0]const u8) ?T {
        if (handle.state != .loaded) return null;
        if (handle.dyn_lib) |*lib| {
            return lib.lookup(T, name);
        }
        return null;
    }

    /// Nombre de plugins chargés (loaded + unloaded historique).
    pub fn count(self: *const Loader) u32 {
        return @intCast(self.plugins.items.len);
    }
};
