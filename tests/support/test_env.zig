//! What a test does when the environment it needs is absent: a compositor, a
//! Vulkan ICD, `glslc`, or the platform itself.
//!
//! In `zig build test` it skips. `zig build test-runtime-env` compiles the same
//! tests with `required` set, for the CI job that provides that environment,
//! and there an absence fails and names what is missing.

const std = @import("std");
const options = @import("test_env_options");

/// The skip, or the failure where the environment is required.
pub fn absent(what: []const u8) error{ SkipZigTest, EnvironmentAbsent } {
    if (!options.required) return error.SkipZigTest;
    std.log.err("required environment absent: {s}", .{what});
    return error.EnvironmentAbsent;
}
