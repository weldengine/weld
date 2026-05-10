//! Step (i) of the S2 brief: CLI parser tests for `src/spike/cli.zig`.
//! The parser is allocation-free and deterministic so this file just
//! drives `cli.parse` with synthetic argv slices.

const std = @import("std");
const cli = @import("spike").cli;

test "CLI parses --smoke-test as flag" {
    const args = try cli.parse(&.{"--smoke-test"});
    try std.testing.expect(args.smoke_test);
    try std.testing.expect(args.measure_frame_time == null);
    try std.testing.expect(args.gpu_prefer == null);
    try std.testing.expect(!args.verbose);
}

test "CLI parses --measure-frame-time=N with default 300" {
    const bare = try cli.parse(&.{"--measure-frame-time"});
    try std.testing.expectEqual(@as(?u32, 300), bare.measure_frame_time);

    const explicit = try cli.parse(&.{"--measure-frame-time=120"});
    try std.testing.expectEqual(@as(?u32, 120), explicit.measure_frame_time);

    const invalid = cli.parse(&.{"--measure-frame-time=oops"});
    try std.testing.expectError(error.InvalidMeasureFrameTime, invalid);
}

test "CLI parses --gpu-prefer=index:5" {
    const args = try cli.parse(&.{"--gpu-prefer=index:5"});
    const hint = args.gpu_prefer orelse return error.TestUnexpectedNull;
    switch (hint) {
        .index => |n| try std.testing.expectEqual(@as(u32, 5), n),
        else => return error.TestUnexpectedVariant,
    }

    const discrete = try cli.parse(&.{"--gpu-prefer=discrete"});
    try std.testing.expect(discrete.gpu_prefer != null and discrete.gpu_prefer.? == .discrete);

    const integrated = try cli.parse(&.{"--gpu-prefer=integrated"});
    try std.testing.expect(integrated.gpu_prefer != null and integrated.gpu_prefer.? == .integrated);

    const bogus = cli.parse(&.{"--gpu-prefer=quantum"});
    try std.testing.expectError(error.InvalidGpuPrefer, bogus);

    const bad_idx = cli.parse(&.{"--gpu-prefer=index:abc"});
    try std.testing.expectError(error.InvalidGpuIndex, bad_idx);
}

test "CLI rejects unknown flags with helpful error" {
    const result = cli.parse(&.{"--nope"});
    try std.testing.expectError(error.UnknownFlag, result);

    // Combined: a valid flag followed by an unknown one — error wins.
    const mixed = cli.parse(&.{ "--smoke-test", "--unknown" });
    try std.testing.expectError(error.UnknownFlag, mixed);
}

test "CLI parses several flags in one invocation" {
    const args = try cli.parse(&.{
        "--smoke-test",
        "--verbose",
        "--measure-frame-time=42",
        "--gpu-prefer=discrete",
    });
    try std.testing.expect(args.smoke_test);
    try std.testing.expect(args.verbose);
    try std.testing.expectEqual(@as(?u32, 42), args.measure_frame_time);
    try std.testing.expect(args.gpu_prefer != null and args.gpu_prefer.? == .discrete);
}
