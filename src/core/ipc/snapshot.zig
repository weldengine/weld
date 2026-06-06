//! Minimal binary scene snapshot persisted by the runtime on
//! `SaveProject`, reloaded on restart as the best-effort-replay
//! reference point (`engine-ipc.md` §7.1, brief E4 "option 1"). This is
//! **not** a `.scene.etch` writer and carries no project-settings
//! serialization (out of Phase 0): for the M0.7 runtime stub the
//! "active scene" is the mire, so the snapshot records a single marker
//! (`frame_id`) — enough to give replay a concrete reload point on the
//! restarted runtime.
//!
//! File I/O goes through `std.Io.Dir` + `io` (the 0.16 filesystem API);
//! `std.fs.cwd()` no longer exists. The runtime supplies `io` from its
//! `std.process.Init`.

const std = @import("std");

/// `"WSNP"` little-endian — distinct from the framing/viewport magics.
pub const magic: u32 = 0x57534E50;
/// Snapshot layout revision; a mismatch makes `read` return `null`.
pub const version: u16 = 1;

/// On-disk snapshot record (fixed size, little-endian extern layout).
pub const Snapshot = extern struct {
    magic: u32,
    version: u16,
    _pad: u16 = 0,
    /// The active scene's minimal state. M0.7 stub: a save marker (the
    /// `SaveProject` seq_id) standing in for the reloadable scene state.
    frame_id: u64,
};

/// Persist `snap` to `path`, overwriting any prior snapshot. Called by
/// the runtime when it acks `SaveProject`. `magic`/`version` are stamped
/// here so callers need only fill `frame_id`.
pub fn write(io: std.Io, path: []const u8, snap: Snapshot) !void {
    var rec = snap;
    rec.magic = magic;
    rec.version = version;
    const f = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer f.close(io);
    try f.writeStreamingAll(io, std.mem.asBytes(&rec));
}

/// Read the snapshot at `path`. Returns `null` when absent or malformed
/// (a fresh runtime with no prior save starts clean — `engine-ipc.md`
/// §7.2: no save ⇒ no reload point).
pub fn read(io: std.Io, path: []const u8) ?Snapshot {
    const f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);

    var scratch: [64]u8 = undefined;
    var reader = f.reader(io, &scratch);
    var dst: [@sizeOf(Snapshot)]u8 = undefined;
    var got: usize = 0;
    while (got < dst.len) {
        const n = reader.interface.readSliceShort(dst[got..]) catch return null;
        if (n == 0) break;
        got += n;
    }
    if (got != @sizeOf(Snapshot)) return null;

    var snap: Snapshot = undefined;
    @memcpy(std.mem.asBytes(&snap), &dst);
    if (snap.magic != magic or snap.version != version) return null;
    return snap;
}

// ---------------------------------------------------------------- tests --

test "snapshot write then read round-trips" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = "weld-snapshot-unittest.bin";
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try write(io, path, .{ .magic = 0, .version = 0, .frame_id = 4242 });
    const got = read(io, path) orelse return error.SnapshotMissing;
    try std.testing.expectEqual(@as(u32, magic), got.magic);
    try std.testing.expectEqual(@as(u16, version), got.version);
    try std.testing.expectEqual(@as(u64, 4242), got.frame_id);
}

test "snapshot read of an absent path returns null" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try std.testing.expect(read(io, "weld-snapshot-absent-xyz.bin") == null);
}

test "snapshot read rejects a wrong-magic file" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = "weld-snapshot-badmagic.bin";
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const f = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    try f.writeStreamingAll(io, &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });
    f.close(io);
    try std.testing.expect(read(io, path) == null);
}
