//! Step (i) of the S2 brief: pure-function gates around the physical-
//! device scorer (`src/spike/scoring.zig`). The scorer is intentionally
//! POD-in / int-out so we can synthesize inputs without spinning up a
//! Vulkan loader. Runs on every host as part of the default `zig build
//! test` step.

const std = @import("std");
const spike = @import("spike");
const scoring = spike.scoring;
const cli = spike.cli;

test "scoreDevice ranks discrete above integrated above CPU" {
    const discrete = scoring.scoreDevice(.{ .device_type = .discrete_gpu }, null);
    const integrated = scoring.scoreDevice(.{ .device_type = .integrated_gpu }, null);
    const virtual = scoring.scoreDevice(.{ .device_type = .virtual_gpu }, null);
    const other = scoring.scoreDevice(.{ .device_type = .other }, null);
    const cpu = scoring.scoreDevice(.{ .device_type = .cpu }, null);

    try std.testing.expect(discrete > integrated);
    try std.testing.expect(integrated > virtual);
    try std.testing.expect(virtual > other);
    try std.testing.expect(other > cpu);
    try std.testing.expect(cpu > 0);
}

test "scoreDevice respects --gpu-prefer=integrated" {
    const discrete = scoring.scoreDevice(.{ .device_type = .discrete_gpu }, .integrated);
    const integrated = scoring.scoreDevice(.{ .device_type = .integrated_gpu }, .integrated);
    const cpu = scoring.scoreDevice(.{ .device_type = .cpu }, .integrated);

    try std.testing.expect(integrated > 0);
    try std.testing.expect(discrete < 0);
    try std.testing.expect(cpu < 0);
}

test "scoreDevice respects --gpu-prefer=discrete" {
    const discrete = scoring.scoreDevice(.{ .device_type = .discrete_gpu }, .discrete);
    const integrated = scoring.scoreDevice(.{ .device_type = .integrated_gpu }, .discrete);

    try std.testing.expect(discrete > 0);
    try std.testing.expect(integrated < 0);
}

test "scoreDevice respects --gpu-prefer=index:N" {
    // `.index` bypasses scoring entirely — the caller does the direct
    // lookup, so `scoreDevice` flattens every candidate to 0. Out-of-
    // range handling lives in `vk_setup.zig` and is exercised by the
    // smoke-test on real hardware; not testable here without a loader.
    const a = scoring.scoreDevice(.{ .device_type = .discrete_gpu }, .{ .index = 0 });
    const b = scoring.scoreDevice(.{ .device_type = .integrated_gpu }, .{ .index = 3 });
    const c = scoring.scoreDevice(.{ .device_type = .cpu }, .{ .index = 99 });

    try std.testing.expectEqual(@as(i32, 0), a);
    try std.testing.expectEqual(@as(i32, 0), b);
    try std.testing.expectEqual(@as(i32, 0), c);
}
