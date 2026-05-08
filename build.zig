const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    comptime {
        if (builtin.zig_version.major != 0 or builtin.zig_version.minor != 16) {
            @compileError(std.fmt.comptimePrint(
                "Weld requires Zig 0.16.x, got {d}.{d}.{d}",
                .{ builtin.zig_version.major, builtin.zig_version.minor, builtin.zig_version.patch },
            ));
        }
    }

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "weld",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the weld executable");
    run_step.dependOn(&run_cmd.step);

    const main_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_main_tests = b.addRunArtifact(main_tests);

    const smoke_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/smoke_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_smoke_tests = b.addRunArtifact(smoke_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_main_tests.step);
    test_step.dependOn(&run_smoke_tests.step);
}
