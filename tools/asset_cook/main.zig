//! Thin offline asset cook entry (M0.6 / E4 — brief §Observable behavior).
//!
//! Cooks the three M0.6 fixtures (PNG / glTF / WAV) end-to-end: import →
//! intermediate `<type>.asset.etch` + `.weld/blobs/<hash>.blob` → cook →
//! `.weld/cooked/pc/<name>.<type>.bin`, driven through the local cooking
//! cache. Re-running logs a cache hit and skips the cook.
//!
//! The asset `uuid` is generated (UUIDv7) on the first cook and preserved
//! across re-runs by reading the existing `.asset.etch` — this is the
//! generate-once / preserve-forever identity policy (the pure importer
//! receives the already-resolved uuid; the fs-aware resolution lives here).
//!
//! This is the thin offline surface; the user-facing `weld cook` CLI is
//! Phase 1 (brief §Out-of-scope).
//!
//! Usage: `zig build cook-demo [-- <out_dir>]` (default `zig-out/cook-demo`).

const std = @import("std");
const assets = @import("weld_asset_pipeline");

const Kind = enum { texture, mesh, audio };
const Fixture = struct { path: []const u8, kind: Kind, type_tag: []const u8 };

const fixtures = [_]Fixture{
    .{ .path = "tests/assets/data/checker.png", .kind = .texture, .type_tag = "texture" },
    .{ .path = "tests/assets/data/cube.gltf", .kind = .mesh, .type_tag = "mesh" },
    .{ .path = "tests/assets/data/tone.wav", .kind = .audio, .type_tag = "audio" },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const out_path = if (args.len > 1) args[1] else "zig-out/cook-demo";

    const cwd = std.Io.Dir.cwd();
    var out = try cwd.createDirPathOpen(io, out_path, .{});
    defer out.close(io);
    var intermediate_dir = try out.createDirPathOpen(io, "intermediate", .{});
    defer intermediate_dir.close(io);
    var blobs_dir = try out.createDirPathOpen(io, "blobs", .{});
    defer blobs_dir.close(io);
    var cooked_dir = try out.createDirPathOpen(io, "cooked/pc", .{});
    defer cooked_dir.close(io);
    var cache_dir = try out.createDirPathOpen(io, "cache", .{});
    defer cache_dir.close(io);
    const cache = assets.cache.Cache.init(cache_dir);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_w.interface;
    try stdout.print("weld asset cook — {d} fixtures → {s}\n", .{ fixtures.len, out_path });

    for (fixtures) |fx| {
        const stem = std.fs.path.stem(fx.path);
        var etch_name_buf: [256]u8 = undefined;
        const etch_name = try std.fmt.bufPrint(&etch_name_buf, "{s}.{s}.asset.etch", .{ stem, fx.type_tag });

        // Stable identity: reuse the existing .asset.etch's uuid, else generate.
        var uuid_buf: [36]u8 = undefined;
        const uuid_str = try resolveUuid(gpa, io, intermediate_dir, etch_name, &uuid_buf);

        const src = try readFile(gpa, io, cwd, fx.path);
        defer gpa.free(src);

        var imp = try importOne(gpa, fx, src, uuid_str);
        defer imp.deinit(gpa);
        const doc = imp.doc;

        // Intermediate text + blob.
        const etch = try assets.format.intermediate.writeAlloc(gpa, doc);
        defer gpa.free(etch);
        try writeFile(io, intermediate_dir, etch_name, etch);
        var blob_name_buf: [64]u8 = undefined;
        const blob_name = try std.fmt.bufPrint(&blob_name_buf, "{s}.blob", .{doc.blobHash().?});
        try writeFile(io, blobs_dir, blob_name, imp.blob);

        // Cook through the cache.
        const key = assets.cache.computeKey(doc.source_hash, "pc", 0);
        var bin_name_buf: [256]u8 = undefined;
        const bin_name = try std.fmt.bufPrint(&bin_name_buf, "{s}.{s}.bin", .{ doc.name, fx.type_tag });

        if (cache.contains(io, &key)) {
            try stdout.print("  {s:<28} cache HIT  (uuid {s})\n", .{ fx.path, doc.uuid });
        } else {
            const bin = try cookOne(gpa, fx, doc, imp.blob);
            defer gpa.free(bin);
            try cache.put(io, &key, bin);
            try writeFile(io, cooked_dir, bin_name, bin);
            try stdout.print("  {s:<28} cooked MISS → {s} ({d} B, uuid {s})\n", .{ fx.path, bin_name, bin.len, doc.uuid });
        }
    }
    try stdout.flush();
}

fn importOne(gpa: std.mem.Allocator, fx: Fixture, src: []const u8, uuid: []const u8) !assets.importers.Import {
    return switch (fx.kind) {
        .texture => try assets.importers.png.import(gpa, fx.path, src, uuid),
        .mesh => try assets.importers.gltf.import(gpa, fx.path, src, uuid),
        .audio => try assets.importers.wav.import(gpa, fx.path, src, uuid),
    };
}

fn cookOne(gpa: std.mem.Allocator, fx: Fixture, doc: assets.AssetDoc, blob: []const u8) ![]u8 {
    return switch (fx.kind) {
        .texture => try assets.cookers.cookTexture(gpa, doc, blob),
        .mesh => try assets.cookers.cookMesh(gpa, doc, blob),
        .audio => try assets.cookers.cookAudio(gpa, doc, blob),
    };
}

/// Reuse the uuid of an existing intermediate `.asset.etch`, else generate a
/// fresh UUIDv7. The result is written into `buf` (lives across the import).
fn resolveUuid(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, etch_name: []const u8, buf: *[36]u8) ![]const u8 {
    if (try readFileOpt(gpa, io, dir, etch_name)) |text| {
        defer gpa.free(text);
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        if (assets.format.intermediate.parseEtch(arena.allocator(), text)) |doc| {
            if (doc.uuid.len == 36) {
                @memcpy(buf, doc.uuid[0..36]);
                return buf;
            }
        } else |_| {}
    }
    @memcpy(buf, &assets.uuid.toString(assets.uuid.generateV7(io)));
    return buf;
}

fn readFileOpt(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) !?[]u8 {
    const f = dir.openFile(io, path, .{}) catch return null;
    defer f.close(io);
    const size: usize = @intCast((try f.stat(io)).size);
    const out = try gpa.alloc(u8, size);
    errdefer gpa.free(out);
    var read_buf: [4096]u8 = undefined;
    var reader = f.reader(io, &read_buf);
    var written: usize = 0;
    while (written < size) {
        const n = try reader.interface.readSliceShort(out[written..]);
        if (n == 0) break;
        written += n;
    }
    return out[0..written];
}

fn readFile(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) ![]u8 {
    return (try readFileOpt(gpa, io, dir, path)) orelse error.FileNotFound;
}

fn writeFile(io: std.Io, dir: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    const f = try dir.createFile(io, path, .{ .truncate = true });
    defer f.close(io);
    try f.writeStreamingAll(io, bytes);
}
