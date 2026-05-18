const std = @import("std");
const builtin = @import("builtin");

const codegen_corpus = @import("tests/etch_interp/codegen_corpus_build.zig");

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

    // Shared `weld_etch` module — S3 parser + type-checker + S4 tree-walking
    // interpreter (foundation submodule per `engine-directory-structure.md`
    // §9.1). Etch is not a Tier 1 module; it is conceptually a foundation
    // submodule and ships as its own top-level public surface under
    // `src/etch/root.zig`. The S4 interpreter pulls in `weld_core` to drive
    // the runtime registry / dynamic archetype / resource store.
    const etch_module = b.createModule(.{
        .root_source_file = b.path("src/etch/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    etch_module.addImport("weld_core", core_module);

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

    // Same-file tests inside src/etch/*.zig.
    const etch_tests = b.addTest(.{ .root_module = etch_module });
    test_step.dependOn(&b.addRunArtifact(etch_tests).step);

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
    const etch_corpus_module = b.createModule(.{
        .root_source_file = b.path("tests/etch/corpus_facade.zig"),
        .target = target,
        .optimize = optimize,
    });

    // S4 differential corpus — `tests/etch_interp/` houses 20 .etch
    // programs and their sidecar `expected.zig` files. The facade is the
    // shared module the corpus_test driver and the bench harness both
    // import (same pattern as the S3 corpus facade above).
    // Generic test driver module (independent of the corpus + runner) so it
    // can be reused by S5's codegen-runner without modifying call sites.
    const etch_interp_driver_module = b.createModule(.{
        .root_source_file = b.path("tests/etch_interp/diff_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    etch_interp_driver_module.addImport("weld_core", core_module);
    // S4 differential corpus — `tests/etch_interp/` houses 20 .etch
    // programs and their sidecar `expected.zig` files. The facade enumerates
    // them and is consumed by `corpus_test.zig` (the test driver) and by
    // the bench harness. Sidecars in `programs/` reach the diff_runner
    // types through the `diff_runner` module dependency below.
    const etch_interp_corpus_module = b.createModule(.{
        .root_source_file = b.path("tests/etch_interp/corpus_facade.zig"),
        .target = target,
        .optimize = optimize,
    });
    etch_interp_corpus_module.addImport("weld_core", core_module);
    etch_interp_corpus_module.addImport("weld_etch", etch_module);
    etch_interp_corpus_module.addImport("diff_runner", etch_interp_driver_module);
    // Runner module — the interpreter backend.
    const etch_interp_runner_module = b.createModule(.{
        .root_source_file = b.path("tests/etch_interp/runner_interp.zig"),
        .target = target,
        .optimize = optimize,
    });
    etch_interp_runner_module.addImport("weld_core", core_module);
    etch_interp_runner_module.addImport("weld_etch", etch_module);

    const TestSpec = struct {
        path: []const u8,
        spike: bool = false,
        wl_protocols: bool = false,
        etch: bool = false,
        etch_interp: bool = false,
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
        .{ .path = "tests/etch/corpus_test.zig", .etch = true },
        .{ .path = "tests/etch_interp/corpus_test.zig", .etch_interp = true },
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
        if (spec.etch) {
            t_mod.addImport("weld_etch", etch_module);
            t_mod.addImport("corpus_facade", etch_corpus_module);
        }
        if (spec.etch_interp) {
            t_mod.addImport("weld_etch", etch_module);
            t_mod.addImport("corpus_facade", etch_interp_corpus_module);
            t_mod.addImport("diff_runner", etch_interp_driver_module);
            t_mod.addImport("runner_interp", etch_interp_runner_module);
        }
        const t = b.addTest(.{ .root_module = t_mod });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // ------------------------------------------------ S6 IPC tests --------
    //
    // Each IPC test is its own exe so a deadlock in one case (the
    // previous session's 46-minute test-runner hang taught us this
    // the expensive way) cannot stall the rest of `zig build test`.
    // The `test-ipc` step runs only the IPC tests for fast iteration
    // during S6; the main `test` step also dependsOn each of them so
    // CI keeps a single entry point.
    const test_ipc_step = b.step("test-ipc", "Run the S6 IPC tests");
    const ipc_test_paths = [_][]const u8{
        "tests/ipc/framing.zig",
        "tests/ipc/schema_hash.zig",
        "tests/ipc/transport.zig",
        "tests/ipc/shm.zig",
        "tests/ipc/shm_viewport.zig",
        "tests/ipc/fd_passing.zig",
        "tests/ipc/process.zig",
        "tests/ipc/handshake.zig",
    };
    for (ipc_test_paths) |p| {
        const t_mod = b.createModule(.{
            .root_source_file = b.path(p),
            .target = target,
            .optimize = optimize,
            // The IPC tests bind directly to libc primitives (socket,
            // shm_open, pipe, unlink, setsockopt) alongside the
            // `weld_core` re-exports. `weld_core` itself links libc
            // but the test module needs the link flag too — Zig 0.16
            // does not propagate `link_libc` across module imports
            // for the consumer's own `extern "c"` declarations.
            .link_libc = true,
        });
        t_mod.addImport("weld_core", core_module);
        const t = b.addTest(.{ .root_module = t_mod });
        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
        test_ipc_step.dependOn(&run_t.step);
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

    // -------------------------------------------- Fixture facade (S4 demo) --

    // `@embedFile` cannot escape the package root of the module that
    // invokes it, so both the S4 bench and the S4 demo binary import this
    // tiny facade module that holds the fixture at its canonical path.
    const fixture_facade_module = b.createModule(.{
        .root_source_file = b.path("bench/fixture_facade.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ------------------------------------------------- S4 demo binary ------

    const demo_module = b.createModule(.{
        .root_source_file = b.path("src/demo_etch_interp.zig"),
        .target = target,
        .optimize = optimize,
    });
    demo_module.addImport("weld_core", core_module);
    demo_module.addImport("weld_etch", etch_module);
    demo_module.addImport("fixture_facade", fixture_facade_module);
    const demo_exe = b.addExecutable(.{
        .name = "demo-etch-interp",
        .root_module = demo_module,
    });
    b.installArtifact(demo_exe);
    const demo_run = b.addRunArtifact(demo_exe);
    demo_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| demo_run.addArgs(args);
    const demo_step = b.step(
        "run-demo-etch-interp",
        "Run the S4 demo (1000 entities × 5 rules × 60 ticks)",
    );
    demo_step.dependOn(&demo_run.step);

    // -------------------------------------------- S4 Etch interpreter bench --

    const interp_bench_module = b.createModule(.{
        .root_source_file = b.path("bench/etch_interp.zig"),
        .target = target,
        .optimize = optimize,
    });
    interp_bench_module.addImport("weld_core", core_module);
    interp_bench_module.addImport("weld_etch", etch_module);
    interp_bench_module.addImport("fixture_facade", fixture_facade_module);
    const interp_bench_exe = b.addExecutable(.{
        .name = "etch-interp-bench",
        .root_module = interp_bench_module,
    });
    b.installArtifact(interp_bench_exe);
    const interp_bench_run = b.addRunArtifact(interp_bench_exe);
    interp_bench_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| interp_bench_run.addArgs(args);
    const interp_bench_step = b.step(
        "bench-etch-interp",
        "Run the S4 interpreter bench (pass `-- --smoke` for a CI sanity run)",
    );
    interp_bench_step.dependOn(&interp_bench_run.step);

    // ---------------------------------------------------- Etch parse bench --

    const etch_bench_module = b.createModule(.{
        .root_source_file = b.path("bench/etch_parse.zig"),
        .target = target,
        .optimize = optimize,
    });
    etch_bench_module.addImport("weld_etch", etch_module);
    etch_bench_module.addImport("corpus_facade", etch_corpus_module);
    const etch_bench_exe = b.addExecutable(.{
        .name = "etch-parse-bench",
        .root_module = etch_bench_module,
    });
    b.installArtifact(etch_bench_exe);

    const etch_bench_run = b.addRunArtifact(etch_bench_exe);
    etch_bench_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| etch_bench_run.addArgs(args);
    const etch_bench_step = b.step(
        "bench-etch",
        "Run the S3 Etch parse bench (pass `-- --smoke` for a CI sanity run)",
    );
    etch_bench_step.dependOn(&etch_bench_run.step);

    // --------------------------------------- S5 Etch → Zig codegen tool ---
    //
    // `tools/etch_cook` is a standalone CLI that runs the S5 codegen on a
    // list of `.etch` programs and emits a single consolidated `.zig`
    // file. The build invokes it once per corpus (the differential test
    // programs, the synthetic 100-file bench fixture) and exposes the
    // result as a Zig module for downstream test / bench binaries.

    const etch_cook_module = b.createModule(.{
        .root_source_file = b.path("tools/etch_cook/main.zig"),
        .target = b.graph.host,
        // Use the user-selected optimize so `zig build bench-etch-compile
        // -Doptimize=ReleaseSafe` builds the cook tool in the same mode
        // as the bench harness — otherwise metric (a) is dominated by
        // Debug-mode parser/type-checker cost and the gate is unreachable.
        .optimize = optimize,
    });
    etch_cook_module.addImport("weld_etch", etch_module);
    etch_cook_module.addImport("weld_core", core_module);
    const etch_cook_exe = b.addExecutable(.{
        .name = "etch_cook",
        .root_module = etch_cook_module,
    });
    b.installArtifact(etch_cook_exe);

    // Cook the 20 differential corpus programs into a single consolidated
    // `corpus_codegen.zig`. The driver test imports it via the
    // `corpus_codegen` module name.
    const cook_diff_run = b.addRunArtifact(etch_cook_exe);
    cook_diff_run.addArg("--output");
    const diff_codegen_path = cook_diff_run.addOutputFileArg("corpus_codegen.zig");
    for (codegen_corpus.programs) |p| {
        cook_diff_run.addArg(b.fmt("{s}={s}", .{ p.name, p.etch_path }));
    }

    const diff_codegen_module = b.createModule(.{
        .root_source_file = diff_codegen_path,
        .target = target,
        .optimize = optimize,
    });
    diff_codegen_module.addImport("weld_core", core_module);

    // Codegen-backed runner module — used by both the codegen diff test
    // and the synthetic bench (the latter compiles the cooked corpus
    // through `zig build` to measure compile-time wall-clock).
    const codegen_runner_module = b.createModule(.{
        .root_source_file = b.path("tests/etch_interp/runner_codegen.zig"),
        .target = target,
        .optimize = optimize,
    });
    codegen_runner_module.addImport("weld_core", core_module);
    codegen_runner_module.addImport("corpus_codegen", diff_codegen_module);

    // Build step that just executes the codegen diff binary.
    const codegen_diff_module = b.createModule(.{
        .root_source_file = b.path("tests/etch_interp/codegen_diff_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    codegen_diff_module.addImport("weld_core", core_module);
    codegen_diff_module.addImport("weld_etch", etch_module);
    codegen_diff_module.addImport("corpus_facade", etch_interp_corpus_module);
    codegen_diff_module.addImport("diff_runner", etch_interp_driver_module);
    codegen_diff_module.addImport("runner_codegen", codegen_runner_module);
    const codegen_diff_test = b.addTest(.{ .root_module = codegen_diff_module });
    const codegen_diff_run = b.addRunArtifact(codegen_diff_test);
    test_step.dependOn(&codegen_diff_run.step);
    const codegen_diff_step = b.step(
        "test-codegen-diff",
        "Run the S5 differential corpus through the Zig codegen runner",
    );
    codegen_diff_step.dependOn(&codegen_diff_run.step);

    // Parity test: same corpus, runs interpreter + codegen back-to-back.
    const codegen_parity_module = b.createModule(.{
        .root_source_file = b.path("tests/etch_interp/codegen_parity_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    codegen_parity_module.addImport("weld_core", core_module);
    codegen_parity_module.addImport("weld_etch", etch_module);
    codegen_parity_module.addImport("corpus_facade", etch_interp_corpus_module);
    codegen_parity_module.addImport("diff_runner", etch_interp_driver_module);
    codegen_parity_module.addImport("runner_interp", etch_interp_runner_module);
    codegen_parity_module.addImport("runner_codegen", codegen_runner_module);
    const codegen_parity_test = b.addTest(.{ .root_module = codegen_parity_module });
    test_step.dependOn(&b.addRunArtifact(codegen_parity_test).step);

    // ----------------------------------------- S5 etch_synth tool ------------

    const etch_synth_module = b.createModule(.{
        .root_source_file = b.path("tools/etch_synth/main.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const etch_synth_exe = b.addExecutable(.{
        .name = "etch_synth",
        .root_module = etch_synth_module,
    });
    const etch_synth_run = b.addRunArtifact(etch_synth_exe);
    etch_synth_run.has_side_effects = true;
    if (b.args) |args| etch_synth_run.addArgs(args);
    const etch_synth_step = b.step(
        "synth-100",
        "Regenerate bench/fixtures/synth_100/scripts from the deterministic seed",
    );
    etch_synth_step.dependOn(&etch_synth_run.step);

    // -------------------------------- S5 demo binary (run-demo-etch-codegen) --

    const cook_demo_run = b.addRunArtifact(etch_cook_exe);
    cook_demo_run.addArg("--output");
    const demo_codegen_path = cook_demo_run.addOutputFileArg("cooked_demo.zig");
    cook_demo_run.addArg("demo=bench/fixtures/demo_5_rules_codegen.etch");

    const cooked_demo_module = b.createModule(.{
        .root_source_file = demo_codegen_path,
        .target = target,
        .optimize = optimize,
    });
    cooked_demo_module.addImport("weld_core", core_module);

    const demo_codegen_module = b.createModule(.{
        .root_source_file = b.path("src/demo_etch_codegen.zig"),
        .target = target,
        .optimize = optimize,
    });
    demo_codegen_module.addImport("weld_core", core_module);
    demo_codegen_module.addImport("cooked_demo", cooked_demo_module);
    const demo_codegen_exe = b.addExecutable(.{
        .name = "demo-etch-codegen",
        .root_module = demo_codegen_module,
    });
    b.installArtifact(demo_codegen_exe);
    const demo_codegen_run = b.addRunArtifact(demo_codegen_exe);
    demo_codegen_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| demo_codegen_run.addArgs(args);
    const demo_codegen_step = b.step(
        "run-demo-etch-codegen",
        "Run the S5 codegen demo (cooks demo_5_rules_codegen.etch, runs 10 ticks)",
    );
    demo_codegen_step.dependOn(&demo_codegen_run.step);

    // ----------------------------- S5 compile-time bench (3 metrics) -------

    const compile_bench_module = b.createModule(.{
        .root_source_file = b.path("bench/etch_compile.zig"),
        .target = target,
        .optimize = optimize,
    });
    const compile_bench_exe = b.addExecutable(.{
        .name = "etch-compile-bench",
        .root_module = compile_bench_module,
    });
    b.installArtifact(compile_bench_exe);
    const compile_bench_run = b.addRunArtifact(compile_bench_exe);
    // Bench needs etch_cook on disk (path: zig-out/bin/etch_cook). Drive
    // the install step before the bench runs.
    compile_bench_run.step.dependOn(b.getInstallStep());
    if (b.args) |args| compile_bench_run.addArgs(args);
    const compile_bench_step = b.step(
        "bench-etch-compile",
        "Run the S5 compile-time bench (cook + cold + incremental, N=10; pass `-- --smoke` for CI)",
    );
    compile_bench_step.dependOn(&compile_bench_run.step);

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
