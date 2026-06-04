//! M0.6 / E5 — async loader + lifecycle acceptance.
//!
//! Brief §Acceptance ▸ Tests: `test "async load does not block main thread"` —
//! the main loop ticks while a load is in flight, the load completes, with an
//! internal 5 s watchdog and clean teardown (S6 hang lesson,
//! `engine-zig-conventions.md` §13).

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

test "async load does not block main thread" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const rgba = [_]u8{
        0xff, 0x00, 0x00, 0xff, 0x00, 0xff, 0x00, 0xff,
        0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0x00, 0xff,
    };
    try cookTextureBin(gpa, io, tmp.dir, "x.texture.bin", &rgba);

    var loader = Loader.init(tmp.dir);
    defer loader.deinit(gpa);

    // Begin the load and keep ticking the main loop until it is ready. A
    // 5 s wall-clock watchdog guarantees the suite cannot hang on a stuck
    // load, with clean teardown via `pending.cancel`.
    var pending = try loader.beginLoad(gpa, io, "x.texture.bin");
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    var ticks: usize = 0;
    while (!pending.ready()) {
        ticks += 1;
        std.mem.doNotOptimizeAway(ticks);
        if (start.untilNow(io).raw.nanoseconds > 5 * std.time.ns_per_s) {
            pending.cancel(io);
            return error.LoadTimedOut;
        }
    }
    try std.testing.expect(ticks >= 1); // the main loop advanced; the read ran off-thread

    const raw = try pending.wait(io);
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
