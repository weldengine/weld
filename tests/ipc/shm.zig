//! Residual shm tests that DON'T trigger the macOS BSD shm
//! intra-process quirk (no `shm_open(O_CREAT) → shm_open(O_RDWR)`
//! sequence). The create-then-open pair lives in
//! `tests/ipc/shm_cases/{round_trip,attacher_writes}.zig`, one test
//! per binary so each runs in a fresh process and the macOS quirk
//! cannot bite — see those files for the full rationale.

const std = @import("std");
const builtin = @import("builtin");

const weld_core = @import("weld_core");
const shm = weld_core.ipc.shm;

const is_posix = builtin.os.tag == .linux or builtin.os.tag == .macos;

test "create rejects too-long names" {
    if (!is_posix) return error.SkipZigTest;
    const too_long = "/weld-this-name-is-deliberately-way-too-long-for-pshmnamlen";
    try std.testing.expectError(error.NameTooLong, shm.ShmRegion.create(too_long, 4096));
}
