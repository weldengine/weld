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

test "1000 frame alternation produces no torn slot bytes" {
    if (!is_linux) return error.SkipZigTest;

    const name = "/weld-tvp-notear";
    forceShmUnlink(name);
    defer forceShmUnlink(name);

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
        const sb = attacher.slotBytes(r);
        try std.testing.expectEqual(fill, sb[0]);
        try std.testing.expectEqual(fill, sb[sb.len - 1]);
        try std.testing.expectEqual(fill, sb[sb.len / 2]);
        try std.testing.expectEqual(fill, sb[sb.len / 3]);
    }

    try std.testing.expectEqual(@as(u64, 1000), attacher.frameId());
}
