//! Shader hot-reload — Phase 0 / M0.4.
//!
//! Filewatch on `assets/shaders/` + recompile in a dedicated thread +
//! pipeline recreate via GAL. Target latency < 200 ms (brief §Scope).
//!
//! Phase 0: polling-based watcher (stat every N ms). Phase 1+: switch
//! to inotify/FSEvents/ReadDirectoryChangesW depending on OS via `std.fs.Watch`
//! once the stdlib stabilizes it.
//!
//! If `glslc` is absent from PATH when the watcher starts, we log a warn
//! (`glslc not found, hot-reload disabled, runtime continues with cached
//! .spv`) and `start` returns without starting the thread (cf. brief §Observable
//! behavior + §Notes decision 7).

const std = @import("std");
const compiler = @import("compiler.zig");
const cache = @import("cache.zig");

const log = std.log.scoped(.shader_hot_reload);

/// Callback invoked when a shader is re-compiled (or fails).
/// Phase 0: receives the path + new SPIR-V (or diagnostic). Phase 1+:
/// also receives a GAL.ShaderModule handle for pipeline recreation.
pub const OnRecompile = *const fn (ctx: ?*anyopaque, path: []const u8, spv: ?[]const u8, diag: ?[]const u8) void;

/// Watcher configuration.
pub const Config = struct {
    /// Io instance propagated for fs ops + spawn (Zig 0.16).
    io: std.Io,
    /// Root directory to watch (typically `assets/shaders/`).
    root: []const u8 = "assets/shaders",
    /// Poll interval in milliseconds Phase 0. Trade-off latency vs CPU.
    poll_interval_ms: u32 = 50,
    /// Recompile (or failure) callback.
    on_recompile: OnRecompile,
    /// Opaque user context passed to the callback.
    callback_ctx: ?*anyopaque = null,
};

/// Shader watcher — holds the polling thread + the mtime state.
pub const Watcher = struct {
    allocator: std.mem.Allocator,
    config: Config,
    thread: ?std.Thread = null,
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    glslc_version: []const u8 = "0.0.0",

    /// Starts the watcher. Returns immediately after spawning the thread.
    /// If glslc absent → log warn and return without starting.
    pub fn start(self: *Watcher) !void {
        if (!compiler.isAvailable(self.allocator, self.config.io)) {
            log.warn("glslc not found, hot-reload disabled, runtime continues with cached .spv", .{});
            return;
        }
        self.stop_flag.store(false, .release);
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
    }

    /// Requests stop + join. Blocks until the thread finishes.
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

/// Watcher init. `start()` must be called separately.
pub fn init(allocator: std.mem.Allocator, config: Config) Watcher {
    return .{ .allocator = allocator, .config = config };
}

/// Thread body — poll → diff → recompile loop.
fn threadMain(watcher: *Watcher) void {
    // i96 mirrors `std.Io.Timestamp.nanoseconds` width so the map value
    // round-trips losslessly. Zig 0.16's `Stat.mtime` shifted from i128
    // to a `Io.Timestamp` struct; we store the inner nanoseconds.
    var mtime_map = std.StringHashMapUnmanaged(i96).empty;
    defer {
        var it = mtime_map.iterator();
        while (it.next()) |kv| watcher.allocator.free(kv.key_ptr.*);
        mtime_map.deinit(watcher.allocator);
    }

    const weld_core = @import("weld_core");
    const time_mod = weld_core.platform.time;
    while (!watcher.stop_flag.load(.acquire)) {
        scanDir(watcher, &mtime_map) catch |e| {
            log.warn("watcher scan failed: {t}", .{e});
        };
        const sleep_ns: u64 = @as(u64, watcher.config.poll_interval_ms) * std.time.ns_per_ms;
        time_mod.sleepPrecise(watcher.config.io, sleep_ns) catch {};
    }
}

fn scanDir(watcher: *Watcher, mtime_map: *std.StringHashMapUnmanaged(i96)) !void {
    var dir = std.Io.Dir.cwd().openDir(watcher.config.io, watcher.config.root, .{ .iterate = true }) catch return;
    defer dir.close(watcher.config.io);

    var it = dir.iterate();
    while (try it.next(watcher.config.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".glsl")) continue;

        const stat = dir.statFile(watcher.config.io, entry.name, .{}) catch continue;
        const mtime: i96 = stat.mtime.nanoseconds;

        const gop = mtime_map.getOrPut(watcher.allocator, entry.name) catch continue;
        if (!gop.found_existing) {
            const owned = watcher.allocator.dupe(u8, entry.name) catch continue;
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

    var file = std.Io.Dir.cwd().openFile(watcher.config.io, path, .{}) catch return;
    defer file.close(watcher.config.io);
    const stat = file.stat(watcher.config.io) catch return;
    const source = watcher.allocator.alloc(u8, @intCast(stat.size)) catch return;
    defer watcher.allocator.free(source);
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(watcher.config.io, &read_buf);
    reader.interface.readSliceAll(source) catch return;

    const stage: compiler.Stage = if (std.mem.indexOf(u8, name, ".vert") != null)
        .vertex
    else if (std.mem.indexOf(u8, name, ".frag") != null)
        .fragment
    else if (std.mem.indexOf(u8, name, ".comp") != null)
        .compute
    else
        return;

    var result = compiler.compile(watcher.allocator, watcher.config.io, source, stage, null) catch |e| {
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

    const key: cache.LookupKey = .{ .source = source, .glslc_version = watcher.glslc_version };
    cache.insert(watcher.allocator, watcher.config.io, key, result.spv) catch {};
    watcher.config.on_recompile(watcher.config.callback_ctx, path, result.spv, result.diagnostics);
}

test "hot_reload: Watcher init / deinit cycle without start" {
    const cb = struct {
        fn cb(_: ?*anyopaque, _: []const u8, _: ?[]const u8, _: ?[]const u8) void {}
    }.cb;
    var w = init(std.testing.allocator, .{ .io = std.testing.io, .on_recompile = cb });
    defer w.deinit();
}
