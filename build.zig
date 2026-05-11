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
        // Generated Vulkan + Wayland bindings use `extern "c"` for the
        // dlopen/dlsym wrapper on POSIX hosts. Linking libc satisfies the
        // resolver; on Windows the same code path takes the kernel32
        // branch and libc is not actually referenced.
        .link_libc = true,
    });

    // Main executable.
    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addImport("weld_core", core_module);

    // Shaders embedding — the SPIR-V files live under `assets/shaders/`,
    // outside the spike binary's source root. `@embedFile` cannot escape
    // the package directory, so we wrap the embeds in a tiny module
    // rooted at `assets/shaders/embed.zig` and import it as `shaders`.
    const shaders_module = b.createModule(.{
        .root_source_file = b.path("assets/shaders/embed.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addImport("shaders", shaders_module);
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
    // Out-of-tree spike + bindings tests need to reach files that live
    // outside `weld_core`'s module tree. Each group is exposed via a
    // thin facade module — Zig 0.16 forbids a single file from belonging
    // to two module trees, so we can't expose siblings as separate
    // modules when they `@import` each other. The facades sit next to
    // the code they shepherd so the throwaway-blast-radius is preserved.
    const spike_test_module = b.createModule(.{
        .root_source_file = b.path("src/spike/tests_facade.zig"),
        .target = target,
        .optimize = optimize,
    });
    const wl_protocols_test_module = b.createModule(.{
        .root_source_file = b.path("src/core/platform/window/wayland_protocols/tests_facade.zig"),
        .target = target,
        .optimize = optimize,
    });

    const TestSpec = struct {
        path: []const u8,
        spike: bool = false,
        wl_protocols: bool = false,
    };
    const test_specs = [_]TestSpec{
        .{ .path = "tests/smoke_test.zig" },
        .{ .path = "tests/ecs/world_test.zig" },
        .{ .path = "tests/ecs/chunk_test.zig" },
        .{ .path = "tests/ecs/query_test.zig" },
        .{ .path = "tests/ecs/no_alloc_in_simulation_test.zig" },
        .{ .path = "tests/jobs/deque_test.zig" },
        .{ .path = "tests/jobs/scheduler_test.zig" },
        .{ .path = "tests/window/win32_open_close_test.zig" },
        .{ .path = "tests/window/wayland_open_close_test.zig" },
        .{ .path = "tests/spike/scoring_test.zig", .spike = true },
        .{ .path = "tests/spike/cli_test.zig", .spike = true },
        .{ .path = "tests/bindings/vk_abi_test.zig" },
        .{ .path = "tests/bindings/wayland_abi_test.zig", .wl_protocols = true },
    };
    for (test_specs) |spec| {
        const t_mod = b.createModule(.{
            .root_source_file = b.path(spec.path),
            .target = target,
            .optimize = optimize,
        });
        t_mod.addImport("weld_core", core_module);
        if (spec.spike) {
            t_mod.addImport("spike", spike_test_module);
        }
        if (spec.wl_protocols) {
            t_mod.addImport("wl_protocols", wl_protocols_test_module);
        }
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

    // ------------------------------------------------ vk_gen (S2 bindgen) --
    //
    // Throwaway generator that re-emits `src/core/platform/vk.zig` from the
    // vendored `bindings/upstream/vulkan/vk.xml`. Replaced in S3 by the
    // unified bindgen system. Run explicitly via `zig build bindgen-vk`,
    // never as part of the default `zig build`.

    const vk_gen_module = b.createModule(.{
        .root_source_file = b.path("tools/vk_gen/main.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const vk_gen_exe = b.addExecutable(.{
        .name = "vk_gen",
        .root_module = vk_gen_module,
    });
    const vk_gen_run = b.addRunArtifact(vk_gen_exe);
    vk_gen_run.has_side_effects = true;
    // Generator output is unformatted; the brief's "bindgen-vk produces
    // an empty diff" criterion only holds after `zig fmt` normalises
    // identifier escapes (e.g. `@"undefined"` → `undefined`) and trims
    // trailing blank lines. Pipe through fmt in the same step so the
    // command is self-sufficient regardless of pre-commit hooks.
    const vk_gen_fmt = b.addSystemCommand(&.{ b.graph.zig_exe, "fmt", "src/core/platform/vk.zig" });
    vk_gen_fmt.step.dependOn(&vk_gen_run.step);
    const vk_gen_step = b.step("bindgen-vk", "Regenerate src/core/platform/vk.zig from vk.xml");
    vk_gen_step.dependOn(&vk_gen_fmt.step);

    // ----------------------------------------- wayland_gen (S2 bindgen) --

    const wayland_gen_module = b.createModule(.{
        .root_source_file = b.path("tools/wayland_gen/main.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const wayland_gen_exe = b.addExecutable(.{
        .name = "wayland_gen",
        .root_module = wayland_gen_module,
    });
    const wayland_gen_run = b.addRunArtifact(wayland_gen_exe);
    wayland_gen_run.has_side_effects = true;
    // Same fmt pass as vk_gen — see comment there.
    const wayland_gen_fmt = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "fmt",
        "src/core/platform/window/wayland_protocols/core.zig",
        "src/core/platform/window/wayland_protocols/xdg_shell.zig",
        "src/core/platform/window/wayland_protocols/xdg_decoration.zig",
    });
    wayland_gen_fmt.step.dependOn(&wayland_gen_run.step);
    const wayland_gen_step = b.step(
        "bindgen-wayland",
        "Regenerate src/core/platform/window/wayland_protocols/*.zig from wayland-protocols XMLs",
    );
    wayland_gen_step.dependOn(&wayland_gen_fmt.step);
}
