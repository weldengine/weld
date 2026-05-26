//! Shader hot-reload — Phase 0 / M0.4.
//!
//! Filewatch sur `assets/shaders/` + recompile dans un thread dédié +
//! pipeline recreate via GAL. Cible latence < 200 ms (brief §Scope).
//!
//! Phase 0 : polling-based watcher (stat every N ms). Phase 1+ : passer
//! à inotify/FSEvents/ReadDirectoryChangesW selon OS via `std.fs.Watch`
//! quand la stdlib le stabilisera.
//!
//! Si `glslc` est absent du PATH au démarrage du watcher, on log un warn
//! (`glslc not found, hot-reload disabled, runtime continues with cached
//! .spv`) et `start` retourne sans démarrer le thread (cf. brief §Comportement
//! observable + §Notes décision 7).

const std = @import("std");
const compiler = @import("compiler.zig");
const cache = @import("cache.zig");

const log = std.log.scoped(.shader_hot_reload);

/// Callback appelé quand un shader est re-compilé (ou échoue).
/// Phase 0 : reçoit le path + nouveau SPIR-V (ou diagnostic). Phase 1+ :
/// reçoit aussi un handle GAL.ShaderModule pour recréation pipeline.
pub const OnRecompile = *const fn (ctx: ?*anyopaque, path: []const u8, spv: ?[]const u8, diag: ?[]const u8) void;

/// Configuration du watcher.
pub const Config = struct {
    /// Dossier racine à surveiller (typiquement `assets/shaders/`).
    root: []const u8 = "assets/shaders",
    /// Intervalle de poll en millisecondes Phase 0. Trade-off latence vs CPU.
    poll_interval_ms: u32 = 50,
    /// Callback de recompile (ou échec).
    on_recompile: OnRecompile,
    /// Context utilisateur opaque passé au callback.
    callback_ctx: ?*anyopaque = null,
};

/// Watcher de shaders — porte le thread de polling + l'état des mtimes.
pub const Watcher = struct {
    allocator: std.mem.Allocator,
    config: Config,
    thread: ?std.Thread = null,
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    glslc_version: []const u8 = "0.0.0",

    /// Démarre le watcher. Retourne immédiatement après spawn du thread.
    /// Si glslc absent → log warn et retourne sans démarrer.
    pub fn start(self: *Watcher) !void {
        if (!compiler.isAvailable(self.allocator)) {
            log.warn("glslc not found, hot-reload disabled, runtime continues with cached .spv", .{});
            return;
        }
        self.stop_flag.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    }

    /// Demande l'arrêt + join. Bloque jusqu'à la fin du thread.
    pub fn stop(self: *Watcher) void {
        self.stop_flag.store(true, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    pub fn deinit(self: *Watcher) void {
        self.stop();
        self.* = undefined;
    }
};

/// Init du watcher. `start()` doit être appelé séparément.
pub fn init(allocator: std.mem.Allocator, config: Config) Watcher {
    return .{ .allocator = allocator, .config = config };
}

/// Thread body — boucle de poll → diff → recompile.
fn threadMain(watcher: *Watcher) void {
    var mtime_map = std.StringHashMapUnmanaged(i128).empty;
    defer {
        var it = mtime_map.iterator();
        while (it.next()) |kv| watcher.allocator.free(kv.key_ptr.*);
        mtime_map.deinit(watcher.allocator);
    }

    while (!watcher.stop_flag.load(.acquire)) {
        scanDir(watcher, &mtime_map) catch |e| {
            log.warn("watcher scan failed: {t}", .{e});
        };
        std.Thread.sleep(@as(u64, watcher.config.poll_interval_ms) * std.time.ns_per_ms);
    }
}

fn scanDir(watcher: *Watcher, mtime_map: *std.StringHashMapUnmanaged(i128)) !void {
    var dir = std.fs.cwd().openDir(watcher.config.root, .{ .iterate = true }) catch return;
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".glsl")) continue;

        const stat = dir.statFile(entry.name) catch continue;
        const mtime = stat.mtime;

        const gop = mtime_map.getOrPut(watcher.allocator, entry.name) catch continue;
        if (!gop.found_existing) {
            // Nouveau fichier : duplique le nom pour le storage.
            const owned = watcher.allocator.dupe(u8, entry.name) catch continue;
            // Remplacer la clé éphémère.
            _ = mtime_map.remove(entry.name);
            mtime_map.put(watcher.allocator, owned, mtime) catch {
                watcher.allocator.free(owned);
                continue;
            };
            recompile(watcher, owned) catch {};
            continue;
        }
        if (gop.value_ptr.* != mtime) {
            gop.value_ptr.* = mtime;
            recompile(watcher, gop.key_ptr.*) catch {};
        }
    }
}

fn recompile(watcher: *Watcher, name: []const u8) !void {
    const path = try std.fmt.allocPrint(watcher.allocator, "{s}/{s}", .{ watcher.config.root, name });
    defer watcher.allocator.free(path);

    const source = std.fs.cwd().readFileAlloc(watcher.allocator, path, 1024 * 1024) catch return;
    defer watcher.allocator.free(source);

    const stage: compiler.Stage = if (std.mem.indexOf(u8, name, ".vert") != null)
        .vertex
    else if (std.mem.indexOf(u8, name, ".frag") != null)
        .fragment
    else if (std.mem.indexOf(u8, name, ".comp") != null)
        .compute
    else
        return;

    var result = compiler.compile(watcher.allocator, source, stage, null) catch |e| {
        const msg = std.fmt.allocPrint(watcher.allocator, "compile failed: {t}", .{e}) catch return;
        defer watcher.allocator.free(msg);
        watcher.config.on_recompile(watcher.config.callback_ctx, path, null, msg);
        return;
    };
    defer result.deinit(watcher.allocator);

    if (result.spv.len == 0) {
        watcher.config.on_recompile(watcher.config.callback_ctx, path, null, result.diagnostics);
        return;
    }

    // Met en cache + callback.
    const key: cache.LookupKey = .{ .source = source, .glslc_version = watcher.glslc_version };
    cache.insert(watcher.allocator, key, result.spv) catch {};
    watcher.config.on_recompile(watcher.config.callback_ctx, path, result.spv, result.diagnostics);
}

test "hot_reload: Watcher init / deinit cycle without start" {
    const cb = struct {
        fn cb(_: ?*anyopaque, _: []const u8, _: ?[]const u8, _: ?[]const u8) void {}
    }.cb;
    var w = init(std.testing.allocator, .{ .on_recompile = cb });
    defer w.deinit();
    // Pas de start — la thread n'est jamais spawned, deinit doit pas hang.
}
