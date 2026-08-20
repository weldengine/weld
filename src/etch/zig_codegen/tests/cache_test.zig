//! Per-file content-hash cache tests (S5).

const std = @import("std");
const cache = @import("../cache.zig");

test "identical content hits cache, no regeneration" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // `Io.Dir` carries no `realpath` in Zig 0.16. `tmpDir` creates
    // `.zig-cache/tmp/<sub_path>` relative to CWD and `sub_path` is public;
    // the cache API is CWD-relative and creates the directory itself.
    const cache_dir = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(cache_dir);

    const src = "component A { x: int = 0 }";
    try cache.writeHash(gpa, cache_dir, "a.etch", cache.computeHash(src));

    const should = try cache.shouldRegenerate(gpa, cache_dir, "a.etch", src);
    try std.testing.expect(!should);
}

test "modified content invalidates cache, regenerates" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // `Io.Dir` carries no `realpath` in Zig 0.16. `tmpDir` creates
    // `.zig-cache/tmp/<sub_path>` relative to CWD and `sub_path` is public;
    // the cache API is CWD-relative and creates the directory itself.
    const cache_dir = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(cache_dir);

    const src1 = "component A { x: int = 0 }";
    const src2 = "component A { x: int = 1 }";
    try cache.writeHash(gpa, cache_dir, "a.etch", cache.computeHash(src1));

    const should = try cache.shouldRegenerate(gpa, cache_dir, "a.etch", src2);
    try std.testing.expect(should);
}
