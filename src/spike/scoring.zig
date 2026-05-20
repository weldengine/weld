//! Pure Vulkan physical-device scoring for the S2 spike. Throwaway.
//! Tested in isolation (`tests/spike/scoring_test.zig`); takes only POD
//! inputs so the test does not need a Vulkan loader.

const std = @import("std");
const cli = @import("cli.zig");

/// Subset of `VkPhysicalDeviceType` (from `engine-c-bindings.md` §4.2,
/// the binding emits an `enum(i32)` named `PhysicalDeviceType`). We
/// keep the integer values here so the scorer is not coupled to the
/// generated binding and the unit tests can synthesize inputs cleanly.
pub const DeviceType = enum(u32) {
    other = 0,
    integrated_gpu = 1,
    discrete_gpu = 2,
    virtual_gpu = 3,
    cpu = 4,
};

/// Per-physical-device data fed into `scoreDevice`.
pub const DeviceInfo = struct {
    device_type: DeviceType,
};

/// Score a single physical device against the active preference hint.
/// Higher is better; negative scores rule the device out entirely. The
/// caller (vk_setup) picks the device with the highest non-negative score.
///
/// `hint = null` means "use the default policy: discrete > integrated >
/// virtual > other > cpu" (per brief). `hint = .index` is handled by
/// the caller via direct lookup, not via this function — passing it here
/// returns 0 for every device since the caller bypasses scoring.
pub fn scoreDevice(info: DeviceInfo, hint: ?cli.GpuPrefer) i32 {
    const h = hint orelse return defaultScore(info);
    return switch (h) {
        .discrete => if (info.device_type == .discrete_gpu) 1000 else -1,
        .integrated => if (info.device_type == .integrated_gpu) 1000 else -1,
        .index => 0,
    };
}

fn defaultScore(info: DeviceInfo) i32 {
    return switch (info.device_type) {
        .discrete_gpu => 1000,
        .integrated_gpu => 500,
        .virtual_gpu => 100,
        .other => 50,
        .cpu => 10,
    };
}
