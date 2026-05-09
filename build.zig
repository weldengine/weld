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

    // Shared `weld_core` module — Tier 0 internals consumed by the runtime,
    // the bench harness, and every test executable.
    const core_module = b.createModule(.{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Main executable.
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addImport("weld_core", core_module);
    const exe = b.addExecutable(.{
        .name = "weld",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the weld executable");
    run_step.dependOn(&run_cmd.step);

    // -------------------------------------------------------------- Tests --

    const test_step = b.step("test", "Run all tests");

    // Inline tests living next to the core code.
    const core_tests = b.addTest(.{ .root_module = core_module });
    test_step.dependOn(&b.addRunArtifact(core_tests).step);

    // Inline tests in src/main.zig.
    const main_tests = b.addTest(.{ .root_module = exe_module });
    test_step.dependOn(&b.addRunArtifact(main_tests).step);

    // Out-of-tree tests. Each file is its own root_module and imports
    // `weld_core` to reach the engine internals.
    const test_files = [_][]const u8{
        "tests/smoke_test.zig",
        "tests/ecs/world_test.zig",
        "tests/ecs/chunk_test.zig",
        "tests/ecs/query_test.zig",
        "tests/ecs/no_alloc_in_simulation_test.zig",
        "tests/jobs/deque_test.zig",
        "tests/jobs/scheduler_test.zig",
    };
    for (test_files) |path| {
        const t_mod = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        t_mod.addImport("weld_core", core_module);
        const t = b.addTest(.{ .root_module = t_mod });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // ----------------------------------------------------- ECS bench step --

    const bench_module = b.createModule(.{
        .root_source_file = b.path("bench/ecs_iteration.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_module.addImport("weld_core", core_module);
    const bench_exe = b.addExecutable(.{
        .name = "ecs-iteration-bench",
        .root_module = bench_module,
    });
    b.installArtifact(bench_exe);

    const bench_run = b.addRunArtifact(bench_exe);
    bench_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| bench_run.addArgs(args);
    const bench_step = b.step(
        "bench-ecs",
        "Run the S1 ECS iteration bench (pass `-- --smoke` for a CI sanity run)",
    );
    bench_step.dependOn(&bench_run.step);
}
