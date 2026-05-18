//! S6 viewport tests — writer + reader on a double-buffered
//! `ShmViewport`, validating the slot-alternation protocol and that
//! the reader never observes torn pixels.
//!
//! **macOS skip note:** see `tests/ipc/shm.zig` — macOS POSIX shm
//! is unreliable across multiple intra-process `shm_open(O_CREAT)`
//! + `shm_open(O_RDWR)` cycles. The tests below gate on
//! `is_linux` so they exercise the protocol fully on the CI Linux
//! host and leave macOS coverage to the two-process demo and the
//! crash-recovery test that spawns real processes.

const std = @import("std");
const builtin = @import("builtin");

const weld_core = @import("weld_core");
const viewport = weld_core.ipc.viewport;

const is_linux = builtin.os.tag == .linux;
const is_posix = builtin.os.tag == .linux or builtin.os.tag == .macos;

extern "c" fn shm_unlink(name: [*:0]const u8) i32;

fn forceShmUnlink(name: []const u8) void {
    if (comptime !is_posix) return;
    var name_buf: [64]u8 = undefined;
    if (name.len + 1 > name_buf.len) return;
    @memcpy(name_buf[0..name.len], name);
    name_buf[name.len] = 0;
    _ = shm_unlink(@ptrCast(&name_buf[0]));
}

test "create + write + read across two slots" {
    if (!is_linux) return error.SkipZigTest;

    var name_buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "/weld-tvp-{d}", .{@src().line});
    forceShmUnlink(name);
    defer forceShmUnlink(name);

    var owner = try viewport.ShmViewport.create(name, 64, 48);
    defer owner.close();
    var attacher = try viewport.ShmViewport.open(name, 64, 48);
    defer attacher.close();

    // Writer commits slot 1 (initial last_complete is 0, so
    // nextWriteSlot is 1).
    const w_slot = owner.nextWriteSlot();
    try std.testing.expectEqual(@as(u32, 1), w_slot);
    @memset(owner.slotBytes(w_slot), 0xAA);
    owner.commit(w_slot);

    const r_slot = attacher.readSlot();
    try std.testing.expectEqual(@as(u32, 1), r_slot);
    for (attacher.slotBytes(r_slot)[0..16]) |b| try std.testing.expectEqual(@as(u8, 0xAA), b);

    // Second commit alternates back to slot 0.
    const w2 = owner.nextWriteSlot();
    try std.testing.expectEqual(@as(u32, 0), w2);
    @memset(owner.slotBytes(w2), 0xBB);
    owner.commit(w2);
    const r2 = attacher.readSlot();
    try std.testing.expectEqual(@as(u32, 0), r2);
    for (attacher.slotBytes(r2)[0..16]) |b| try std.testing.expectEqual(@as(u8, 0xBB), b);

    try std.testing.expectEqual(@as(u64, 2), attacher.frameId());
}

test "open rejects wrong width" {
    if (!is_linux) return error.SkipZigTest;

    var name_buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "/weld-tvp-{d}", .{@src().line});
    forceShmUnlink(name);
    defer forceShmUnlink(name);

    var owner = try viewport.ShmViewport.create(name, 64, 48);
    defer owner.close();
    try std.testing.expectError(error.InvalidHeader, viewport.ShmViewport.open(name, 128, 48));
}

test "1000 frame alternation produces no torn slot bytes" {
    if (!is_linux) return error.SkipZigTest;

    var name_buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "/weld-tvp-{d}", .{@src().line});
    forceShmUnlink(name);
    defer forceShmUnlink(name);

    // Small resolution keeps the test cheap — the protocol does not
    // depend on the slot size for correctness.
    var owner = try viewport.ShmViewport.create(name, 64, 48);
    defer owner.close();
    var attacher = try viewport.ShmViewport.open(name, 64, 48);
    defer attacher.close();

    var frame: u32 = 0;
    while (frame < 1000) : (frame += 1) {
        const slot = owner.nextWriteSlot();
        const fill: u8 = @intCast(frame & 0xFF);
        @memset(owner.slotBytes(slot), fill);
        owner.commit(slot);

        const r = attacher.readSlot();
        // Sample the four corners — if any byte does not match `fill`
        // we observed a torn slot.
        const sb = attacher.slotBytes(r);
        try std.testing.expectEqual(fill, sb[0]);
        try std.testing.expectEqual(fill, sb[sb.len - 1]);
        try std.testing.expectEqual(fill, sb[sb.len / 2]);
        try std.testing.expectEqual(fill, sb[sb.len / 3]);
    }

    try std.testing.expectEqual(@as(u64, 1000), attacher.frameId());
}
