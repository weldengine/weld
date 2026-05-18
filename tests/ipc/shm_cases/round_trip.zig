//! One-test-per-binary split: every shm test runs in its own
//! process so the test runner does not co-locate two
//! `shm_open(O_CREAT) → shm_open(O_RDWR)` pairs in the same exe.
//! On Linux this is just for clarity; on macOS the structure
//! sidesteps the BSD shm intra-process quirk.
//!
//! Even with the split, macOS still fails these tests when invoked
//! through `zig build test-ipc` (verified empirically — the shm
//! namespace of a `zig build`-spawned child inherits poisoned
//! state from the parent `zig` process). The bare test binary
//! invoked from a clean shell passes 3/3 runs in a row, but `zig
//! build` is the only invocation that matters for CI. Net result:
//! `is_linux` gate stays. The split unblocks Linux CI where each
//! binary fires up fresh.

const std = @import("std");
const builtin = @import("builtin");

const weld_core = @import("weld_core");
const shm = weld_core.ipc.shm;

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

test "create + write + open + read round-trip" {
    if (!is_linux) return error.SkipZigTest;

    const name = "/weld-tshm-roundtrip";
    forceShmUnlink(name);
    defer forceShmUnlink(name);

    var owner = try shm.ShmRegion.create(name, 4096);
    defer owner.close();

    @memset(owner.bytes()[0..16], 0xAB);

    var attacher = try shm.ShmRegion.open(name, 4096);
    defer attacher.close();

    for (attacher.bytes()[0..16]) |b| try std.testing.expectEqual(@as(u8, 0xAB), b);
}
