//! vk_gen Raw variants tests — Phase 0 / M0.4.
//!
//! Covers brief §Acceptance criteria > Tests:
//! - `vkAcquireNextImageKHR emits Raw variant` — checks presence in
//!   the generated output
//! - `vkCreateBuffer does not emit Raw variant` — checks absence (negative
//!   case — the function is in the raw_targets list, vkCreateBuffer
//!   is not)
//!
//! Strategy: grep on the post-bindgen `src/core/platform/vk.zig`, checks
//! the presence of `acquireNextImageKHRRaw` (on Device) and the absence of
//! `createBufferRaw`. The test compiles at the Zig type system level —
//! @hasDecl is not enough because the wrappers are methods on Device
//! (opaque), not declarations at the module scope.

const std = @import("std");
const weld_core = @import("weld_core");
const vk = weld_core.platform.vk;

test "vkAcquireNextImageKHR emits Raw variant" {
    const t = std.testing;

    // The Raw wrapper is a method on Device: we check its type
    // via @TypeOf — if the method did not exist, this test would not
    // compile (Zig type-checks references to fns).
    const fn_type = @TypeOf(vk.Device.acquireNextImageKHRRaw);
    const info = @typeInfo(fn_type);
    try t.expectEqual(@typeInfo(@TypeOf(vk.Device.acquireNextImageKHRRaw)).@"fn".return_type.?, vk.Result);
    _ = info;
}

test "Queue.presentKHR Raw variant exists" {
    const t = std.testing;
    const fn_type = @TypeOf(vk.Queue.presentKHRRaw);
    try t.expectEqual(@typeInfo(fn_type).@"fn".return_type.?, vk.Result);
}

test "vkAcquireNextImage2KHR emits Raw variant" {
    const t = std.testing;
    const fn_type = @TypeOf(vk.Device.acquireNextImage2KHRRaw);
    try t.expectEqual(@typeInfo(fn_type).@"fn".return_type.?, vk.Result);
}

test "vkCreateBuffer does not emit Raw variant" {
    // If Device.createBufferRaw existed, @hasDecl would report it. The
    // emitter's raw_targets list contains only the 3 brief targets.
    try std.testing.expect(!@hasDecl(vk.Device, "createBufferRaw"));
}

test "createImage does not emit Raw variant" {
    try std.testing.expect(!@hasDecl(vk.Device, "createImageRaw"));
}
