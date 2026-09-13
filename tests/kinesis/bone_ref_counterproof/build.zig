//! Standalone build for the bone-addressing counter-proof corpus.
//!
//! A sub-project on the declared-access corpus's idiom: it consumes the parent
//! engine through the `weld` path dependency, so the fixtures get a correctly
//! wired module graph without this file re-deriving the parent's.
//!
//! **Why a sub-project and not objects in the parent build.** Three of the four
//! fixtures must FAIL to compile, and a compile step that fails inside the
//! parent graph fails the parent build — so the failures are driven as
//! subprocesses, each with its own named step here.
//!
//! `zig build` with no argument builds ONLY the control, so the default is the
//! case that must succeed.

const std = @import("std");

/// Every fixture: its step name, its source file, and whether it must compile.
const Case = struct {
    step: []const u8,
    file: []const u8,
    must_compile: bool,
    description: []const u8,
};

const cases = [_]Case{
    .{
        .step = "control",
        .file = "control.zig",
        .must_compile = true,
        .description = "resolves by role and by literal name through BoneRef — must compile",
    },
    .{
        .step = "case-literal-name",
        .file = "case_literal_name.zig",
        .must_compile = false,
        .description = "names a bone with a bare string literal — must NOT compile",
    },
    .{
        .step = "case-raw-index",
        .file = "case_raw_index.zig",
        .must_compile = false,
        .description = "names a bone with a bare index — must NOT compile",
    },
    .{
        .step = "case-role-as-int",
        .file = "case_role_as_int.zig",
        .must_compile = false,
        .description = "builds a role from a bare integer ordinal — must NOT compile",
    },
    .{
        .step = "case-view-write",
        .file = "case_view_write.zig",
        .must_compile = false,
        .description = "writes into the hierarchy of a handed-out rig — must NOT compile",
    },
    .{
        .step = "case-view-deinit",
        .file = "case_view_deinit.zig",
        .must_compile = false,
        .description = "frees a handed-out rig — must NOT compile",
    },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const weld = b.dependency("weld", .{
        .target = target,
        .optimize = optimize,
    });

    for (cases) |case| {
        const mod = b.createModule(.{
            .root_source_file = b.path(case.file),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("weld_core", weld.module("weld_core"));
        mod.addImport("foundation", weld.module("foundation"));
        mod.addImport("weld_kinesis", weld.module("weld_kinesis"));
        mod.addImport("weld_interfaces_animation", weld.module("weld_interfaces_animation"));

        const obj = b.addObject(.{
            .name = case.step,
            .root_module = mod,
        });

        const step = b.step(case.step, case.description);
        step.dependOn(&obj.step);

        // The control is the only case in the default step: `zig build` here
        // must succeed, and it does so by building exactly the fixture that is
        // supposed to.
        if (case.must_compile) b.getInstallStep().dependOn(&obj.step);
    }
}
