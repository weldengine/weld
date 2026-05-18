//! One-test-per-binary split — see `tests/ipc/shm_cases/round_trip.zig`
//! for rationale.

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

    const name = "/weld-tvp-twoslots";
    forceShmUnlink(name);
    defer forceShmUnlink(name);

    var owner = try viewport.ShmViewport.create(name, 64, 48);
    defer owner.close();
    var attacher = try viewport.ShmViewport.open(name, 64, 48);
    defer attacher.close();

    const w_slot = owner.nextWriteSlot();
    try std.testing.expectEqual(@as(u32, 1), w_slot);
    @memset(owner.slotBytes(w_slot), 0xAA);
    owner.commit(w_slot);

    const r_slot = attacher.readSlot();
    try std.testing.expectEqual(@as(u32, 1), r_slot);
    for (attacher.slotBytes(r_slot)[0..16]) |b| try std.testing.expectEqual(@as(u8, 0xAA), b);

    const w2 = owner.nextWriteSlot();
    try std.testing.expectEqual(@as(u32, 0), w2);
    @memset(owner.slotBytes(w2), 0xBB);
    owner.commit(w2);
    const r2 = attacher.readSlot();
    try std.testing.expectEqual(@as(u32, 0), r2);
    for (attacher.slotBytes(r2)[0..16]) |b| try std.testing.expectEqual(@as(u8, 0xBB), b);

    try std.testing.expectEqual(@as(u64, 2), attacher.frameId());
}
