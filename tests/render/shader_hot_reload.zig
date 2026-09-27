//! Shader hot-reload: the watcher compiles a probe `.frag.glsl` dropped into
//! `assets/shaders/`. Needs `glslc` (`test_env`): without it the watcher does
//! not start. The < 200 ms latency is `bench/shader_hot_reload.zig`'s.

const std = @import("std");
const test_env = @import("test_env");
const hot_reload = @import("weld_render").shader_pipeline.hot_reload;
const compiler_mod = @import("weld_render").shader_pipeline.compiler;
const time_mod = @import("weld_core").platform.time;

const PROBE_REL_PATH: []const u8 = "assets/shaders/_hot_reload_probe.frag.glsl";
const PROBE_SOURCE: []const u8 =
    \\#version 450
    \\layout(location = 0) out vec4 outColor;
    \\void main() {
    \\    outColor = vec4(0.42, 0.5, 0.5, 1.0);
    \\}
    \\
;
const POLL_MS: u32 = 10;

const ProbeState = struct {
    fired: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// The recompile produced SPIR-V: a failed one fires the callback too.
    compiled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

// The watcher's first scan compiles every shader of the directory, so the
// callback fires for the others too.
fn onRecompile(ctx_opaque: ?*anyopaque, path: []const u8, spv: ?[]const u8, diag: ?[]const u8) void {
    _ = diag;
    if (!std.mem.eql(u8, path, PROBE_REL_PATH)) return;
    const state: *ProbeState = @ptrCast(@alignCast(ctx_opaque.?));
    state.compiled.store(if (spv) |bytes| bytes.len > 0 else false, .release);
    state.fired.store(true, .release);
}

fn deleteProbe(io: std.Io) void {
    std.Io.Dir.cwd().deleteFile(io, PROBE_REL_PATH) catch {};
}

fn writeProbe(io: std.Io) !void {
    var file = try std.Io.Dir.cwd().createFile(io, PROBE_REL_PATH, .{ .truncate = true });
    defer file.close(io);
    var buf: [256]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(PROBE_SOURCE);
    try writer.interface.flush();
}

test "filewatch compiles a shader dropped into the watched directory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    if (!compiler_mod.isAvailable(allocator, io)) return test_env.absent("glslc");

    writeProbe(io) catch return test_env.absent("a writable assets/shaders");
    defer deleteProbe(io);

    var state = ProbeState{};
    var watcher = hot_reload.init(allocator, .{
        .io = io,
        .root = "assets/shaders",
        .poll_interval_ms = POLL_MS,
        .on_recompile = onRecompile,
        .callback_ctx = @ptrCast(&state),
    });
    defer watcher.deinit();
    try watcher.start();

    while (!state.fired.load(.acquire)) {
        time_mod.sleepPrecise(io, 1 * std.time.ns_per_ms) catch {};
    }
    try std.testing.expect(state.compiled.load(.acquire));
}
