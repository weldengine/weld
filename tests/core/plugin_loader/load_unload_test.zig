//! M0.2 / E6 — plugin loader happy / error path tests.
//!
//! Exercises `Loader.loadPlugin` + `unloadPlugin` against three
//! stub libraries built by the main `build.zig`:
//!   - `weld_stub_plugin_happy`     — `weld_plugin_entry` present,
//!                                    `api_version_min = 0`
//!   - `weld_stub_plugin_future`    — `weld_plugin_entry` present,
//!                                    `api_version_min = 99`
//!   - `weld_stub_plugin_no_entry`  — symbol absent
//!
//! The test relies on `zig build` having installed each library
//! to its canonical OS-specific path under `zig-out/lib/`
//! (`zig-out/bin/` for Windows DLLs).

const std = @import("std");
const builtin = @import("builtin");
const weld_core = @import("weld_core");

const Loader = weld_core.plugin_loader.Loader;

// Note : le loader émet `log.warn` (pas `log.err`) sur ses
// chemins d'erreur (`MissingEntryPoint`, `ApiVersionTooNew`,
// `LibraryLoadFailed`). L'erreur est portée par le retour
// `LoaderError`, le log est purement diagnostique. Ce choix
// évite que le test runner Zig 0.16 ne compte les logs comme
// échecs alors que les tests vérifient justement les chemins
// d'erreur.

const lib_prefix = switch (builtin.os.tag) {
    .windows => "",
    else => "lib",
};
const lib_suffix = switch (builtin.os.tag) {
    .windows => ".dll",
    .macos, .ios => ".dylib",
    else => ".so",
};
const lib_dir = switch (builtin.os.tag) {
    .windows => "zig-out/bin/",
    else => "zig-out/lib/",
};

fn stubPath(comptime base: []const u8) []const u8 {
    return lib_dir ++ lib_prefix ++ base ++ lib_suffix;
}

const happy_path = stubPath("weld_stub_plugin_happy");
const future_path = stubPath("weld_stub_plugin_future");
const no_entry_path = stubPath("weld_stub_plugin_no_entry");

test "Loader charges le stub plugin sans erreur" {
    const gpa = std.testing.allocator;
    var loader = Loader.init(gpa);
    defer loader.deinit();

    const handle = try loader.loadPlugin(happy_path);
    try std.testing.expect(handle.state == .loaded);
    try std.testing.expectEqual(@as(u32, 1), loader.count());

    loader.unloadPlugin(handle);
    try std.testing.expect(handle.state == .unloaded);
}

test "Loader lit WeldPluginDesc correctement" {
    const gpa = std.testing.allocator;
    var loader = Loader.init(gpa);
    defer loader.deinit();

    const handle = try loader.loadPlugin(happy_path);
    defer loader.unloadPlugin(handle);

    try std.testing.expectEqualStrings("stub", handle.desc.name.slice());
    try std.testing.expectEqualStrings("0.0.1", handle.desc.version.slice());
    try std.testing.expectEqual(@as(u32, 0), handle.desc.api_version_min);
}

test "unloadPlugin propre sans leak" {
    const gpa = std.testing.allocator;
    var loader = Loader.init(gpa);
    defer loader.deinit();

    // Multiple load/unload cycles must not leak — `Loader.deinit`
    // runs through `std.testing.allocator`, leaks would surface
    // at scope exit.
    for (0..3) |_| {
        const handle = try loader.loadPlugin(happy_path);
        loader.unloadPlugin(handle);
    }
    try std.testing.expectEqual(@as(u32, 3), loader.count());
}

test "load d'un binaire sans weld_plugin_entry retourne MissingEntryPoint" {
    const gpa = std.testing.allocator;
    var loader = Loader.init(gpa);
    defer loader.deinit();

    try std.testing.expectError(
        error.MissingEntryPoint,
        loader.loadPlugin(no_entry_path),
    );
    try std.testing.expectEqual(@as(u32, 0), loader.count());
}

test "load d'un plugin avec api_version_min > current retourne ApiVersionTooNew" {
    const gpa = std.testing.allocator;
    var loader = Loader.init(gpa);
    defer loader.deinit();

    try std.testing.expectError(
        error.ApiVersionTooNew,
        loader.loadPlugin(future_path),
    );
    try std.testing.expectEqual(@as(u32, 0), loader.count());
}

test "loadPlugin sur un chemin invalide retourne LibraryLoadFailed" {
    const gpa = std.testing.allocator;
    var loader = Loader.init(gpa);
    defer loader.deinit();

    try std.testing.expectError(
        error.LibraryLoadFailed,
        loader.loadPlugin("zig-out/lib/libdoes_not_exist.so"),
    );
}
