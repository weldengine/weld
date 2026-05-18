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

test "open rejects wrong width" {
    if (!is_linux) return error.SkipZigTest;

    const name = "/weld-tvp-wrongw";
    forceShmUnlink(name);
    defer forceShmUnlink(name);

    var owner = try viewport.ShmViewport.create(name, 64, 48);
    defer owner.close();
    try std.testing.expectError(error.InvalidHeader, viewport.ShmViewport.open(name, 128, 48));
}
