//! M0.9 vertical-slice offline asset cook (E4).
//!
//! Cooks the slice's single source asset — `assets/slice_albedo.png` — through
//! the real M0.6 pipeline (import → intermediate `AssetDoc` + RGBA8 blob → cook
//! → `.texture.bin`) and writes the runtime `.bin` to disk. The slice host then
//! loads that `.bin` at runtime via the M0.6 async `Loader` and uploads it to a
//! GPU texture (`copyBufferToTexture`). This is the offline half of the
//! "source → intermediate → .bin → runtime load" chain; the user-facing
//! `weld cook` CLI is Phase 1.
//!
//! Usage (wired as `zig build cook-vertical-slice-assets`):
//!   cook_assets <input.png> <output.texture.bin>
//! Defaults: examples/vertical_slice/assets/slice_albedo.png →
//!           zig-out/vertical-slice-assets/slice_albedo.texture.bin

const std = @import("std");
const assets = @import("weld_asset_pipeline");

const default_in = "examples/vertical_slice/assets/slice_albedo.png";
const default_out = "zig-out/vertical-slice-assets/slice_albedo.texture.bin";

/// Fixed identity for the slice's albedo — deterministic so re-cooks are
/// reproducible (the generate-once/preserve-forever policy is the offline
/// `weld cook` CLI's job, Phase 1).
const albedo_uuid = "0190b3f0-1c2d-7e4a-8b6c-5117ce0a1be0";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const in_path = if (args.len > 1) args[1] else default_in;
    const out_path = if (args.len > 2) args[2] else default_out;

    const cwd = std.Io.Dir.cwd();

    // Source → intermediate (doc + RGBA8 blob).
    const src = try readFile(gpa, io, cwd, in_path);
    defer gpa.free(src);
    var imp = try assets.importers.png.import(gpa, in_path, src, albedo_uuid);
    defer imp.deinit(gpa);

    // Intermediate → runtime `.texture.bin`.
    const bin = try assets.cookers.cookTexture(gpa, imp.doc, imp.blob);
    defer gpa.free(bin);

    // Write the `.bin`, creating the parent directory chain.
    if (std.fs.path.dirname(out_path)) |dir_path| {
        var dir = try cwd.createDirPathOpen(io, dir_path, .{});
        dir.close(io);
    }
    const out_file = try cwd.createFile(io, out_path, .{ .truncate = true });
    defer out_file.close(io);
    try out_file.writeStreamingAll(io, bin);

    var stdout_buf: [256]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_w.interface;
    try stdout.print(
        "vertical-slice cook: {s} -> {s} ({d} B, uuid {s})\n",
        .{ in_path, out_path, bin.len, imp.doc.uuid },
    );
    try stdout.flush();
}

fn readFile(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) ![]u8 {
    const f = try dir.openFile(io, path, .{});
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
