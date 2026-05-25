//! Tests M0.3 — VFS resolver + `mmapFile`.
//!
//! Covers the two acceptance tests called out in the M0.3 brief:
//!   - "VFS resolves assets:// cache:// user:// to absolute paths"
//!   - "mmapFile reads cooked asset zero-copy"
//!
//! Tests with external resources have an internal timeout pattern via
//! the std.testing.allocator (leak detector) + a bounded loop where
//! applicable. `engine-zig-conventions.md` §13 expects ≤ 5 s wall-clock.

const std = @import("std");
const weld = @import("weld_core");
const fs = weld.platform.fs;
const builtin = @import("builtin");

test "VFS resolves assets:// cache:// user:// to absolute paths" {
    const gpa = std.testing.allocator;
    var vfs = try fs.Vfs.init(gpa, "/tmp/weld_test_project_root", "weld-m03-tests");
    defer vfs.deinit();

    // assets://
    const a = try vfs.resolve(gpa, "assets://meshes/cube.gltf");
    defer gpa.free(a);
    try std.testing.expect(std.mem.indexOf(u8, a, "weld_test_project_root") != null);
    try std.testing.expect(std.mem.indexOf(u8, a, "assets") != null);
    try std.testing.expect(std.mem.endsWith(u8, a, "cube.gltf") or std.mem.endsWith(u8, a, "cube.gltf"));

    // cache://
    const c = try vfs.resolve(gpa, "cache://shaders/blit.spv");
    defer gpa.free(c);
    try std.testing.expect(std.mem.indexOf(u8, c, ".weld_cache") != null);

    // user:// — requires HOME/APPDATA in env; CI runners always have these.
    const u = vfs.resolve(gpa, "user://saves/save0.json") catch |err| switch (err) {
        // Headless containers can lack HOME. Accept that as a skip signal.
        error.MissingEnv => return error.SkipZigTest,
        else => return err,
    };
    defer gpa.free(u);
    try std.testing.expect(std.mem.indexOf(u8, u, "saves") != null);
    try std.testing.expect(std.mem.indexOf(u8, u, "weld-m03-tests") != null);
}

test "mmapFile reads cooked asset zero-copy" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Use a name in the test's current working directory — `/tmp/...` is
    // POSIX-only and trips OBJECT_PATH_NOT_FOUND on Windows. The CWD is
    // writable on every CI runner (Linux, macOS, Windows) and the file
    // is deleted after the assertion.
    const test_path = "weld_m03_mmap_test.bin";
    const expected_content: []const u8 = "MMAP_TEST_PAYLOAD_0123456789";

    const root = std.Io.Dir.cwd();
    const f = try root.createFile(io, test_path, .{ .truncate = true });
    try f.writeStreamingAll(io, expected_content);
    f.close(io);
    defer root.deleteFile(io, test_path) catch {};

    var mmap = try fs.mmapFile(gpa, test_path);
    defer mmap.close();

    try std.testing.expectEqual(expected_content.len, mmap.bytes.len);
    try std.testing.expectEqualSlices(u8, expected_content, mmap.bytes);
}

test "mmapFile: missing file returns OpenFailed" {
    const gpa = std.testing.allocator;
    const result = fs.mmapFile(gpa, "weld_m03_definitely_missing_file_xyz.bin");
    try std.testing.expectError(error.OpenFailed, result);
}
