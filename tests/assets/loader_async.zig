const std = @import("std");
const assets = @import("weld_asset_pipeline");

const Loader = assets.Loader;
const AssetType = assets.AssetType;
const fmt = assets.format;

fn cookTextureBin(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8, rgba: []const u8) !void {
    const extracted = [_]fmt.Field{
        .{ .key = "width", .value = .{ .int = 2 } },
        .{ .key = "height", .value = .{ .int = 2 } },
        .{ .key = "blob", .value = .{ .string = "00" } },
    };
    const doc = fmt.AssetDoc{
        .name = "x",
        .type_name = "Texture2D",
        .version = 1,
        .source = "x.png",
        .source_hash = "0",
        .extracted = &extracted,
    };
    const bin = try assets.cookers.cookTexture(gpa, doc, rgba);
    defer gpa.free(bin);
    const file = try dir.createFile(io, name, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bin);
}

const gated_path = "x.texture.bin";
var open_released = std.atomic.Value(bool).init(false);
var gated_opens = std.atomic.Value(u32).init(0);
var base_vtable: *const std.Io.VTable = undefined;

/// The base `Io`'s `dirOpenFile`, held for `gated_path` until the test sets
/// `open_released`.
fn gatedOpenFile(
    userdata: ?*anyopaque,
    dir: std.Io.Dir,
    sub_path: []const u8,
    options: std.Io.Dir.OpenFileOptions,
) std.Io.File.OpenError!std.Io.File {
    if (std.mem.eql(u8, sub_path, gated_path)) {
        _ = gated_opens.fetchAdd(1, .acq_rel);
        while (!open_released.load(.acquire)) std.Thread.yield() catch {};
    }
    return base_vtable.dirOpenFile(userdata, dir, sub_path, options);
}

test "async load does not block main thread" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rgba = [_]u8{
        0xff, 0x00, 0x00, 0xff, 0x00, 0xff, 0x00, 0xff,
        0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0x00, 0xff,
    };
    try cookTextureBin(gpa, io, tmp.dir, gated_path, &rgba);

    var loader = Loader.init(tmp.dir);
    defer loader.deinit(gpa);

    var gated_vtable = io.vtable.*;
    gated_vtable.dirOpenFile = gatedOpenFile;
    base_vtable = io.vtable;
    const gated_io: std.Io = .{ .userdata = io.userdata, .vtable = &gated_vtable };

    var pending = try loader.beginLoad(gpa, gated_io, gated_path);
    try std.testing.expect(!pending.ready());
    open_released.store(true, .release);
    const raw = try pending.wait(gated_io);
    try std.testing.expectEqual(@as(u32, 1), gated_opens.load(.acquire));
    const handle = try loader.finish(gpa, raw);

    try std.testing.expectEqual(AssetType.texture, handle.assetType().?);
    try std.testing.expectEqual(AssetType.texture, loader.headerOf(handle).?.assetType().?);
    try std.testing.expectEqualSlices(u8, &rgba, loader.get(handle).?);
    try std.testing.expectEqual(@as(u32, 1), loader.registry.refCount(handle).?);

    // Lifecycle: retain bumps the count; release at 0 unloads + frees payload.
    try loader.retain(handle);
    try std.testing.expectEqual(@as(u32, 2), loader.registry.refCount(handle).?);
    try loader.release(gpa, handle);
    try std.testing.expect(loader.get(handle) != null); // still alive at refcount 1
    try loader.release(gpa, handle);
    try std.testing.expectEqual(@as(?[]const u8, null), loader.get(handle));
    try std.testing.expect(!loader.registry.isAlive(handle));
}

test "loader reload swaps the payload, forced unload drops it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const red = [_]u8{ 0xff, 0, 0, 0xff } ** 4;
    const blue = [_]u8{ 0, 0, 0xff, 0xff } ** 4;
    try cookTextureBin(gpa, io, tmp.dir, "a.texture.bin", &red);
    try cookTextureBin(gpa, io, tmp.dir, "b.texture.bin", &blue);

    var loader = Loader.init(tmp.dir);
    defer loader.deinit(gpa);

    // Blocking convenience load.
    const handle = try loader.load(gpa, io, "a.texture.bin");
    try std.testing.expectEqualSlices(u8, &red, loader.get(handle).?);

    // Hot-reload swaps the payload; the handle (and refcount) are preserved.
    try loader.reload(gpa, io, handle, "b.texture.bin");
    try std.testing.expectEqualSlices(u8, &blue, loader.get(handle).?);
    try std.testing.expect(loader.registry.isAlive(handle));

    // Forced unload drops the slot regardless of refcount.
    try loader.unload(gpa, handle);
    try std.testing.expect(!loader.registry.isAlive(handle));
    try std.testing.expectEqual(@as(?[]const u8, null), loader.get(handle));
}
